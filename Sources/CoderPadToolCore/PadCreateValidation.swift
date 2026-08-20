//
//  PadCreateValidation.swift
//  CoderPadToolCore
//
//  Shared validation for create_pad inputs used by both MCP servers.
//

import Foundation

public let maxPadTitleCharacters = 255
/// UTF-8 safety bound for titles: at most four bytes per Unicode scalar (#162).
public let maxPadTitleUTF8Bytes = maxPadTitleCharacters * 4
public let maxOwnerEmailBytes = 254
/// Matches `CoderPadKit.ScreenClient.maximumEmailFilterLength` for Screen list filters.
public let maxScreenCandidateEmailCharacters = 320
public let maxMCPWriteFieldBytes = 512 * 1024
public let maxMCPWriteBodyBytes = 1024 * 1024

/// Languages and frameworks documented by the Interview API `#Languages` section.
public let creatablePadLanguages = [
    "angular", "bash", "c", "clojure", "coffeescript", "cpp", "csharp", "django",
    "elixir", "erlang", "fsharp", "gin", "haskell", "html", "java", "javascript",
    "julia", "kotlin", "lua", "markdown", "node", "objc", "ocaml", "perl", "php",
    "plaintext", "postgresql", "python", "rails", "react", "ruby", "rust", "spring",
    "svelte", "swift", "tcl", "typescript", "vb", "vue",
]

public func validatedCreatePadLanguage(_ language: String?) -> String? {
    guard let language else { return nil }

    let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return creatablePadLanguages.contains(normalized) ? normalized : nil
}

public func createPadLanguageValidationError(_ language: String?) -> String? {
    guard let language, validatedCreatePadLanguage(language) == nil else { return nil }

    return "language must be one of: \(creatablePadLanguages.joined(separator: ", "))."
}

/// Rejects titles that exceed the API's 255 Unicode-scalar limit or the matching UTF-8
/// safety bound. Uses scalar count (not grapheme clusters) so combining-character
/// stacks cannot bypass the advertised limit (#162).
public func padTitleValidationError(_ title: String?) -> String? {
    guard let title else { return nil }
    guard title.unicodeScalars.count <= maxPadTitleCharacters else {
        return "title must be at most \(maxPadTitleCharacters) characters."
    }
    guard title.utf8.count <= maxPadTitleUTF8Bytes else {
        return "title must be at most \(maxPadTitleUTF8Bytes) UTF-8 bytes."
    }

    return nil
}

public func padUpdateTitleValidationError(_ title: String?) -> String? {
    guard let title else { return nil }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "title must not be empty or whitespace-only."
    }

    return padTitleValidationError(title)
}

/// Question titles have no separate API character cap beyond the write-field budget;
/// reject blank values so updates and creates cannot replace a title with whitespace.
public func questionTitleValidationError(_ title: String?) -> String? {
    guard let title else { return nil }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "title must not be empty or whitespace-only."
    }

    return nil
}

public func ownerEmailValidationError(_ email: String?) -> String? {
    guard let email, !email.isEmpty else { return nil }
    guard email.utf8.count <= maxOwnerEmailBytes,
          email.allSatisfy(\.isASCII),
          !email.contains(where: \.isWhitespace)
    else {
        return "owner_email must be a valid email address."
    }

    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return "owner_email must be a valid email address." }
    let local = parts[0]
    let domain = parts[1]
    let localSymbols = Set("!#$%&'*+-/=?^_`{|}~")
    guard (1 ... 64).contains(local.utf8.count),
          !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
          local.allSatisfy({ $0 == "." || $0.isLetter || $0.isNumber || localSymbols.contains($0) })
    else {
        return "owner_email must be a valid email address."
    }

    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
          labels.allSatisfy({ label in
              !label.isEmpty && label.utf8.count <= 63
                  && !label.hasPrefix("-") && !label.hasSuffix("-")
                  && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
          })
    else {
        return "owner_email must be a valid email address."
    }

    return nil
}

/// Update paths treat a present owner_email as an ownership change; empty is not a
/// supported clearing form and must fail like any other malformed address (#101).
public func padUpdateOwnerEmailValidationError(_ email: String?) -> String? {
    guard let email else { return nil }
    if email.isEmpty {
        return "owner_email must be a valid email address."
    }

    return ownerEmailValidationError(email)
}

/// Requires a present team id to be a canonical UUID, matching the Interview API (#107).
public func teamIDValidationError(_ teamID: String?) -> String? {
    guard let teamID else { return nil }
    guard UUID(uuidString: teamID) != nil else {
        return "team_id must be a canonical UUID."
    }

    return nil
}

public func normalizedScreenCandidateEmail(_ email: String?) -> String? {
    guard let value = email?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

public func screenCandidateEmailValidationError(_ email: String?) -> String? {
    guard let email = normalizedScreenCandidateEmail(email) else { return nil }
    guard email.count <= maxScreenCandidateEmailCharacters,
          email.allSatisfy(\.isASCII),
          !email.contains(where: \.isWhitespace),
          !email.unicodeScalars.contains(where: {
              let category = $0.properties.generalCategory
              return category == .control || category == .format
          })
    else {
        return "candidateEmail must be a valid email address."
    }

    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return "candidateEmail must be a valid email address." }
    let local = parts[0]
    let domain = parts[1]
    let localSymbols = Set("!#$%&'*+-/=?^_`{|}~")
    guard (1 ... 64).contains(local.utf8.count),
          !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
          local.allSatisfy({ $0 == "." || $0.isLetter || $0.isNumber || localSymbols.contains($0) })
    else {
        return "candidateEmail must be a valid email address."
    }

    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
          labels.allSatisfy({ label in
              !label.isEmpty && label.utf8.count <= 63
                  && !label.hasPrefix("-") && !label.hasSuffix("-")
                  && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
          })
    else {
        return "candidateEmail must be a valid email address."
    }

    return nil
}

public func padSeedValidationError(questionID: Int?, contents: String?) -> String? {
    // Server question ids are positive; zero/negative values only come from
    // malformed tool calls and would produce ambiguous seed behavior (#1611).
    if let questionID, questionID < 1 {
        return "question_id must be a positive integer."
    }
    // Whitespace-only contents is not a real seed: passing it through would
    // create an unintentionally blank pad (#1610).
    let hasContents = contents.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if hasContents == false {
        return "contents must not be empty or whitespace-only."
    }
    guard questionID != nil, hasContents == true else { return nil }

    return "question_id and contents are mutually exclusive; provide only one seed source."
}
