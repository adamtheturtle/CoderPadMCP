//
//  PadAggregation.swift
//  CoderPadToolCore
//
//  The count / aggregate / compact transforms (#500). The executable pages the whole
//  pad list over the network; these pure functions do the filtering and tallying, so
//  "how many pads match X" returns a small answer instead of streaming every record
//  through the model.
//

import Foundation

public let maxPaginationTokenBytes = 256

/// Interprets a `next_page` value (an absolute/relative continuation URL, a string page
/// token, or a number in some responses); nil means there are no more pages. CoderPad's
/// published response shape uses an absolute URL, but the provider rebuilds requests
/// against the configured account origin rather than following a server-supplied URL
/// with credentials. Extracting only its `page` query value preserves that boundary.
/// Plain tokens remain compatible with proxies that return only the page value, and
/// positive whole numbers are accepted in JSON numeric forms (#1599). Booleans,
/// zero, negative values, and fractional values are not tokens.
public func nextPageToken(_ value: Any?) -> String? {
    if value is Bool {
        return nil
    }
    switch value {
    case let token as String:
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let page = components.queryItems?.first(where: { $0.name == "page" })?.value?
           .trimmingCharacters(in: .whitespacesAndNewlines),
           !page.isEmpty
        {
            return boundedPaginationToken(page)
        }
        return boundedPaginationToken(trimmed)

    case let number as Int:
        return number > 0 ? String(number) : nil

    case let number as NSNumber:
        let value = number.doubleValue
        guard value.isFinite, value > 0, value.rounded() == value,
              value <= Double(Int64.max)
        else { return nil }
        return String(Int64(value))

    default:
        return nil
    }
}

/// Tracks opaque pagination tokens for one scan. A token may be requested only once;
/// seeing it again means the upstream page chain has entered a cycle.
public struct PaginationTokenTracker: Sendable {
    private var seen: Set<String> = []

    public init() {}

    public mutating func accept(_ token: String) -> Bool {
        guard boundedPaginationToken(token) != nil else { return false }
        return seen.insert(token).inserted
    }
}

private func boundedPaginationToken(_ token: String) -> String? {
    token.utf8.count <= maxPaginationTokenBytes ? token : nil
}

public enum RecordIdentityDisposition: Equatable, Sendable {
    case accepted
    case duplicate
    case invalid
}

/// Deduplicates records across every page in one scan without retaining the records
/// themselves. Pads normally expose `id`; `slug` is accepted as the documented stable
/// fallback.
public struct RecordIdentityTracker: Sendable {
    private var seen: Set<String> = []

    public init() {}

    public mutating func acceptPad(_ pad: [String: Any]) -> RecordIdentityDisposition {
        guard let identity = stableIdentity(pad["id"]) ?? stableIdentity(pad["slug"]) else { return .invalid }

        return seen.insert(identity).inserted ? .accepted : .duplicate
    }

    public mutating func acceptQuestion(_ question: [String: Any]) -> RecordIdentityDisposition {
        let identity: String? = if let value = question["id"] as? Int, value > 0 {
            String(value)
        } else if let value = question["id"] as? String,
                  let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed > 0
        {
            String(parsed)
        } else {
            nil
        }
        guard let identity else { return .invalid }

        return seen.insert(identity).inserted ? .accepted : .duplicate
    }

    private func stableIdentity(_ raw: Any?) -> String? {
        if let value = validatedPadID(raw as? String) {
            let unsigned = value.first.map { $0 == "+" || $0 == "-" } == true
                ? value.dropFirst()
                : value[...]
            if !unsigned.isEmpty, unsigned.allSatisfy(\.isNumber) {
                return Int(value).map(String.init)
            }
            return value
        }
        if let value = raw as? Int, value > 0 {
            return String(value)
        }
        return nil
    }
}

/// Folds the API's pad-state synonyms onto one canonical spelling, mirroring the app's
/// `PadState(apiState:)`: the Interview API reports a live pad as "started" while the
/// tool catalog (and the app UI) say "active", so comparing raw strings would make the
/// documented filter value unmatchable (#1014). Values are trimmed first so a padded
/// API value like " started " doesn't become its own unknown group (#1601). Unknown
/// states pass through trimmed and lowercased.
public func canonicalPadState(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "started", "active", "running": "active"
    case "ended", "finished", "completed": "ended"
    case "pending", "draft": "pending"
    case let value: value
    }
}

