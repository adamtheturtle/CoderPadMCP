//
//  CoderPadProvider.swift
//  CoderPadMCP
//
//  A local Model Context Protocol server for CoderPad (#393). It speaks MCP over
//  stdio and exposes a small set of tools that fetch a CoderPad account's pads and
//  questions straight from the REST API, so an MCP-aware assistant can answer questions
//  about your interviews without the macOS app being involved.
//
//  It loads configuration and wires up the stdio server. The network-free logic (account resolution,
//  argument coercion, tool schemas, and the pad code/count/aggregate transforms) lives
//  in the CoderPadMCP library so it can be unit-tested (#522).
//
//  The server can act as several accounts (#521), mirroring the in-app server, so every
//  account-scoped tool takes an optional `account` argument and `list_accounts` lists
//  them. Accounts come from a JSON config file (CODERPAD_MCP_CONFIG, default
//  ~/.config/coderpad-mcp/config.json):
//    { "accounts": [ { "name": "Acme", "api_key": "…", "base_url": "…",
//                      "screen_api_key": "…", "screen_region": "eu", "default": true } ],
//      "allow_writes": false }
//  With no config file the legacy single-account environment variables are used instead:
//    CODERPAD_API_KEY (required), CODERPAD_BASE_URL, CODERPAD_SCREEN_API_KEY,
//    CODERPAD_SCREEN_REGION, CODERPAD_MCP_ALLOW_WRITES.
//
//  Read tools are always available. Write tools (create/edit) are OFF unless writes are
//  opted in (#502). There is no delete tool: deletion stays a human action in the app.
//

import Foundation
import MCP

private let knownToolNames = Set(
    availableTools(screenEnabled: true, writesEnabled: true).map(\.name),
)

// MARK: - Result helpers

private func missingArgument(_ name: String) -> CallTool.Result {
    CallTool.Result(
        content: [.text(text: "Missing required argument: \(name)", annotations: nil, _meta: nil)],
        isError: true,
    )
}

private func writesDisabled(accountSet: MCPAccountSet, account: MCPAccount) -> CallTool.Result {
    let text = if !accountSet.allowWrites {
        "Writes are disabled globally. Enable them with \"allow_writes\": true in the "
            + "config (or CODERPAD_MCP_ALLOW_WRITES=1) to use the create/edit tools."
    } else if !account.allowWrites {
        "Writes are disabled for account \"\(account.name)\". Set that account's "
            + "\"allow_writes\": true in the config (global writes are already enabled)."
    } else {
        "Writes are disabled for this account."
    }
    return CallTool.Result(
        content: [.text(text: text, annotations: nil, _meta: nil)],
        isError: true,
    )
}

private func unknownAccount(_ requested: String?, accountSet: MCPAccountSet) -> CallTool.Result {
    let names = accountSet.accounts.map(\.name).joined(separator: ", ")
    return CallTool.Result(
        content: [.text(
            text: "No account matches \"\(requested ?? "")\". Available accounts: \(names). "
                + "Use list_accounts to see them.",
            annotations: nil, _meta: nil,
        )],
        isError: true,
    )
}

func cachedRecords(
    _ kind: CoderPadMCPRecordKind,
    account: MCPAccount,
    requireFresh: Bool,
    cache: CoderPadMCPCache?,
) -> [[String: Any]]? {
    guard let data = cache?.load(kind, account.id, requireFresh),
          let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
        return nil
    }

    return records
}

private func getRecord(
    path: String,
    idKey: String,
    id: String,
    kind: CoderPadMCPRecordKind,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    let response = try await apiGet(path, account: account)
    if response.ok || response.status != 0 {
        return toolResult(response)
    }

    let record = cachedRecords(kind, account: account, requireFresh: false, cache: cache)?
        .first { String(describing: $0[idKey] ?? "") == id || String(describing: $0["slug"] ?? "") == id }
    guard let record else { return toolResult(response) }

    return jsonResult(record)
}

