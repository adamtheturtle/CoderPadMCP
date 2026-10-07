@testable import CoderPadMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor AIConversationRequestProbe {
    var requests: [URLRequest] = []
    func capture(_ request: URLRequest) {
        requests.append(request)
    }

    func captured() -> [URLRequest] {
        requests
    }
}

@Suite("Screen AI conversation tool")
struct ScreenAIConversationProviderTests {
    private let questionID = "4143ca74-2f0e-4151-90d6-e1428739450b"

    @Test(arguments: [false, true])
    func `conversations preserve order and evolving structured outputs including empty arrays`(empty: Bool) async throws {
        let payload = empty ? "[]" : #"""
        [{"id":"first","subject":null,"creation_time":"2026-01-01T00:00:00Z","messages":[
        {"role":"USER","content":"Explain","creation_time":"2026-01-01T00:00:01Z"},
        {"role":"ASSISTANT","content":"Answer","output_items":[{"type":"future_tool","result":{"ok":false,"count":0}},
        {"type":"reasoning","summary":[]}]}]},
        {"id":"second","subject":"Follow up","messages":[]}]
        """#
        let provider = try provider()
        let probe = AIConversationRequestProbe()
        let loader = responseLoader(probe, payload: payload)
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_ai_assist_conversations", arguments: [
                "test": .int(42), "question": .string(questionID.uppercased()),
            ])
        }
        #expect(result.isError != true)
        #expect(try text(result) == payload)
        let requests = await probe.captured()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString
            == "https://www.codingame.eu/assessment/api/v1.1/tests/42/questions/" + questionID + "/ai-assist-conversations")
        #expect(request.value(forHTTPHeaderField: "API-Key") == "screen-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
    }

    @Test(arguments: [404, 409])
    func `missing projects and unfinished tests retain their HTTP error`(status: Int) async throws {
        let provider = try provider()
        let probe = AIConversationRequestProbe()
        let loader = responseLoader(probe, payload: #"{"message":"not available"}"#, status: status)
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_ai_assist_conversations", arguments: ["test": .int(42), "question": .string(questionID)])
        }
        #expect(result.isError == true)
        #expect(try text(result).contains(String(status)))
        #expect(await probe.captured().count == 1)
    }

    @Test
    func `oversized conversation output is an explicit failure without a partial success`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, limit in
            #expect(limit == 8 * 1024 * 1024)
            throw BoundedHTTPResponseError(limit: limit)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_ai_assist_conversations", arguments: ["test": .int(42), "question": .string(questionID)])
        }
        #expect(result.isError == true)
        #expect(try text(result) == "Transport failure: response_too_large")
    }

    @Test(arguments: [
        ["test": Value.int(0)], ["test": .int(Int(Int32.max) + 1)], ["test": .double(1.5)], ["test": .bool(false)], ["test": .string("42")],
        ["question": .int(42)], ["question": .string("../project")], ["question": .null], ["unknown": .bool(true)],
    ])
    func `invalid arguments fail before transport`(fields: [String: Value]) async throws {
        let provider = try provider()
        let probe = AIConversationRequestProbe()
        let arguments = ["test": Value.int(42), "question": .string(questionID)].merging(fields) { _, new in new }
        let loader = responseLoader(probe, payload: "[]")
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_ai_assist_conversations", arguments: arguments)
        }
        #expect(result.isError == true)
        #expect(await probe.captured() == [])
    }

    @Test
    func `catalog hides conversations without Screen and marks the tool read only`() throws {
        let hidden = availableTools(screenEnabled: false, writesEnabled: false).map(\.name)
        #expect(hidden.contains("screen_ai_assist_conversations") == false)
        let tool = try #require(availableTools(screenEnabled: true, writesEnabled: false)
            .first { $0.name == "screen_ai_assist_conversations" })
        #expect(tool.annotations.readOnlyHint == true)
        #expect(tool.annotations.destructiveHint == false)
        guard case let .object(schema) = tool.inputSchema else { throw CocoaError(.coderReadCorrupt) }
        #expect(schema["required"] == .array([.string("test"), .string("question")]))
    }

    private func provider() throws -> CoderPadProvider {
        let account = try MCPAccount(name: "Selected", apiKey: "interview-key",
                                     baseURL: #require(URL(string: "https://app.coderpad.io")),
                                     screenAPIKey: "screen-key", screenRegion: "eu")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false))
    }

    private func responseLoader(_ probe: AIConversationRequestProbe, payload: String, status: Int = 200) -> ScreenResponseRequest {
        let data = Data(payload.utf8)
        return { request, limit in
            await probe.capture(request)
            #expect(limit == 8 * 1024 * 1024)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return text
    }
}