/// Whether a pad passes the optional owner/state/language filters (case-insensitive
/// exact match; an empty/absent filter always passes). Both sides are trimmed so a
/// whitespace-padded tool argument matches like the config parsers do (#1600). The
/// state comparison folds API synonyms first, so `state:"active"` matches pads the
/// API reports as "started".
public func padMatches(_ pad: [String: Any], owner: String?, state: String?, language: String?) -> Bool {
    PadMatcher(owner: owner, state: state, language: language).matches(pad)
}

/// A pad filter with its criteria already normalized.
///
/// The filter values are constant for a whole list, but `padMatches` normalized them
/// again for every pad it was called on — trimming and lowercasing (and, for state,
/// folding synonyms) once per pad per field. Building the matcher once and reusing it
/// does that work a fixed three times instead of three times per pad (#2453).
public struct PadMatcher: Sendable {
    private let owner: String?
    private let state: String?
    private let language: String?

    public init(owner: String?, state: String?, language: String?) {
        // Every stored value is already in the form `matches` compares against, so the
        // per-pad side only has to normalize the pad's own field.
        self.owner = Self.prepared(owner)?.lowercased()
        self.state = Self.prepared(state).map(canonicalPadState)
        self.language = Self.prepared(language)?.lowercased()
    }

    /// The trimmed filter value, or nil when it is absent or blank (which matches all).
    private static func prepared(_ wanted: String?) -> String? {
        let cleaned = wanted?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned?.isEmpty ?? true) ? nil : cleaned
    }

    public func matches(_ pad: [String: Any]) -> Bool {
        equals(pad, "owner_email", owner) { $0.lowercased() }
            && equals(pad, "state", state, normalize: canonicalPadState)
            && equals(pad, "language", language) { $0.lowercased() }
    }

    private func equals(
        _ pad: [String: Any],
        _ field: String,
        _ wanted: String?,
        normalize: (String) -> String,
    ) -> Bool {
        guard let wanted else { return true }

        return (pad[field] as? String)
            .map { normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == wanted
    }
}

/// The error message for a 2xx list response whose JSON object lacks the expected records
/// array: an API schema change or a 200-wrapped proxy/error page must be surfaced, never
/// silently counted as zero rows (#829, #830, #1024, #1026). Only a stable body
/// identifier is returned so proxy pages cannot disclose credentials or personal data.
public func invalidListResponseMessage(_ path: String, expecting key: String, body: String) -> String {
    let message = "The \(path) response wasn't the expected JSON object with a \"\(key)\" "
        + "array; the upstream server may have returned a proxy or error page."
    return message + " [body-id: \(String(bodyIdentifier(body), radix: 16))]"
}

/// An HTTP failure safe to return to an assistant. The status remains visible, while
/// a stable body identifier lets logs correlate repeated upstream failures without
/// exposing any raw response text.
public func sanitizedHTTPErrorMessage(status: Int, body: String, context: String = "") -> String {
    let identifier = String(bodyIdentifier(body), radix: 16)
    return "HTTP \(status)\(context) [body-id: \(identifier)]"
}

/// Stable, non-cryptographic diagnostic identity for an untrusted response body.
private func bodyIdentifier(_ body: String) -> UInt64 {
    body.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
}

/// The UTC calendar prefix (YYYY-MM or YYYY-MM-DD, per `count`) of an ISO-8601
/// `created_at`. Parsing and reformatting in UTC keeps month/date bucketing and
/// filtering identical no matter which offset the source spelled the instant in —
/// the API can send non-UTC offsets while the app's cache re-encodes to "Z", and the
/// two must never bucket the same record differently (#1034, #1035). An unparseable
/// value has no trustworthy calendar prefix.
func utcCreatedPrefix(_ created: String, count: Int) -> String? {
    guard let date = iso8601Date(from: created) else { return nil }

    return String(DateParsers.utcDayFormatter.string(from: date).prefix(count))
}

/// Classification of a record's `created_at` for date-filtered scans.
public enum CreatedAtPresence: Equatable, Sendable {
    case absent
    case malformed
    case present
}

