import Foundation

public nonisolated(unsafe) let questionProjectProperties: [String: [String: Any]] = [
    "language": ["type": "string", "description": "Language key or project template slug.",
                 "minLength": 1, "maxLength": 100, "pattern": "^[A-Za-z0-9_-]+$"],
    "file_contents": [
        "type": "array", "maxItems": 200,
        "description": "Structured starter files, encoded as a JSON string. Mutually exclusive with contents. "
            + "Creation overlays template files. Parent updates ignore deleted entries. Empty arrays are preserved.",
        "items": [
            "type": "object", "required": ["path"], "additionalProperties": false,
            "properties": [
                "path": mcpStringSchema("Safe relative file path.", minLength: 1, maxLength: 1024),
                "contents": mcpStringSchema("File contents, required unless deleted is true.", maxLength: maxMCPWriteFieldBytes),
                "hidden": mcpBoolSchema("Hide this file from the candidate."),
                "deleted": mcpBoolSchema("Remove a template file on creation. The .cpad file is protected."),
            ],
            "anyOf": [["required": ["contents"]], ["required": ["deleted"], "properties": ["deleted": ["const": true]]]],
        ],
    ],
]
