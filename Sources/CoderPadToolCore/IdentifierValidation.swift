//
//  IdentifierValidation.swift
//  CoderPadToolCore
//

import Foundation

/// Returns a numeric server-object identifier only when it can name a real object.
public func positiveID(_ id: Int?) -> Int? {
    guard let id, id > 0 else { return nil }

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