/// Whether `created_at` is absent, present-but-unparseable, or a usable timestamp.
public func createdAtPresence(_ record: [String: Any]) -> CreatedAtPresence {
    guard let raw = record["created_at"] as? String else { return .absent }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .absent }
    return iso8601Date(from: trimmed) == nil ? .malformed : .present
}

/// Shared parser/formatter instances: `DateFormatter` and `ISO8601DateFormatter`
/// are documented thread-safe on modern OS releases, and a count/aggregate scan
/// parses one date per record - allocating a fresh formatter each time dominated
/// large scans (#1605).
private enum DateParsers {
    static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ISO8601DateFormatter lacks a Sendable annotation but is documented
    /// thread-safe; these instances are configured once and only read after.
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()
}

/// Whether a record's `created_at` falls within an optional [after, before] range. Month
/// and date bounds are compared against the UTC-normalized prefix of `created_at`; full
/// ISO-8601 timestamps are parsed and compared as normalized instants. A record with no
/// `created_at` fails any present bound; empty/absent bounds always pass. Shared by the pad
/// and question count/aggregate tools.
public func withinDateRange(_ record: [String: Any], after: String?, before: String?) -> Bool {
    let created = ((record["created_at"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    func passes(_ bound: String?, isAfter: Bool) -> Bool {
        guard let bound, !bound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard !created.isEmpty else { return false }
        guard let dateBound = dateBound(from: bound) else { return false }

        switch dateBound {
        case let .month(value), let .day(value):
            guard let createdPrefix = utcCreatedPrefix(created, count: value.count) else { return false }

            return isAfter ? createdPrefix >= value : createdPrefix <= value

        case let .timestamp(value):
            guard let createdDate = iso8601Date(from: created) else { return false }

            return isAfter ? createdDate >= value : createdDate <= value
        }
    }

    return passes(after, isAfter: true) && passes(before, isAfter: false)
}

/// Validates optional created_at bounds before a count/aggregate scan. Supported
/// forms intentionally match `withinDateRange`: month (`YYYY-MM`), date
/// (`YYYY-MM-DD`), or an ISO-8601 timestamp.
public func dateBoundValidationError(after: String?, before: String?) -> String? {
    if let error = dateBoundValidationError(name: "created_after", value: after) {
        return error
    }
    if let error = dateBoundValidationError(name: "created_before", value: before) {
        return error
    }
    // An inverted range silently yields zero records, which reads as a legitimate
    // empty result (#1604). Month/date bounds compare as whole inclusive periods
    // (a before of 2025-01 spans all of January), matching `withinDateRange`.
    // Upper bounds use the next period's exclusive start so fractional final-second
    // timestamps remain representable (#153).
    if let after, let lower = dateBound(from: after).flatMap({ orderingInstant($0, isUpper: false) }),
       let before, let upper = dateBound(from: before).flatMap({ orderingInstant($0, isUpper: true) }),
       lower > upper
    {
        return "created_after must not be later than created_before."
    }
    return nil
}

/// The instant a bound occupies for range-ordering purposes: timestamps are exact,
/// month/date lower bounds are the period start, and month/date upper bounds are the
/// exclusive start of the next period (so the full inclusive filter window is ordered).
private func orderingInstant(_ bound: DateBound, isUpper: Bool) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    switch bound {
    case let .timestamp(date):
        return date

    case let .month(value):
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1])) else { return nil }
        guard isUpper else { return start }

        return calendar.date(byAdding: DateComponents(month: 1), to: start)

    case let .day(value):
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        guard isUpper else { return start }

        return calendar.date(byAdding: DateComponents(day: 1), to: start)
    }
}

private func dateBoundValidationError(name: String, value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard isSupportedDateBound(value) else {
        return "\(name) must be a valid YYYY-MM month, YYYY-MM-DD date, or ISO-8601 timestamp."
    }

    return nil
}

public func isSupportedDateBound(_ value: String) -> Bool {
    dateBound(from: value) != nil
}

private enum DateBound {
    case month(String)
    case day(String)
    case timestamp(Date)
}

private func dateBound(from value: String) -> DateBound? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if isValidMonthBound(trimmed) {
        return .month(trimmed)
    }
    if isValidDateBound(trimmed) {
        return .day(trimmed)
    }
    if let date = iso8601Date(from: trimmed) {
        return .timestamp(date)
    }
    return nil
}

