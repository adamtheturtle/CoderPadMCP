import Foundation
import MCP

struct PadControlInputError: Error {
    let message: String
}

func padControlBody(_ arguments: [String: Value]?, creating: Bool) throws(PadControlInputError) -> [String: Any] {
    var body: [String: Any] = [:]
    let booleans = padControlBooleanFields + (creating ? padCreationBooleanFields : [])
    for name in booleans {
        guard let value = arguments?[name] else { continue }
        guard case let .bool(enabled) = value else {
            throw PadControlInputError(message: "\(name) must be a boolean.")
        }
        if name == "execution_enabled" {
            body[name] = enabled ? "true" : "false"
        } else {
            body[name] = enabled
        }
    }
    if let value = arguments?["allowed_interviewer_emails"] {
        guard case let .array(values) = value, values.count <= maximumAllowedInterviewerEmails else {
            throw PadControlInputError(message: "allowed_interviewer_emails must be an array of at most 100 email strings.")
        }
        var emails: [String] = []
        for value in values {
            guard case let .string(email) = value, !email.isEmpty, ownerEmailValidationError(email) == nil else {
                throw PadControlInputError(message: "Each allowed_interviewer_emails entry must be a non-empty bounded email string.")
            }
            emails.append(email)
        }
        body["allowed_interviewer_emails"] = emails
    }
    if creating, let value = arguments?["take_home_time_limit"] {
        let minutes: Int? = switch value {
        case let .int(value): value
        case let .double(value): Int(exactly: value)
        default: nil
        }
        guard let minutes, minutes >= 0, minutes <= Int(Int32.max) else {
            throw PadControlInputError(message: "take_home_time_limit must be an integer from 0 to 2147483647 minutes.")
        }
        body["take_home_time_limit"] = minutes
    }
    return body
}
