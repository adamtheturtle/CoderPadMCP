import Foundation

public let maximumQuestionSearchBytes = 4096
public let maximumQuestionPadTypeFilters = 100
public let questionPagingSortFields: Set<String> = ["created_at", "updated_at", "title", "used"]

public nonisolated(unsafe) let questionSearchProperties: [String: [String: Any]] = [
    "text": mcpStringSchema("Optional server-side question text search. Empty text is preserved. At most 4096 UTF-8 bytes.",
                            maxLength: maximumQuestionSearchBytes),
    "pad_types": [
        "type": "array", "maxItems": maximumQuestionPadTypeFilters,
        "description": "Optional usage categories, sent as repeated pad_types[] query keys. An empty array adds no filter.",
        "items": ["type": "string", "enum": ["any", "live", "take_home"]],
    ],
]

public nonisolated(unsafe) let questionPagingProperties: [String: [String: Any]] = questionSearchProperties.merging([
    "page": mcpIntSchema("Optional 1-based page number.", minimum: 1, maximum: maxPaginationPage),
    "sort": mcpStringSchema(
        "Question sort: created_at, updated_at, title, or used, optionally followed by asc or desc. Bare fields default to descending.",
        allowedValues: questionPagingSortFields.sorted().flatMap { [$0, "\($0),asc", "\($0),desc", "-\($0)"] },
    ),
]) { _, new in new }

public func normalizedQuestionPagingSort(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    if value.first == "-" {
        let field = String(value.dropFirst())
        return questionPagingSortFields.contains(field) ? "\(field),desc" : nil
    }
    let components = value.split(separator: ",", omittingEmptySubsequences: false)
    if components.count == 1, questionPagingSortFields.contains(value) {
        return "\(value),desc"
    }
    guard components.count == 2, questionPagingSortFields.contains(String(components[0])),
          components[1] == "asc" || components[1] == "desc" else { return nil }
    return value
}
