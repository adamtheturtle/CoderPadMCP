//
//  Diagnostics.swift
//  CoderPadMCP
//
//  Bounded, fingerprintable snippets for untrusted caller input that must appear
//  in MCP errors or activity logs without echoing megabytes of attacker-controlled
//  text (#168, #169).
//

import Foundation

/// Maximum UTF-8 bytes kept from an untrusted diagnostic fragment before truncation.
public let maxDiagnosticSnippetBytes = 128

/// A short, log-safe rendering of untrusted text: truncated with a stable body id so
/// oversized or repeated values remain correlatable without echoing the full input.
public func boundedDiagnostic(_ value: String, limit: Int = maxDiagnosticSnippetBytes) -> String {
    let byteCount = value.utf8.count
    guard byteCount > limit, limit > 0 else { return value }

    var kept = ""
    var keptBytes = 0
    for scalar in value.unicodeScalars {
        let scalarBytes = scalar.utf8.count
        guard keptBytes + scalarBytes <= limit else { break }
        kept.unicodeScalars.append(scalar)
        keptBytes += scalarBytes
    }
    let dropped = byteCount - keptBytes
    let identifier = String(diagnosticBodyIdentifier(value), radix: 16)
    return "\(kept)… [truncated, \(dropped) more bytes, id: \(identifier)]"
}

/// Stable, non-cryptographic identity for an untrusted diagnostic string.
private func diagnosticBodyIdentifier(_ body: String) -> UInt64 {
    body.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
}
