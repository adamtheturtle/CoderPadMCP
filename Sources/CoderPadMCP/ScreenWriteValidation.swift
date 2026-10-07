import Foundation
import MCP

struct ScreenWriteInputError: Error {
    let message: String
}

func screenWriteValue(_ value: Value, schema: [String: Any], path: String,
                      budget: inout Int) throws(ScreenWriteInputError) -> Any
{
    budget += 16
    guard budget <= maxMCPWriteBodyBytes else { throw ScreenWriteInputError(message: "The Screen write body exceeds its byte limit.") }
    switch schema["type"] as? String {
    case "object":
        return try screenWriteObject(value, schema: schema, path: path, budget: &budget)
    case "array":
        guard case let .array(values) = value, let items = schema["items"] as? [String: Any],
              values.count >= (schema["minItems"] as? Int ?? 0), values.count <= (schema["maxItems"] as? Int ?? 200)
        else {
            throw ScreenWriteInputError(message: "\(path) must be an array within its item limits.")
        }
        var array: [Any] = []
        for (index, item) in values.enumerated() {
            try array.append(screenWriteValue(item, schema: items, path: "\(path)[\(index)]", budget: &budget))
        }
        return array
    case "string":
        guard case let .string(string) = value,
              string.unicodeScalars.count >= (schema["minLength"] as? Int ?? 0),
              string.unicodeScalars.count <= (schema["maxLength"] as? Int ?? 4096),
              (schema["enum"] as? [String]).map({ $0.contains(string) }) ?? true
        else {
            throw ScreenWriteInputError(message: "\(path) must be a bounded string with a supported value.")
        }
        if schema["format"] as? String == "uuid", UUID(uuidString: string) == nil {
            throw ScreenWriteInputError(message: "\(path) must be a UUID.")
        }
        if schema["format"] as? String == "date-time", campaignInstant(string) == nil {
            throw ScreenWriteInputError(message: "\(path) must be an ISO 8601 instant.")
        }
        budget += jsonEncodedStringByteCount(string)
        guard budget <= maxMCPWriteBodyBytes else { throw ScreenWriteInputError(message: "The Screen write body exceeds its byte limit.") }
        return string
    case "boolean":
        guard case let .bool(boolean) = value else { throw ScreenWriteInputError(message: "\(path) must be a boolean.") }
        return boolean
    case "integer":
        let number: Int? = switch value {
        case let .int(value): value
        case let .double(value): Int(exactly: value)
        default: nil
        }
        guard let number, number >= (schema["minimum"] as? Int ?? 0), number <= (schema["maximum"] as? Int ?? Int(Int32.max)) else {
            throw ScreenWriteInputError(message: "\(path) must be an integer within its limits.")
        }
        return number
    default:
        throw ScreenWriteInputError(message: "Unsupported Screen input schema for \(path).")
    }
}

func campaignInstant(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
