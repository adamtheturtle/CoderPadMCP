@testable import CoderPadMCP
import Foundation
import MCP
import Testing

private actor QuestionSettingProbe {
    var calls = 0
    var invalidations: [String] = []
    func request() {
        calls += 1
    }

    func invalidate(_ kind: CoderPadMCPRecordKind, _ account: String) {
        invalidations.append("\(kind.rawValue):\(account)")
    }

    func count() -> Int {
        calls
    }

    func cleared() -> [String] {
        invalidations
    }
}

@Suite("Question instruction and organization settings")
struct QuestionSettingProviderTests {
    @Test(arguments: ["create_question", "update_question"], [false, true])
    func `writes and dry runs preserve encoded steps false sharing and empty prompt`(tool: String, dryRun: Bool) async throws {
        let probe = QuestionSettingProbe()
        let provider = try provider(probe: probe) { method, path, account, query, body, limit in
            await probe.request()
            #expect(method == (tool == "create_question" ? "POST" : "PUT"))
            #expect(path == "/api/questions/" + (tool == "update_question" ? "42" : ""))
            #expect(account.apiKey == "chosen-key")
            #expect(account.baseURL.absoluteString == "https://chosen.example")
            #expect(query == [])
            #expect(limit == 1024 * 1024)
            let data = try #require(body)
            let actual = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            try checkBody(actual, creating: tool == "create_question")
            return APIResponse(status: 200, body: #"{"id":42}"#)
        }
        let steps: [Value] = [
            .object(["instructions": .string("Read 世界"), "name": .string(""), "default_visible": .bool(false)]),
            .object(["instructions": .string("Then code")]),
        ]
        var arguments: [String: Value] = [
            "candidate_instructions": .array(steps),
            "shared": .bool(false), "custom_database_id": .int(501), "ai_assist_custom_system_prompt": .string(""),
            "dry_run": .bool(dryRun),
        ]
        if tool == "create_question" {
            arguments["title"] = .string("Question")
        } else {
            arguments["question"] = .int(42)
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError != true)
        if dryRun {
            let preview = try object(result)
            let body = try #require(preview["body"] as? [String: Any])
            try checkBody(body, creating: tool == "create_question")
            #expect(preview["changed"] as? Bool == false)
            #expect(preview["method"] as? String == (tool == "create_question" ? "POST" : "PUT"))
            #expect(await probe.count() == 0)
            #expect(await probe.cleared() == [])
        } else {
            #expect(await probe.count() == 1)
            #expect(await probe.cleared() == ["questions:chosen"])
        }
    }

    @Test
    func `empty instruction array clears steps and omitted settings stay absent`() async throws {
        let probe = QuestionSettingProbe()
        let provider = try provider(probe: probe) { _, _, _, _, _, _ in
            Issue.record("Dry runs must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let clearing = try await provider.callTool("update_question", arguments: [
            "question": .int(42), "candidate_instructions": .array([]), "dry_run": .bool(true),
        ])
        #expect(clearing.isError != true)
        let preview = try object(clearing)
        #expect(preview["body"] as? NSDictionary == NSDictionary(dictionary: ["candidate_instructions": "[]"]))
        let omitted = try await provider.callTool("create_question", arguments: ["title": .string("Question"), "dry_run": .bool(true)])
        let omittedPreview = try object(omitted)
        #expect(omittedPreview["body"] as? NSDictionary == NSDictionary(dictionary: ["question": ["title": "Question"]]))
    }

    @Test(arguments: ["create_question", "update_question"])
    func `wrong types and nested budgets fail without requests`(tool: String) async throws {
        let probe = QuestionSettingProbe()
        let provider = try provider(probe: probe) { _, _, _, _, _, _ in
            Issue.record("Invalid settings must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let oversized = String(repeating: "a", count: 65537)
        let invalid: [[String: Value]] = [
            ["shared": .string("false")], ["custom_database_id": .bool(true)], ["custom_database_id": .double(1.5)],
            ["custom_database_id": .string("501")], ["ai_assist_custom_system_prompt": .null],
            ["candidate_instructions": .string("[]")], ["candidate_instructions": .array([.string("text")])],
            ["candidate_instructions": .array([.object([:])])],
            ["candidate_instructions": .array([.object(["instructions": .string("read"), "name": .bool(false)])])],
            ["candidate_instructions": .array([.object(["instructions": .string("read"), "default_visible": .string("false")])])],
            ["candidate_instructions": .array([.object(["instructions": .string("read"), "typo": .string("bad")])])],
            ["candidate_instructions": .array([.object(["instructions": .string(oversized)])])],
            ["candidate_instructions": .array(Array(repeating: .object(["instructions": .string("read")]), count: 101))],
            ["candidate_instructions": .array(Array(repeating: .object(["instructions": .string(String(repeating: "a", count: 65536))]),
                                                    count: 9))],
            ["contents": .string(String(repeating: "a", count: 524_288)),
             "ai_assist_custom_system_prompt": .string(String(repeating: "b", count: 524_288))],
        ]
        for var arguments in invalid {
            if tool == "create_question" {
                arguments["title"] = .string("Question")
            } else {
                arguments["question"] = .int(42)
            }
            let result = try await provider.callTool(tool, arguments: arguments)
            #expect(result.isError == true)
        }
        #expect(await probe.count() == 0)
        #expect(await probe.cleared() == [])
    }

    @Test(arguments: [400, 403, 404, 409, 500])
    func `permission and feature errors run once without cache changes`(status: Int) async throws {
        let probe = QuestionSettingProbe()
        let provider = try provider(probe: probe) { _, _, _, _, _, _ in
            await probe.request()
            return APIResponse(status: status, body: #"{"message":"feature unavailable"}"#)
        }
        let result = try await provider.callTool("update_question", arguments: ["question": .int(42), "shared": .bool(false)])
        #expect(result.isError == true)
        #expect(await probe.count() == 1)
        #expect(await probe.cleared() == [])
    }

    private func checkBody(_ raw: [String: Any], creating: Bool) throws {
        var body = raw
        let encoded = try #require(body["candidate_instructions"] as? String)
        let steps = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
        body["candidate_instructions"] = steps
        var expected: [String: Any] = ["shared": false, "custom_database_id": 501, "ai_assist_custom_system_prompt": "",
                                       "candidate_instructions": [["instructions": "Read 世界", "name": "", "default_visible": false],
                                                                  ["instructions": "Then code"]]]
        if creating {
            expected["question"] = ["title": "Question"]
        }
        #expect(NSDictionary(dictionary: body) == NSDictionary(dictionary: expected))
    }

    private func provider(probe: QuestionSettingProbe, request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://chosen.example"))
        let account = try MCPAccount(id: "chosen", name: "Selected", apiKey: "chosen-key", baseURL: url,
                                     screenAPIKey: nil, screenRegion: "us")
        let cache = CoderPadMCPCache(load: { _, _, _ in nil }, invalidate: { await probe.invalidate($0, $1) })
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.id, allowWrites: true),
                                    cache: cache, interviewRequest: request)
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
