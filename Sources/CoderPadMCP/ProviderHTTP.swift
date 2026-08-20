//
//  ProviderHTTP.swift
//  CoderPadMCP
//

import CoderPadKit
import Foundation
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private let screenAPIPrefix = "/assessment/api/v1.1"
private let interviewReadResponseLimit = 8 * 1024 * 1024
private let interviewWriteResponseLimit = 1 * 1024 * 1024
private let screenReadResponseLimit = 8 * 1024 * 1024

typealias InterviewRequest = @Sendable (
    _ method: String,
    _ path: String,
    _ account: MCPAccount,
    _ query: [URLQueryItem],
    _ body: Data?,
    _ responseLimit: Int,
) async throws -> APIResponse

let liveInterviewRequest: InterviewRequest = { method, path, account, query, body, responseLimit in
    let response = try await CoderPadClient(
        apiKey: account.apiKey,
        baseURL: account.baseURL,
    ).rawRequest(
        method: method,
        path: path,
        query: query,
        body: body,
        responseLimit: responseLimit,
    )
    return APIResponse(status: response.status, data: response.data)
}

enum ProviderRequestContext {
    @TaskLocal static var interviewRequest = liveInterviewRequest
}

/// Locally synthesized transport failures use status 0 with a safe category token in the
/// body so callers can act without hashing an opaque fingerprint.
enum TransportFailureCategory: String, Sendable {
    case offline
    case timeout
    case responseTooLarge = "response_too_large"
    case invalidURL = "invalid_url"
    case encodingFailed = "encoding_failed"
    case screenNotConfigured = "screen_not_configured"
    case requestFailed = "request_failed"
}

func transportFailureResponse(_ category: TransportFailureCategory) -> APIResponse {
    APIResponse(status: 0, body: category.rawValue)
}

func classifyTransportError(_ error: Error) -> TransportFailureCategory {
    if error is BoundedHTTPResponseError {
        return .responseTooLarge
    }
    let text = error.localizedDescription.lowercased()
    if text.contains("timed out") || text.contains("timeout") {
        return .timeout
    }
    if text.contains("offline")
        || text.contains("not connected")
        || text.contains("network connection was lost")
        || text.contains("could not connect")
        || text.contains("dns")
        || text.contains("name or service not known")
        || text.contains("nodename nor servname")
    {
        return .offline
    }
    return .requestFailed
}

/// Performs an authenticated GET against an account and returns the status and raw body.
func apiGet(_ path: String, account: MCPAccount, query: [URLQueryItem] = []) async throws -> APIResponse {
    try Task.checkCancellation()
    do {
        return try await ProviderRequestContext.interviewRequest(
            "GET", path, account, query, nil, interviewReadResponseLimit,
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return transportFailureResponse(classifyTransportError(error))
    }
}

func toolResult(_ response: APIResponse) -> CallTool.Result {
    guard response.ok else {
        if response.status == 0 {
            let category = TransportFailureCategory(rawValue: response.body) ?? .requestFailed
            return errorResult("Transport failure: \(category.rawValue)")
        }
        return errorResult(sanitizedHTTPErrorMessage(status: response.status, body: response.body))
    }
    guard isValidJSONObjectOrArray(response.data) else {
        return errorResult("CoderPad returned an invalid JSON response.")
    }
    if let message = apiErrorEnvelopeMessage(in: response.data) {
        return errorResult(message)
    }

    return CallTool.Result(content: [.text(text: response.body, annotations: nil, _meta: nil)], isError: nil)
}

/// Performs an authenticated write (POST/PUT) against an account with a JSON body.
func apiSend(
    _ method: String,
    _ path: String,
    account: MCPAccount,
    body: [String: Any],
) async throws -> APIResponse {
    try Task.checkCancellation()
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
        return transportFailureResponse(.encodingFailed)
    }

    do {
        return try await ProviderRequestContext.interviewRequest(
            method, path, account, [], payload, interviewWriteResponseLimit,
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return transportFailureResponse(classifyTransportError(error))
    }
}

/// An authenticated GET against the CoderPad Screen API for an account, which uses an
/// `API-Key` header (not Bearer) and its own host + version prefix.
func screenGet(_ path: String, account: MCPAccount, query: [URLQueryItem] = []) async throws -> APIResponse {
    try Task.checkCancellation()
    guard let key = account.screenAPIKey else {
        return transportFailureResponse(.screenNotConfigured)
    }
    guard var comps = URLComponents(
        url: account.screenBaseURL.appending(path: screenAPIPrefix + path), resolvingAgainstBaseURL: false,
    ) else {
        return transportFailureResponse(.invalidURL)
    }

    let items = query.filter { ($0.value ?? "").isEmpty == false }
    if !items.isEmpty {
        comps.queryItems = items
    }
    guard let url = comps.url else {
        return transportFailureResponse(.invalidURL)
    }

    var request = URLRequest(url: url)
    request.setValue(key, forHTTPHeaderField: "API-Key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
        let (data, response) = try await boundedResponseData(
            for: request,
            limit: screenReadResponseLimit,
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return APIResponse(status: status, data: data)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return transportFailureResponse(classifyTransportError(error))
    }
}