private func iso8601Date(from value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard hasValidISO8601Offset(trimmed), hasValidTimestampComponents(trimmed) else { return nil }
    return DateParsers.iso8601.date(from: trimmed)
        ?? DateParsers.iso8601Fractional.date(from: trimmed)
}

/// Rejects impossible timezone offsets such as `+24:00` or `+99:99` before Foundation
/// normalizes them into unrelated instants.
private func hasValidISO8601Offset(_ value: String) -> Bool {
    if value.hasSuffix("Z") || value.hasSuffix("z") { return true }
    guard let index = value.lastIndex(where: { $0 == "+" || $0 == "-" }),
          index > value.startIndex,
          value[..<index].contains(where: { $0 == "T" || $0 == "t" })
    else { return false }

    let offset = value[value.index(after: index)...]
    if offset.count == 5, offset[offset.index(offset.startIndex, offsetBy: 2)] == ":" {
        let hours = offset.prefix(2)
        let minutes = offset.suffix(2)
        guard hours.allSatisfy(\.isNumber), minutes.allSatisfy(\.isNumber),
              let hour = Int(hours), let minute = Int(minutes),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        else { return false }
        return true
    }
    if offset.count == 4, offset.allSatisfy(\.isNumber) {
        guard let hour = Int(offset.prefix(2)), let minute = Int(offset.suffix(2)),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        else { return false }
        return true
    }
    return false
}

/// Rejects calendar-impossible timestamps that Foundation would otherwise normalize
/// (for example `2026-02-30` or `T24:00:00`).
private func hasValidTimestampComponents(_ value: String) -> Bool {
    guard let tIndex = value.firstIndex(of: "T") ?? value.firstIndex(of: "t") else { return false }
    let datePart = value[..<tIndex]
    let timeAndZone = value[value.index(after: tIndex)...]
    guard datePart.count == 10,
          let timeEnd = timeAndZone.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "z" })
    else { return false }

    let timePart = timeAndZone[..<timeEnd]
    let timePieces = timePart.split(separator: ":", omittingEmptySubsequences: false)
    guard timePieces.count >= 2,
          let year = Int(datePart.prefix(4)),
          let month = Int(datePart.dropFirst(5).prefix(2)),
          let day = Int(datePart.suffix(2)),
          let hour = Int(timePieces[0]),
          let minute = Int(timePieces[1]),
          (0 ... 23).contains(hour),
          (0 ... 59).contains(minute)
    else { return false }

    let secondFragment = timePieces.count >= 3 ? timePieces[2] : "0"
    let secondPieces = secondFragment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let second = Int(secondPieces[0]), (0 ... 59).contains(second) else { return false }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    let components = DateComponents(
        calendar: calendar, timeZone: calendar.timeZone,
        year: year, month: month, day: day,
    )
    guard let date = calendar.date(from: components) else { return false }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    return resolved.year == year && resolved.month == month && resolved.day == day
}

private func isValidMonthBound(_ value: String) -> Bool {
    guard value.count == 7, value[value.index(value.startIndex, offsetBy: 4)] == "-",
          let month = Int(value.suffix(2)),
          isASCIIYear(value.prefix(4)),
          (1 ... 12).contains(month)
    else { return false }

    return true
}

private func isValidDateBound(_ value: String) -> Bool {
    guard value.count == 10,
          value[value.index(value.startIndex, offsetBy: 4)] == "-",
          value[value.index(value.startIndex, offsetBy: 7)] == "-",
          isASCIIYear(value.prefix(4))
    else { return false }

    let parts = value.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2])
    else { return false }

    var calendar = Calendar(identifier: .gregorian)
    if let utc = TimeZone(secondsFromGMT: 0) {
        calendar.timeZone = utc
    }
    let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return false }

    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    return resolved.year == year && resolved.month == month && resolved.day == day
}

private func isASCIIYear(_ value: Substring) -> Bool {
    let scalars = value.unicodeScalars
    return scalars.count == 4 && scalars.allSatisfy { (48 ... 57).contains($0.value) }
}