private func invalidating(
    _ result: CallTool.Result,
    kind: CoderPadMCPRecordKind,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async -> CallTool.Result {
    if result.isError != true {
        await cache?.invalidate(kind, account.id)
    }
    return result
}

// MARK: - Server

/// The CoderPad provider for MCPKit's `MCPServer`: it advertises the CoderPad
/// catalogue, prompts and resources, and runs the tool dispatch + resource reads against
/// the configured accounts. The generic server wiring (handler registration, the
/// PromptError mapping, stdio) is the shared `MCPServer`; only this CoderPad-specific
/// behaviour lives here, identical to the in-app server's provider.
/// A completed tool call suitable for privacy-preserving host activity logs.
public struct CoderPadMCPActivity: Sendable {
    public let tool: String
    public let accountID: String?
    public let accountName: String?
    public let succeeded: Bool
    public let failureReason: String?

    public init(
        tool: String,
        accountID: String?,
        accountName: String?,
        succeeded: Bool,
        failureReason: String?,
    ) {
        self.tool = tool
        self.accountID = accountID
        self.accountName = accountName
        self.succeeded = succeeded
        self.failureReason = failureReason
    }
}

public struct CoderPadProvider: MCPToolProvider {
    public let accountSet: MCPAccountSet
    private let cache: CoderPadMCPCache?
    private let activity: (@Sendable (CoderPadMCPActivity) -> Void)?
    private let interviewRequest: InterviewRequest

    public init(
        accountSet: MCPAccountSet,
        cache: CoderPadMCPCache? = nil,
        activity: (@Sendable (CoderPadMCPActivity) -> Void)? = nil,
    ) {
        self.init(
            accountSet: accountSet,
            cache: cache,
            activity: activity,
            interviewRequest: liveInterviewRequest,
        )
    }

    init(
        accountSet: MCPAccountSet,
        cache: CoderPadMCPCache? = nil,
        activity: (@Sendable (CoderPadMCPActivity) -> Void)? = nil,
        interviewRequest: @escaping InterviewRequest,
    ) {
        self.accountSet = accountSet
        self.cache = cache
        self.activity = activity
        self.interviewRequest = interviewRequest
    }

    public func tools() async -> [Tool] {
        availableTools(
            screenEnabled: accountSet.anyScreenEnabled,
            writesEnabled: accountSet.anyWritesEnabled,
        )
    }

    public func callTool(_ name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        guard knownToolNames.contains(name) else {
            let result = errorResult("Unknown tool: \(name)")
            record(name: name, account: nil, result: result)
            return result
        }

        // list_accounts is a directory-level query - it isn't scoped to one account.
        if name == "list_accounts" {
            let result = jsonResult(["accounts": accountSet.directory()])
            record(name: name, account: nil, result: result)
            return result
        }

        // Resolve the target account up front so every tool gives the same clear error.
        let requestedAccount = stringArgument(arguments, "account")
        guard let account = accountSet.resolve(requestedAccount) else {
            let result = unknownAccount(requestedAccount, accountSet: accountSet)
            record(name: name, account: nil, result: result)
            return result
        }

        // Write tools are gated on the opt-in, regardless of which account is targeted.
        if writeToolNames.contains(name), !accountSet.allowsWrites(to: account) {
            let result = writesDisabled(accountSet: accountSet, account: account)
            record(name: name, account: account, result: result)
            return result
        }
        if writeToolNames.contains(name), strictDryRunArgument(arguments) == .invalid {
            let result = errorResult("dry_run must be a boolean (true or false).")
            record(name: name, account: account, result: result)
            return result
        }

        try Task.checkCancellation()
        let result = try await ProviderRequestContext.$interviewRequest.withValue(interviewRequest) {
            try await dispatch(
                name: name,
                arguments: arguments,
                account: account,
                writesEnabled: accountSet.allowsWrites(to: account),
                cache: cache,
            )
        }
        record(name: name, account: account, result: result)
        return result
    }

    private func record(name: String, account: MCPAccount?, result: CallTool.Result) {
        let failureReason: String? = if result.isError == true,
                                        case let .text(text, _, _)? = result.content.first
        {
            text
        } else {
            nil
        }
        activity?(CoderPadMCPActivity(
            tool: name,
            accountID: account?.id,
            accountName: account?.name,
            succeeded: result.isError != true,
            failureReason: failureReason,
        ))
    }

    public func prompts() async -> [Prompt] {
        interviewPrompts
    }

    public func getPrompt(_ name: String, arguments: [String: String]?) async throws -> GetPrompt.Result {
        try renderPrompt(name: name, arguments: arguments)
    }

    public func resources() async -> [Resource] {
        staticResources(for: accountSet)
    }

    public func resourceTemplates() async -> [Resource.Template] {
        // Qualified: the unqualified name resolves to this method, not the core helper.
        CoderPadMCP.resourceTemplates(for: accountSet)
    }

    public func readResource(_ uri: String) async throws -> ReadResource.Result {
        guard let request = parseResourceURI(uri) else {
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }

        let account: MCPAccount = switch resolveResourceAccount(request, accountSet: accountSet) {
        case let .account(account):
            account

        case .noAccounts:
            throw MCPError.invalidParams("No CoderPad accounts are configured.")

        case .requiresAccount:
            throw MCPError.invalidParams(
                "Resource URI must include an account in multi-account configs: "
                    + "coderpad://account/{account}/...",
            )

        case let .unknownAccount(name):
            throw MCPError.invalidParams("No account matches resource selector \"\(name)\".")
        }
        return try await ProviderRequestContext.$interviewRequest.withValue(interviewRequest) {
            try await readCoderPadResource(request.unqualified, uri: uri, account: account)
        }
    }
}

// MARK: - Tool dispatch

/// The names of the write tools, gated on the writes opt-in. Kept as one set so the
/// `tools/list` filter and the call gate can't drift apart.
let writeToolNames: Set<String> = ["create_pad", "update_pad", "create_question", "update_question"]

/// Runs one account-scoped tool against the resolved account.
private func dispatch(
    name: String,
    arguments: [String: Value]?,
    account: MCPAccount,
    writesEnabled: Bool,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
    if let invalid = invalidIntegerArgument(arguments, names: integerArgumentNames(forTool: name)) {
        return errorResult("\(invalid) must be an integer without a fractional part.")
    }

    switch name {
    case "whoami":
        return try await whoami(account: account, writesEnabled: writesEnabled)

    case "list_pads":
        return try await listPads(arguments: arguments, account: account)

    case "get_pad":
        guard let pad = validatedPadID(stringArgument(arguments, "pad")) else {
            return errorResult("pad must be a positive id or a non-empty slug.")
        }

        return try await getRecord(
            path: "/api/pads/\(pad)",
            idKey: "id",
            id: pad,
            kind: .pads,
            account: account,
            cache: cache,
        )

    case "get_pad_code":
        guard let pad = validatedPadID(stringArgument(arguments, "pad")) else {
            return errorResult("pad must be a positive id or a non-empty slug.")
        }

        return try await getPadCode(
            id: pad,
            maxFileChars: strictIntArgument(arguments, "max_file_chars"),
            account: account,
        )

    case "count_pads":
        return try await countPads(arguments: arguments, account: account, cache: cache)

    case "aggregate_pads":
        guard let groupBy = stringArgument(arguments, "group_by"), !groupBy.isEmpty else {
            return missingArgument("group_by")
        }

        return try await aggregatePadsTool(
            groupBy: groupBy,
            arguments: arguments,
            account: account,
            cache: cache,
        )

    case "list_pads_compact":
        return try await listPadsCompact(arguments: arguments, account: account)

    case "list_questions":
        return try await listQuestions(arguments: arguments, account: account)

    case "get_question":
        guard let question = positiveID(strictIntArgument(arguments, "question")) else {
            return errorResult("question must be a positive integer.")
        }

        return try await getRecord(
            path: "/api/questions/\(question)",
            idKey: "id",
            id: String(question),
            kind: .questions,
            account: account,
            cache: cache,
        )

    case "count_questions":
        return try await countQuestions(arguments: arguments, account: account, cache: cache)

    case "aggregate_questions":
        guard let groupBy = stringArgument(arguments, "group_by"), !groupBy.isEmpty else {
            return missingArgument("group_by")
        }

        return try await aggregateQuestionsTool(
            groupBy: groupBy,
            arguments: arguments,
            account: account,
            cache: cache,
        )

    case "list_questions_compact":
        return try await listQuestionsCompact(arguments: arguments, account: account)

    case "get_quota":
        return try await toolResult(apiGet("/api/quota", account: account))

    case "get_organization":
        return try await toolResult(apiGet("/api/organization", account: account))

    default:
        return try await dispatchScreenOrWrite(
            name: name,
            arguments: arguments,
            account: account,
            cache: cache,
        )
    }
}

/// The Screen and write tools, split out so `dispatch` stays within the
/// cyclomatic-complexity budget.
private func dispatchScreenOrWrite(
    name: String,
    arguments: [String: Value]?,
    account: MCPAccount,
    cache: CoderPadMCPCache?,
) async throws -> CallTool.Result {
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
        return errorResult(error)
    }
    if let fields = budgetedWriteFields[name],
       let invalid = invalidWriteStringArgument(arguments, names: fields)
    {
        return errorResult("\(invalid) must be a string.")
    }
    if let fields = budgetedWriteFields[name],
       let error = writeStringBudgetValidationError(arguments, fields: fields)
    {
        return errorResult(error)
    }

    switch name {
    case "screen_list_campaigns":
        return try await toolResult(screenGet("/campaigns", account: account))

    case "screen_list_tests":
        if let campaign = strictIntArgument(arguments, "campaignId"), positiveID(campaign) == nil {
            return errorResult("campaignId must be a positive integer.")
        }
        if let error = screenPaginationValidationError(
            start: strictIntArgument(arguments, "start"),
            limit: strictIntArgument(arguments, "limit"),
        ) {
            return errorResult(error)
        }
        if let invalid = invalidPresentStringArgument(arguments, names: ["candidateEmail"]) {
            return errorResult("\(invalid) must be a string.")
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

    case "screen_get_test":
        guard let test = positiveID(strictIntArgument(arguments, "test")) else {
            return errorResult("test must be a positive integer.")
        }

        return try await toolResult(screenGet("/tests/\(test)", account: account))

    case "create_pad":
        let result = try await createPad(arguments: arguments, account: account)
        return await invalidating(result, kind: .pads, account: account, cache: cache)

    case "update_pad":
        guard let pad = validatedPadID(stringArgument(arguments, "pad")) else {
            return errorResult("pad must be a positive id or a non-empty slug.")
        }

        let result = try await updatePad(id: pad, arguments: arguments, account: account)
        return await invalidating(result, kind: .pads, account: account, cache: cache)

    case "create_question":
        guard arguments?["title"] != nil else { return missingArgument("title") }
        let rawTitle = presentWriteString(arguments, "title")
        if let error = questionTitleValidationError(rawTitle) {
            return errorResult(error)
        }
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return missingArgument("title")
        }

        let result = try await createQuestion(title: title, arguments: arguments, account: account)
        return await invalidating(result, kind: .questions, account: account, cache: cache)

    case "update_question":
        guard let question = positiveID(strictIntArgument(arguments, "question")) else {
            return errorResult("question must be a positive integer.")
        }

        let result = try await updateQuestion(id: question, arguments: arguments, account: account)
        return await invalidating(result, kind: .questions, account: account, cache: cache)

    default:
        return CallTool.Result(
            content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
            isError: true,
        )
    }
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

// MARK: - whoami (#518)

/// Reports which account/org this server acts as, without the API key: the account
/// name, the org name (fetched from `/api/organization`), the base URL, and whether
/// Screen and writes are enabled.
private func whoami(account: MCPAccount, writesEnabled: Bool) async throws -> CallTool.Result {
    var info: [String: Any] = [
        "account": account.name,
        "base_url": account.baseURL.absoluteString,
        "screen_configured": account.screenEnabled,
        "writes_enabled": writesEnabled,
    ]

    let org = try await apiGet("/api/organization", account: account)
    if org.ok, let object = jsonObject(org.data), let name = object["organization_name"] as? String {
        info["organization_name"] = name
    } else {
        info["organization_note"] = "Could not fetch the organization name from the API."
    }

    return jsonResult(info)
}

// MARK: - get_pad_code (#499)

/// Fetches the pad and each of its environments and assembles the compact code JSON
/// via the pure `padCodePayload` in the core library. Throws `MCPError` on an HTTP or
/// parse failure so both the tool and the resource reader can surface it.
private func padCodeJSON(id: String, maxFileChars: Int?, account: MCPAccount) async throws -> String {
    if let error = maxFileCharsValidationError(maxFileChars) {
        throw MCPError.invalidParams(error)
    }

    let padResponse = try await apiGet("/api/pads/\(id)", account: account)
    guard padResponse.ok else {
        throw MCPError.internalError(
            sanitizedHTTPErrorMessage(status: padResponse.status, body: padResponse.body),
        )
    }
    guard let pad = jsonObject(padResponse.data) else {
        throw MCPError.internalError("Could not parse the pad response as JSON.")
    }

    // Fetch in bounded concurrent batches, retaining source order in the result (#2260, #42).
    // Parse and release each batch before fetching the next so one call cannot retain
    // ~100 × 8 MiB of raw environment bodies at once (#178).
    let ids = environmentIDs(in: pad)
    if let error = environmentCountValidationError(ids) {
        throw MCPError.internalError(error)
    }
    var environments: [PadCodeEnvironment] = []
    var failedEnvironmentIDs: [Int] = []
    for batchStart in stride(from: 0, to: ids.count, by: maxConcurrentPadCodeEnvironmentRequests) {
        let offsets = batchStart ..< min(batchStart + maxConcurrentPadCodeEnvironmentRequests, ids.count)
        // The response bodies cross the task boundary, not the parsed objects:
        // `[String: Any]` is not Sendable, so parsing happens on the collecting side.
        var batchBodies: [Int: Data] = [:]
        try await withThrowingTaskGroup(of: (offset: Int, body: Data?).self) { group in
            for offset in offsets {
                group.addTask {
                    let response = try await apiGet("/api/pad_environments/\(ids[offset])", account: account)
                    return (offset, response.ok ? response.data : nil)
                }
            }
            for try await result in group {
                batchBodies[result.offset] = result.body
            }
        }
        for offset in offsets {
            let environmentID = ids[offset]
            guard let body = batchBodies[offset], let object = jsonObject(body) else {
                failedEnvironmentIDs.append(environmentID)
                continue
            }
            environments.append(PadCodeEnvironment(id: environmentID, object: object))
        }
    }

    let payload = padCodePayload(
        id: id, pad: pad, environments: environments,
        maxFileChars: maxFileChars, failedEnvironmentIDs: failedEnvironmentIDs,
    )
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys],
    ) else {
        throw MCPError.internalError("Could not encode the pad code.")
    }

    return String(decoding: data, as: UTF8.self)
}

