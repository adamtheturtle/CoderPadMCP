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

/// The per-file UTF-8 byte cap applied when a caller omits `max_file_chars`: the
/// transform is bounded by default so an omitted or invalid limit can never request
/// an unbounded response (#126, #1589). Generous for real code files.
public let defaultMaxFileChars = 200_000
public let maxPadCodeFiles = 100
public let maxPadCodeContentBytes = 800_000
public let maxPadCodePathBytes = 256
public let maxPadCodePathComponentBytes = 255

/// Truncates a file body to a UTF-8 byte budget, appending a marker noting how much
/// was dropped. Budgets are enforced on encoded bytes, never `String.count`: emoji or
/// combining input could pass a character cap yet blow a downstream byte/token limit
/// (#127, #1588). The cut lands on a character boundary so no grapheme is split, and a
/// nil/non-positive limit falls back to `defaultMaxFileChars` rather than "unlimited"
/// (#126, #1589). The truncation marker is included inside the budget so the returned
/// contents never exceed the requested byte cap (#128).
public func truncate(_ body: String, to maxChars: Int?) -> String {
    let limit = if let maxChars, maxChars > 0 {
        maxChars
    } else {
        defaultMaxFileChars
    }
    let totalBytes = body.utf8.count
    guard totalBytes > limit else { return body }

    let markerOverheadEstimate = truncationMarker(droppedBytes: totalBytes).utf8.count
    let contentBudget = max(0, limit - markerOverheadEstimate)
    var kept = utf8Prefix(body, maxBytes: contentBudget)
    var dropped = totalBytes - kept.utf8.count
    var result = kept + truncationMarker(droppedBytes: dropped)
    while result.utf8.count > limit, !kept.isEmpty {
        let shrinkBy = max(1, result.utf8.count - limit)
        kept = utf8Prefix(kept, maxBytes: max(0, kept.utf8.count - shrinkBy))
        dropped = totalBytes - kept.utf8.count
        result = kept + truncationMarker(droppedBytes: dropped)
    }
    return result.utf8.count <= limit ? result : utf8Prefix(result, maxBytes: limit)
}

private func truncationMarker(droppedBytes: Int) -> String {
    "\n… [truncated, \(droppedBytes) more bytes]"
}

/// Validates the optional get_pad_code file-size cap. Nil selects the documented
/// default per-file UTF-8 byte cap; any provided value must be positive so callers
/// cannot accidentally request "no limit" with 0 or a negative number.
public func maxFileCharsValidationError(_ maxFileChars: Int?) -> String? {
    guard let maxFileChars, maxFileChars <= 0 else { return nil }

    return "max_file_chars must be greater than 0 when provided."
}

