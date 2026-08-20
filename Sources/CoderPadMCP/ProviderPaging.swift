//
//  ProviderPaging.swift
//  CoderPadMCP
//
//  Internal paging, count, aggregate, and compact-list tools for pads and questions.
//

import Foundation
import MCP

// MARK: - count_pads / aggregate_pads / list_pads_compact (#500)

/// Safety cap on internal paging so a huge org (or a paging bug) can't loop forever.
/// At ~50 pads/page this covers 25k pads; if hit, the result reports it as truncated
/// rather than silently capping.
private let maxPadPagesToFetch = 500

/// At most this many groups are returned by aggregate_pads; if there are more, the top
/// ones by count are returned and the result flags that it was truncated.
private let maxReturnedAggregateGroups = 200

/// The accumulated result of paging the whole pad list internally. Only the totals are
/// kept: the pages themselves are handed to the caller's tally as they arrive (#2121).
private struct PadPageScan {
    var scanned = 0
    var totalReported: Int?
    var pagesFetched = 0
    var truncated = false
    var error: APIResponse?
    var paginationError: String?
    var recordError: String?
    /// Set when a 2xx page decoded to JSON but lacked the expected records array —
    /// an API schema change or 200-wrapped error page, which must be surfaced rather
    /// than silently counted as zero rows (#1024).
    var invalidShape: String?
}

/// Pages `/api/pads/` from the first page following `next_page`, handing each page to
/// `consume`, so the count/aggregate tools can tally in-process and return a small answer
/// instead of streaming thousands of records through the model. Pages are tallied and
/// then dropped rather than retained, so a huge org does not sit in memory purely to be
/// filtered once at the end (#2121).
private func fetchAllPads(
    account: MCPAccount,
    cache: CoderPadMCPCache?,
    consume: ([[String: Any]]) -> Void,
) async throws -> PadPageScan {
    if let pads = cachedRecords(.pads, account: account, requireFresh: true, cache: cache) {
        return consumeUniquePads(pads, into: PadPageScan(), consume: consume)
    }

    var scan = PadPageScan()
    var page: String?
    var tokens = PaginationTokenTracker()
    var records = RecordIdentityTracker()
    while scan.pagesFetched < maxPadPagesToFetch {
        var query: [URLQueryItem] = []
        if let page {
            query.append(URLQueryItem(name: "page", value: page))
        }
        let response = try await apiGet("/api/pads/", account: account, query: query)
        guard response.ok, let object = jsonObject(response.data) else {
            scan.error = response
            return scan
        }
        guard let pads = object["pads"] as? [[String: Any]] else {
            scan.invalidShape = invalidListResponseMessage("/api/pads/", expecting: "pads", body: response.body)
            return scan
        }

        var unique: [[String: Any]] = []
        for pad in pads {
            switch records.acceptPad(pad) {
            case .accepted: unique.append(pad)
            case .duplicate: continue
            case .invalid:
                scan.recordError = "Pad pagination returned a record without a usable id or slug; the scan is incomplete."
                return scan
            }
        }

        if scan.totalReported == nil {
            scan.totalReported = reportedListTotal(object["total"])
        }
        consume(unique)
        scan.scanned += unique.count
        scan.pagesFetched += 1
        switch nextPageContinuation(object["next_page"]) {
        case .finished:
            return finalizePadScan(scan)
        case let .page(next):
            guard tokens.accept(next) else {
                scan.paginationError = "Pad pagination repeated next_page token \"\(next)\"; the scan is incomplete."
                return scan
            }
            page = next
        case .malformed:
            scan.paginationError = "Pad pagination returned a malformed next_page; the scan is incomplete."
            return scan
        }
    }

    scan.truncated = true
    return scan
}

/// Applies the same identity validation and deduplication used for network pages to a
/// fresh cache array (#119).
private func consumeUniquePads(
    _ pads: [[String: Any]],
    into scan: PadPageScan,
    consume: ([[String: Any]]) -> Void,
) -> PadPageScan {
    var scan = scan
    var records = RecordIdentityTracker()
    var unique: [[String: Any]] = []
    for pad in pads {
        switch records.acceptPad(pad) {
        case .accepted: unique.append(pad)
        case .duplicate: continue
        case .invalid:
            scan.recordError = "Pad pagination returned a record without a usable id or slug; the scan is incomplete."
            return scan
        }
    }
    consume(unique)
    scan.scanned = unique.count
    scan.totalReported = unique.count
    return scan
}

