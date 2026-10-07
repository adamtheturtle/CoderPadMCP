import Foundation
import MCP

func screenWriteObject(_ value: Value, schema: [String: Any], path: String,
                       budget: inout Int) throws(ScreenWriteInputError) -> [String: Any]
{
    guard case let .object(fields) = value, fields.count <= (schema["maxProperties"] as? Int ?? 200) else {
        throw ScreenWriteInputError(message: "\(path) must be a bounded object.")
    }
    let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
    let additional = schema["additionalProperties"] as? [String: Any]
    let arbitrary = schema["additionalProperties"] as? Bool == true
    guard additional != nil || arbitrary || Set(fields.keys).isSubset(of: Set(properties.keys)) else {
        throw ScreenWriteInputError(message: "\(path) contains an unsupported or read-only field.")
    }
    for key in schema["required"] as? [String] ?? [] where fields[key] == nil {
        throw ScreenWriteInputError(message: "\(path).\(key) is required.")
    }
    var object: [String: Any] = [:]
    for key in fields.keys.sorted() {
        guard let field = fields[key], !key.isEmpty, key.utf8.count <= 1024 else {
            throw ScreenWriteInputError(message: "\(path) contains an invalid key.")
        }
        budget += jsonEncodedStringByteCount(key)
        if let property = properties[key] ?? additional {
            object[key] = try screenWriteValue(field, schema: property, path: path + "." + key, budget: &budget)
        } else if arbitrary {
            object[key] = try boundedScreenJSON(field, depth: 0, budget: &budget)
        }
    }
    return object
}

private func boundedScreenJSON(_ value: Value, depth: Int, budget: inout Int) throws(ScreenWriteInputError) -> Any {
    budget += 16
    guard depth <= 16, budget <= maxMCPWriteBodyBytes else {
        throw ScreenWriteInputError(message: "The JSON Schema value exceeds its nesting or byte limit.")
    }
    switch value {
    case let .string(string):
        budget += jsonEncodedStringByteCount(string)
        guard budget <= maxMCPWriteBodyBytes else { throw ScreenWriteInputError(message: "The JSON Schema value exceeds its byte limit.") }
        return string
    case let .int(number): return number
    case let .double(number):
        guard number.isFinite else { throw ScreenWriteInputError(message: "JSON numbers must be finite.") }
        return number
    case let .bool(boolean): return boolean
    case .null: return NSNull()
    case let .array(values):
        guard values.count <= 200 else { throw ScreenWriteInputError(message: "JSON arrays are limited to 200 items.") }
        var output: [Any] = []
        for item in values {
            try output.append(boundedScreenJSON(item, depth: depth + 1, budget: &budget))
        }
        return output
    case let .object(fields):
        guard fields.count <= 200 else { throw ScreenWriteInputError(message: "JSON objects are limited to 200 fields.") }
        var output: [String: Any] = [:]
        for (key, item) in fields {
            guard key.utf8.count <= 1024 else { throw ScreenWriteInputError(message: "JSON object keys exceed their byte limit.") }
            budget += jsonEncodedStringByteCount(key)
            output[key] = try boundedScreenJSON(item, depth: depth + 1, budget: &budget)
        }
        return output
    default: throw ScreenWriteInputError(message: "Unsupported JSON value.")
    }
}
