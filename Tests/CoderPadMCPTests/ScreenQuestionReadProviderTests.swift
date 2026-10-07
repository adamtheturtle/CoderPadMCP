@testable import CoderPadMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor ScreenQuestionRequestProbe {
    var requests: [URLRequest] = []
    func capture(_ request: URLRequest) {
        requests.append(request)
    }

    func captured() -> [URLRequest] {
        requests
    }
}

@Suite("Screen question reads")
struct ScreenQuestionReadProviderTests {
    private let questionID = "4143ca74-2f0e-4151-90d6-e1428739450b"

    @Test
    func `listing forwards every filter and retains pagination false and zero values`() async throws {
        let probe = ScreenQuestionRequestProbe()
        let provider = try provider()
        let body = #"""
        {"questions":[{"id":"4143ca74-2f0e-4151-90d6-e1428739450b","type":"PROJECT","duration_seconds":0,
        "from_coderpad_question_bank":false}],"pagination":{"start":0,"limit":1,"has_more_items":true,"next_start":1}}
        """#
        let arguments: [String: Value] = [
            "account": .string("Screen"), "start": .int(0), "limit": .int(1), "type": .string("PROJECT"),
            "duration_seconds_min": .int(0), "duration_seconds_max": .int(120), "difficulty": .string("EASY"),
            "domain": .string("a&b+c"), "skill": .string("C#"), "programming_language": .string("C++"),
            "from_coderpad_question_bank": .bool(false), "product": .string("SCREEN"),
            "sort": .string("duration_seconds"), "order": .string("desc"),
        ]
        let result = try await invoke(provider, probe: probe, body: body) {
            try await provider.callTool("screen_list_questions", arguments: arguments)
        }
        #expect(result.isError != true)
        #expect(try text(result) == body)
        let requests = await probe.captured()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://screen.coderpad.io/assessment/api/v1.1/questions"
            + "?start=0&limit=1&type=PROJECT&duration_seconds_min=0&duration_seconds_max=120&difficulty=EASY"
            + "&domain=a%26b%2Bc&skill=C%23&programming_language=C%2B%2B&from_coderpad_question_bank=false"
            + "&product=SCREEN&sort=duration_seconds&order=desc")
        #expect(request.value(forHTTPHeaderField: "API-Key") == "screen-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: ["screen_get_question", "screen_question_insights"])
    func `UUID reads preserve type specific details and empty insight metrics`(tool: String) async throws {
        let provider = try provider()
        let probe = ScreenQuestionRequestProbe()
        let body = tool == "screen_get_question" ? #"""
        {"id":"4143ca74-2f0e-4151-90d6-e1428739450b","type":"PROJECT","project_details":{"ai_assist_allowed":false},
        "evaluation":{"test_report":{"test_cases":[]},"rubric":{"criteria":[{"max_points":0}]}}}
        """# : #"""
        {"usage":{"view_count":0,"average_score":null},"answer_repartition":[],"score_repartition":[],"total_candidates":0}
        """#
        var arguments: [String: Value] = ["account": .string("Screen"), "question": .string(questionID.uppercased())]
        if tool == "screen_question_insights" {
            arguments["programming_language"] = .string("C++")
        }
        let result = try await invoke(provider, probe: probe, body: body) {
            try await provider.callTool(tool, arguments: arguments)
        }
        #expect(result.isError != true)
        #expect(try text(result) == body)
        let requests = await probe.captured()
        #expect(requests.count == 1)
        let suffix = tool == "screen_question_insights" ? "/insights?programming_language=C%2B%2B" : ""
        #expect(requests.first?.url?.absoluteString
            == "https://screen.coderpad.io/assessment/api/v1.1/questions/" + questionID + suffix)
    }

    @Test(arguments: [400, 403, 404])
    func `question read failures preserve HTTP errors and do not fetch extra pages`(status: Int) async throws {
        let provider = try provider()
        let probe = ScreenQuestionRequestProbe()
        let result = try await invoke(provider, probe: probe, body: #"{"message":"denied"}"#, status: status) {
            try await provider.callTool("screen_get_question", arguments: ["account": .string("Screen"), "question": .string(questionID)])
        }
        #expect(result.isError == true)
        #expect(try text(result).contains(String(status)))
        #expect(await probe.captured().count == 1)
    }

    @Test(arguments: [
        ["start": Value.int(-1)], ["start": .int(maxPaginationStart + 1)], ["start": .bool(false)],
        ["limit": .int(0)], ["limit": .int(51)], ["limit": .string("1")], ["limit": .double(1.5)],
        ["duration_seconds_min": .int(-1)], ["duration_seconds_max": .int(Int(Int32.max) + 1)],
        ["duration_seconds_min": .int(2), "duration_seconds_max": .int(1)], ["from_coderpad_question_bank": .string("false")],
        ["type": .bool(true)], ["difficulty": .string("easy")], ["product": .string("UNKNOWN")],
        ["sort": .string("created_at")], ["order": .string("ASC")], ["domain": .string(" ")], ["unknown": .int(1)],
    ])
    func `list schema restrictions are enforced before transport`(fields: [String: Value]) async throws {
        let provider = try provider()
        let probe = ScreenQuestionRequestProbe()
        let result = try await invoke(provider, probe: probe, body: "{}") {
            try await provider.callTool("screen_list_questions", arguments: ["account": Value.string("Screen")].merging(fields) { _, new in new })
        }
        #expect(result.isError == true)
        #expect(await probe.captured() == [])
    }

    @Test(arguments: [Value.int(42), .string("../question"), .string("not-a-uuid"), .null])
    func `UUID identity is validated before transport`(id: Value) async throws {
        let provider = try provider()
        let probe = ScreenQuestionRequestProbe()
        let result = try await invoke(provider, probe: probe, body: "{}") {
            try await provider.callTool("screen_get_question", arguments: ["account": .string("Screen"), "question": id])
        }
        #expect(result.isError == true)
        #expect(await probe.captured() == [])
    }

    @Test
    func `screen tools require an account selector when only another account has credentials`() async throws {
        let provider = try provider()
        let tools = await provider.tools()
        for name in ["screen_list_questions", "screen_get_question", "screen_question_insights"] {
            let tool = try #require(tools.first { $0.name == name })
            guard case let .object(schema) = tool.inputSchema else { throw CocoaError(.coderReadCorrupt) }
            #expect(schema["required"] == .array(name == "screen_list_questions"
                    ? [.string("account")] : [.string("question"), .string("account")]))
            #expect(try await provider.callTool(name, arguments: nil).isError == true)
        }
        let names = availableTools(screenEnabled: false, writesEnabled: false).map(\.name)
        #expect(names.contains("screen_list_questions") == false)
        #expect(names.contains("screen_get_question") == false)
        #expect(names.contains("screen_question_insights") == false)
    }

    @Test
    func `empty pages and integral JSON numbers retain normal list behavior`() async throws {
        let provider = try provider()
        let probe = ScreenQuestionRequestProbe()
        let body = #"{"questions":[],"pagination":{"has_more_items":false}}"#
        let result = try await invoke(provider, probe: probe, body: body) {
            try await provider.callTool("screen_list_questions", arguments: ["account": .string("Screen"), "limit": .double(50)])
        }
        #expect(result.isError != true)
        #expect(try text(result) == body)
        #expect(await probe.captured().first?.url?.query == "limit=50")
    }

    private func provider() throws -> CoderPadProvider {
        let base = try #require(URL(string: "https://app.coderpad.io"))
        let interview = try MCPAccount(name: "Interview", apiKey: "interview-key", baseURL: base,
                                       screenAPIKey: nil, screenRegion: "us")
        let screen = try MCPAccount(name: "Screen", apiKey: "other-interview-key", baseURL: base,
                                    screenAPIKey: "screen-key", screenRegion: "us")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [interview, screen], defaultName: "Interview", allowWrites: false))
    }

    private func invoke(
        _: CoderPadProvider,
        probe: ScreenQuestionRequestProbe,
        body: String,
        status: Int = 200,
        operation: () async throws -> CallTool.Result,
    ) async throws -> CallTool.Result {
        let data = Data(body.utf8)
        let responseRequest: ScreenResponseRequest = { request, limit in
            await probe.capture(request)
            #expect(limit == 8 * 1024 * 1024)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        return try await ProviderRequestContext.$screenResponse.withValue(responseRequest, operation: operation)
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return text
    }
}
