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

import Foundation
import MCP
import MCPKit

/// The prompt catalog advertised by `prompts/list`.
public let interviewPrompts: [Prompt] = [
    Prompt(
        name: "review_pad_code",
        title: "Review a candidate's pad",
        description: "Review the code in a CoderPad interview pad for correctness, clarity, edge cases, and complexity.",
        arguments: [
            Prompt.Argument(name: "pad_id", description: "The pad id / slug to review.", required: true),
        ],
    ),
    Prompt(
        name: "summarize_pad",
        title: "Summarize a pad",
        description: "Summarize what happened in an interview pad: the problem, the candidate's approach, and the outcome.",
        arguments: [
            Prompt.Argument(name: "pad_id", description: "The pad id / slug to summarize.", required: true),
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
        let padID = try requiredPromptArgument(arguments, "pad_id")
        return GetPrompt.Result(
            description: "Review the code in pad \(padID).",
            messages: [userPromptMessage("""
            Review the code in CoderPad pad "\(padID)".

            First call the get_pad_code tool with pad: "\(padID)" to read every file, and \
            get_pad with pad: "\(padID)" for the surrounding context (title, language, participants).

            Then give a focused review covering:
            - Correctness: does it solve the stated problem? Any bugs or unhandled edge cases?
            - Complexity: time and space, and whether it's appropriate.
            - Clarity: naming, structure, and readability.
            - What you'd ask the candidate next.

            Be concrete and cite the relevant code.
            """)],
        )

    case "summarize_pad":
        let padID = try requiredPromptArgument(arguments, "pad_id")
        return GetPrompt.Result(
            description: "Summarize pad \(padID).",
            messages: [userPromptMessage("""
            Summarize the CoderPad interview pad "\(padID)".

            Call get_pad with pad: "\(padID)" (and get_pad_code with pad: "\(padID)" for the code) and then give a short \
            summary: the problem posed, the candidate's approach and how far they got, notable \
            strengths or struggles, and the apparent outcome. Keep it to a few tight paragraphs.
            """)],
        )

    case "compare_pads":
        let ids = try requiredPromptArgument(arguments, "pad_ids")
        let list = ids.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !list.isEmpty else { throw PromptError.missingArgument("pad_ids") }

        let quoted = list.map { "\"\($0)\"" }.joined(separator: ", ")
        return GetPrompt.Result(
            description: "Compare pads \(list.joined(separator: ", ")).",
            messages: [userPromptMessage("""
            Compare these CoderPad pads to help rank the candidates: \(quoted).

            For each pad, call get_pad and get_pad_code with the pad argument set to that pad's id \
            to read its code and context. Then compare \
            them on correctness, code quality, problem-solving approach, and communication signals \
            you can infer. Finish with a ranked recommendation and the reasoning behind it.
            """)],
        )

    case "draft_question":
        let topic = try requiredPromptArgument(arguments, "topic")
        let language = promptArgument(arguments, "language")
        let difficulty = promptArgument(arguments, "difficulty")
        var constraints = ""
        if let language { constraints += "\nTarget language: \(language)." }
        if let difficulty { constraints += "\nDifficulty: \(difficulty)." }
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
