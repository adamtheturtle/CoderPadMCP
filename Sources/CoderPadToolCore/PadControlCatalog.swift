import Foundation

public let maximumAllowedInterviewerEmails = 100
public let padControlBooleanFields = ["private", "execution_enabled", "restrict_interviewer_access", "disable_coaching_tips"]
public let padCreationBooleanFields = ["take_home", "ai_assist_enabled"]

public nonisolated(unsafe) let padControlProperties: [String: [String: Any]] = [
    "private": mcpBoolSchema("Keep the candidate in the waiting room until admitted."),
    "execution_enabled": mcpBoolSchema("Enable execution. Encoded as the API string true or false."),
    "restrict_interviewer_access": mcpBoolSchema("Restrict interviewer access to the allowed email list."),
    "disable_coaching_tips": mcpBoolSchema("Disable interviewer coaching tips."),
    "allowed_interviewer_emails": [
        "type": "array", "maxItems": maximumAllowedInterviewerEmails,
        "description": "Replacement interviewer email list. An empty array clears the list.",
        "items": mcpStringSchema("Interviewer email.", minLength: 1, maxLength: maxOwnerEmailBytes),
    ],
]

public nonisolated(unsafe) let padCreationControlProperties: [String: [String: Any]] = padControlProperties.merging([
    "take_home": mcpBoolSchema("Create a take-home pad."),
    "ai_assist_enabled": mcpBoolSchema("Enable AI assistance when creating the pad."),
    "take_home_time_limit": mcpIntSchema("Take-home time limit in minutes.", minimum: 0, maximum: Int(Int32.max)),
]) { _, new in new }
