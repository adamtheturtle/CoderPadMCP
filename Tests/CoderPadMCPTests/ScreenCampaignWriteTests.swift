@testable import CoderPadMCP
import Foundation
import MCP
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor CampaignWriteProbe {
    var requests: [URLRequest] = []
    func capture(_ request: URLRequest) {
        requests.append(request)
    }

    func captured() -> [URLRequest] {
        requests
    }
}

@Suite("Screen campaign creation")
struct ScreenCampaignWriteTests {
    private let questionID = "4143ca74-2f0e-4151-90d6-e1428739450b"
    private let teamID = "0558b3e3-b76c-42ea-9435-8da1adb7e232"

    @Test
    func `one Screen POST preserves ordered selections random sets and explicit settings`() async throws {
        let probe = CampaignWriteProbe()
        let provider = try provider()
        let arguments = completeArguments()
        let responseBody = #"{"id":1,"retained":false}"#
        let loader: ScreenResponseRequest = { request, limit in
            await probe.capture(request)
            #expect(request.url?.absoluteString == "https://www.codingame.eu/assessment/api/v1.1/campaigns")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "API-Key") == "screen-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(limit == 1024 * 1024)
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            try checkCompleteBody(body)
            return try response(request, status: 201, body: responseBody)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_campaign", arguments: arguments)
        }
        #expect(result.isError != true)
        #expect(try text(result) == responseBody)
        #expect(await probe.captured().count == 1)
    }

