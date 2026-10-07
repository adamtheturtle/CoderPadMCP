import Foundation
import MCP

private struct SavedScreenQuestion: Decodable {
    let id: UUID
}

func screenSaveQuestion(_ arguments: [String: Value]?, account: MCPAccount, update: Bool) async throws -> CallTool.Result {
    guard account.screenEnabled else { return errorResult("CoderPad Screen is not configured for this account.") }
    var allowed: Set<String> = [mcpAccountArgument, "payload", "dry_run"]
    if update {
        allowed.insert("question")
    }
    if let error = unknownArgumentError(arguments, allowed: allowed) {
        return errorResult(error)
    }
    let id = stringArgument(arguments, "question").flatMap(UUID.init(uuidString:))
    if update, id == nil {
        return errorResult("question must be a UUID.")
    }
    guard let payload = arguments?["payload"] else { return missingArgument("payload") }
    let body: [String: Any]
    do {
        var budget = 256
        guard let object = try screenWriteValue(payload, schema: screenQuestionWriteSchema,
                                                path: "payload", budget: &budget) as? [String: Any]
        else {
            return errorResult("Question encoding failed.")
        }
        try validateScreenQuestionSave(object, update: update)
        body = object
    } catch {
        return errorResult(error.message)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= maxMCPWriteBodyBytes else {
        return errorResult("The Screen write body exceeds its byte limit.")
    }
    let path = "/questions" + (id.map { "/" + $0.uuidString.lowercased() } ?? "")
    let method = update ? "PUT" : "POST"
    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: method, path: "/assessment/api/v1.1" + path, body: body)
    }
    let response = try await screenSend(method, path: path, account: account, data: data, contentType: "application/json")
    guard response.ok, apiErrorEnvelopeMessage(in: response.data) == nil else { return toolResult(response) }
    guard let saved = try? JSONDecoder().decode(SavedScreenQuestion.self, from: response.data),
          let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
    else {
        return errorResult("Screen question saving returned no usable UUID question details.")
    }
    if update, saved.id != id {
        return errorResult("Screen question saving returned a different question UUID.")
    }
    return jsonResult(["question": object, "location": response.location.map { $0 as Any } ?? NSNull(), "status": response.status])
}

func screenUploadProject(_ arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    guard account.screenEnabled else { return errorResult("CoderPad Screen is not configured for this account.") }
    if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument, "archive_uri", "dry_run"]) {
        return errorResult(error)
    }
    guard case let .string(uri)? = arguments?["archive_uri"], !uri.isEmpty, uri.utf8.count <= 4096,
          URL(string: uri)?.scheme != nil else { return errorResult("archive_uri must be an explicit bounded resource URI.") }
    let archive: Data
    do {
        archive = try await ProviderRequestContext.archiveInput(uri, 52_428_800)
        try Task.checkCancellation()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return errorResult("The selected archive could not be read within the 52,428,800 byte limit.")
    }
    guard archive.count <= 52_428_800, archive.count >= 2, archive.prefix(2) == Data([0x1F, 0x8B]) else {
        return errorResult("The selected resource must be a gzip archive within the 52,428,800 byte limit.")
    }
    if strictDryRunArgument(arguments) == .value(true) {
        return jsonResult([
            "dry_run": true, "method": "POST", "path": "/assessment/api/v1.1/temporary-file",
            "archive_uri": uri, "headers": ["Content-Type": "application/gzip", "Content-Length": String(archive.count)],
        ])
    }
    let response = try await screenSend("POST", path: "/temporary-file", account: account, data: archive, contentType: "application/gzip")
    if response.ok {
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = object["id"] as? String, UUID(uuidString: id) != nil
        else {
            return errorResult("Screen upload returned no usable temporary file UUID.")
        }
    }
    return toolResult(response)
}
