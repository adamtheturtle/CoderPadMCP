import Foundation

private let maximumVariantFiles = 200

private func variantIdentityProperties(single: Bool) -> [String: [String: Any]] {
    var properties = ["question": mcpIntSchema("The parent question's numeric id.", minimum: 1)]
    if single {
        properties["variant"] = mcpIntSchema("The variant's numeric id within this question.", minimum: 1)
    }
    return withAccount(properties)
}

private func variantMutationProperties(single: Bool) -> [String: [String: Any]] {
    var properties = variantIdentityProperties(single: single)
    properties["language"] = mcpStringSchema("A language key or project-template slug.", minLength: 1, maxLength: 100)
    properties["solution"] = mcpStringSchema("Reference solution, including an empty string.", maxLength: maxMCPWriteFieldBytes)
    properties["contents"] = [
        "type": ["string", "null"],
        "description": "Omit to preserve code, send an empty string for blank code, or null to restore the language default.",
        "maxLength": maxMCPWriteFieldBytes,
    ]
    properties["file_contents"] = [
        "type": "array", "maxItems": maximumVariantFiles,
        "description": "Structured project files. Omit to preserve them, or send an empty array to reset to template files.",
        "items": [
            "type": "object", "additionalProperties": false, "required": ["path"],
            "properties": [
                "path": mcpStringSchema("Relative project file path.", minLength: 1, maxLength: 1024),
                "contents": mcpStringSchema("File contents, including empty code.", maxLength: maxMCPWriteFieldBytes),
                "hidden": mcpBoolSchema("Whether the starter file is hidden."),
                "deleted": mcpBoolSchema("Whether to delete this template file. The .cpad file cannot be deleted."),
            ],
            "anyOf": [
                ["required": ["contents"]],
                ["required": ["deleted"], "properties": ["deleted": ["const": true]]],
            ],
        ],
    ]
    properties["dry_run"] = mcpBoolSchema("Preview the exact request without changing the question.")
    return properties
}

public nonisolated(unsafe) let coderPadVariantReadToolDescriptors: [[String: Any]] = [
    mcpToolDescriptor("list_question_variants", "List variants within a question, including full starter code and project files.",
                      properties: variantIdentityProperties(single: false), required: ["question"]),
    mcpToolDescriptor("get_question_variant", "Get a variant by both parent question id and variant id.",
                      properties: variantIdentityProperties(single: true), required: ["question", "variant"]),
]

public nonisolated(unsafe) let coderPadVariantWriteToolDescriptors: [[String: Any]] = [
    mcpToolDescriptor("create_question_variant", "Create a language or project-template variant within a question.",
                      properties: variantMutationProperties(single: false), required: ["question", "language"],
                      schemaExtras: ["not": ["required": ["contents", "file_contents"]]],
                      annotations: writeAnnotations(title: "Create question variant", destructive: false)),
    mcpToolDescriptor("update_question_variant", "Update supplied variant fields. Language changes clear code unless replacement code is supplied.",
                      properties: variantMutationProperties(single: true), required: ["question", "variant"],
                      schemaExtras: [
                          "not": ["required": ["contents", "file_contents"]],
                          "anyOf": ["language", "solution", "contents", "file_contents"].map { ["required": [$0]] },
                      ],
                      annotations: writeAnnotations(title: "Update question variant", destructive: true)),
]