private func getPadCode(id: String, maxFileChars: Int?, account: MCPAccount) async throws -> CallTool.Result {
    do {
        let json = try await padCodeJSON(id: id, maxFileChars: maxFileChars, account: account)
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: nil)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return CallTool.Result(
            content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
            isError: true,
        )
    }
}

// MARK: - Resource reads (#517)

/// Fetches the JSON behind a parsed resource URI and returns it as the resource's
/// contents. Throws `MCPError` on failure so the client gets a proper JSON-RPC error.
private func readCoderPadResource(
    _ request: ResourceRequest,
    uri: String,
    account: MCPAccount,
) async throws -> ReadResource.Result {
    func jsonResource(_ path: String) async throws -> ReadResource.Result {
        let response = try await apiGet(path, account: account)
        guard response.ok else {
            throw MCPError.internalError(
                sanitizedHTTPErrorMessage(
                    status: response.status,
                    body: response.body,
                    context: " reading \(uri)",
                ),
            )
        }
        guard isValidJSON(response.data) else {
            throw MCPError.internalError("CoderPad returned invalid JSON reading \(uri).")
        }

        return ReadResource.Result(contents: [.text(response.body, uri: uri, mimeType: "application/json")])
    }

    switch request {
    case .quota: return try await jsonResource("/api/quota")

    case .organization: return try await jsonResource("/api/organization")

    case let .pad(id): return try await jsonResource("/api/pads/\(id)")

    case let .question(id): return try await jsonResource("/api/questions/\(id)")

    case let .padCode(id):
        let json = try await padCodeJSON(id: id, maxFileChars: nil, account: account)
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])

    case .accountQuota, .accountOrganization, .accountPad, .accountPadCode, .accountQuestion:
        // The caller resolves the account and passes `request.unqualified`, so these
        // only arrive if a new call site forgets to; strip the qualifier and recurse.
        return try await readCoderPadResource(request.unqualified, uri: uri, account: account)
    }
}