/// When pagination ends, fail if a trustworthy API total proves records were skipped (#117).
private func finalizePadScan(_ scan: PadPageScan) -> PadPageScan {
    var scan = scan
    if let total = scan.totalReported, total > scan.scanned {
        scan.paginationError = "Pad pagination ended early: the API reported \(total) pads but only "
            + "\(scan.scanned) were reached; the scan is incomplete."
    }
    return scan
}

/// A non-negative whole total from a list response, or nil when missing/malformed so
/// unfiltered counts can fall back to a full scan (#165, #166).
private func reportedListTotal(_ value: Any?) -> Int? {
    if value is Bool {
        return nil
    }
    if let number = value as? Int, number >= 0 {
        return number
    }
    if let number = value as? NSNumber {
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue >= 0, doubleValue.rounded() == doubleValue,
              doubleValue <= Double(Int.max)
        else { return nil }
        return Int(doubleValue)
    }
    return nil
}

private func padFilterTypeError(_ arguments: [String: Value]?) -> String? {
    guard let invalid = invalidPresentStringArgument(
        arguments,
        names: ["owner", "state", "language", "created_after", "created_before"],
    ) else { return nil }
    return "\(invalid) must be a string."
}

private func questionFilterTypeError(_ arguments: [String: Value]?) -> String? {
    guard let invalid = invalidPresentStringArgument(
        arguments,
        names: ["owner", "author", "language", "type", "created_after", "created_before"],
    ) else { return nil }
    return "\(invalid) must be a string."
}

private func listSortTypeError(_ arguments: [String: Value]?) -> String? {
    guard let invalid = invalidPresentStringArgument(arguments, names: ["sort"]) else { return nil }
    return "\(invalid) must be a string."
}

/// True when any count/aggregate filter would narrow the result set.
private func hasActivePadFilters(
    owner: String?,
    state: String?,
    language: String?,
    after: String?,
    before: String?,
) -> Bool {
    normalizedFilterValue(owner) != nil
        || normalizedFilterValue(state) != nil
        || normalizedFilterValue(language) != nil
        || normalizedFilterValue(after) != nil
        || normalizedFilterValue(before) != nil
}

private func hasActiveQuestionFilters(
    owner: String?,
    author: String?,
    language: String?,
    type: String?,
    after: String?,
    before: String?,
) -> Bool {
    normalizedFilterValue(owner) != nil
        || normalizedFilterValue(author) != nil
        || normalizedFilterValue(language) != nil
        || normalizedFilterValue(type) != nil
        || normalizedFilterValue(after) != nil
        || normalizedFilterValue(before) != nil
}

