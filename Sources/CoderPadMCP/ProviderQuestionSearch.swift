import Foundation
import MCP

struct QuestionSearchInputError: Error {
    let message: String
}

func questionSearchQuery(_ arguments: [String: Value]?) throws(QuestionSearchInputError) -> [URLQueryItem] {
    var query: [URLQueryItem] = []
    if let value = arguments?["text"] {
        guard case let .string(text) = value, text.utf8.count <= maximumQuestionSearchBytes else {
            throw QuestionSearchInputError(message: "text must be a string of at most \(maximumQuestionSearchBytes) UTF-8 bytes.")
        }
        query.append(URLQueryItem(name: "text", value: text))
    }
    if let value = arguments?["pad_types"] {
        guard case let .array(types) = value, types.count <= maximumQuestionPadTypeFilters else {
            throw QuestionSearchInputError(message: "pad_types must be an array of at most \(maximumQuestionPadTypeFilters) usage categories.")
        }
        for value in types {
            guard case let .string(type) = value, ["any", "live", "take_home"].contains(type) else {
                throw QuestionSearchInputError(message: "Each pad_types value must be any, live, or take_home.")
            }
            query.append(URLQueryItem(name: "pad_types[]", value: type))
        }
    }
    return query
}

func questionListQuery(_ arguments: [String: Value]?) throws(QuestionSearchInputError) -> [URLQueryItem] {
    if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument, "page", "sort", "text", "pad_types"]) {
        throw QuestionSearchInputError(message: error)
    }
    if let error = pageValidationError(strictIntArgument(arguments, "page")) {
        throw QuestionSearchInputError(message: error)
    }
    var query: [URLQueryItem] = []
    if let page = strictIntArgument(arguments, "page") {
        query.append(URLQueryItem(name: "page", value: String(page)))
    }
    if let value = arguments?["sort"] {
        guard case let .string(raw) = value, let sort = normalizedQuestionPagingSort(raw) else {
            throw QuestionSearchInputError(message: "sort must be created_at, updated_at, title, or used with an optional asc or desc direction.")
        }
        query.append(URLQueryItem(name: "sort", value: sort))
    }
    query += try questionSearchQuery(arguments)
    return query
}

func questionSearchEcho(_ arguments: [String: Value]?, into filters: inout [String: Any]) {
    if case let .string(text)? = arguments?["text"] {
        filters["text"] = text
    }
    if case let .array(types)? = arguments?["pad_types"] {
        filters["pad_types"] = types.compactMap {
            if case let .string(type) = $0 {
                type
            } else {
                nil
            }
        }
    }
}
