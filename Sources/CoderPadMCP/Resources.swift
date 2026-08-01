//
//  Resources.swift
//  CoderPadMCP
//
//  The MCP resources the server exposes (#517). Resources are addressable, readable
//  context items identified by a `coderpad://` URI. A handful of singletons (quota,
//  organization) are listed directly; pads and questions are exposed as URI templates
//  the client fills in. The URI parsing is pure, so it is unit-tested without a server.
//

import Foundation
import MCP

/// The URI scheme for all CoderPad resources.
public let resourceScheme = "coderpad"

/// Concrete, always-available resources (no parameters), advertised by
/// `resources/list`.
public let staticResources: [Resource] = [
    Resource(
        name: "Pad quota",
        uri: "coderpad://quota",
        description: "The account's pad quota usage.",
        mimeType: "application/json",
    ),
    Resource(
        name: "Organization directory",
        uri: "coderpad://organization",
        description: "The organization's teams and members.",
        mimeType: "application/json",
    ),
]

public func staticResources(for accountSet: MCPAccountSet) -> [Resource] {
    guard accountSet.accounts.count > 1 else { return staticResources }

    return accountSet.accounts.flatMap { account in
        let encodedName = resourcePathComponent(account.name)
        return [
            Resource(
                name: "\(account.name) pad quota",
                uri: "coderpad://account/\(encodedName)/quota",
                description: "The pad quota usage for \(account.name).",
                mimeType: "application/json",
            ),
            Resource(
                name: "\(account.name) organization directory",
                uri: "coderpad://account/\(encodedName)/organization",
                description: "The organization teams and members for \(account.name).",
                mimeType: "application/json",
            ),
        ]
    }
}

/// URI templates for the parameterized resources, advertised by
/// `resources/templates/list`.
public let resourceTemplates: [Resource.Template] = [
    Resource.Template(
        uriTemplate: "coderpad://pad/{id}",
        name: "Pad",
        description: "A single pad's full detail as JSON. {id} is the pad id / slug.",
        mimeType: "application/json",
    ),
    Resource.Template(
        uriTemplate: "coderpad://pad/{id}/code",
        name: "Pad code",
        description: "Just the code in a pad: each file with its filename, language, and contents.",
        mimeType: "application/json",
    ),
    Resource.Template(
        uriTemplate: "coderpad://question/{id}",
        name: "Question",
        description: "A single question's full detail as JSON. {id} is the numeric question id.",
        mimeType: "application/json",
    ),
]

public let accountResourceTemplates: [Resource.Template] = [
    Resource.Template(
        uriTemplate: "coderpad://account/{account}/pad/{id}",
        name: "Account pad",
        description: "A single pad's full detail as JSON for the selected account.",
        mimeType: "application/json",
    ),
    Resource.Template(
        uriTemplate: "coderpad://account/{account}/pad/{id}/code",
        name: "Account pad code",
        description: "Just the code in a pad for the selected account.",
        mimeType: "application/json",
    ),
    Resource.Template(
        uriTemplate: "coderpad://account/{account}/question/{id}",
        name: "Account question",
        description: "A single question's full detail as JSON for the selected account.",
        mimeType: "application/json",
    ),
]

public func resourceTemplates(for accountSet: MCPAccountSet) -> [Resource.Template] {
    guard accountSet.accounts.count > 1 else { return resourceTemplates }

    return accountResourceTemplates
}

/// A parsed `coderpad://` resource request, decoupling URI shape from the fetch.
public enum ResourceRequest: Equatable {
    case quota
    case organization
    case pad(String)
    case padCode(String)
    case question(Int)
    case accountQuota(String)
    case accountOrganization(String)
    case accountPad(account: String, id: String)
    case accountPadCode(account: String, id: String)
    case accountQuestion(account: String, id: Int)

    public var accountName: String? {
        switch self {
        case let .accountQuota(account),
             let .accountOrganization(account),
             let .accountPad(account, _),
             let .accountPadCode(account, _),
             let .accountQuestion(account, _):
            account
        default:
            nil
        }
    }

    public var unqualified: Self {
        switch self {
        case .quota, .organization, .pad, .padCode, .question:
            self
        case .accountQuota:
            .quota
        case .accountOrganization:
            .organization
        case let .accountPad(_, id):
            .pad(id)
        case let .accountPadCode(_, id):
            .padCode(id)
        case let .accountQuestion(_, id):
            .question(id)
        }
    }
}