func countPads(
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "owner", "state", "language", "created_after", "created_before"],
    ) {
        return errorResult(error)
    }
    if let error = padFilterTypeError(arguments) {
        return errorResult(error)
    }
    let owner = stringArgument(arguments, "owner")
    let state = stringArgument(arguments, "state")
    let language = stringArgument(arguments, "language")
    let after = stringArgument(arguments, "created_after")
    let before = stringArgument(arguments, "created_before")
    if let error = dateBoundValidationError(after: after, before: before) {
        return errorResult(error)
    }
    let dateFilterActive = normalizedFilterValue(after) != nil || normalizedFilterValue(before) != nil

    if !hasActivePadFilters(owner: owner, state: state, language: language, after: after, before: before) {
        if let shortCircuit = try await unfilteredCountFromFirstPage(
            path: "/api/pads/",
            recordsKey: "pads",
            account: account,
            cacheKind: .pads,
            cache: cache,
        ) {
            return shortCircuit
        }
    }

    // Built once for the whole list rather than re-normalizing the filter
    // values for every row (#2453).
    let matcher = PadMatcher(owner: owner, state: state, language: language)
    var matched = 0
    var unusableCreatedAt = 0
    let scan = try await fetchAllPads(account: account, cache: cache) { pads in
        for pad in pads where matcher.matches(pad) {
            if dateFilterActive {
                switch createdAtPresence(pad) {
                case .absent, .malformed:
                    unusableCreatedAt += 1
                    continue
                case .present:
                    break
                }
            }
            if withinDateRange(pad, after: after, before: before) {
                matched += 1
            }
        }
    }
    if let error = scan.error {
        return toolResult(error)
    }
    if let message = scan.invalidShape {
        return errorResult(message)
    }
    if let message = scan.paginationError {
        return errorResult(message)
    }
    if let message = scan.recordError {
        return errorResult(message)
    }

    var result: [String: Any] = [
        "matched": matched,
        "scanned": scan.scanned,
        "pages_fetched": scan.pagesFetched,
        "truncated": scan.truncated,
    ]
    if let total = scan.totalReported {
        result["total_reported_by_api"] = total
    }
    var filters = filtersEcho(owner: owner, state: state, language: language)
    addDateFilters(&filters, after: after, before: before)
    if !filters.isEmpty {
        result["filters"] = filters
    }
    if dateFilterActive, unusableCreatedAt > 0 {
        result["unusable_created_at"] = unusableCreatedAt
        result["date_filter_incomplete"] = true
    }
    if scan.truncated {
        result["note"] = "Hit the internal page cap (\(maxPadPagesToFetch) pages); the count covers only the pads scanned."
    }

    return jsonResult(result)
}

/// Uses the first list page's authoritative `total` for an unfiltered count when the
/// value is trustworthy; otherwise returns nil so the caller can fall back to a full
/// scan (#165, #166).
private func unfilteredCountFromFirstPage(
    path: String,
    recordsKey: String,
    account: MCPAccount,
    cacheKind: CoderPadMCPRecordKind,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result? {
    if let cached = cachedRecords(cacheKind, account: account, requireFresh: true, cache: cache) {
        var records = RecordIdentityTracker()
        var unique = 0
        for record in cached {
            switch cacheKind {
            case .pads:
                switch records.acceptPad(record) {
                case .accepted: unique += 1
                case .duplicate: continue
                case .invalid:
                    return errorResult(
                        "Pad pagination returned a record without a usable id or slug; the scan is incomplete.",
                    )
                }
            case .questions:
                switch records.acceptQuestion(record) {
                case .accepted: unique += 1
                case .duplicate: continue
                case .invalid:
                    return errorResult(
                        "Question pagination returned a record without a positive id; the scan is incomplete.",
                    )
                }
            }
        }
        return jsonResult([
            "matched": unique,
            "scanned": unique,
            "pages_fetched": 0,
            "truncated": false,
            "total_reported_by_api": unique,
        ])
    }

    let response = try await apiGet(path, account: account)
    guard response.ok, let object = jsonObject(response.data) else {
        return toolResult(response)
    }
    guard object[recordsKey] is [[String: Any]] else {
        return errorResult(invalidListResponseMessage(path, expecting: recordsKey, body: response.body))
    }
    guard let total = reportedListTotal(object["total"]) else {
        return nil
    }
    return jsonResult([
        "matched": total,
        "scanned": total,
        "pages_fetched": 1,
        "truncated": false,
        "total_reported_by_api": total,
    ])
}

func aggregatePadsTool(
    groupBy: String,
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "group_by", "owner", "state", "language", "created_after", "created_before"],
    ) {
        return errorResult(error)
    }

    guard let field = aggregateField(for: groupBy) else {
        return CallTool.Result(
            content: [.text(
                text: "Unsupported group_by \"\(groupBy)\". Use owner, language, state, or month.",
                annotations: nil, _meta: nil,
            )],
            isError: true,
        )
    }

    if let error = padFilterTypeError(arguments) {
        return errorResult(error)
    }
    let owner = stringArgument(arguments, "owner")
    let state = stringArgument(arguments, "state")
    let language = stringArgument(arguments, "language")
    let after = stringArgument(arguments, "created_after")
    let before = stringArgument(arguments, "created_before")
    if let error = dateBoundValidationError(after: after, before: before) {
        return errorResult(error)
    }

    // Built once for the whole list rather than re-normalizing the filter
    // values for every row (#2453).
    let matcher = PadMatcher(owner: owner, state: state, language: language)
    let dateFilterActive = normalizedFilterValue(after) != nil || normalizedFilterValue(before) != nil
    var matched = 0
    var unusableCreatedAt = 0
    var accumulation = AggregateAccumulation()
    let scan = try await fetchAllPads(account: account, cache: cache) { pads in
        let page = pads.filter { pad in
            guard matcher.matches(pad) else { return false }
            if dateFilterActive {
                switch createdAtPresence(pad) {
                case .absent, .malformed:
                    unusableCreatedAt += 1
                    return false
                case .present:
                    break
                }
            }
            return withinDateRange(pad, after: after, before: before)
        }
        matched += page.count
        accumulateCounts(&accumulation, pads: page, field: field)
    }
    if let error = scan.error {
        return toolResult(error)
    }
    if let message = scan.invalidShape {
        return errorResult(message)
    }
    if let message = scan.paginationError {
        return errorResult(message)
    }
    if let message = scan.recordError {
        return errorResult(message)
    }

    let capped = topGroups(accumulation.counts, limit: maxReturnedAggregateGroups)
    let groups: [[String: Any]] = capped.map { ["value": $0.value, "count": $0.count] }

    var result: [String: Any] = [
        "group_by": field,
        "matched": matched,
        "scanned": scan.scanned,
        "distinct_groups": accumulation.distinctGroups,
        "groups": groups,
        "pages_fetched": scan.pagesFetched,
        "truncated": scan.truncated,
    ]
    var filters = filtersEcho(owner: owner, state: state, language: language)
    addDateFilters(&filters, after: after, before: before)
    if !filters.isEmpty {
        result["filters"] = filters
    }
    if accumulation.counts[aggregateOverflowGroup] != nil {
        result["distinct_groups_includes_overflow"] = true
    }
    if dateFilterActive, unusableCreatedAt > 0 {
        result["unusable_created_at"] = unusableCreatedAt
        result["date_filter_incomplete"] = true
    }
    if accumulation.counts.count > capped.count {
        result["groups_truncated"] = true
        result["note"] = "Showing the top \(capped.count) of \(accumulation.counts.count) groups by count."
    }
    if scan.truncated {
        result["page_cap_note"] = "Hit the internal page cap (\(maxPadPagesToFetch) pages); the aggregation covers only the pads scanned."
    }

    return jsonResult(result)
}

