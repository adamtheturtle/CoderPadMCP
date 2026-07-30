//
//  WriteSafety.swift
//  CoderPadMCP
//

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