/// Adds active `created_after`/`created_before` bounds to a filters echo.
public func addDateFilters(_ filters: inout [String: Any], after: String?, before: String?) {
    if let after = normalizedFilterValue(after) {
        filters["created_after"] = after
    }
    if let before = normalizedFilterValue(before) {
        filters["created_before"] = before
    }
}

/// Echoes the active filters back into a result, for clarity on what was counted.
public func filtersEcho(owner: String?, state: String?, language: String?) -> [String: Any] {
    var filters: [String: Any] = [:]
    if let owner = normalizedFilterValue(owner) {
        filters["owner"] = owner
    }
    if let state = normalizedFilterValue(state) {
        filters["state"] = state
    }
    if let language = normalizedFilterValue(language) {
        filters["language"] = language
    }
    return filters
}

public func normalizedFilterValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }

    return value
}

/// Normalizes a user-facing `group_by` to a pad field, or nil when unsupported. The
/// special value "month" buckets by the year-month of created_at.
public func aggregateField(for groupBy: String) -> String? {
    switch groupBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "owner", "owner_email": "owner_email"
    case "language": "language"
    case "state": "state"
    case "month", "created_at": "month"
    default: nil
    }
}

/// Tallies pads into { groupKey: count } for a normalized field. "month" buckets by
/// the first 7 chars of created_at (YYYY-MM); "state" buckets by the canonical state
/// spelling (so a group value can be fed straight back as a filter); missing/empty
/// values bucket as "unknown".
/// Group-key sanity caps (#1606): remote fields are untrusted, and unbounded keys or
/// cardinality can allocate massive maps and return huge payloads even after
/// `topGroups` trims the answer. Overflow groups tally under "other".
public let maxAggregateGroups = 1000
public let maxAggregateKeyLength = 128
public let aggregateOverflowGroup = "__additional_groups__"
public let aggregateMissingGroup = "__missing_value__"
public let aggregateLiteralPrefix = "literal:"

public struct AggregateAccumulation: Equatable, Sendable {
    public var counts: [String: Int]
    /// True cardinality of distinct group keys, including values folded into the overflow bucket.
    public var distinctGroups: Int
    /// Keys already folded into ``aggregateOverflowGroup`` so repeats are not re-counted.
    var foldedKeys: Set<String>

    public init(counts: [String: Int] = [:], distinctGroups: Int = 0, foldedKeys: Set<String> = []) {
        self.counts = counts
        self.distinctGroups = distinctGroups
        self.foldedKeys = foldedKeys
    }
}

public func aggregateCounts(pads: [[String: Any]], field: String) -> [String: Int] {
    var accumulation = AggregateAccumulation()
    accumulateCounts(&accumulation, pads: pads, field: field)
    return accumulation.counts
}

/// The page-at-a-time form of `aggregateCounts`: tallies `pads` into an existing map so
/// a caller paging a whole org can keep only the running totals instead of retaining
/// every record just to group it afterwards (#2121). The cardinality cap is applied to
/// the running map, so the result matches tallying the same rows in one go.
public func accumulateCounts(_ counts: inout [String: Int], pads: [[String: Any]], field: String) {
    var accumulation = AggregateAccumulation(counts: counts, distinctGroups: counts.count)
    accumulateCounts(&accumulation, pads: pads, field: field)
    counts = accumulation.counts
}