func listPads(arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    if let error = pageValidationError(strictIntArgument(arguments, "page")) {
        return errorResult(error)
    }
    if let error = listSortTypeError(arguments) {
        return errorResult(error)
    }
    if let error = pagingSortValidationError(stringArgument(arguments, "sort")) {
        return errorResult(error)
    }

    return try await toolResult(apiGet("/api/pads/", account: account, query: pagingQuery(arguments)))
}

func listPadsCompact(arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "page", "sort"],
    ) {
        return errorResult(error)
    }

    if let error = pageValidationError(strictIntArgument(arguments, "page")) {
        return errorResult(error)
    }
    if let error = listSortTypeError(arguments) {
        return errorResult(error)
    }
    if let error = pagingSortValidationError(stringArgument(arguments, "sort")) {
        return errorResult(error)
    }

    let response = try await apiGet("/api/pads/", account: account, query: pagingQuery(arguments))
    guard response.ok, let object = jsonObject(response.data) else { return toolResult(response) }
    guard let pads = object["pads"] as? [[String: Any]] else {
        return errorResult(invalidListResponseMessage("/api/pads/", expecting: "pads", body: response.body))
    }

    var identities = RecordIdentityTracker()
    var valid: [[String: Any]] = []
    var malformed = 0
    for pad in pads {
        switch identities.acceptPad(pad) {
        case .accepted:
            valid.append(pad)
        case .duplicate:
            continue
        case .invalid:
            malformed += 1
        }
    }

    let compact = compactPads(valid)

    var result: [String: Any] = ["pads": compact, "count": compact.count]
    if malformed > 0 {
        result["malformed_records"] = malformed
        result["incomplete"] = true
    }
    if let next = compactPaginationMetadata(object["next_page"]) {
        result["next_page"] = next
    }
    if let total = compactPaginationMetadata(object["total"]) {
        result["total"] = total
    }

    return jsonResult(result)
}

