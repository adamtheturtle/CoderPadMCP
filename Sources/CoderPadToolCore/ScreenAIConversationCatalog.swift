import Foundation

public nonisolated(unsafe) let coderPadScreenAIToolDescriptors: [[String: Any]] = [
    mcpToolDescriptor(
        "screen_ai_assist_conversations",
        "Read candidate AI Assist conversations for a Screen project question. Preserves ordered messages and structured output items.",
        properties: [
            mcpAccountArgument: mcpAccountSchema,
            "test": mcpIntSchema("The test session's positive int32 id.", minimum: 1, maximum: maximumScreenID),
            "question": ["type": "string", "format": "uuid", "description": "The project question UUID."],
        ],
        required: ["test", "question"],
        annotations: ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": true],
    ),
]
