//
//  Prompts.swift
//  CoderPadMCP
//
//  Reusable prompt templates the server exposes over MCP (#517). Prompts are
//  pre-written, argument-driven instructions a client can offer as slash-commands or
//  quick actions — e.g. "review this pad's code" — so the assistant doesn't have to be
//  told from scratch each time how to drive the CoderPad tools. Rendering is pure, so
//  it is unit-tested without a server.
//

import CoderPadToolCore
import Foundation
import MCP
import MCPKit

public let maxComparedPads = 10
public let maxComparePadIDsBytes = 1024

private let promptAccountArgument = Prompt.Argument(
    name: "account",
    description: "Stable account id from list_accounts (preferred), or a unique display name. "
        + "Required in multi-account setups so tool calls target the right organization.",
    required: false,
)

/// The prompt catalog advertised by `prompts/list`.
public let interviewPrompts: [Prompt] = [
    Prompt(
        name: "review_pad_code",
        title: "Review a candidate's pad",
        description: "Review the code in a CoderPad interview pad for correctness, clarity, edge cases, and complexity.",
        arguments: [
            Prompt.Argument(name: "pad_id", description: "The pad id / slug to review.", required: true),
            promptAccountArgument,
        ],
    ),
    Prompt(
        name: "summarize_pad",
        title: "Summarize a pad",
        description: "Summarize what happened in an interview pad: the problem, the candidate's approach, and the outcome.",
        arguments: [
            Prompt.Argument(name: "pad_id", description: "The pad id / slug to summarize.", required: true),
            promptAccountArgument,
        ],
    ),
    Prompt(
        name: "compare_pads",
        title: "Compare candidates",
        description: "Compare the code and approach across several pads to help rank candidates.",
        arguments: [
            Prompt.Argument(
                name: "pad_ids",
                description: "Comma-separated pad ids / slugs to compare.",
                required: true,
            ),
            promptAccountArgument,
        ],
    ),
    Prompt(
        name: "draft_question",
        title: "Draft an interview question",
        description: "Draft a new interview question on a topic, with a prompt, examples, and a reference solution.",
        arguments: [
            Prompt.Argument(name: "topic", description: "What the question should cover.", required: true),
            Prompt.Argument(name: "language", description: "Target language (optional).", required: false),
            Prompt.Argument(
                name: "difficulty",
                description: "Easy / medium / hard (optional).",
                required: false,
            ),
        ],
    ),
]

/// Renders a prompt's messages from its arguments, ready to return from `prompts/get`.
/// Throws `.unknownPrompt` for an unrecognized name and `.missingArgument` when a
/// required argument is absent.
public func renderPrompt(name: String, arguments: [String: String]?) throws -> GetPrompt.Result {
    switch name {
    case "review_pad_code":
        let padID = try requiredPromptPadID(arguments)
        let accountArg = try promptAccountToolArgument(arguments)
        return GetPrompt.Result(
            description: "Review the code in pad \(padID).",
            messages: [userPromptMessage("""
            Review the code in CoderPad pad "\(padID)".

            First call the get_pad_code tool with pad: "\(padID)"\(accountArg) to read every file, and \
            get_pad with pad: "\(padID)"\(accountArg) for the surrounding context (title, language, participants).

            Then give a focused review covering:
            - Correctness: does it solve the stated problem? Any bugs or unhandled edge cases?
            - Complexity: time and space, and whether it's appropriate.
            - Clarity: naming, structure, and readability.
            - What you'd ask the candidate next.

            Be concrete and cite the relevant code.
            """)],
        )

    case "summarize_pad":
        let padID = try requiredPromptPadID(arguments)
        let accountArg = try promptAccountToolArgument(arguments)
        return GetPrompt.Result(
            description: "Summarize pad \(padID).",
            messages: [userPromptMessage("""
            Summarize the CoderPad interview pad "\(padID)".

            Call get_pad with pad: "\(padID)"\(accountArg) for title, language, participants, and status, and \
            get_pad_code with pad: "\(padID)"\(accountArg) for the code. There is no events tool; do not claim \
            a step-by-step timeline you cannot observe. Infer approach, progress, and outcome only \
            from the pad metadata and code, and say when evidence is missing. Keep it to a few \
            tight paragraphs.
            """)],
        )

    case "compare_pads":
        let ids = try requiredPromptArgument(arguments, "pad_ids")
        let list = try comparedPadIDs(ids)
        let accountArg = try promptAccountToolArgument(arguments)

        let quoted = list.map { "\"\($0)\"" }.joined(separator: ", ")
        let accountInstruction = accountArg.isEmpty
            ? ""
            : " Include\(accountArg) on every tool call."
        return GetPrompt.Result(
            description: "Compare pads \(list.joined(separator: ", ")).",
            messages: [userPromptMessage("""
            Compare these CoderPad pads to help rank the candidates: \(quoted).

            For each pad, call get_pad and get_pad_code with the pad argument set to that pad's id \
            to read its code and context.\(accountInstruction) Then compare \
            them on correctness, code quality, problem-solving approach, and communication signals \
            you can infer. Finish with a ranked recommendation and the reasoning behind it.
            """)],
        )

    case "draft_question":
        let topic = try requiredPromptArgument(arguments, "topic")
        let language = promptArgument(arguments, "language")
        let difficulty = try validatedDraftQuestionDifficulty(promptArgument(arguments, "difficulty"))
        var constraints = ""
        if let language {
            constraints += "\nTarget language: \(language)."
        }
        if let difficulty {
            constraints += "\nDifficulty: \(difficulty)."
        }
        return GetPrompt.Result(
            description: "Draft a question about \(topic).",
            messages: [userPromptMessage("""
            Draft a CoderPad interview question on: \(topic).\(constraints)

            Produce: a clear problem statement, 2-3 worked examples (input -> output), any \
            constraints, a reference solution with a short complexity note, and 1-2 follow-up \
            variations to probe deeper. If it would make a good bank entry, note that the \
            create_question tool can save it (writes must be enabled).
            """)],
        )

    default:
        throw PromptError.unknownPrompt(name)
    }
}