// MARK: - count_questions / aggregate_questions / list_questions_compact (#500)

/// The accumulated result of paging the whole question bank internally. See
/// `PadPageScan`: only the totals are kept (#2121).
private struct QuestionPageScan {
    var scanned = 0
    var totalReported: Int?
    var pagesFetched = 0
    var truncated = false
    var error: APIResponse?
    var paginationError: String?
    var recordError: String?
    /// See `PadPageScan.invalidShape` (#1024).
    var invalidShape: String?
}

/// Pages `/api/questions/` from the first page following `next_page`, handing each page
/// to `consume`, so the count/aggregate tools can tally in-process and return a small
/// answer instead of streaming thousands of records through the model. Pages are tallied
/// and then dropped rather than retained (#2121).
private func fetchAllQuestions(
    account: MCPAccount,
    cache: CoderPadMCPCache?,
    consume: ([[String: Any]]) -> Void,
) async throws -> QuestionPageScan {
    if let questions = cachedRecords(.questions, account: account, requireFresh: true, cache: cache) {
        return consumeUniqueQuestions(questions, into: QuestionPageScan(), consume: consume)
    }

    var scan = QuestionPageScan()
    var page: String?
    var tokens = PaginationTokenTracker()
    var records = RecordIdentityTracker()
    while scan.pagesFetched < maxPadPagesToFetch {
        var query: [URLQueryItem] = []
        if let page {
            query.append(URLQueryItem(name: "page", value: page))
        }
        let response = try await apiGet("/api/questions/", account: account, query: query)
        guard response.ok, let object = jsonObject(response.data) else {
            scan.error = response
            return scan
        }
        guard let questions = object["questions"] as? [[String: Any]] else {
            scan.invalidShape = invalidListResponseMessage(
                "/api/questions/", expecting: "questions", body: response.body,
            )
            return scan
        }

        var unique: [[String: Any]] = []
        for question in questions {
            switch records.acceptQuestion(question) {
            case .accepted: unique.append(question)
            case .duplicate: continue
            case .invalid:
                scan.recordError = "Question pagination returned a record without a positive id; the scan is incomplete."
                return scan
            }
        }

        if scan.totalReported == nil {
            scan.totalReported = reportedListTotal(object["total"])
        }
        consume(unique)
        scan.scanned += unique.count
        scan.pagesFetched += 1
        switch nextPageContinuation(object["next_page"]) {
        case .finished:
            return finalizeQuestionScan(scan)
        case let .page(next):
            guard tokens.accept(next) else {
                scan.paginationError = "Question pagination repeated next_page token \"\(next)\"; the scan is incomplete."
                return scan
            }
            page = next
        case .malformed:
            scan.paginationError = "Question pagination returned a malformed next_page; the scan is incomplete."
            return scan
        }
    }

    scan.truncated = true
    return scan
}

private func consumeUniqueQuestions(
    _ questions: [[String: Any]],
    into scan: QuestionPageScan,
    consume: ([[String: Any]]) -> Void,
) -> QuestionPageScan {
    var scan = scan
    var records = RecordIdentityTracker()
    var unique: [[String: Any]] = []
    for question in questions {
        switch records.acceptQuestion(question) {
        case .accepted: unique.append(question)
        case .duplicate: continue
        case .invalid:
            scan.recordError = "Question pagination returned a record without a positive id; the scan is incomplete."
            return scan
        }
    }
    consume(unique)
    scan.scanned = unique.count
    scan.totalReported = unique.count
    return scan
}

private func finalizeQuestionScan(_ scan: QuestionPageScan) -> QuestionPageScan {
    var scan = scan
    if let total = scan.totalReported, total > scan.scanned {
        scan.paginationError = "Question pagination ended early: the API reported \(total) questions but only "
            + "\(scan.scanned) were reached; the scan is incomplete."
    }
    return scan
}

