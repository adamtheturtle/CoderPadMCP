import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A single bounded Screen mutation. The transport never retries a write.
func screenSend(_ method: String, path: String, account: MCPAccount, data: Data,
                contentType: String) async throws -> APIResponse
{
    try Task.checkCancellation()
    guard let key = account.screenAPIKey else { return transportFailureResponse(.screenNotConfigured) }
    let url = account.screenBaseURL.appending(path: "/assessment/api/v1.1" + path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = data
    request.setValue(key, forHTTPHeaderField: "API-Key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    do {
        let (responseData, response) = try await ProviderRequestContext.screenResponse(request, 1024 * 1024)
        guard let response = response as? HTTPURLResponse else { return transportFailureResponse(.requestFailed) }
        return APIResponse(status: response.statusCode, data: responseData)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return transportFailureResponse(classifyTransportError(error))
    }
}
