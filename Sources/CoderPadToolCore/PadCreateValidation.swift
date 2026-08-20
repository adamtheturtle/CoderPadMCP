//
//  PadCreateValidation.swift
//  CoderPadToolCore
//
//  Shared validation for create_pad inputs used by both MCP servers.
//

import Foundation

public let maxPadTitleCharacters = 255
public let maxOwnerEmailBytes = 254
/// Matches `CoderPadKit.ScreenClient.maximumEmailFilterLength` for Screen list filters.
public let maxScreenCandidateEmailCharacters = 320
public let maxMCPWriteFieldBytes = 512 * 1024
public let maxMCPWriteBodyBytes = 1024 * 1024

public let creatablePadLanguages = [
    "python3", "python2", "javascript", "typescript", "nodejs", "swift", "go", "rust",
    "java", "kotlin", "scala", "ruby", "c", "cpp", "csharp", "objective-c", "php", "r",
    "sql", "mysql", "postgresql", "bash", "shell", "elixir", "erlang", "haskell", "perl",
    "lua", "dart", "clojure", "ocaml", "fsharp", "julia", "solidity", "tcl", "verilog",
    "html", "css", "markdown", "plaintext",
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

public func padTitleValidationError(_ title: String?) -> String? {
    guard let title, title.count > maxPadTitleCharacters else { return nil }

    return "title must be at most \(maxPadTitleCharacters) characters."
}

public func padUpdateTitleValidationError(_ title: String?) -> String? {
    guard let title else { return nil }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "title must not be empty or whitespace-only."
    }

    return padTitleValidationError(title)
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
