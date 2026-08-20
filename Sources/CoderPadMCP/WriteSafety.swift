//
//  WriteSafety.swift
//  CoderPadMCP
//

import Foundation
import MCP
import MCPKit

/// Parses the write safety flag without failing open. Absent is a valid live
/// request; a present value must be an actual boolean or the exact JSON-string
/// spelling used by older MCP clients.
public enum StrictDryRunValue: Equatable, Sendable {
    case absent
    case value(Bool)
    case invalid
}

public func strictDryRunArgument(_ arguments: [String: Value]?) -> StrictDryRunValue {
    guard let value = arguments?["dry_run"] else { return .absent }

    switch value {
    case let .bool(value):
        return .value(value)
    case .string("true"):
        return .value(true)
    case .string("false"):
        return .value(false)
    default:
        return .invalid
    }
}

/// Distinguishes an absent write string from a present value that cannot be decoded
/// as a string-like scalar, so wrong-typed optionals are rejected instead of dropped.
public enum StrictWriteStringValue: Equatable, Sendable {
    case absent
    case value(String)
    case invalid
}

public func strictWriteString(_ arguments: [String: Value]?, _ name: String) -> StrictWriteStringValue {
    guard let value = arguments?[name] else { return .absent }

    switch value {
    case let .string(string):
        return .value(string)
    case let .int(int):
        return .value(String(int))
    case let .double(double):
        return .value(String(double))
    default:
        return .invalid
    }
}

/// Reads a present string-like write argument without trimming or erasing an
/// explicitly empty value.
public func presentWriteString(_ arguments: [String: Value]?, _ name: String) -> String? {
    if case let .value(string) = strictWriteString(arguments, name) {
        return string
    }

    return nil
}

/// Returns the first present write field whose value is not a string-like scalar.
public func invalidWriteStringArgument(
    _ arguments: [String: Value]?,
    names: some Sequence<String>,
) -> String? {
    names.first { strictWriteString(arguments, $0) == .invalid }
}

/// Rejects misspelled or undeclared write arguments (e.g. `dryrun`) before a live
/// mutation can proceed under an absent `dry_run` (#158).
public func unknownWriteArgumentError(
    _ arguments: [String: Value]?,
    allowed: Set<String>,
) -> String? {
    guard let arguments else { return nil }
    let unknown = arguments.keys.filter { !allowed.contains($0) }.sorted()
    guard let first = unknown.first else { return nil }

    return "Unknown argument: \(first)."
}

/// Numeric identifiers and paging values must not silently change value during
/// coercion. Integral doubles remain compatible with JSON clients that encode every
/// number as floating point; fractional, non-finite, and out-of-range values fail.
public func strictIntArgument(_ arguments: [String: Value]?, _ name: String) -> Int? {
    guard let value = arguments?[name] else { return nil }

    switch value {
    case let .int(value):
        return value
    case let .double(value):
        return Int(exactly: value)
    case let .string(value):
        return Int(value)
    default:
        return nil
    }
}

public func invalidIntegerArgument(
    _ arguments: [String: Value]?,
    names: some Sequence<String>,
) -> String? {
    names.first { name in
        arguments?[name] != nil && strictIntArgument(arguments, name) == nil
    }
}

/// Names of integer-typed arguments for a tool. Validation must stay scoped to the
/// selected tool so an unrelated `page:false` cannot break `whoami` (#111).
public func integerArgumentNames(forTool name: String) -> [String] {
    switch name {
    case "list_pads", "list_pads_compact", "list_questions", "list_questions_compact":
        ["page"]
    case "get_pad_code":
        ["max_file_chars"]
    case "get_question", "update_question":
        ["question"]
    case "screen_list_tests":
        ["campaignId", "start", "limit"]
    case "screen_get_test":
        ["test"]
    case "create_pad":
        ["question_id"]
    default:
        []
    }
}

/// A present argument that cannot be read as a string-like scalar (string / int /
/// finite double). Used so filters and sort cannot silently widen when a client
/// sends a boolean, array, object, or null (#110, #112–#115).
public func invalidPresentStringArgument(
    _ arguments: [String: Value]?,
    names: some Sequence<String>,
) -> String? {
    names.first { name in
        arguments?[name] != nil && stringArgument(arguments, name) == nil
    }
}

/// Rejects oversized write strings before a dispatcher trims, copies, dry-runs, or
/// JSON-encodes them. The aggregate uses the exact JSON string escape size plus a
/// small structural allowance, so control-heavy input cannot evade a raw-byte sum.
public func writeStringBudgetValidationError(
    _ arguments: [String: Value]?,
    fields: some Sequence<String>,
) -> String? {
    var encodedBytes = 256
    for field in fields {
        guard let value = presentWriteString(arguments, field) else { continue }
        let rawBytes = value.utf8.count
        guard rawBytes <= maxMCPWriteFieldBytes else {
            return "\(field) must be at most \(maxMCPWriteFieldBytes) UTF-8 bytes."
        }
        encodedBytes += field.utf8.count + 4 + jsonEncodedStringByteCount(value)
        guard encodedBytes <= maxMCPWriteBodyBytes else {
            return "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes."
        }
    }
    return nil
}

/// Matches `JSONSerialization`'s string encoding, including escaped solidus (`\/`).
func jsonEncodedStringByteCount(_ value: String) -> Int {
    2 + value.unicodeScalars.reduce(into: 0) { count, scalar in
        switch scalar.value {
        case 0 ... 0x1F:
            count += 6
        case 0x22, 0x5C, 0x2F:
            count += 2
        default:
            count += String(scalar).utf8.count
        }
    }
}