public func accumulateCounts(
    _ accumulation: inout AggregateAccumulation,
    pads: [[String: Any]],
    field: String,
) {
    for pad in pads {
        var key: String
        var isMissing = false
        if field == "month" {
            let created = ((pad["created_at"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let month = utcCreatedPrefix(created, count: 7) {
                key = month
            } else {
                key = aggregateMissingGroup
                isMissing = true
            }
        } else {
            let raw = (pad[field] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if let raw {
                key = switch field {
                case "state": canonicalPadState(raw)
                case "owner_email", "author_name", "language": raw.lowercased()
                case "pad_type": canonicalInterviewType(raw)
                default: raw
                }
            } else {
                key = aggregateMissingGroup
                isMissing = true
            }
        }
        key = boundedAggregateKey(key)
        if !isMissing {
            key = escapeAggregateSentinel(key)
        }
        let atCapacity = accumulation.counts[aggregateOverflowGroup] != nil
            || accumulation.counts.count >= maxAggregateGroups - 1
        if let existing = accumulation.counts[key] {
            accumulation.counts[key] = existing + 1
        } else if accumulation.foldedKeys.contains(key) {
            accumulation.counts[aggregateOverflowGroup, default: 0] += 1
        } else if atCapacity {
            accumulation.distinctGroups += 1
            accumulation.foldedKeys.insert(key)
            accumulation.counts[aggregateOverflowGroup, default: 0] += 1
        } else {
            accumulation.distinctGroups += 1
            accumulation.counts[key] = 1
        }
    }
}

/// Tags literal values that would otherwise collide with sentinel group names.
private func escapeAggregateSentinel(_ key: String) -> String {
    if key == aggregateMissingGroup
        || key == aggregateOverflowGroup
        || key.hasPrefix(aggregateLiteralPrefix)
    {
        return aggregateLiteralPrefix + key
    }
    return key
}

/// Keeps untrusted display keys bounded without merging values that share a prefix.
/// The stable whole-value identifier preserves their distinct identities.
private func boundedAggregateKey(_ key: String) -> String {
    guard key.count > maxAggregateKeyLength else { return key }

    let suffix = "… [id: \(String(bodyIdentifier(key), radix: 16))]"
    return String(key.prefix(maxAggregateKeyLength - suffix.count)) + suffix
}

/// A single aggregation bucket: the group value and its count.
public struct AggregateGroup: Equatable {
    public let value: String
    public let count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// Sorts counts by count descending, then key ascending (deterministic), and caps to
/// `limit` groups. The limit is clamped to 0...maxAggregateGroups so a negative or
/// enormous caller value can't trap or return every high-cardinality group (#1607).
public func topGroups(_ counts: [String: Int], limit: Int) -> [AggregateGroup] {
    let clamped = min(max(limit, 0), maxAggregateGroups)
    let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    return sorted.prefix(clamped).map { AggregateGroup(value: $0.key, count: $0.value) }
}

/// The fields kept by list_pads_compact, dropping the verbose blob so far more rows
/// fit per response.
public let compactPadKeys = ["id", "title", "owner_email", "state", "language", "created_at"]
public let maxCompactScalarCharacters = 1000
public let maxCompactScalarUTF8Bytes = 4000

/// Projects pads down to the compact key set. Only scalar values survive (#1608):
/// a response nesting a huge object under an allowed key would defeat the entire
/// point of the compact projection.
public func compactPads(_ pads: [[String: Any]]) -> [[String: Any]] {
    pads.map { pad in
        var row: [String: Any] = [:]
        for key in compactPadKeys {
            if let value = compactScalar(pad[key]) {
                row[key] = value
            }
        }
        return row
    }
}

/// Bounded scalar pagination metadata for compact list tools.
public func compactPaginationMetadata(_ value: Any?) -> Any? {
    switch value {
    case is NSNull:
        return nil
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue >= Double(Int64.min),
              doubleValue <= Double(Int64.max),
              doubleValue.rounded() == doubleValue
        else { return nil }
        return Int64(doubleValue)
    case let string as String:
        return compactScalar(string)
    default:
        return nil
    }
}

/// The scalar (string/number/bool/null) form of a compact-row value, with strings
/// capped by character and UTF-8 budgets; nested arrays/objects are dropped rather
/// than copied through (#1608, #181, #182).
func compactScalar(_ value: Any?) -> Any? {
    switch value {
    case let string as String:
        truncateCompactString(string)
    case let number as NSNumber:
        number
    case is NSNull:
        NSNull()
    default:
        nil
    }
}

func truncateCompactString(_ string: String) -> String {
    if string.count <= maxCompactScalarCharacters, string.utf8.count <= maxCompactScalarUTF8Bytes {
        return string
    }

    let ellipsis = "…"
    let maxBodyCharacters = maxCompactScalarCharacters - 1
    let maxBodyUTF8 = maxCompactScalarUTF8Bytes - ellipsis.utf8.count
    var characterCount = 0
    var byteCount = 0
    var end = string.startIndex
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(after: index)
        let scalarBytes = string[index ..< next].utf8.count
        if characterCount + 1 > maxBodyCharacters || byteCount + scalarBytes > maxBodyUTF8 {
            break
        }
        characterCount += 1
        byteCount += scalarBytes
        end = next
        index = next
    }
    return String(string[..<end]) + ellipsis
}