// MARK: - Write tools (#502, gated behind the writes opt-in)

private func dryRunResult(method: String, path: String, body: [String: Any]) -> CallTool.Result {
    jsonResult(["dry_run": true, "changed": false, "method": method, "path": path, "body": body])
}

private func createPad(arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    let title = optionalString(arguments, "title")
    if let error = padTitleValidationError(title) {
        return errorResult(error)
    }
    let rawOwnerEmail = stringArgument(arguments, "owner_email")
    if let error = ownerEmailValidationError(rawOwnerEmail) {
        return errorResult(error)
    }
    let ownerEmail = rawOwnerEmail.flatMap { $0.isEmpty ? nil : $0 }
    let rawLanguage = optionalString(arguments, "language")
    if let error = createPadLanguageValidationError(rawLanguage) {
        return errorResult(error)
    }
    let language = validatedCreatePadLanguage(rawLanguage)
    if let error = padSeedValidationError(
        questionID: strictIntArgument(arguments, "question_id"),
        contents: presentWriteString(arguments, "contents"),
    ) {
        return errorResult(error)
    }
    let teamID = optionalString(arguments, "team_id")
    if let error = teamIDValidationError(teamID) {
        return errorResult(error)
    }

    var body: [String: Any] = [:]
    if let title {
        body["title"] = title
    }
    if let language {
        body["language"] = language
    }
    if let owner = ownerEmail {
        // Interview create/modify pad ownership uses `user_email`, not response `owner_email`.
        body["user_email"] = owner
    }
    if let contents = presentWriteString(arguments, "contents") {
        body["contents"] = contents
    }
    if let notes = optionalString(arguments, "notes") {
        body["notes"] = notes
    }
    if let questionID = strictIntArgument(arguments, "question_id") {
        body["question_id"] = questionID
    }
    if let teamID {
        body["team_id"] = teamID
    }

    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: "POST", path: "/api/pads/", body: body)
    }
    return try await toolResult(apiSend("POST", "/api/pads/", account: account, body: body))
}