/// Parses a `coderpad://` URI into a request, or nil when it doesn't match any known
/// resource. Tolerates a trailing slash and percent-encoded ids. The scheme and route
/// literals (`pad`, `question`, `account`, `quota`, `organization`, `code`) compare
/// case-insensitively per URI convention (#1581); ids keep their exact case.
public func parseResourceURI(_ uri: String) -> ResourceRequest? {
    // Reject oversized input before URLComponents or percent decoding can expand it.
    // The longest supported route has five segments; 1 KiB per encoded segment is
    // ample for account names while bounding allocations and downstream logs (#1577).
    guard uri.utf8.count <= 5120,
          let components = URLComponents(string: uri),
          components.scheme?.lowercased() == resourceScheme,
          components.percentEncodedQuery == nil,
          components.percentEncodedFragment == nil,
          components.percentEncodedUser == nil,
          components.percentEncodedPassword == nil,
          components.port == nil
    else {
        return nil
    }

    // For coderpad://pad/x the host is "pad" and the path is "/x"; normalize both into
    // one list of segments so the matching below reads uniformly. Split the still-encoded
    // path so an encoded "/" inside a segment survives, then decode each segment exactly
    // once — `components.path`/`.host` are already decoded, so decoding them again would
    // mangle values and break the round-trip with `resourcePathComponent` (#1030).
    var segments: [String] = []
    if let host = components.percentEncodedHost, !host.isEmpty {
        segments.append(host)
    }
    segments += components.percentEncodedPath.split(separator: "/").map(String.init)
    guard segments.count <= 5, segments.allSatisfy({ $0.utf8.count <= 1024 }) else { return nil }

    let decoded = segments.map { $0.removingPercentEncoding ?? $0 }

    // Decoded segments are untrusted: dot navigation or a decoded separator must
    // never survive into an identifier that downstream URL construction could
    // re-interpret (#1580).
    guard decoded.allSatisfy(isSafeDecodedSegment) else { return nil }

    return parseUnqualifiedResource(decoded) ?? parseAccountResource(decoded)
}

/// Whether a percent-decoded URI segment is safe to treat as an identifier or
/// account name: never dot navigation or control characters (#1580). A decoded
/// "/" is allowed here because account names round-trip encoded slashes (#1030);
/// pad ids additionally reject it via `isSafePadID`.
private func isSafeDecodedSegment(_ segment: String) -> Bool {
    segment != "." && segment != ".."
        && !segment.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

/// Pad ids flow into downstream REST URL construction. Keep their grammar in
/// sync with the app's `PadIDValidation`: short ASCII-alphanumeric tokens with
/// optional hyphens or underscores (#1578).
private func isSafePadID(_ id: String) -> Bool {
    (1 ... 64).contains(id.count) && id.allSatisfy { character in
        character == "-" || character == "_"
            || (character.isASCII && (character.isLetter || character.isNumber))
    }
}

/// Whether a route literal matches, case-insensitively (#1581).
private func isRoute(_ segment: String?, _ literal: String) -> Bool {
    segment?.lowercased() == literal
}

private func parseUnqualifiedResource(_ decoded: [String]) -> ResourceRequest? {
    if isRoute(decoded.first, "quota"), decoded.count == 1 {
        return .quota
    }
    if isRoute(decoded.first, "organization"), decoded.count == 1 {
        return .organization
    }
    if isRoute(decoded.first, "pad") {
        return parsePadResource(Array(decoded.dropFirst()))
    }
    if isRoute(decoded.first, "question") {
        return parseQuestionResource(Array(decoded.dropFirst()))
    }
    return nil
}

private func parseAccountResource(_ decoded: [String]) -> ResourceRequest? {
    guard decoded.count >= 3, isRoute(decoded[0], "account"), !decoded[1].isEmpty else { return nil }

    let account = decoded[1]
    if isRoute(decoded[2], "quota"), decoded.count == 3 {
        return .accountQuota(account)
    }
    if isRoute(decoded[2], "organization"), decoded.count == 3 {
        return .accountOrganization(account)
    }
    if isRoute(decoded[2], "pad") {
        return parseAccountPadResource(account: account, tail: Array(decoded.dropFirst(3)))
    }
    if isRoute(decoded[2], "question") {
        return parseAccountQuestionResource(account: account, tail: Array(decoded.dropFirst(3)))
    }
    return nil
}

private func parsePadResource(_ tail: [String]) -> ResourceRequest? {
    switch tail.count {
    case 1 where isSafePadID(tail[0]):
        .pad(tail[0])
    case 2 where isSafePadID(tail[0]) && isRoute(tail[1], "code"):
        .padCode(tail[0])
    default:
        nil
    }
}

private func parseQuestionResource(_ tail: [String]) -> ResourceRequest? {
    guard tail.count == 1, let id = Int(tail[0]), id > 0 else { return nil }

    return .question(id)
}

private func parseAccountPadResource(account: String, tail: [String]) -> ResourceRequest? {
    switch tail.count {
    case 1 where isSafePadID(tail[0]):
        .accountPad(account: account, id: tail[0])
    case 2 where isSafePadID(tail[0]) && isRoute(tail[1], "code"):
        .accountPadCode(account: account, id: tail[0])
    default:
        nil
    }
}

private func parseAccountQuestionResource(account: String, tail: [String]) -> ResourceRequest? {
    guard tail.count == 1, let id = Int(tail[0]), id > 0 else { return nil }

    return .accountQuestion(account: account, id: id)
}

public enum ResourceAccountResolution: Equatable {
    case account(MCPAccount)
    case noAccounts
    case requiresAccount
    case unknownAccount(String)
}

public func resolveResourceAccount(_ request: ResourceRequest, accountSet: MCPAccountSet) -> ResourceAccountResolution {
    if let accountName = request.accountName {
        guard let account = accountSet.resolve(accountName) else { return .unknownAccount(accountName) }

        return .account(account)
    }

    guard !accountSet.accounts.isEmpty else { return .noAccounts }
    guard accountSet.accounts.count == 1 else { return .requiresAccount }
    guard let defaultAccount = accountSet.defaultAccount else { return .noAccounts }

    return .account(defaultAccount)
}

private func resourcePathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    if let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) {
        return encoded
    }

    // Guaranteed byte-level fallback: returning the raw value here could emit a
    // slash or control character into a URI and change resource routing (#1584).
    return value.utf8.map { String(format: "%%%02X", $0) }.joined()
}
