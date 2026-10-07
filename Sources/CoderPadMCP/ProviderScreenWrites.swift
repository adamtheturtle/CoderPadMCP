//
//  ProviderScreenWrites.swift
//  CoderPadMCP
//
//  Screen and write-tool dispatch, kept separate so CoderPadProvider.swift stays
//  within SwiftLint complexity and body-length budgets.
//

import Foundation
import MCP

func dispatchScreenOrWrite(
    name: String,
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    if let error = writeArgumentValidationError(name: name, arguments: arguments) {
        return errorResult(error)
    }

    switch name {
    case "screen_ai_assist_conversations":
        return try await screenAIConversations(arguments: arguments, account: account)

    case "screen_create_question", "screen_update_question":
        return try await screenSaveQuestion(arguments, account: account, update: name == "screen_update_question")

    case "screen_upload_project":
        return try await screenUploadProject(arguments, account: account)

    case "screen_create_campaign":
        return try await screenCreateCampaign(arguments, account: account)

    case "screen_project_archive":
        return screenProjectArchiveLink(arguments, account: account)

    case "screen_list_questions", "screen_get_question", "screen_question_insights":
        return try await dispatchScreenQuestionRead(name: name, arguments: arguments, account: account)

    case "screen_list_campaigns":
        if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument]) {
            return errorResult(error)
        }
        return try await toolResult(screenGet("/campaigns", account: account))

    case "screen_list_tests":
        return try await screenListTests(arguments: arguments, account: account)

    case "screen_get_test":
        return try await screenGetTest(arguments: arguments, account: account)

    case "create_pad":
        let result = try await createPad(arguments: arguments, account: account)
        return await invalidating(
            result, kind: .pads, account: account, cache: cache,
            dryRun: strictDryRunArgument(arguments) == .value(true),
        )

    case "update_pad":
        guard let pad = validatedPadID(stringArgument(arguments, "pad")) else {
            return errorResult("pad must be a positive id or a non-empty slug.")
        }
        let result = try await updatePad(id: pad, arguments: arguments, account: account)
        return await invalidating(
            result, kind: .pads, account: account, cache: cache,
            dryRun: strictDryRunArgument(arguments) == .value(true),
        )

    case "create_question":
        guard let title = optionalString(arguments, "title") else { return missingArgument("title") }
        let result = try await createQuestion(title: title, arguments: arguments, account: account)
        return await invalidating(
            result, kind: .questions, account: account, cache: cache,
            dryRun: strictDryRunArgument(arguments) == .value(true),
        )

    case "update_question":
        guard let question = positiveID(strictIntArgument(arguments, "question")) else {
            return errorResult("question must be a positive integer.")
        }
        let result = try await updateQuestion(id: question, arguments: arguments, account: account)
        return await invalidating(
            result, kind: .questions, account: account, cache: cache,
            dryRun: strictDryRunArgument(arguments) == .value(true),
        )

    default:
        return CallTool.Result(
            content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
            isError: true,
        )
    }
}

private func writeArgumentValidationError(name: String, arguments: [String: Value]?) -> String? {
    let writeArgumentAllowlists: [String: Set<String>] = [
        "create_pad": [
            mcpAccountArgument, "title", "language", "question_id", "contents", "owner_email",
            "notes", "team_id", "dry_run",
        ],
        "update_pad": [
            mcpAccountArgument, "pad", "title", "notes", "owner_email", "language", "dry_run",
        ],
        "create_question": [
            mcpAccountArgument, "title", "language", "description", "solution", "contents", "dry_run",
        ],
        "update_question": [
            mcpAccountArgument, "question", "title", "language", "description", "solution",
            "contents", "dry_run",
        ],
    ]
    let budgetedWriteFields = [
        "create_pad": ["title", "language", "contents", "owner_email", "notes", "team_id"],
        "update_pad": ["title", "notes", "owner_email", "language"],
        "create_question": ["title", "language", "description", "solution", "contents"],
        "update_question": ["title", "language", "description", "solution", "contents"],
    ]
    if let allowed = writeArgumentAllowlists[name],
       let error = unknownWriteArgumentError(arguments, allowed: allowed)
    {
        return error
    }
    if let fields = budgetedWriteFields[name],
       let invalid = invalidPresentStringArgument(arguments, names: fields)
    {
        return "\(invalid) must be a string."
    }
    if let fields = budgetedWriteFields[name] {
        return writeStringBudgetValidationError(arguments, fields: fields)
    }
    return nil
}

private func screenListTests(
    arguments: [String: Value]?,
    account: MCPAccount,
) async throws -> CallTool.Result {
    if let error = unknownArgumentError(
        arguments,
        allowed: [mcpAccountArgument, "campaignId", "candidateEmail", "start", "limit"],
    ) {
        return errorResult(error)
    }
    if let invalid = invalidPresentStringArgument(arguments, names: ["candidateEmail"]) {
        return errorResult("\(invalid) must be a string.")
    }
    if let campaign = strictIntArgument(arguments, "campaignId"), positiveScreenID(campaign) == nil {
        return errorResult("campaignId must be a positive int32.")
    }
    if arguments?["campaignId"] != nil, strictIntArgument(arguments, "campaignId") == nil {
        return errorResult("campaignId must be a positive int32.")
    }
    if let error = screenPaginationValidationError(
        start: strictIntArgument(arguments, "start"),
        limit: strictIntArgument(arguments, "limit"),
    ) {
        return errorResult(error)
    }
    let rawCandidateEmail = stringArgument(arguments, "candidateEmail")
    if let error = screenCandidateEmailValidationError(rawCandidateEmail) {
        return errorResult(error)
    }
    return try await toolResult(screenGet(
        "/tests",
        account: account,
        query: screenTestQuery(arguments, candidateEmail: normalizedScreenCandidateEmail(rawCandidateEmail)),
    ))
}

private func screenGetTest(
    arguments: [String: Value]?,
    account: MCPAccount,
) async throws -> CallTool.Result {
    if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument, "test", "withCommunityStats"]) {
        return errorResult(error)
    }
    guard let test = positiveScreenID(strictIntArgument(arguments, "test")) else {
        return errorResult("test must be a positive int32.")
    }
    var query: [URLQueryItem] = []
    if let value = arguments?["withCommunityStats"] {
        guard case let .bool(enabled) = value else {
            return errorResult("withCommunityStats must be a boolean.")
        }
        query.append(URLQueryItem(name: "withCommunityStats", value: enabled ? "true" : "false"))
    }
    return try await toolResult(screenGet("/tests/\(test)", account: account, query: query))
}

private func screenTestQuery(_ arguments: [String: Value]?, candidateEmail: String?) -> [URLQueryItem] {
    var query: [URLQueryItem] = []
    if let campaign = strictIntArgument(arguments, "campaignId") {
        query.append(URLQueryItem(name: "campaignId", value: String(campaign)))
    }
    if let email = candidateEmail {
        query.append(URLQueryItem(name: "candidateEmail", value: email))
    }
    if let start = strictIntArgument(arguments, "start") {
        query.append(URLQueryItem(name: "start", value: String(start)))
    }
    if let limit = strictIntArgument(arguments, "limit") {
        query.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    return query
}
