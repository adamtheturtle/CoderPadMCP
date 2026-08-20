//
//  Models.swift
//  CoderPadMCP
//
//  The network-free core of the standalone CoderPad MCP server (#393), split out
//  of the executable so it can be unit-tested (#522) and, in time, shared with the
//  in-app server (#521). Everything here is pure: argument coercion, tool schemas,
//  and the pad code / count / aggregate transforms. The executable (`coderpad-mcp`)
//  keeps the env reading, the REST calls, and the stdio server wiring.
//

import Foundation

/// The status and raw JSON body of a CoderPad REST call. The body is passed through
/// verbatim to the MCP client rather than decoded — the API's JSON is already the
/// most useful representation for an assistant, and passing it through keeps the
/// server resilient to schema additions.
public struct APIResponse: Sendable {
    public let status: Int

    /// The raw response bytes. Kept rather than eagerly stringified so JSON callers can
    /// parse them directly instead of paying a Data -> String -> Data round-trip on every
    /// parsed call — which the count/aggregate tools make once per page (#2120).
    public let data: Data

    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }

    /// Locally synthesized failures (an unbuildable URL, a transport error) carry a
    /// message rather than a payload; it is stored as bytes so callers see one shape.
    public init(status: Int, body: String) {
        self.init(status: status, data: Data(body.utf8))
    }

    /// The body as text, decoded on demand for the paths that hand it to the model.
    public var body: String {
        String(decoding: data, as: UTF8.self)
    }

    public var ok: Bool {
        (200 ..< 300).contains(status)
    }
}

/// Whether a response body is syntactically valid JSON, including fragments.
public func isValidJSON(_ data: Data) -> Bool {
    (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
}

/// Whether a response body is a top-level JSON object or array. Scalar fragments such as
/// `null`, `true`, or `"text"` are rejected so proxy/schema failures cannot masquerade as
/// documented endpoint payloads.
public func isValidJSONObjectOrArray(_ data: Data) -> Bool {
    guard let value = try? JSONSerialization.jsonObject(with: data) else { return false }
    return value is [String: Any] || value is [Any]
}

/// Detects the CoderPad API's documented error envelope even when wrapped in HTTP 2xx.
public func apiErrorEnvelopeMessage(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = object["status"] as? String,
          status.caseInsensitiveCompare("ERROR") == .orderedSame
    else {
        return nil
    }

    if let message = object["message"] as? String,
       !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = trimmed.utf8.count > 240
            ? String(decoding: trimmed.utf8.prefix(240), as: UTF8.self) + "…"
            : trimmed
        return "CoderPad API error: \(bounded)"
    }
    return "CoderPad API error."
}
