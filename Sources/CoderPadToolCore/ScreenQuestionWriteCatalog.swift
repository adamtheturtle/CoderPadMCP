import Foundation

public nonisolated(unsafe) let screenQuestionWriteDescriptors: [[String: Any]] = [
    mcpToolDescriptor(
        "screen_create_question", "Create a Screen question of type MCQ, CODE, TEXT, FILE_UPLOAD, VIDEO, or PROJECT. Requires writes opt-in. "
            + "Use writable payload fields. PROJECT creation requires a temporary_file_id from screen_upload_project.",
        properties: withAccount([
            "payload": screenQuestionWriteSchema,
            "dry_run": mcpBoolSchema("Validate and preview without sending a request."),
        ]), required: ["payload"], schemaExtras: ["additionalProperties": false],
        annotations: writeAnnotations(title: "Create Screen question", destructive: false),
    ),
    mcpToolDescriptor(
        "screen_update_question", "Update a Screen UUID question with writable fields and writes opt-in. "
            + "PROJECT source archives are replaced in the question editor, not through this tool.",
        properties: withAccount([
            "question": ["type": "string", "format": "uuid"], "payload": screenQuestionWriteSchema,
            "dry_run": mcpBoolSchema("Validate and preview without sending a request."),
        ]), required: ["question", "payload"], schemaExtras: ["additionalProperties": false],
        annotations: writeAnnotations(title: "Update Screen question", destructive: true),
    ),
    mcpToolDescriptor(
        "screen_upload_project", "Upload raw gzip archive bytes for a Screen PROJECT question. Requires writes opt-in. "
            + "archive_uri must be an explicit absolute file URI, or a binary resource URI supported by the embedding host. "
            + "The archive limit is 52,428,800 bytes. Reference the returned temporary ID promptly.",
        properties: withAccount([
            "archive_uri": ["type": "string", "minLength": 1, "maxLength": 4096],
            "dry_run": mcpBoolSchema("Read and validate the archive and preview headers without uploading it."),
        ]), required: ["archive_uri"], schemaExtras: ["additionalProperties": false],
        annotations: writeAnnotations(title: "Upload Screen project", destructive: false),
    ),
]
