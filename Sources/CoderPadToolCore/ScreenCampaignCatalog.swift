import Foundation

public nonisolated(unsafe) let screenCampaignCreateSchema: [String: Any] = [
    "required": ["name", "questions"],
    "type": "object",
    "description": "the test to create",
    "properties": [
        "name": [
            "type": "string",
            "description": "the test name",
            "maxLength": 64,
            "minLength": 3,
        ],
        "questions": [
            "minItems": 1,
            "type": "array",
            "description": "the test entries",
            "items": [
                "required": ["type"],
                "type": "object",
                "description": "one entry of the test",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "whether the entry is a single question or a set drawn at random",
                        "enum": ["QUESTION", "RANDOM_QUESTION_SET"],
                        "maxLength": 4096,
                    ],
                    "configuration": [
                        "type": "object", "required": ["question_type", "target_duration_minutes"],
                        "description": "which questions a random set may draw",
                        "properties": [
                            "domain": [
                                "type": "string",
                                "description": "the domain the questions are drawn from",
                                "maxLength": 4096,
                            ],
                            "skills": [
                                "type": "array",
                                "description": "the skills the questions must cover",
                                "items": [
                                    "type": "string",
                                    "description": "the skills the questions must cover",
                                    "maxLength": 4096,
                                ],
                                "maxItems": 200,
                            ],
                            "question_type": [
                                "type": "string",
                                "description": "the kind of question drawn",
                                "enum": ["QUIZ", "CODE"],
                                "maxLength": 4096,
                            ],
                            "target_duration_minutes": [
                                "type": "integer",
                                "description": "how long the drawn questions should last altogether",
                                "format": "int32",
                                "minimum": 0,
                                "maximum": 2_147_483_647,
                            ],
                            "target_experience_level": [
                                "type": "string",
                                "description": "the experience level the questions target",
                                "enum": ["JUNIOR", "SENIOR", "EXPERT"],
                                "maxLength": 4096,
                            ],
                            "included_question_ids": [
                                "type": "array",
                                "description": "the only questions the set may draw",
                                "items": [
                                    "type": "string",
                                    "description": "the only questions the set may draw",
                                    "format": "uuid",
                                    "maxLength": 36,
                                    "minLength": 36,
                                ],
                                "maxItems": 200,
                            ],
                            "excluded_question_ids": [
                                "type": "array",
                                "description": "the questions the set must never draw",
                                "items": [
                                    "type": "string",
                                    "description": "the questions the set must never draw",
                                    "format": "uuid",
                                    "maxLength": 36,
                                    "minLength": 36,
                                ],
                                "maxItems": 200,
                            ],
                        ],
                        "additionalProperties": false,
                        "not": [
                            "required": ["included_question_ids", "excluded_question_ids"],
                        ],
                    ],
                    "question_id": [
                        "type": "string",
                        "description": "the question to add",
                        "format": "uuid",
                        "maxLength": 36,
                        "minLength": 36,
                    ],
                ],
                "additionalProperties": false,
                "oneOf": [[
                    "properties": [
                        "type": [
                            "const": "QUESTION",
                        ],
                    ],
                    "required": ["question_id"],
                    "not": [
                        "required": ["configuration"],
                    ],
                ], [
                    "properties": [
                        "type": [
                            "const": "RANDOM_QUESTION_SET",
                        ],
                    ],
                    "required": ["configuration"],
                    "not": [
                        "required": ["question_id"],
                    ],
                ]],
            ],
            "maxItems": 200,
        ],
        "settings": [
            "type": "object",
            "description": "how the test behaves",
            "properties": [
                "languages": [
                    "type": "array",
                    "description": "the locales the test is available in",
                    "items": [
                        "type": "string",
                        "description": "the locales the test is available in",
                        "maxLength": 4096,
                    ],
                    "maxItems": 200,
                ],
                "timer": [
                    "type": "object", "required": ["mode"],
                    "description": "how the test times the candidate",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "description": "how the test times the candidate",
                            "enum": ["PER_QUESTION", "GLOBAL", "UNLIMITED"],
                            "maxLength": 4096,
                        ],
                        "duration_minutes": [
                            "type": "integer",
                            "description": "how long the whole test lasts",
                            "format": "int32",
                            "minimum": 0,
                            "maximum": 2_147_483_647,
                        ],
                    ],
                    "additionalProperties": false,
                ],
                "invitation_expiration_days": [
                    "type": "integer",
                    "description": "how many days a candidate has to start the test after being invited",
                    "format": "int32",
                    "minimum": 0,
                    "maximum": 2_147_483_647,
                ],
                "access_period": [
                    "type": "object",
                    "description": "when candidates are allowed to take the test",
                    "properties": [
                        "min_start_time": [
                            "type": "string",
                            "description": "ISO 8601 instant before which candidates cannot start the test",
                            "maxLength": 4096,
                            "format": "date-time",
                        ],
                        "max_end_time": [
                            "type": "string",
                            "description": "ISO 8601 instant after which candidates cannot take the test anymore",
                            "maxLength": 4096,
                            "format": "date-time",
                        ],
                    ],
                    "additionalProperties": false,
                ],
                "send_candidate_simplified_report": [
                    "type": "boolean",
                    "description": "whether candidates receive a simplified report once they submit the test",
                ],
                "copy_paste_blocked": [
                    "type": "boolean",
                    "description": "whether candidates are prevented from copying and pasting",
                ],
                "follow_up_questions": [
                    "type": "object",
                    "description": "asking candidates to justify their answers after a coding exercise",
                    "properties": [
                        "enabled": [
                            "type": "boolean",
                            "description": "whether follow-up questions are asked",
                        ],
                        "answer_format": [
                            "type": "string",
                            "description": "how candidates answer the follow-up questions",
                            "enum": ["TEXT", "VIDEO", "AUDIO"],
                            "maxLength": 4096,
                        ],
                    ],
                    "additionalProperties": false,
                ],
                "webcam_proctoring": [
                    "type": "object",
                    "description": "recording candidates via their webcam while they take the test",
                    "properties": [
                        "enabled": [
                            "type": "boolean",
                            "description": "whether candidates are recorded through their webcam",
                        ],
                        "ai_analysis_enabled": [
                            "type": "boolean",
                            "description": "whether the webcam snapshots are analyzed by AI",
                        ],
                    ],
                    "additionalProperties": false,
                ],
                "full_screen_required": [
                    "type": "boolean",
                    "description": "whether candidates must keep the test in full screen",
                ],
                "ai_assist_enabled": [
                    "type": "boolean",
                    "description": "whether candidates have access to the AI assistant in project questions",
                ],
                "enabled_coding_agents": [
                    "type": "string",
                    "description": "the coding agents candidates may run",
                    "enum": ["", "CLAUDE_CODE", "CODEX"],
                    "maxLength": 4096,
                ],
            ],
            "additionalProperties": false,
        ],
        "team_id": [
            "type": "string",
            "description": "the team the test belongs to",
            "format": "uuid",
            "maxLength": 36,
            "minLength": 36,
        ],
    ],
    "additionalProperties": false,
]

public nonisolated(unsafe) let screenCampaignWriteDescriptors: [[String: Any]] = [
    mcpToolDescriptor(
        "screen_create_campaign", "Create a Screen campaign from ordered selected or random questions and optional team settings.",
        properties: withAccount((screenCampaignCreateSchema["properties"] as? [String: [String: Any]] ?? [:]).merging([
            "dry_run": mcpBoolSchema("Validate and preview without creating a campaign."),
        ]) { _, new in new }),
        required: ["name", "questions"], schemaExtras: ["additionalProperties": false],
        annotations: writeAnnotations(title: "Create Screen campaign", destructive: false),
    ),
]
