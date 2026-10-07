import Foundation
import MCP

private struct VariantInputError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

func dispatchQuestionVariant(
    name: String,
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    let write = coderPadWriteToolNames.contains(name)
    let single = name == "get_question_variant" || name == "update_question_variant"
    var allowed: Set<String> = [mcpAccountArgument, "question"]
    if single {
        allowed.insert("variant")
    }
    if write {
        allowed.formUnion(["language", "solution", "contents", "file_contents", "dry_run"])
    }
    if let error = unknownArgumentError(arguments, allowed: allowed) {
        return errorResult(error)
    }
    guard let question = positiveID(strictIntArgument(arguments, "question")) else {
        return errorResult("question must be a positive integer.")
    }
    var path = "/api/questions/\(question)/variants"
    if single {
        guard let variant = positiveID(strictIntArgument(arguments, "variant")) else {
            return errorResult("variant must be a positive integer.")
        }
        path += "/\(variant)"
    }
    if !write {
        return try await toolResult(apiGet(path, account: account))
    }
    let body: [String: Any]
    do {
        body = try variantMutationBody(arguments, creating: !single)
    } catch let error as VariantInputError {
        return errorResult(error.message)
    }
    let method = single ? "PUT" : "POST"
    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: method, path: path, body: body)
    }
    let result = try await toolResult(apiSend(method, path, account: account, body: body))
    return await invalidating(result, kind: .questions, account: account, cache: cache, dryRun: false)
}

private func variantMutationBody(_ arguments: [String: Value]?, creating: Bool) throws -> [String: Any] {
    var body: [String: Any] = [:]
    for key in ["language", "solution"] {
        if let value = arguments?[key] {
            guard case let .string(string) = value else { throw VariantInputError(message: "\(key) must be a string.") }
            guard string.utf8.count <= (key == "language" ? 100 : maxMCPWriteFieldBytes) else {
                throw VariantInputError(message: "\(key) exceeds its UTF-8 byte limit.")
            }
            if key == "language", string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw VariantInputError(message: "language must not be blank.")
            }
            body[key] = string
        }
    }
    if creating, body["language"] == nil {
        throw VariantInputError(message: "Creating a variant requires language.")
    }
    if let value = arguments?["contents"] {
        switch value {
        case let .string(string):
            guard string.utf8.count <= maxMCPWriteFieldBytes else {
                throw VariantInputError(message: "contents exceeds its UTF-8 byte limit.")
            }
            body["contents"] = string
        case .null: body["contents"] = NSNull()
        default: throw VariantInputError(message: "contents must be a string or null.")
        }
    }
    if let value = arguments?["file_contents"] {
        guard body["contents"] == nil else {
            throw VariantInputError(message: "contents and file_contents are mutually exclusive.")
        }
        guard case let .array(files) = value, files.count <= 200 else {
            throw VariantInputError(message: "file_contents must be an array of at most 200 files.")
        }
        var budget = 256 + body.values.compactMap { $0 as? String }.reduce(0) { $0 + jsonEncodedStringByteCount($1) }
        var decodedFiles: [[String: Any]] = []
        for value in files {
            let file = try variantFile(value)
            budget += 128 + file.values.compactMap { $0 as? String }.reduce(0) { $0 + jsonEncodedStringByteCount($1) }
            guard budget <= maxMCPWriteBodyBytes else {
                throw VariantInputError(message: "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes.")
            }
            decodedFiles.append(file)
        }
        body["file_contents"] = decodedFiles
    }
    guard !body.isEmpty else { throw VariantInputError(message: "Supply at least one variant field to update.") }
    let stringBudget = 256 + body.values.compactMap { $0 as? String }.reduce(0) { $0 + jsonEncodedStringByteCount($1) }
    guard stringBudget <= maxMCPWriteBodyBytes else {
        throw VariantInputError(message: "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes.")
    }
    let data = try JSONSerialization.data(withJSONObject: body)
    guard data.count <= maxMCPWriteBodyBytes else {
        throw VariantInputError(message: "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes.")
    }
    return body
}

private func variantFile(_ value: Value) throws -> [String: Any] {
    guard case let .object(fields) = value,
          Set(fields.keys).isSubset(of: ["path", "contents", "hidden", "deleted"]),
          case let .string(path)? = fields["path"], validVariantPath(path)
    else {
        throw VariantInputError(message: "Each file needs a safe relative path and only declared file fields.")
    }
    var file: [String: Any] = ["path": path]
    for key in ["hidden", "deleted"] {
        if let value = fields[key] {
            guard case let .bool(flag) = value else { throw VariantInputError(message: "\(key) must be a boolean.") }
            file[key] = flag
        }
    }
    if let value = fields["contents"] {
        guard case let .string(contents) = value, contents.utf8.count <= maxMCPWriteFieldBytes else {
            throw VariantInputError(message: "File contents must be a string within the UTF-8 byte limit.")
        }
        file["contents"] = contents
    }
    guard file["contents"] != nil || file["deleted"] as? Bool == true else {
        throw VariantInputError(message: "A file requires contents unless deleted is true.")
    }
    if path == ".cpad", file["deleted"] as? Bool == true {
        throw VariantInputError(message: "The .cpad file cannot be deleted.")
    }
    return file
}

private func validVariantPath(_ path: String) -> Bool {
    guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
          !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
    else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