func countQuestions(
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "owner", "author", "language", "type", "created_after", "created_before"],
    ) {
        return errorResult(error)
    }

    if let error = questionFilterTypeError(arguments) {
        return errorResult(error)
    }
    let owner = stringArgument(arguments, "owner")
    let author = stringArgument(arguments, "author")
    let language = stringArgument(arguments, "language")
    let type = stringArgument(arguments, "type")
    let after = stringArgument(arguments, "created_after")
    let before = stringArgument(arguments, "created_before")
    if let error = dateBoundValidationError(after: after, before: before) {
        return errorResult(error)
    }

    if !hasActiveQuestionFilters(
        owner: owner, author: author, language: language, type: type, after: after, before: before,
    ) {
        if let shortCircuit = try await unfilteredCountFromFirstPage(
            path: "/api/questions/",
            recordsKey: "questions",
            account: account,
            cacheKind: .questions,
            cache: cache,
        ) {
            return shortCircuit
        }
    }

    // Built once for the whole list rather than re-normalizing the filter
    // values for every row (#2452).
    let matcher = QuestionMatcher(owner: owner, author: author, language: language, type: type)
    let dateFilterActive = normalizedFilterValue(after) != nil || normalizedFilterValue(before) != nil
    var matched = 0
    var unusableCreatedAt = 0
    let scan = try await fetchAllQuestions(account: account, cache: cache) { questions in
        for question in questions where matcher.matches(question) {
            if dateFilterActive {
                switch createdAtPresence(question) {
                case .absent, .malformed:
                    unusableCreatedAt += 1
                    continue
                case .present:
                    break
                }
            }
            if withinDateRange(question, after: after, before: before) {
                matched += 1
            }
        }
    }
    if let error = scan.error {
        return toolResult(error)
    }
    if let message = scan.invalidShape {
        return errorResult(message)
    }
    if let message = scan.paginationError {
        return errorResult(message)
    }
    if let message = scan.recordError {
        return errorResult(message)
    }

    var result: [String: Any] = [
        "matched": matched,
        "scanned": scan.scanned,
        "pages_fetched": scan.pagesFetched,
        "truncated": scan.truncated,
    ]
    if let total = scan.totalReported {
        result["total_reported_by_api"] = total
    }
    var filters = questionFiltersEcho(owner: owner, author: author, language: language, type: type)
    addDateFilters(&filters, after: after, before: before)
    if !filters.isEmpty {
        result["filters"] = filters
    }
    if dateFilterActive, unusableCreatedAt > 0 {
        result["unusable_created_at"] = unusableCreatedAt
        result["date_filter_incomplete"] = true
    }
    if scan.truncated {
        result["note"] = "Hit the internal page cap (\(maxPadPagesToFetch) pages); the count covers only the questions scanned."
    }

    return jsonResult(result)
}

