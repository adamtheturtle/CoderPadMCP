import Foundation
import MCP

func dispatchScreenQuestionRead(
    name: String,
    arguments: [String: Value]?,
    account: MCPAccount,
) async throws -> CallTool.Result {
    if name == "screen_list_questions" {
        do {
            return try await toolResult(screenGet("/questions", account: account, query: screenQuestionListQuery(arguments)))
        } catch let error as ScreenQuestionReadInputError {
            return errorResult(error.message)
        }
    }
    let insights = name == "screen_question_insights"
    let allowed: Set<String> = insights ? [mcpAccountArgument, "question", "programming_language"] : [mcpAccountArgument, "question"]
    if let error = unknownArgumentError(arguments, allowed: allowed) {
        return errorResult(error)
    }
    guard case let .string(raw)? = arguments?["question"], raw.count == 36, let id = UUID(uuidString: raw) else {
        return errorResult("question must be a UUID string.")
    }
    var query: [URLQueryItem] = []
    if insights, let value = arguments?["programming_language"] {
        guard case let .string(language) = value, validScreenQuestionString(language) else {
            return errorResult("programming_language must be a nonblank string of at most 200 UTF-8 bytes.")
        }
        query.append(URLQueryItem(name: "programming_language", value: language))
    }
    let path = "/questions/\(id.uuidString.lowercased())" + (insights ? "/insights" : "")
    return try await toolResult(screenGet(path, account: account, query: query))
}

private struct ScreenQuestionReadInputError: Error {
    let message: String
}

private func screenQuestionListQuery(_ arguments: [String: Value]?) throws -> [URLQueryItem] {
    let fields = ["start", "limit", "type", "duration_seconds_min", "duration_seconds_max", "difficulty", "domain", "skill",
                  "programming_language", "from_coderpad_question_bank", "product", "sort", "order"]
    if let error = unknownArgumentError(arguments, allowed: Set(fields + [mcpAccountArgument])) {
        throw ScreenQuestionReadInputError(message: error)
    }
    var query: [URLQueryItem] = []
    var integerValues: [String: Int] = [:]
    let enumValues = ["difficulty": ["EASY", "MEDIUM", "HARD"], "product": ["SCREEN", "QUALIFY"],
                      "sort": screenQuestionSortFields, "order": ["asc", "desc"]]
    for field in fields {
        guard let value = arguments?[field] else { continue }
        if ["start", "limit", "duration_seconds_min", "duration_seconds_max"].contains(field) {
            let maximum = field == "start" ? maxPaginationStart : field == "limit" ? maximumScreenQuestionPageSize : Int(Int32.max)
            let minimum = field == "limit" ? 1 : 0
            let number: Int? = switch value {
            case let .int(integer): integer
            case let .double(double): Int(exactly: double)
            default: nil
            }
            guard let number, (minimum ... maximum).contains(number) else {
                throw ScreenQuestionReadInputError(message: "\(field) must be between \(minimum) and \(maximum).")
            }
            integerValues[field] = number
            query.append(URLQueryItem(name: field, value: String(number)))
        } else if field == "from_coderpad_question_bank" {
            guard case let .bool(flag) = value else { throw ScreenQuestionReadInputError(message: "\(field) must be a boolean.") }
            query.append(URLQueryItem(name: field, value: flag ? "true" : "false"))
        } else {
            guard case let .string(string) = value, validScreenQuestionString(string),
                  enumValues[field]?.contains(string) ?? true
            else {
                throw ScreenQuestionReadInputError(message: "\(field) must be a valid nonblank string within the byte limit.")
            }
            query.append(URLQueryItem(name: field, value: string))
        }
    }
    if let minimum = integerValues["duration_seconds_min"], let maximum = integerValues["duration_seconds_max"], minimum > maximum {
        throw ScreenQuestionReadInputError(message: "duration_seconds_min must not exceed duration_seconds_max.")
    }
    return query
}

private func validScreenQuestionString(_ string: String) -> Bool {
    !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && string.utf8.count <= 200
}