private func comparedPadIDs(_ raw: String) throws -> [String] {
    guard raw.utf8.count <= maxComparePadIDsBytes else {
        throw PromptError.invalidArgument(name: "pad_ids", reason: "must be at most \(maxComparePadIDsBytes) bytes")
    }
    let values = raw.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard values.contains(where: { !$0.isEmpty }) else { throw PromptError.missingArgument("pad_ids") }
    guard values.count <= maxComparedPads else {
        throw PromptError.invalidArgument(name: "pad_ids", reason: "must contain at most \(maxComparedPads) pads")
    }
    guard values.allSatisfy({ validatedPadID($0) != nil }) else {
        throw PromptError.invalidArgument(name: "pad_ids", reason: "must contain only safe pad identifiers")
    }
    let ids = values.compactMap(validatedPadID)
    var seen = Set<String>()
    var unique: [String] = []
    unique.reserveCapacity(ids.count)
    for id in ids {
        if seen.contains(id) {
            throw PromptError.invalidArgument(name: "pad_ids", reason: "must not contain duplicate pad identifiers")
        }
        seen.insert(id)
        unique.append(id)
    }
    guard unique.count >= 2 else {
        throw PromptError.invalidArgument(name: "pad_ids", reason: "must contain at least 2 distinct pads")
    }
    return unique
}

private func requiredPromptPadID(_ arguments: [String: String]?) throws -> String {
    let raw = try requiredPromptArgument(arguments, "pad_id")
    guard let padID = validatedPadID(raw) else {
        throw PromptError.invalidArgument(name: "pad_id", reason: "must be a positive id or safe slug")
    }
    return padID
}

private let draftQuestionDifficulties = ["easy", "medium", "hard"]

private func validatedDraftQuestionDifficulty(_ raw: String?) throws -> String? {
    guard let raw else { return nil }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard draftQuestionDifficulties.contains(normalized) else {
        throw PromptError.invalidArgument(
            name: "difficulty",
            reason: "must be one of: \(draftQuestionDifficulties.joined(separator: ", "))",
        )
    }
    return normalized
}

/// Returns `, account: "…"` for inclusion in generated tool-call instructions, or "" when
/// the optional account selector is omitted (#141).
private func promptAccountToolArgument(_ arguments: [String: String]?) throws -> String {
    guard let raw = promptArgument(arguments, "account") else { return "" }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard trimmed.count <= maxAccountSelectorCharacters,
          trimmed.utf8.count <= maxAccountSelectorUTF8Bytes,
          !trimmed.contains("\""),
          !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          trimmed != ".", trimmed != ".."
    else {
        throw PromptError.invalidArgument(
            name: "account",
            reason: "must be a safe account id or unique display name",
        )
    }

    return ", account: \"\(trimmed)\""
}