func aggregateQuestionsTool(
    groupBy: String,
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "group_by", "owner", "author", "language", "type", "created_after", "created_before"],
    ) {
        return errorResult(error)
    }

    guard let field = questionAggregateField(for: groupBy) else {
        return CallTool.Result(
            content: [.text(
                text: "Unsupported group_by \"\(groupBy)\". Use owner, author, language, type, or month.",
                annotations: nil, _meta: nil,
            )],
            isError: true,
        )
    }

    if let error = questionFilterTypeError(arguments) {
        return errorResult(error)
    }
    let owner = stringArgument(arguments, "owner")
    let author = stringArgument(arguments, "author")
    let language = stringArgument(arguments, "language")
    let type = stringArgument(arguments, "type")
    let after = stringArgument(arguments, "created_after")
    let before = stringArgument(arguments, "created_before")
    if let error = dateBoundValidationError(after: after, before: before) {
        return errorResult(error)
    }

    // Built once for the whole list rather than re-normalizing the filter
    // values for every row (#2452).
    let matcher = QuestionMatcher(owner: owner, author: author, language: language, type: type)
    let dateFilterActive = normalizedFilterValue(after) != nil || normalizedFilterValue(before) != nil
    var matched = 0
    var unusableCreatedAt = 0
    var accumulation = AggregateAccumulation()
    let scan = try await fetchAllQuestions(account: account, cache: cache) { questions in
        let page = questions.filter { question in
            guard matcher.matches(question) else { return false }
            if dateFilterActive {
                switch createdAtPresence(question) {
                case .absent, .malformed:
                    unusableCreatedAt += 1
                    return false
                case .present:
                    break
                }
            }
            return withinDateRange(question, after: after, before: before)
        }
        matched += page.count
        accumulateCounts(&accumulation, pads: page, field: field)
    }
    if let error = scan.error {
        return toolResult(error)
    }
    if let message = scan.invalidShape {
        return errorResult(message)
    }
    if let message = scan.paginationError {
        return errorResult(message)
    }
    if let message = scan.recordError {
        return errorResult(message)
    }

    let capped = topGroups(accumulation.counts, limit: maxReturnedAggregateGroups)
    let groups: [[String: Any]] = capped.map { ["value": $0.value, "count": $0.count] }

    var result: [String: Any] = [
        "group_by": field,
        "matched": matched,
        "scanned": scan.scanned,
        "distinct_groups": accumulation.distinctGroups,
        "groups": groups,
        "pages_fetched": scan.pagesFetched,
        "truncated": scan.truncated,
    ]
    var filters = questionFiltersEcho(owner: owner, author: author, language: language, type: type)
    addDateFilters(&filters, after: after, before: before)
    if !filters.isEmpty {
        result["filters"] = filters
    }
    if accumulation.counts[aggregateOverflowGroup] != nil {
        result["distinct_groups_includes_overflow"] = true
    }
    if dateFilterActive, unusableCreatedAt > 0 {
        result["unusable_created_at"] = unusableCreatedAt
        result["date_filter_incomplete"] = true
    }
    if accumulation.counts.count > capped.count {
        result["groups_truncated"] = true
        result["note"] = "Showing the top \(capped.count) of \(accumulation.counts.count) groups by count."
    }
    if scan.truncated {
        result["page_cap_note"] = "Hit the internal page cap (\(maxPadPagesToFetch) pages); the aggregation covers only the questions scanned."
    }

    return jsonResult(result)
}

func listQuestions(arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    if let error = pageValidationError(strictIntArgument(arguments, "page")) {
        return errorResult(error)
    }
    if let error = listSortTypeError(arguments) {
        return errorResult(error)
    }
    if let error = pagingSortValidationError(stringArgument(arguments, "sort")) {
        return errorResult(error)
    }

    return try await toolResult(apiGet("/api/questions/", account: account, query: pagingQuery(arguments)))
}

func listQuestionsCompact(arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "page", "sort"],
    ) {
        return errorResult(error)
    }

    if let error = pageValidationError(strictIntArgument(arguments, "page")) {
        return errorResult(error)
    }
    if let error = listSortTypeError(arguments) {
        return errorResult(error)
    }
    if let error = pagingSortValidationError(stringArgument(arguments, "sort")) {
        return errorResult(error)
    }

    let response = try await apiGet("/api/questions/", account: account, query: pagingQuery(arguments))
    guard response.ok, let object = jsonObject(response.data) else { return toolResult(response) }
    guard let questions = object["questions"] as? [[String: Any]] else {
        return errorResult(invalidListResponseMessage("/api/questions/", expecting: "questions", body: response.body))
    }

    var identities = RecordIdentityTracker()
    var valid: [[String: Any]] = []
    var malformed = 0
    for question in questions {
        switch identities.acceptQuestion(question) {
        case .accepted:
            valid.append(question)
        case .duplicate:
            continue
        case .invalid:
            malformed += 1
        }
    }

    let compact = compactQuestions(valid)

    var result: [String: Any] = ["questions": compact, "count": compact.count]
    if malformed > 0 {
        result["malformed_records"] = malformed
        result["incomplete"] = true
    }
    if let next = compactPaginationMetadata(object["next_page"]) {
        result["next_page"] = next
    }
    if let total = compactPaginationMetadata(object["total"]) {
        result["total"] = total
    }

    return jsonResult(result)
}