/// Language → file extension mappings for synthesizing filenames on legacy
/// single-file pads. Covers every creatable pad language (#180).
public let languageExtensions: [String: String] = [
    "python": "py", "python2": "py", "python3": "py",
    "javascript": "js", "nodejs": "js", "typescript": "ts",
    "java": "java", "ruby": "rb", "go": "go", "golang": "go", "c": "c",
    "cpp": "cpp", "c++": "cpp", "csharp": "cs", "c#": "cs", "php": "php",
    "swift": "swift", "kotlin": "kt", "rust": "rs", "sql": "sql",
    "mysql": "sql", "postgresql": "sql",
    "scala": "scala", "r": "r", "perl": "pl", "bash": "sh", "shell": "sh",
    "objective-c": "m", "elixir": "ex", "erlang": "erl", "haskell": "hs",
    "lua": "lua", "dart": "dart", "clojure": "clj", "ocaml": "ml",
    "fsharp": "fs", "julia": "jl", "solidity": "sol", "tcl": "tcl",
    "verilog": "v", "html": "html", "css": "css", "markdown": "md",
    "plaintext": "txt",
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

private struct PadCodeFileAssembly {
    let files: [[String: Any]]
    let omittedFileCount: Int
    let omittedEnvironmentIDs: [Int]
    let schemaErrors: [String]
}

public let maxPadCodeEnvironments = 100
public let maxConcurrentPadCodeEnvironmentRequests = 6

public func environmentCountValidationError(_ ids: [Int]) -> String? {
    guard ids.count > maxPadCodeEnvironments else { return nil }
    return "The pad references more than \(maxPadCodeEnvironments) environments."
}

/// How `pad_environment_ids` was interpreted while collecting numeric ids.
public struct PadEnvironmentIDParse {
    public let ids: [Int]
    /// True when `pad_environment_ids` is present but not a JSON array (#120).
    public let malformedContainer: Bool
    /// True when at least one array element could not be coerced to a positive id (#121).
    public let rejectedElement: Bool

    public init(ids: [Int], malformedContainer: Bool, rejectedElement: Bool) {
        self.ids = ids
        self.malformedContainer = malformedContainer
        self.rejectedElement = rejectedElement
    }
}

/// The numeric environment ids referenced by a pad, coercing int and integer-string
/// forms only, keeping positive values, and preserving first-seen order while
/// dropping duplicates. Booleans, floats, and other JSON shapes are rejected rather
/// than coerced through their string descriptions (#1591).
public func environmentIDs(in pad: [String: Any]) -> [Int] {
    parsePadEnvironmentIDs(in: pad).ids
}

/// Like `environmentIDs(in:)` but also reports malformed containers and rejected
/// elements so callers can mark the pad-code payload incomplete (#120, #121).
public func parsePadEnvironmentIDs(in pad: [String: Any]) -> PadEnvironmentIDParse {
    guard let raw = pad["pad_environment_ids"] else {
        return PadEnvironmentIDParse(ids: [], malformedContainer: false, rejectedElement: false)
    }
    guard let values = raw as? [Any] else {
        return PadEnvironmentIDParse(ids: [], malformedContainer: true, rejectedElement: false)
    }

    var seen = Set<Int>()
    var ids: [Int] = []
    var rejectedElement = false
    for value in values {
        guard let id = environmentID(from: value) else {
            rejectedElement = true
            continue
        }
        if seen.insert(id).inserted {
            ids.append(id)
        }
    }
    return PadEnvironmentIDParse(ids: ids, malformedContainer: false, rejectedElement: rejectedElement)
}

func environmentID(from value: Any) -> Int? {
    // JSON booleans bridge to NSNumber and would pass an `as? Int` cast as 0/1.
    if value is Bool {
        return nil
    }
    let id: Int? = switch value {
    case let int as Int: int
    case let string as String: Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
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
    assemblePadCodeFiles(
        pad: pad, environments: environments, maxFileChars: maxFileChars, requestedPadID: nil,
    ).files
}

private func assemblePadCodeFiles(
    pad: [String: Any], environments: [PadCodeEnvironment], maxFileChars: Int?,
    requestedPadID: String?,
) -> PadCodeFileAssembly {
    var files: [[String: Any]] = []
    var seenFilenames = Set<String>()
    var remainingContentBytes = maxPadCodeContentBytes
    var omittedFileCount = 0
    var omittedEnvironmentIDs: [Int] = []
    var schemaErrors: [String] = []
    // Ownership checks run only for a concrete get_pad_code payload so pure
    // file-assembly unit tests can omit API identity fields (#176, #177).
    let padIdentities = requestedPadID.map { padIdentityCandidates(requestedID: $0, pad: pad) }

    var seenEnvironments = Set<Int>()
    for environment in environments where seenEnvironments.insert(environment.id).inserted {
        if let padIdentities {
            let ownershipErrors = environmentOwnershipErrors(
                environment: environment, expectedPadIdentities: padIdentities,
            )
            if !ownershipErrors.isEmpty {
                schemaErrors.append(contentsOf: ownershipErrors)
                continue
            }
        }

        let environmentLanguageResult = sanitizedLanguageResult(environment.object["language"])
        if environmentLanguageResult.rejected {
            schemaErrors.append("Environment \(environment.id) language metadata was malformed.")
        }
        let environmentLanguage = environmentLanguageResult.value

        let rawFileContents = environment.object["file_contents"]
        if rawFileContents == nil {
            schemaErrors.append("Environment \(environment.id) is missing file_contents.")
            continue
        }
        guard let fileContents = rawFileContents as? [[String: Any]] else {
            schemaErrors.append(
                "Environment \(environment.id) file_contents was not an array of file objects.",
            )
            continue
        }

        for file in fileContents {
            guard files.count < maxPadCodeFiles else {
                omittedFileCount += 1
                if !omittedEnvironmentIDs.contains(environment.id) {
                    omittedEnvironmentIDs.append(environment.id)
                }
                continue
            }

            let rawBinary = file["binary"]
            let binaryFlagValid: Bool
            let isBinary: Bool
            if rawBinary == nil {
                binaryFlagValid = true
                isBinary = false
            } else if let flag = rawBinary as? Bool {
                binaryFlagValid = true
                isBinary = flag
            } else {
                // Non-boolean binary flags must not be treated as false (#124).
                binaryFlagValid = false
                isBinary = false
                schemaErrors.append(
                    "Environment \(environment.id) file had a malformed binary flag.",
                )
            }

            // Binary entries carry no text contents and must not consume the text
            // budget or be dropped when that budget is exhausted (#125).
            if !isBinary, remainingContentBytes <= 64 {
                omittedFileCount += 1
                if !omittedEnvironmentIDs.contains(environment.id) {
                    omittedEnvironmentIDs.append(environment.id)
                }
                continue
            }

            let languageResult = sanitizedLanguageResult(file["language"])
            if languageResult.rejected {
                schemaErrors.append(
                    "Environment \(environment.id) file language metadata was malformed.",
                )
            }
            let language = languageResult.value ?? environmentLanguage

            let pathResult = sanitizedFilePathResult(file["path"])
            if pathResult.rejected {
                schemaErrors.append(
                    "Environment \(environment.id) file path was unsafe or malformed.",
                )
            }
            let filename = uniqueFilename(
                pathResult.value ?? synthesizedFilename(language: language),
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
                let rawContents = file["contents"]
                let contents = rawContents as? String
                let perFileLimit = maxFileChars.flatMap { $0 > 0 ? $0 : nil } ?? defaultMaxFileChars
                let aggregateLimit = max(1, remainingContentBytes - 64)
                // Missing or null nonbinary contents are schema errors, not empty
                // complete files (#122, #123).
                if contents == nil {
                    entry["contents"] = ""
                    if rawContents == nil || rawContents is NSNull {
                        entry["error"] = "The file's contents were missing in the API response."
                        schemaErrors.append(
                            "Environment \(environment.id) file \(filename) had missing contents.",
                        )
                    } else {
                        entry["error"] = "The file's contents were not a string in the API response."
                        schemaErrors.append(
                            "Environment \(environment.id) file \(filename) had non-string contents.",
                        )
                    }
                } else if let contents {
                    let boundedContents = truncate(contents, to: min(perFileLimit, aggregateLimit))
                    entry["contents"] = boundedContents
                    remainingContentBytes = max(0, remainingContentBytes - boundedContents.utf8.count)
                }
            }
            if let language {
                entry["language"] = language
            }
            if !binaryFlagValid {
                entry["error"] = "The file's binary flag was not a boolean in the API response."
            }
            files.append(entry)
        }
    }

    let referencedEnvironmentIDs = parsePadEnvironmentIDs(in: pad)
    if files.isEmpty, omittedFileCount == 0, referencedEnvironmentIDs.ids.isEmpty,
       !referencedEnvironmentIDs.malformedContainer,
       let rawContents = pad["contents"], !(rawContents is NSNull)
    {
        if let contents = rawContents as? String {
            let languageResult = sanitizedLanguageResult(pad["language"])
            if languageResult.rejected {
                schemaErrors.append("The legacy pad language metadata was malformed.")
            }
            let language = languageResult.value
            let filename = uniqueFilename(synthesizedFilename(language: language), seen: &seenFilenames)
            var entry: [String: Any] = [
                "filename": filename,
                "contents": truncate(contents, to: min(
                    maxFileChars.flatMap { $0 > 0 ? $0 : nil } ?? defaultMaxFileChars,
                    max(1, remainingContentBytes - 64),
                )),
            ]
            if let language {
                entry["language"] = language
            }
            files.append(entry)
        } else {
            schemaErrors.append("The legacy pad contents were not a string in the API response.")
        }
    }

    return PadCodeFileAssembly(
        files: files,
        omittedFileCount: omittedFileCount,
        omittedEnvironmentIDs: omittedEnvironmentIDs,
        schemaErrors: schemaErrors,
    )
}

private struct SanitizedStringResult {
    let value: String?
    let rejected: Bool
}

private func sanitizedLanguageResult(_ raw: Any?) -> SanitizedStringResult {
    guard let raw else { return SanitizedStringResult(value: nil, rejected: false) }
    guard let string = raw as? String else {
        return SanitizedStringResult(value: nil, rejected: true)
    }
    if trimmedNonEmptyValue(string) == nil {
        return SanitizedStringResult(value: nil, rejected: false)
    }
    guard let value = sanitizedLanguage(string) else {
        return SanitizedStringResult(value: nil, rejected: true)
    }
    return SanitizedStringResult(value: value, rejected: false)
}

private func sanitizedFilePathResult(_ raw: Any?) -> SanitizedStringResult {
    guard let raw else { return SanitizedStringResult(value: nil, rejected: false) }
    guard let string = raw as? String else {
        return SanitizedStringResult(value: nil, rejected: true)
    }
    if trimmedNonEmptyValue(string) == nil {
        return SanitizedStringResult(value: nil, rejected: false)
    }
    guard let value = sanitizedFilePath(string) else {
        return SanitizedStringResult(value: nil, rejected: true)
    }
    return SanitizedStringResult(value: value, rejected: false)
}

private func trimmedNonEmptyValue(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    return value
}

private func sanitizedLanguage(_ raw: String?) -> String? {
    guard let value = trimmedNonEmptyValue(raw), value.utf8.count <= 100 else { return nil }
    let hasUnsafeScalar = value.unicodeScalars.contains { scalar in
        let category = scalar.properties.generalCategory
        return category == .control || category == .format
    }
    return hasUnsafeScalar ? nil : value
}

/// A remote file path reduced to a safe relative form: no control/format characters,
/// no leading/trailing separators, no empty components, no `.`/`..` components, and a
/// bounded length. Nil when nothing safe remains, so the caller falls back to a
/// synthesized name (#1593, #130, #131).
func sanitizedFilePath(_ raw: String?) -> String? {
    guard let value = trimmedNonEmptyValue(raw),
          !value.hasPrefix("/"),
          !value.hasSuffix("/"),
          !value.contains("\\"),
          !value.contains(":"),
          !value.unicodeScalars.contains(where: { scalar in
              let category = scalar.properties.generalCategory
              return category == .control || category == .format
          })
    else { return nil }

    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty,
          !parts.contains(where: \.isEmpty),
          !parts.contains(where: { $0 == "." || $0 == ".." })
    else { return nil }
    guard parts.allSatisfy({ $0.utf8.count <= maxPadCodePathComponentBytes }) else { return nil }

    let joined = parts.joined(separator: "/")
    return joined.utf8.count <= maxPadCodePathBytes ? joined : nil
}

private func uniqueFilename(_ filename: String, seen: inout Set<String>) -> String {
    var filename = filename
    let components = filename.split(separator: "/").map(String.init)
    if components.count > 1 {
        var prefix = ""
        let hasFileAncestor = components.dropLast().contains { component in
            prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
            return seen.contains(filenameConflictKey(prefix))
        }
        if hasFileAncestor {
            // Flattening can join safe components into one overlong name; re-bound
            // before materializing (#129).
            filename = utf8Prefix(
                components.joined(separator: "-"),
                maxBytes: maxPadCodePathComponentBytes,
            )
        }
    }
    guard filenameIsAvailable(filename, seen: seen) else {
        return suffixedUniqueFilename(filename, seen: &seen)
    }

    seen.insert(filenameConflictKey(filename))
    return filename
}

private func suffixedUniqueFilename(_ filename: String, seen: inout Set<String>) -> String {
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
    let directoryBytes = (directory.isEmpty || directory == ".") ? 0 : directory.utf8.count + 1
    let maxComponentBytes = max(
        1,
        min(maxPadCodePathComponentBytes, maxPadCodePathBytes - directoryBytes),
    )
    var suffix = 2
    while true {
        let suffixText = "-\(suffix)"
        let extensionText = extensionName.isEmpty ? "" : ".\(extensionName)"
        let boundedExtension = utf8Prefix(
            extensionText,
            maxBytes: max(0, maxComponentBytes - suffixText.utf8.count - 1),
        )
        let boundedStem = utf8Prefix(
            stem,
            maxBytes: max(0, maxComponentBytes - suffixText.utf8.count - boundedExtension.utf8.count),
        )
        let component = boundedStem + suffixText + boundedExtension
        let candidate = directory.isEmpty || directory == "."
            ? component
            : "\(directory)/\(component)"
        if filenameIsAvailable(candidate, seen: seen),
           candidate.utf8.count <= maxPadCodePathBytes,
           component.utf8.count <= maxPadCodePathComponentBytes
        {
            seen.insert(filenameConflictKey(candidate))
            return candidate
        }
        suffix += 1
    }
}

func utf8Prefix(_ value: String, maxBytes: Int) -> String {
    guard maxBytes >= 0 else { return "" }
    guard value.utf8.count > maxBytes else { return value }
    let utf8 = value.utf8
    var cut = utf8.index(utf8.startIndex, offsetBy: maxBytes)
    while cut > utf8.startIndex, String.Index(cut, within: value) == nil {
        cut = utf8.index(before: cut)
    }
    return String(value[..<(String.Index(cut, within: value) ?? value.startIndex)])
}

private func filenameIsAvailable(_ filename: String, seen: Set<String>) -> Bool {
    let key = filenameConflictKey(filename)
    guard !seen.contains(key), !seen.contains(where: { $0.hasPrefix(key + "/") }) else { return false }

    let components = key.split(separator: "/")
    var prefix = ""
    for component in components.dropLast() {
        prefix = prefix.isEmpty ? String(component) : "\(prefix)/\(component)"
        if seen.contains(prefix) {
            return false
        }
    }
    return true
}

/// A materialization key for the default case-insensitive macOS filesystem. Canonical
/// normalization also prevents visually identical composed/decomposed names colliding.
private func filenameConflictKey(_ filename: String) -> String {
    filename.precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

/// Acceptable pad identity strings for environment ownership checks: the requested
/// pad id plus any id/slug fields on the fetched pad object (#177).
func padIdentityCandidates(requestedID: String, pad: [String: Any]) -> Set<String> {
    var identities: Set<String> = []
    if let trimmed = trimmedNonEmptyValue(requestedID) {
        identities.insert(trimmed)
    }
    for key in ["id", "slug"] {
        if let value = pad[key] as? String, let trimmed = trimmedNonEmptyValue(value) {
            identities.insert(trimmed)
        } else if let value = pad[key] as? Int, value > 0 {
            identities.insert(String(value))
        }
    }
    return identities
}

/// Validates that an environment response matches the requested environment id and
/// belongs to the requested pad. Mismatches and missing identity fields are schema
/// errors; callers should skip those environments' files (#176, #177).
public func environmentOwnershipErrors(
    environment: PadCodeEnvironment, expectedPadIdentities: Set<String>,
) -> [String] {
    var errors: [String] = []

    if let rawID = environment.object["id"] {
        if environmentID(from: rawID) != environment.id {
            errors.append(
                "Environment \(environment.id) response id did not match the requested environment.",
            )
        }
    } else {
        errors.append("Environment \(environment.id) response is missing id.")
    }

    guard !expectedPadIdentities.isEmpty else { return errors }

    if let rawPadID = environment.object["pad_id"] {
        let envPadID: String? = switch rawPadID {
        case let string as String: trimmedNonEmptyValue(string)
        case let int as Int where int > 0: String(int)
        default: nil
        }
        if let envPadID {
            if !expectedPadIdentities.contains(envPadID) {
                errors.append("Environment \(environment.id) belongs to a different pad.")
            }
        } else {
            errors.append("Environment \(environment.id) pad_id was malformed.")
        }
    } else {
        errors.append("Environment \(environment.id) response is missing pad_id.")
    }

    return errors
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
    let assembly = assemblePadCodeFiles(
        pad: pad, environments: environments, maxFileChars: maxFileChars, requestedPadID: id,
    )
    var payload: [String: Any] = [
        // Display fields are bounded and control/format-character-free so a
        // malformed response can't pollute MCP output or logs (#1597, #134).
        "pad_id": sanitizedDisplayField(id, cap: 128),
        "title": sanitizedDisplayField(pad["title"] as? String ?? "", cap: 500),
        "files": assembly.files,
    ]
    if assembly.omittedFileCount > 0 {
        payload["incomplete"] = true
        payload["omitted_file_count"] = assembly.omittedFileCount
        payload["omitted_environment_ids"] = assembly.omittedEnvironmentIDs
        payload["output_limit_note"] = "Files were omitted after reaching the \(maxPadCodeFiles)-file or "
            + "\(maxPadCodeContentBytes)-byte aggregate code budget."
    }
    var schemaErrors = assembly.schemaErrors
    let environmentIDParse = parsePadEnvironmentIDs(in: pad)
    if environmentIDParse.malformedContainer {
        schemaErrors.append("pad_environment_ids was not an array of environment ids.")
    }
    if environmentIDParse.rejectedElement {
        schemaErrors.append("pad_environment_ids contained values that were not positive integer ids.")
    }
    if !schemaErrors.isEmpty {
        payload["incomplete"] = true
        payload["schema_errors"] = schemaErrors
    }
    let fetched = Set(environments.map(\.id))
    var missing = failedEnvironmentIDs
    for referenced in environmentIDParse.ids
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

/// A bounded, control- and format-character-free copy of a display string (#1597, #134).
private func sanitizedDisplayField(_ value: String, cap: Int) -> String {
    let cleaned = String(value.unicodeScalars.filter { scalar in
        !CharacterSet.controlCharacters.contains(scalar)
            && scalar.properties.generalCategory != .format
    })
    return String(cleaned.prefix(cap))
}
