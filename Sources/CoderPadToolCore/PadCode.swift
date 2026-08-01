//
//  PadCode.swift
//  CoderPadToolCore
//
//  The get_pad_code transform (#499): turn a fetched pad (and its environments) into
//  a compact { pad_id, title, files: [{ filename, language, contents }] }. Kept pure
//  — the executable does the fetching and hands the decoded JSON in here.
//

import Foundation

/// Parses a JSON object body into a dictionary, or nil if it isn't an object. Lets
/// the code tools pull fields out of the verbatim API JSON without binding to a rigid
/// Codable schema (keeping them resilient to API additions).
public func jsonObject(_ body: String) -> [String: Any]? {
    jsonObject(Data(body.utf8))
}

/// The raw-bytes form: callers holding an HTTP response body parse it directly rather
/// than stringifying it only for this function to encode it back to `Data` (#2120).
public func jsonObject(_ data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    return object
}

/// The cap applied when a caller doesn't provide one: the transform is bounded by
/// default so an omitted or invalid limit can never request an unbounded response
/// (#1589). Generous for real code files.
public let defaultMaxFileChars = 200_000

/// Truncates a file body to a UTF-8 byte budget, appending a marker noting how much
/// was dropped. Budgets are enforced on encoded bytes, never `String.count`: emoji or
/// combining input could pass a character cap yet blow a downstream byte/token limit
/// (#1588). The cut lands on a character boundary so no grapheme is split, and a
/// nil/non-positive limit falls back to `defaultMaxFileChars` rather than "unlimited"
/// (#1589). The marker itself adds at most ~64 bytes on top of the budget.
public func truncate(_ body: String, to maxChars: Int?) -> String {
    let limit = if let maxChars, maxChars > 0 {
        maxChars
    } else {
        defaultMaxFileChars
    }
    let totalBytes = body.utf8.count
    guard totalBytes > limit else { return body }

    let utf8 = body.utf8
    var cut = utf8.index(utf8.startIndex, offsetBy: limit)
    while cut > utf8.startIndex, String.Index(cut, within: body) == nil {
        cut = utf8.index(before: cut)
    }
    let index = String.Index(cut, within: body) ?? body.startIndex
    let kept = String(body[..<index])
    let dropped = totalBytes - kept.utf8.count
    return kept + "\n… [truncated, \(dropped) more bytes]"
}

/// Validates the optional get_pad_code file-size cap. Nil means unlimited; any
/// provided value must be positive so callers cannot accidentally request "no limit"
/// with 0 or a negative number.
public func maxFileCharsValidationError(_ maxFileChars: Int?) -> String? {
    guard let maxFileChars, maxFileChars <= 0 else { return nil }

    return "max_file_chars must be greater than 0 when provided."
}

/// A handful of common language → file extension mappings, used only to synthesize a
/// filename for legacy single-file pads, which have no path of their own.
public let languageExtensions: [String: String] = [
    "python": "py", "python3": "py", "javascript": "js", "typescript": "ts",
    "java": "java", "ruby": "rb", "go": "go", "golang": "go", "c": "c",
    "cpp": "cpp", "c++": "cpp", "csharp": "cs", "c#": "cs", "php": "php",
    "swift": "swift", "kotlin": "kt", "rust": "rs", "sql": "sql",
    "scala": "scala", "r": "r", "perl": "pl", "bash": "sh", "shell": "sh",
]

/// Synthesizes `main.<ext>` for a file that has no path of its own (legacy
/// single-file pads). Falls back to the language name as the extension only when it
/// is a short plain identifier - a remote language value carrying slashes, dots,
/// whitespace, or control characters must not become part of a filename (#1590) -
/// and to txt otherwise.
public func synthesizedFilename(language: String?) -> String {
    guard let language, !language.isEmpty else { return "main.txt" }

    let key = language.lowercased()
    if let known = languageExtensions[key] {
        return "main.\(known)"
    }

    let safe = key.count <= 10 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    return safe ? "main.\(key)" : "main.txt"
}

/// A fetched multi-file environment: its id and decoded JSON object.
public struct PadCodeEnvironment {
    public let id: Int
    public let object: [String: Any]

    public init(id: Int, object: [String: Any]) {
        self.id = id
        self.object = object
    }
}

/// The numeric environment ids referenced by a pad, coercing int and integer-string
/// forms only, keeping positive values, and preserving first-seen order while
/// dropping duplicates. Booleans, floats, and other JSON shapes are rejected rather
/// than coerced through their string descriptions (#1591).
public func environmentIDs(in pad: [String: Any]) -> [Int] {
    var seen = Set<Int>()
    return (pad["pad_environment_ids"] as? [Any])?
        .compactMap(environmentID(from:))
        .filter { seen.insert($0).inserted } ?? []
}

private func environmentID(from value: Any) -> Int? {
    // JSON booleans bridge to NSNumber and would pass an `as? Int` cast as 0/1.
    if value is Bool {
        return nil
    }
    let id: Int? = switch value {
    case let int as Int: int
    case let string as String: Int(string.trimmingCharacters(in: .whitespaces))
    default: nil
    }
    guard let id, id > 0 else { return nil }

    return id
}