    @Test
    func `dry runs preserve omissions and never create an invented id`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, _ in
            Issue.record("Dry runs must not make requests")
            throw CancellationError()
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_campaign", arguments: [
                "name": .string("Backend"), "questions": .array([.object(["type": .string("QUESTION"),
                                                                          "question_id": .string(questionID)])]), "dry_run": .bool(true),
            ])
        }
        #expect(result.isError != true)
        let preview = try object(result)
        #expect(preview["id"] == nil)
        #expect(preview["changed"] as? Bool == false)
        #expect(preview["path"] as? String == "/assessment/api/v1.1/campaigns")
        #expect(preview["method"] as? String == "POST")
        let body = try #require(preview["body"] as? [String: Any])
        #expect(body.keys.sorted() == ["name", "questions"])
    }

    @Test
    func `invalid nested fields and cross-field settings fail before network access`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, _ in
            Issue.record("Invalid campaigns must not make requests")
            throw CancellationError()
        }
        var invalid: [[String: Value]] = [
            ["name": .string("ab")], ["name": .string(String(repeating: "a", count: 65))], ["questions": .array([])],
            ["questions": .array([.object(["type": .string("QUESTION")])])],
            ["questions": .array([.object(["type": .string("QUESTION"), "question_id": .string("bad")])])],
            ["questions": .array([.object(["type": .string("RANDOM_QUESTION_SET"), "configuration": .object([
                "question_type": .string("QUIZ"), "target_duration_minutes": .int(45),
            ])])])], ["team_id": .string("bad")], ["settings": .object(["copy_paste_blocked": .string("false")])],
            ["settings": .object(["timer": .object(["mode": .string("GLOBAL")])])],
            ["settings": .object(["timer": .object(["mode": .string("UNLIMITED"), "duration_minutes": .int(30)])])],
            ["settings": .object(["timer": .object(["mode": .string("PER_QUESTION")]),
                                  "access_period": .object(["max_end_time": .string("2026-10-10T08:00:00Z")])])],
            ["settings": .object(["access_period": .object([
                "min_start_time": .string("2026-10-10T08:00:00Z"), "max_end_time": .string("2026-10-09T08:00:00Z"),
            ])])], ["settings": .object(["invitation_expiration_days": .double(1.5)])],
            ["settings": .object(["unknown": .bool(false)])], ["dry_run": .int(1)],
        ]
        invalid.append(["questions": .array([.object(["type": .string("RANDOM_QUESTION_SET"), "configuration": .object([
            "question_type": .string("CODE"), "target_duration_minutes": .int(30),
            "included_question_ids": .array([]), "excluded_question_ids": .array([]),
        ])])])])
        for replacement in invalid {
            var arguments = completeArguments()
            arguments.merge(replacement) { _, new in new }
            let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
                try await provider.callTool("screen_create_campaign", arguments: arguments)
            }
            #expect(result.isError == true)
        }
    }

    @Test(arguments: [400, 403, 404, 409, 429, 500])
    func `API errors make one attempt`(status: Int) async throws {
        let probe = CampaignWriteProbe()
        let provider = try provider()
        let loader: ScreenResponseRequest = { request, _ in
            await probe.capture(request)
            return try response(request, status: status, body: #"{"message":"unavailable feature"}"#)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_campaign", arguments: completeArguments())
        }
        #expect(result.isError == true)
        #expect(await probe.captured().count == 1)
    }

    @Test(arguments: [#"{}"#, #"{"id":true}"#, #"{"id":0}"#, #"{"id":2147483648}"#])
    func `successful responses require a usable integer identity`(body: String) async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { request, _ in try response(request, status: 201, body: body) }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_campaign", arguments: completeArguments())
        }
        #expect(result.isError == true)
    }

    @Test
    func `both Screen and write capabilities must belong to the selected account`() async throws {
        for (screen, writes) in [(false, true), (true, false), (false, false)] {
            let provider = try provider(screen: screen, writes: writes)
            let tools = await provider.tools()
            #expect(tools.first { $0.name == "screen_create_campaign" } == nil)
            var arguments = completeArguments()
            arguments["dry_run"] = .bool(true)
            let result = try await provider.callTool("screen_create_campaign", arguments: arguments)
            #expect(result.isError == true)
        }
        #expect(availableTools(screenEnabled: true, writesEnabled: false, screenWritesEnabled: true)
            .first { $0.name == "screen_create_campaign" } == nil)
        let enabled = try provider()
        let tool = try #require(await enabled.tools().first { $0.name == "screen_create_campaign" })
        #expect(tool.annotations.readOnlyHint == false)
        #expect(tool.annotations.destructiveHint == false)
        let url = try #require(URL(string: "https://configured.example"))
        let writer = try MCPAccount(id: "writer", name: "Writer", apiKey: "writer-key", baseURL: url,
                                    screenAPIKey: nil, screenRegion: "us", allowWrites: true)
        let reader = try MCPAccount(id: "reader", name: "Reader", apiKey: "reader-key", baseURL: url,
                                    screenAPIKey: "read-only-key", screenRegion: "us", allowWrites: false)
        let split = try CoderPadProvider(accountSet: MCPAccountSet(accounts: [writer, reader], defaultName: writer.id, allowWrites: true))
        #expect(await split.tools().first { $0.name == "screen_create_campaign" } == nil)
    }

    @Test(arguments: ["us", "eu"])
    func `multi-account creation requires and uses the writable Screen account`(region: String) async throws {
        let url = try #require(URL(string: "https://configured.example"))
        let other = try MCPAccount(id: "other", name: "Other", apiKey: "other-interview-key", baseURL: url,
                                   screenAPIKey: "other-screen-key", screenRegion: "us", allowWrites: false)
        let chosen = try MCPAccount(id: "chosen", name: "Chosen", apiKey: "chosen-interview-key", baseURL: url,
                                    screenAPIKey: "chosen-screen-key", screenRegion: region, allowWrites: true)
        let provider = try CoderPadProvider(accountSet: MCPAccountSet(accounts: [other, chosen], defaultName: other.id, allowWrites: true))
        let tool = try #require(await provider.tools().first { $0.name == "screen_create_campaign" })
        guard case let .object(schema) = tool.inputSchema else { throw CocoaError(.coderReadCorrupt) }
        #expect(schema["required"] == .array([.string("name"), .string("questions"), .string("account")]))
        let loader: ScreenResponseRequest = { request, _ in
            #expect(request.url?.host == (region == "eu" ? "www.codingame.eu" : "screen.coderpad.io"))
            #expect(request.value(forHTTPHeaderField: "API-Key") == "chosen-screen-key")
            return try response(request, status: 201, body: #"{"id":42}"#)
        }
        var arguments = completeArguments()
        arguments["account"] = .string("chosen")
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_campaign", arguments: arguments)
        }
        #expect(result.isError != true)
    }

    @Test
    func `cancellation propagates instead of becoming a campaign error`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await ProviderRequestContext.$screenResponse.withValue(loader) {
                try await provider.callTool("screen_create_campaign", arguments: completeArguments())
            }
        }
    }

    @Test
    func `large nested settings are rejected before encoding or sending`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, _ in
            Issue.record("Oversized settings must not make requests")
            throw CancellationError()
        }
        let skill = Value.string(String(repeating: "x", count: 4096))
        let entry: Value = .object(["type": .string("RANDOM_QUESTION_SET"), "configuration": .object([
            "question_type": .string("CODE"), "target_duration_minutes": .int(30),
            "skills": .array(Array(repeating: skill, count: 200)),
        ])])
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_campaign", arguments: [
                "name": .string("Backend"), "questions": .array([entry, entry]),
            ])
        }
        #expect(result.isError == true)
    }

    private func completeArguments() -> [String: Value] {
        ["name": .string("Backend"), "team_id": .string(teamID), "questions": .array([
            .object(["type": .string("QUESTION"), "question_id": .string(questionID)]),
            .object(["type": .string("RANDOM_QUESTION_SET"), "configuration": .object([
                "domain": .string("backend"), "skills": .array([]), "question_type": .string("CODE"),
                "target_duration_minutes": .int(45), "target_experience_level": .string("EXPERT"), "excluded_question_ids": .array([]),
            ])]),
        ]), "settings": .object([
            "timer": .object(["mode": .string("GLOBAL"), "duration_minutes": .int(30)]),
            "copy_paste_blocked": .bool(false), "ai_assist_enabled": .bool(false), "enabled_coding_agents": .string(""),
            "invitation_expiration_days": .int(0), "languages": .array([.string("en"), .string("fr")]),
            "webcam_proctoring": .object(["enabled": .bool(true), "ai_analysis_enabled": .bool(false)]),
        ])]
    }

    private func checkCompleteBody(_ body: [String: Any]) throws {
        #expect(body["name"] as? String == "Backend")
        #expect(body["team_id"] as? String == teamID)
        let questions = try #require(body["questions"] as? [[String: Any]])
        #expect(questions.map { $0["type"] as? String } == ["QUESTION", "RANDOM_QUESTION_SET"])
        let settings = try #require(body["settings"] as? [String: Any])
        #expect(settings["copy_paste_blocked"] as? Bool == false)
        #expect(settings["ai_assist_enabled"] as? Bool == false)
        #expect(settings["enabled_coding_agents"] as? String == "")
        #expect(settings["invitation_expiration_days"] as? Int == 0)
        #expect(settings["access_period"] == nil)
    }

    private func provider(screen: Bool = true, writes: Bool = true) throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://configured.example"))
        let account = try MCPAccount(name: "Campaign", apiKey: "interview-key", baseURL: url,
                                     screenAPIKey: screen ? "screen-key" : nil, screenRegion: "eu")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: writes))
    }

    private func response(_ request: URLRequest, status: Int, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return text
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
    }
}
