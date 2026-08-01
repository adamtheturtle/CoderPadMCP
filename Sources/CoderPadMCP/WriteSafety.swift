//
//  WriteSafety.swift
//  CoderPadMCP
//

import Foundation
import MCP

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

/// Reads a present string-like write argument without trimming or erasing an
/// explicitly empty value.
public func presentWriteString(_ arguments: [String: Value]?, _ name: String) -> String? {
    guard let value = arguments?[name] else { return nil }

    switch value {
    case let .string(string):
        return string
    case let .int(int):
        return String(int)
    case let .double(double):
        return String(double)
    default:
        return nil
    }
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

private func jsonEncodedStringByteCount(_ value: String) -> Int {
    2 + value.unicodeScalars.reduce(into: 0) { count, scalar in
        switch scalar.value {
        case 0 ... 0x1F:
            count += 6
        case 0x22, 0x5C:
            count += 2
        default:
            count += String(scalar).utf8.count
        }
    }
}
