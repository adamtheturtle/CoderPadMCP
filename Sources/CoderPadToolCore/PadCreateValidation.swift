//
//  PadCreateValidation.swift
//  CoderPadToolCore
//
//  Shared validation for create_pad inputs used by both MCP servers.
//

import Foundation

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
