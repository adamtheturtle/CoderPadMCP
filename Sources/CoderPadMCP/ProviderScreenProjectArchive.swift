import Foundation
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public let maximumScreenProjectArchiveBytes = 8 * 1024 * 1024

func screenProjectArchiveLink(_ arguments: [String: Value]?, account: MCPAccount) -> CallTool.Result {
    guard account.screenEnabled else { return errorResult("CoderPad Screen is not configured for this account.") }
    if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument, "test", "question"]) {
        return errorResult(error)
    }
    let test: Int? = switch arguments?["test"] {
    case let .int(value): value
    case let .double(value): Int(exactly: value)
    default: nil
    }
    guard let test, test > 0, test <= Int(Int32.max),
          case let .string(rawQuestion)? = arguments?["question"], let question = UUID(uuidString: rawQuestion)
    else {
        return errorResult("test must be a positive int32 and question must be a UUID.")
    }
    let identity = question.uuidString.lowercased()
    let uri = "coderpad://account/\(resourcePathComponent(account.id))/screen-project/\(test)/\(identity)"
    return CallTool.Result(content: [.resourceLink(
        uri: uri, name: "candidate-project-\(test)-\(identity).tar.gz", title: "Candidate project archive",
        description: "Read this resource to download the tar.gz archive, bounded to 8 MiB. No files are extracted or executed.",
        mimeType: "application/gzip",
    )])
}

func readScreenProjectArchive(test: Int, question: UUID, uri: String,
                              account: MCPAccount) async throws -> ReadResource.Result
{
    try Task.checkCancellation()
    guard let key = account.screenAPIKey else { throw MCPError.invalidParams("CoderPad Screen is not configured for this account.") }
    let path = "/assessment/api/v1.1/tests/\(test)/questions/\(question.uuidString.lowercased())/project"
    var request = URLRequest(url: account.screenBaseURL.appending(path: path))
    request.httpMethod = "GET"
    request.timeoutInterval = 120
    request.setValue(key, forHTTPHeaderField: "API-Key")
    request.setValue("application/gzip", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await ProviderRequestContext.screenResponse(request, maximumScreenProjectArchiveBytes)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        throw MCPError.internalError("Transport failure: \(classifyTransportError(error).rawValue)")
    }
    guard let response = response as? HTTPURLResponse else { throw MCPError.internalError("Transport failure: request_failed") }
    guard (200 ... 299).contains(response.statusCode) else {
        throw MCPError.internalError(sanitizedHTTPErrorMessage(status: response.statusCode, body: String(decoding: data, as: UTF8.self)))
    }
    guard data.count <= maximumScreenProjectArchiveBytes else { throw MCPError.internalError("Transport failure: response_too_large") }
    guard data.prefix(2) == Data([0x1F, 0x8B]) else { throw MCPError.internalError("Screen returned an invalid gzip archive.") }
    return ReadResource.Result(contents: [.binary(data, uri: uri, mimeType: "application/gzip")])
}