/// Assembles the file list for a pad. Multi-file environments take precedence; a
/// legacy single-file pad's top-level "contents" is the fallback used only when the
/// pad declares no environments - including when it is present but empty, so an
/// intentionally blank single-file pad is distinguishable from a pad with no code
/// (#1596). Duplicate environment ids (a retried or malformed fetch) contribute
/// files once (#1592).
public func padCodeFiles(
    pad: [String: Any], environments: [PadCodeEnvironment], maxFileChars: Int?,
) -> [[String: Any]] {
    var files: [[String: Any]] = []
    var seenFilenames = Set<String>()

    var seenEnvironments = Set<Int>()
    for environment in environments where seenEnvironments.insert(environment.id).inserted {
        // An empty/whitespace file language is absent, not a value: it must not
        // shadow a valid environment-level language (#1595).
        let environmentLanguage = trimmedNonEmptyValue(environment.object["language"] as? String)
        let fileContents = environment.object["file_contents"] as? [[String: Any]] ?? []
        for file in fileContents {
            let language = trimmedNonEmptyValue(file["language"] as? String) ?? environmentLanguage
            let rawContents = file["contents"]
            let contents = rawContents as? String
            let isBinary = file["binary"] as? Bool == true
            let filename = uniqueFilename(
                sanitizedFilePath(file["path"] as? String) ?? synthesizedFilename(language: language),
                seen: &seenFilenames,
            )
            var entry: [String: Any] = [
                // Remote paths are untrusted: traversal, control characters, or
                // unbounded names must not flow into tool output that agents may
                // hand to file operations (#1593).
                "filename": filename,
                "environment_id": environment.id,
            ]
            if isBinary {
                entry["binary"] = true
            } else {
                entry["contents"] = truncate(contents ?? "", to: maxFileChars)
            }
            if let language {
                entry["language"] = language
            }
            // A present-but-non-string contents value is a schema problem the
            // caller must see, never a silently "empty" real file (#1594).
            if !isBinary, contents == nil, let rawContents, !(rawContents is NSNull) {
                entry["error"] = "The file's contents were not a string in the API response."
            }
            files.append(entry)
        }
    }

    if files.isEmpty, environmentIDs(in: pad).isEmpty, let contents = pad["contents"] as? String {
        let language = trimmedNonEmptyValue(pad["language"] as? String)
        let filename = uniqueFilename(synthesizedFilename(language: language), seen: &seenFilenames)
        var entry: [String: Any] = [
            "filename": filename,
            "contents": truncate(contents, to: maxFileChars),
        ]
        if let language {
            entry["language"] = language
        }
        files.append(entry)
    }

    return files
}

private func trimmedNonEmptyValue(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }

    return value
}

/// A remote file path reduced to a safe relative form: no control characters, no
/// leading separators, no `.`/`..` components, and a bounded length. Nil when
/// nothing safe remains, so the caller falls back to a synthesized name (#1593).
func sanitizedFilePath(_ raw: String?) -> String? {
    guard let value = trimmedNonEmptyValue(raw),
          !value.hasPrefix("/"),
          !value.contains("\\"),
          !value.contains(":"),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }

    let parts = value.split(separator: "/")
    guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    guard parts.allSatisfy({ $0.utf8.count <= 255 }) else { return nil }

    let joined = parts.joined(separator: "/")
    return joined.utf8.count <= 256 ? joined : nil
}

private func uniqueFilename(_ filename: String, seen: inout Set<String>) -> String {
    guard !seen.insert(filename).inserted else { return filename }

    let components = filename.split(separator: "/", omittingEmptySubsequences: false)
    let directory = components.dropLast().joined(separator: "/")
    let lastComponent = components.last.map(String.init) ?? filename
    let stem: String
    let extensionName: String
    if let dot = lastComponent.lastIndex(of: "."), dot != lastComponent.startIndex {
        stem = String(lastComponent[..<dot])
        extensionName = String(lastComponent[lastComponent.index(after: dot)...])
    } else {
        stem = lastComponent
        extensionName = ""
    }
    var suffix = 2
    while true {
        let component = extensionName.isEmpty
            ? "\(stem)-\(suffix)"
            : "\(stem)-\(suffix).\(extensionName)"
        let candidate = directory.isEmpty || directory == "."
            ? component
            : "\(directory)/\(component)"
        if seen.insert(candidate).inserted {
            return candidate
        }
        suffix += 1
    }
}

/// The full get_pad_code payload for a pad. Environments whose fetch failed must be
/// reported in `failedEnvironmentIDs`: the payload then carries `incomplete: true` and
/// `missing_environment_ids`, so a caller is never silently handed a partial file set
/// (#1015/#1036). Completeness is also *derived*, not just trusted: any environment
/// the pad references that isn't in `environments` counts as missing even when the
/// caller forgot to report it (#1598).
public func padCodePayload(
    id: String, pad: [String: Any], environments: [PadCodeEnvironment],
    maxFileChars: Int?, failedEnvironmentIDs: [Int] = [],
) -> [String: Any] {
    var payload: [String: Any] = [
        // Display fields are bounded and control-character-free so a malformed
        // response can't pollute MCP output or logs (#1597).
        "pad_id": sanitizedDisplayField(id, cap: 128),
        "title": sanitizedDisplayField(pad["title"] as? String ?? "", cap: 500),
        "files": padCodeFiles(pad: pad, environments: environments, maxFileChars: maxFileChars),
    ]
    let fetched = Set(environments.map(\.id))
    var missing = failedEnvironmentIDs
    for referenced in environmentIDs(in: pad)
        where !fetched.contains(referenced) && !missing.contains(referenced)
    {
        missing.append(referenced)
    }
    if !missing.isEmpty {
        payload["incomplete"] = true
        payload["missing_environment_ids"] = missing
        payload["incomplete_note"] = "Some pad environments could not be fetched; "
            + "the files list is missing their contents. Retry to get the full code."
    }
    return payload
}

/// A bounded, control-character-free copy of a display string (#1597).
private func sanitizedDisplayField(_ value: String, cap: Int) -> String {
    let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    return String(cleaned.prefix(cap))
}
