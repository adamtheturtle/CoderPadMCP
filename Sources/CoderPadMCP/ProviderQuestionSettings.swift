import Foundation
import MCP

struct QuestionSettingInputError: Error {
    let message: String
}

func questionSettingBody(_ arguments: [String: Value]?) throws(QuestionSettingInputError) -> [String: Any] {
    var body: [String: Any] = [:]
    if let value = arguments?["shared"] {
        guard case let .bool(shared) = value else {
            throw QuestionSettingInputError(message: "shared must be a boolean.")
        }
        body["shared"] = shared
    }
    if let value = arguments?["custom_database_id"] {
        let identity: Int? = switch value {
        case let .int(value): value
        case let .double(value): Int(exactly: value)
        default: nil
        }
        guard let identity else { throw QuestionSettingInputError(message: "custom_database_id must be an integer.") }
        body["custom_database_id"] = identity
    }
    if let value = arguments?["ai_assist_custom_system_prompt"] {
        guard case let .string(prompt) = value, prompt.utf8.count <= maxMCPWriteFieldBytes else {
            throw QuestionSettingInputError(message: "ai_assist_custom_system_prompt must be a bounded string.")
        }
        body["ai_assist_custom_system_prompt"] = prompt
    }
    if let value = arguments?["candidate_instructions"] {
        body["candidate_instructions"] = try instructionJSONString(value)
    }
    return body
}

private func instructionJSONString(_ value: Value) throws(QuestionSettingInputError) -> String {
    guard case let .array(values) = value, values.count <= maximumCandidateInstructionSteps else {
        throw QuestionSettingInputError(message: "candidate_instructions must be an array of at most 100 steps.")
    }
    var steps: [[String: Any]] = []
    var budget = 256
    for value in values {
        guard case let .object(fields) = value,
              Set(fields.keys).isSubset(of: ["instructions", "name", "default_visible"]),
              case let .string(instructions)? = fields["instructions"], instructions.utf8.count <= maximumCandidateInstructionBytes
        else { throw QuestionSettingInputError(message: "Each step requires bounded instruction text and only declared fields.") }
        var step: [String: Any] = ["instructions": instructions]
        budget += 128 + jsonEncodedStringByteCount(instructions)
        if let value = fields["name"] {
            guard case let .string(name) = value, name.utf8.count <= maximumCandidateInstructionBytes else {
                throw QuestionSettingInputError(message: "Instruction names must be bounded strings.")
            }
            step["name"] = name
            budget += jsonEncodedStringByteCount(name)
        }
        if let value = fields["default_visible"] {
            guard case let .bool(visible) = value else {
                throw QuestionSettingInputError(message: "default_visible must be a boolean.")
            }
            step["default_visible"] = visible
        }
        guard budget <= maxMCPWriteFieldBytes else {
            throw QuestionSettingInputError(message: "The encoded instruction array exceeds its byte limit.")
        }
        steps.append(step)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: steps) else {
        throw QuestionSettingInputError(message: "Instruction encoding failed.")
    }
    return String(decoding: data, as: UTF8.self)
}

func questionWriteBodySizeError(_ body: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= maxMCPWriteBodyBytes else {
        return "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes."
    }
    return nil
}
