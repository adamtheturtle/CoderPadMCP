//
//  ProviderResults.swift
//  CoderPadMCP
//
//  Small result and paging helpers shared by the CoderPad tool provider.
//

import Foundation
import MCP

func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

/// Encodes a result dictionary as pretty JSON text.
func jsonResult(_ object: [String: Any]) -> CallTool.Result {
    guard let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys],
    ) else {
        return CallTool.Result(
            content: [.text(text: "Could not encode the result.", annotations: nil, _meta: nil)],
            isError: true,
        )
    }

    return CallTool.Result(
        content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
        isError: nil,
    )
}

func pagingQuery(_ arguments: [String: Value]?) -> [URLQueryItem] {
    var query: [URLQueryItem] = []
    if let page = strictIntArgument(arguments, "page") {
        query.append(URLQueryItem(name: "page", value: String(page)))
    }
    if let sort = normalizedPagingSort(stringArgument(arguments, "sort")) {
        query.append(URLQueryItem(name: "sort", value: sort))
    }
    return query
}
