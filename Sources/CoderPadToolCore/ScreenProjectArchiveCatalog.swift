import Foundation

public nonisolated(unsafe) let screenProjectArchiveDescriptors: [[String: Any]] = [
    mcpToolDescriptor(
        "screen_project_archive", "Get a binary resource link for a candidate project tar.gz archive. Read the resource to download it. "
            + "Downloads are bounded to 8 MiB, use a 120-second request timeout, and support cancellation.",
        properties: [
            mcpAccountArgument: mcpAccountSchema,
            "test": mcpIntSchema("Positive Screen session identity.", minimum: 1, maximum: Int(Int32.max)),
            "question": ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36,
                         "description": "UUID of the project question in this session."],
        ],
        required: ["test", "question"],
        annotations: ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true],
    ),
]
