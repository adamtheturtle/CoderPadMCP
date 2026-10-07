import Foundation

public let maximumScreenQuestionPageSize = 50
public let screenQuestionSortFields = [
    "id", "title", "type", "duration_seconds", "difficulty", "domain", "skill",
    "programming_language", "modification_time", "from_coderpad_question_bank", "product",
]

private func screenQuestionReadProperties(insights: Bool) -> [String: [String: Any]] {
    var properties = [
        mcpAccountArgument: mcpAccountSchema,
        "question": ["type": "string", "format": "uuid", "description": "The Screen question UUID."],
    ]
    if insights {
        properties["programming_language"] = mcpStringSchema("Optional language for insights.", minLength: 1, maxLength: 200)
    }
    return properties
}

private func screenQuestionListProperties() -> [String: [String: Any]] {
    var properties = [mcpAccountArgument: mcpAccountSchema]
    properties["start"] = mcpIntSchema("Optional zero-based offset.", minimum: 0, maximum: maxPaginationStart)
    properties["limit"] = mcpIntSchema("Optional page size.", minimum: 1, maximum: maximumScreenQuestionPageSize)
    for key in ["type", "domain", "skill", "programming_language"] {
        properties[key] = mcpStringSchema("Optional \(key) filter.", minLength: 1, maxLength: 200)
    }
    for key in ["duration_seconds_min", "duration_seconds_max"] {
        properties[key] = mcpIntSchema("Optional duration bound in seconds.", minimum: 0, maximum: Int(Int32.max))
    }
    properties["difficulty"] = mcpStringSchema("Optional difficulty.", allowedValues: ["EASY", "MEDIUM", "HARD"])
    properties["product"] = mcpStringSchema("Optional product.", allowedValues: ["SCREEN", "QUALIFY"])
    properties["sort"] = mcpStringSchema("Optional sort field.", allowedValues: screenQuestionSortFields)
    properties["order"] = mcpStringSchema("Optional sort direction.", allowedValues: ["asc", "desc"])
    properties["from_coderpad_question_bank"] = mcpBoolSchema("Optional bank origin filter, including false for custom questions.")
    return properties
}

public nonisolated(unsafe) let coderPadScreenQuestionReadDescriptors: [[String: Any]] = [
    mcpToolDescriptor("screen_list_questions", "List one bounded offset page of Screen UUID questions, preserving filters and pagination metadata.",
                      properties: screenQuestionListProperties()),
    mcpToolDescriptor("screen_get_question", "Get full Screen UUID question details, including type-specific content and evaluation configuration.",
                      properties: screenQuestionReadProperties(insights: false), required: ["question"]),
    mcpToolDescriptor("screen_question_insights", "Get usage, answer frequencies, test results and scoring insights for a Screen UUID question.",
                      properties: screenQuestionReadProperties(insights: true), required: ["question"]),
]
