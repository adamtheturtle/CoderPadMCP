import Foundation

public nonisolated(unsafe) let screenQuestionWriteSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "type": [
            "type": "string",
            "enum": ["MCQ", "CODE", "TEXT", "FILE_UPLOAD", "VIDEO", "PROJECT"],
            "maxLength": 524_288,
        ],
        "domain": [
            "type": "string",
            "maxLength": 524_288,
        ],
        "duration_seconds": [
            "type": "integer",
            "format": "int32",
            "minimum": 0,
            "maximum": 2_147_483_647,
        ],
        "difficulty": [
            "type": "string",
            "enum": ["EASY", "MEDIUM", "HARD"],
            "maxLength": 524_288,
        ],
        "points": [
            "type": "integer",
            "format": "int32",
            "minimum": 0,
            "maximum": 2_147_483_647,
        ],
        "title": [
            "type": "object",
            "additionalProperties": [
                "type": "string",
                "maxLength": 524_288,
            ],
            "maxProperties": 200,
        ],
        "statement": [
            "type": "object",
            "additionalProperties": [
                "type": "string",
                "maxLength": 524_288,
            ],
            "maxProperties": 200,
        ],
        "locales": [
            "type": "array",
            "items": [
                "type": "string",
                "maxLength": 524_288,
            ],
            "maxItems": 200,
        ],
        "skill": [
            "type": "string",
            "maxLength": 524_288,
        ],
        "team_id": [
            "type": "string",
            "format": "uuid",
            "maxLength": 524_288,
        ],
        "automatically_selectable": [
            "type": "boolean",
        ],
        "comment": [
            "type": "string",
            "maxLength": 524_288,
        ],
        "evaluation": [
            "type": "object",
            "properties": [
                "rubric": [
                    "type": "object",
                    "properties": [
                        "criteria": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": [
                                        "type": "object",
                                        "additionalProperties": [
                                            "type": "string",
                                            "maxLength": 524_288,
                                        ],
                                        "maxProperties": 200,
                                    ],
                                    "skill": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "points": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "weight": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "review_mode": [
                                        "type": "string",
                                        "enum": ["HUMAN_ONLY", "AI_SUGGESTIONS", "AI_GRADING"],
                                        "maxLength": 524_288,
                                    ],
                                    "description": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                ],
                                "additionalProperties": false,
                                "maxProperties": 200,
                            ],
                            "maxItems": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "validation_code": [
                    "type": "object",
                    "properties": [
                        "test_cases": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": [
                                        "type": "object",
                                        "additionalProperties": [
                                            "type": "string",
                                            "maxLength": 524_288,
                                        ],
                                        "maxProperties": 200,
                                    ],
                                    "test_identifier": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "skill": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "points": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "weight": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "difficulty": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "contributes_to_score": [
                                        "type": "boolean",
                                    ],
                                    "visible_to_candidate": [
                                        "type": "boolean",
                                    ],
                                ],
                                "additionalProperties": false,
                                "maxProperties": 200,
                            ],
                            "maxItems": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "input_output": [
                    "type": "object",
                    "properties": [
                        "test_cases": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": [
                                        "type": "object",
                                        "additionalProperties": [
                                            "type": "string",
                                            "maxLength": 524_288,
                                        ],
                                        "maxProperties": 200,
                                    ],
                                    "input": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "output": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "skill": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "points": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "weight": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "difficulty": [
                                        "type": "integer",
                                        "format": "int32",
                                        "minimum": 0,
                                        "maximum": 2_147_483_647,
                                    ],
                                    "contributes_to_score": [
                                        "type": "boolean",
                                    ],
                                    "visible_to_candidate": [
                                        "type": "boolean",
                                    ],
                                    "timeout_ms_by_programming_language_id": [
                                        "type": "object",
                                        "additionalProperties": [
                                            "type": "integer",
                                            "format": "int32",
                                            "minimum": 0,
                                            "maximum": 2_147_483_647,
                                        ],
                                        "maxProperties": 200,
                                    ],
                                ],
                                "additionalProperties": false,
                                "maxProperties": 200,
                            ],
                            "maxItems": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "sql_query_result_comparison": [
                    "type": "object",
                    "properties": [
                        "reference_query": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                        "comparison": [
                            "type": "object",
                            "properties": [
                                "row_order_matters": [
                                    "type": "boolean",
                                ],
                                "column_order_matters": [
                                    "type": "boolean",
                                ],
                                "compare_all_tables": [
                                    "type": "boolean",
                                ],
                            ],
                            "additionalProperties": false,
                            "maxProperties": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "text_answer_matching": [
                    "type": "object",
                    "properties": [
                        "accepted_answers": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "value": [
                                        "type": "string",
                                        "maxLength": 524_288,
                                    ],
                                    "match_type": [
                                        "type": "string",
                                        "enum": ["EXACT", "REGEX"],
                                        "maxLength": 524_288,
                                    ],
                                ],
                                "additionalProperties": false,
                                "maxProperties": 200,
                            ],
                            "maxItems": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "choice_selection": [
                    "type": "object",
                    "properties": [
                        "correct_choice_indexes": [
                            "type": "array",
                            "items": [
                                "type": "integer",
                                "format": "int32",
                                "minimum": 0,
                                "maximum": 2_147_483_647,
                            ],
                            "maxItems": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
            ],
            "additionalProperties": false,
            "maxProperties": 200,
        ],
        "code_details": [
            "type": "object",
            "properties": [
                "environment": [
                    "type": "object",
                    "properties": [
                        "version": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                        "environment_id": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "mode": [
                    "type": "string",
                    "enum": ["SINGLE_LANGUAGE", "MULTI_LANGUAGE"],
                    "maxLength": 524_288,
                ],
                "programming_language_id": [
                    "type": "string",
                    "maxLength": 524_288,
                ],
                "candidate_test_code": [
                    "type": "string",
                    "maxLength": 524_288,
                ],
                "validator_code": [
                    "type": "string",
                    "maxLength": 524_288,
                ],
                "timeout_ms": [
                    "type": "integer",
                    "format": "int32",
                    "minimum": 0,
                    "maximum": 2_147_483_647,
                ],
                "database_engine": [
                    "type": "object",
                    "properties": [
                        "version": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                        "engine_id": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "database_setup_script": [
                    "type": "string",
                    "maxLength": 524_288,
                ],
                "starter_code": [
                    "type": "string",
                    "maxLength": 524_288,
                ],
                "function_signature": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                        "parameters": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": true,
                                "maxProperties": 200,
                            ],
                            "maxItems": 200,
                        ],
                        "return_type": [
                            "type": "object",
                            "additionalProperties": true,
                            "maxProperties": 200,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "possible_solution": [
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                        "programming_language_id": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "show_function_signature_in_statement": [
                    "type": "boolean",
                ],
            ],
            "additionalProperties": false,
            "maxProperties": 200,
        ],
        "mcq_details": [
            "type": "object",
            "properties": [
                "choices": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": [
                                "type": "object",
                                "additionalProperties": [
                                    "type": "string",
                                    "maxLength": 524_288,
                                ],
                                "maxProperties": 200,
                            ],
                        ],
                        "additionalProperties": false,
                        "maxProperties": 200,
                    ],
                    "maxItems": 200,
                ],
                "selection_mode": [
                    "type": "string",
                    "enum": ["SINGLE", "MULTIPLE"],
                    "maxLength": 524_288,
                ],
                "randomize_choices": [
                    "type": "boolean",
                ],
            ],
            "additionalProperties": false,
            "maxProperties": 200,
        ],
        "text_details": [
            "type": "object",
            "properties": [
                "evaluation_mode": [
                    "type": "string",
                    "enum": ["MANUAL", "AUTOMATIC"],
                    "maxLength": 524_288,
                ],
            ],
            "additionalProperties": false,
            "maxProperties": 200,
        ],
        "video_details": [
            "type": "object",
            "properties": [
                "recording_media": [
                    "type": "string",
                    "enum": ["VIDEO", "AUDIO"],
                    "maxLength": 524_288,
                ],
            ],
            "additionalProperties": false,
            "maxProperties": 200,
        ],
        "project_details": [
            "type": "object",
            "properties": [
                "environment": [
                    "type": "object",
                    "properties": [
                        "version": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                        "environment_id": [
                            "type": "string",
                            "maxLength": 524_288,
                        ],
                    ],
                    "additionalProperties": false,
                    "maxProperties": 200,
                ],
                "resources": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "version": [
                                "type": "string",
                                "maxLength": 524_288,
                            ],
                            "resource_id": [
                                "type": "string",
                                "maxLength": 524_288,
                            ],
                        ],
                        "additionalProperties": false,
                        "maxProperties": 200,
                    ],
                    "maxItems": 200,
                ],
                "ai_assist_additional_instructions": [
                    "type": "string",
                    "maxLength": 524_288,
                ],
                "ai_assist_allowed": [
                    "type": "boolean",
                ],
                "temporary_file_id": [
                    "type": "string",
                    "format": "uuid",
                    "maxLength": 524_288,
                ],
            ],
            "additionalProperties": false,
            "maxProperties": 200,
        ],
    ],
    "additionalProperties": false,
    "maxProperties": 200,
    "required": ["type"],
]