private func updatePad(id: String, arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    let title = presentWriteString(arguments, "title")
    if let error = padUpdateTitleValidationError(title) {
        return errorResult(error)
    }
    let owner = presentWriteString(arguments, "owner_email")
    if let error = padUpdateOwnerEmailValidationError(owner) {
        return errorResult(error)
    }
    let rawLanguage = presentWriteString(arguments, "language")
    if let error = createPadLanguageValidationError(rawLanguage) {
        return errorResult(error)
    }
    let language = validatedCreatePadLanguage(rawLanguage)
    var body: [String: Any] = [:]
    if let title {
        body["title"] = title
    }
    if let notes = presentWriteString(arguments, "notes") {
        body["notes"] = notes
    }
    if let owner {
        body["user_email"] = owner
    }
    if let language {
        body["language"] = language
    }
    guard !body.isEmpty else {
        return missingArgument("at least one of title / notes / owner_email / language")
    }

    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: "PUT", path: "/api/pads/\(id)", body: body)
    }
    return try await toolResult(apiSend("PUT", "/api/pads/\(id)", account: account, body: body))
}

private func createQuestion(
    title: String,
    arguments: [String: Value]?,
    account: MCPAccount,
) async throws -> CallTool.Result {
    let rawLanguage = optionalString(arguments, "language")
    if let error = createPadLanguageValidationError(rawLanguage) {
        return errorResult(error)
    }
    var question: [String: Any] = ["title": title]
    if let language = validatedCreatePadLanguage(rawLanguage) {
        question["language"] = language
    }
    var body: [String: Any] = ["question": question]
    if let description = presentWriteString(arguments, "description") {
        body["description"] = description
    }
    if let solution = presentWriteString(arguments, "solution") {
        body["solution"] = solution
    }
    if let contents = presentWriteString(arguments, "contents") {
        body["contents"] = contents
    }

    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: "POST", path: "/api/questions/", body: body)
    }
    return try await toolResult(apiSend("POST", "/api/questions/", account: account, body: body))
}

private func updateQuestion(
    id: Int,
    arguments: [String: Value]?,
    account: MCPAccount,
) async throws -> CallTool.Result {
    let title = presentWriteString(arguments, "title")
    if let error = questionTitleValidationError(title) {
        return errorResult(error)
    }
    let rawLanguage = presentWriteString(arguments, "language")
    if let error = createPadLanguageValidationError(rawLanguage) {
        return errorResult(error)
    }
    var question: [String: Any] = [:]
    if let title {
        question["title"] = title
    }
    if let language = validatedCreatePadLanguage(rawLanguage) {
        question["language"] = language
    }
    var body: [String: Any] = [:]
    if !question.isEmpty {
        body["question"] = question
    }
    if let description = presentWriteString(arguments, "description") {
        body["description"] = description
    }
    if let solution = presentWriteString(arguments, "solution") {
        body["solution"] = solution
    }
    if let contents = presentWriteString(arguments, "contents") {
        body["contents"] = contents
    }
    guard !body.isEmpty else {
        return missingArgument("at least one of title / language / description / solution / contents")
    }

    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: "PUT", path: "/api/questions/\(id)", body: body)
    }
    return try await toolResult(apiSend("PUT", "/api/questions/\(id)", account: account, body: body))
}
