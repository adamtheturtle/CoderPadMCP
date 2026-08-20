//
//  QuestionAggregation.swift
//  CoderPadToolCore
//
//  The count / aggregate / compact transforms for the QUESTION bank (#500), mirroring
//  PadAggregation. The executable pages the whole question list over the network; these
//  pure functions filter and tally, so "how many questions by language / author" returns a
//  small answer instead of streaming every record through the model. Questions expose
//  owner_email, author_name, language, pad_type and created_at, so they group and filter by
//  those (rather than pads' owner/state/language). The field-agnostic helpers —
//  aggregateCounts, topGroups, nextPageToken — are reused from PadAggregation.
//

import Foundation

/// Whether a question passes the optional owner/author/language/type filters
/// (case-insensitive exact match on trimmed values; an empty/absent filter always
/// passes). The type comparison folds interview-type spellings so a tool value of
/// `take-home` matches the API's `take_home` and vice versa (#1609), mirroring the
/// app UI's `InterviewType(rawType:)` normalization.
public func questionMatches(
    _ question: [String: Any], owner: String?, author: String?, language: String?, type: String?,
) -> Bool {
    QuestionMatcher(owner: owner, author: author, language: language, type: type).matches(question)
}

/// A question filter with its criteria already normalized — the question counterpart
/// to `PadMatcher`, for the same reason: the filter values are constant across the
/// whole list but were re-normalized for every question and every field (#2452).
public struct QuestionMatcher: Sendable {
    private let owner: String?
    private let author: String?
    private let language: String?
    private let type: String?

    public init(owner: String?, author: String?, language: String?, type: String?) {
        self.owner = Self.prepared(owner)?.lowercased()
        self.author = Self.prepared(author)?.lowercased()
        self.language = Self.prepared(language)?.lowercased()
        self.type = Self.prepared(type).map(canonicalInterviewType)
    }

    private static func prepared(_ wanted: String?) -> String? {
        let cleaned = wanted?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned?.isEmpty ?? true) ? nil : cleaned
    }

    public func matches(_ question: [String: Any]) -> Bool {
        equals(question, "owner_email", owner) { $0.lowercased() }
            && equals(question, "author_name", author) { $0.lowercased() }
            && equals(question, "language", language) { $0.lowercased() }
            && equals(question, "pad_type", type, normalize: canonicalInterviewType)
    }

    private func equals(
        _ question: [String: Any],
        _ field: String,
        _ wanted: String?,
        normalize: (String) -> String,
    ) -> Bool {
        guard let wanted else { return true }

        return (question[field] as? String)
            .map { normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == wanted
    }
}

/// Folds the interview-type spellings the API and docs have used (`take-home`,
/// `take_home`, `takehome`; `live`) onto one canonical token for comparison (#1609).
/// Unknown type tokens keep their separators so values such as `a-b` and `a_b` stay
/// distinct (#186).
public func canonicalInterviewType(_ raw: String) -> String {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let folded = normalized
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
    switch folded {
    case "takehome": return "takehome"
    case "live": return "live"
    default: return normalized
    }
}

/// Echoes the active question filters back into a result, for clarity on what was counted.
public func questionFiltersEcho(owner: String?, author: String?, language: String?, type: String?) -> [String: Any] {
    var filters: [String: Any] = [:]
    if let owner = normalizedFilterValue(owner) {
        filters["owner"] = owner
    }
    if let author = normalizedFilterValue(author) {
        filters["author"] = author
    }
    if let language = normalizedFilterValue(language) {
        filters["language"] = language
    }
    if let type = normalizedFilterValue(type) {
        filters["type"] = type
    }
    return filters
}

/// Normalizes a user-facing `group_by` to a question field, or nil when unsupported. The
/// special value "month" buckets by the year-month of created_at.
public func questionAggregateField(for groupBy: String) -> String? {
    switch groupBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "owner", "owner_email": "owner_email"
    case "author", "author_name": "author_name"
    case "language": "language"
    case "type", "pad_type": "pad_type"
    case "month", "created_at": "month"
    default: nil
    }
}

/// The fields kept by list_questions_compact, dropping the verbose blob (description,
/// solution, starter code, test cases) so far more rows fit per response.
public let compactQuestionKeys = [
    "id", "title", "owner_email", "author_name", "language", "pad_type", "is_draft", "created_at",
]

/// Projects questions down to the compact key set. Only scalar values survive,
/// like `compactPads` (#1608).
public func compactQuestions(_ questions: [[String: Any]]) -> [[String: Any]] {
    questions.map { question in
        var row: [String: Any] = [:]
        for key in compactQuestionKeys {
            if let value = compactScalar(question[key]) {
                row[key] = value
            }
        }
        return row
    }
}
