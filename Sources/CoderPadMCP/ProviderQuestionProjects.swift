import Foundation
import MCP

struct QuestionProjectInputError: Error {
    let message: String
}

func questionProjectLanguage(_ arguments: [String: Value]?) throws(QuestionProjectInputError) -> String? {
    guard let value = arguments?["language"] else { return nil }
    guard case let .string(language) = value, !language.isEmpty, language.utf8.count <= 100,
          language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else {
        throw QuestionProjectInputError(message: "language must be a bounded language key or project template slug.")
    }
    return language
}

func questionFilesJSONString(_ arguments: [String: Value]?) throws(QuestionProjectInputError) -> String? {
    guard let value = arguments?["file_contents"] else { return nil }
    guard arguments?["contents"] == nil else {
        throw QuestionProjectInputError(message: "contents and file_contents are mutually exclusive.")
    }
    guard case let .array(values) = value, values.count <= 200 else {
        throw QuestionProjectInputError(message: "file_contents must be an array of at most 200 files.")
    }
    var files: [[String: Any]] = []
    var paths: Set<String> = []
    var budget = 256
    for value in values {
        let file = try parentQuestionFile(value)
        let path = file["path"] as? String ?? ""
        guard paths.insert(path).inserted else { throw QuestionProjectInputError(message: "File paths must be unique.") }
        budget += 128 + file.values.compactMap { $0 as? String }.reduce(0) { $0 + jsonEncodedStringByteCount($1) }
        guard budget <= maxMCPWriteFieldBytes else {
            throw QuestionProjectInputError(message: "The encoded file array exceeds its byte limit.")
        }
        files.append(file)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: files) else {
        throw QuestionProjectInputError(message: "File encoding failed.")
    }
    return String(decoding: data, as: UTF8.self)
}

private func parentQuestionFile(_ value: Value) throws(QuestionProjectInputError) -> [String: Any] {
    guard case let .object(fields) = value,
          Set(fields.keys).isSubset(of: ["path", "contents", "hidden", "deleted"]),
          case let .string(path)? = fields["path"], validQuestionProjectPath(path)
    else {
        throw QuestionProjectInputError(message: "Each file needs a safe relative path and only declared file fields.")
    }
    var file: [String: Any] = ["path": path]
    for key in ["hidden", "deleted"] {
        if let value = fields[key] {
            guard case let .bool(flag) = value else { throw QuestionProjectInputError(message: "\(key) must be a boolean.") }
            file[key] = flag
        }
    }
    if let value = fields["contents"] {
        guard case let .string(contents) = value, contents.utf8.count <= maxMCPWriteFieldBytes else {
            throw QuestionProjectInputError(message: "File contents must be a bounded string.")
        }
        file["contents"] = contents
    }
    guard file["contents"] != nil || file["deleted"] as? Bool == true else {
        throw QuestionProjectInputError(message: "A file requires contents unless deleted is true.")
    }
    if path == ".cpad", file["deleted"] as? Bool == true {
        throw QuestionProjectInputError(message: "The .cpad file cannot be deleted.")
    }
    return file
}

private func validQuestionProjectPath(_ path: String) -> Bool {
    guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
          !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
    else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
