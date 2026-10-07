import Foundation

public let maximumCandidateInstructionSteps = 100
public let maximumCandidateInstructionBytes = 65536

public nonisolated(unsafe) let questionSettingProperties: [String: [String: Any]] = [
    "candidate_instructions": [
        "type": "array", "maxItems": maximumCandidateInstructionSteps,
        "description": "Candidate instruction steps. Encoded as a JSON string. An empty array clears the instructions.",
        "items": [
            "type": "object", "required": ["instructions"], "additionalProperties": false,
            "properties": [
                "instructions": mcpStringSchema("Instruction Markdown, at most 65536 UTF-8 bytes.",
                                                maxLength: maximumCandidateInstructionBytes),
                "name": mcpStringSchema("Optional instruction step name.", maxLength: maximumCandidateInstructionBytes),
                "default_visible": mcpBoolSchema("Whether the step is initially visible. The first step is always visible."),
            ],
        ],
    ],
    "ai_assist_custom_system_prompt": mcpStringSchema("Custom AI Assist prompt. Empty text clears it. Enterprise feature.",
                                                      maxLength: maxMCPWriteFieldBytes),
    "shared": mcpBoolSchema("Share the question with the organization. Only its author may change this."),
    "custom_database_id": mcpIntSchema("Integer identity of an existing custom database."),
]
