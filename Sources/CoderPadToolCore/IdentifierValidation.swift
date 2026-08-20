//
//  IdentifierValidation.swift
//  CoderPadToolCore
//

import Foundation

/// Character and UTF-8 ceilings for account names/ids used as tool selectors and
/// resource path components. Kept in ToolCore so schemas and runtime share one bound.
public let maxAccountSelectorCharacters = 100
public let maxAccountSelectorUTF8Bytes = 256

/// Screen's documented campaign/test id domain (`integer<int32>`).
public let maximumScreenID = Int(Int32.max)

/// Returns a numeric server-object identifier only when it can name a real object.
public func positiveID(_ id: Int?) -> Int? {
    guard let id, id > 0 else { return nil }

    return id
}

/// A Screen campaign or test id: positive and within the API's int32 domain.
public func positiveScreenID(_ id: Int?) -> Int? {
    guard let id, id > 0, id <= maximumScreenID else { return nil }

    return id
}

/// Pad identifiers may be slugs, but a numeric spelling still has to identify a
/// real server object rather than zero or a negative value.
public func validatedPadID(_ id: String?) -> String? {
    guard let id else { return nil }

    let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let unsigned = normalized.first.map { $0 == "+" || $0 == "-" } == true
        ? normalized.dropFirst()
        : normalized[...]
    if !unsigned.isEmpty, unsigned.allSatisfy(\.isNumber) {
        guard let numeric = Int(normalized), numeric > 0 else { return nil }
        return normalized
    }

    return isSafePadID(normalized) ? normalized : nil
}

/// The grammar accepted by both tool arguments and resource URIs. Keeping pad ids
/// to one bounded ASCII path component prevents dot-segment or separator traversal
/// when the value is appended to an authenticated REST path.
public func isSafePadID(_ id: String) -> Bool {
    (1 ... 64).contains(id.count) && id.allSatisfy { character in
        character == "-" || character == "_"
            || (character.isASCII && (character.isLetter || character.isNumber))
    }
}
