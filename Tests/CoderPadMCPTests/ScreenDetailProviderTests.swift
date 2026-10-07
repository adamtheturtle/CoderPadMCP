@testable import CoderPadMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor ScreenDetailRequestProbe {
    var requests: [URLRequest] = []
    func capture(_ request: URLRequest) {
        requests.append(request)
    }

    func captured() -> [URLRequest] {
        requests
    }
}

@Suite("Screen JSON details")
struct ScreenDetailProviderTests {
    private let complete = #"""
    {
      "id": 42,
      "timer_type": "PER_QUESTION",
      "report": {
        "score": 0,
        "marked_as_cheated_by_recruiter": false,
        "community_stats": [
          0,
          1
        ]
      },
      "questions": [
        {
          "id": "4143ca74-2f0e-4151-90d6-e1428739450b",
          "grading_status": "PENDING_MANUAL_REVIEW",
          "awarded_points": null,
          "answer": {
            "project_answer": {
              "download_url": "/assessment/api/v1.1/tests/42/questions/4143ca74-2f0e-4151-90d6-e1428739450b/project",
              "ai_assist_conversation_count": 0
            }
          }
        }
      ]
    }
    """#

    @Test(arguments: [0, 1, 2])
    func `one JSON request retains detailed results and exact optional community flag`(option: Int) async throws {
        let probe = ScreenDetailRequestProbe()
        let provider = try provider()
        var arguments: [String: Value] = ["test": .int(42), "account": .string("Europe")]
        if option != 0 {
            arguments["withCommunityStats"] = .bool(option == 1)
        }
        let data = Data(complete.utf8)
        let responseRequest: ScreenResponseRequest = { request, limit in
            await probe.capture(request)
            #expect(limit == 8 * 1024 * 1024)
            // The PDF export has a different endpoint. Any extra request fails this check.
            #expect(request.url?.path == "/assessment/api/v1.1/tests/42")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (data, response)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(responseRequest) {
            try await provider.callTool("screen_get_test", arguments: arguments)
        }
        #expect(result.isError != true)
        #expect(try text(result) == complete)
        let requests = await probe.captured()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let suffix = option == 0 ? "" : "?withCommunityStats=\(option == 1 ? "true" : "false")"
        #expect(request.url?.absoluteString == "https://www.codingame.eu/assessment/api/v1.1/tests/42" + suffix)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "API-Key") == "europe-screen-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
    }

    @Test
    func `permission limited details do not synthesize report errors`() async throws {
        let provider = try provider()
        let data = Data(#"{"id":42,"status":"completed","report":{"score":80}}"#.utf8)
        let probe = ScreenDetailRequestProbe()
        let responseRequest: ScreenResponseRequest = { request, _ in
            await probe.capture(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                        httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(responseRequest) {
            try await provider.callTool("screen_get_test", arguments: ["test": .int(42)])
        }
        #expect(result.isError != true)
        #expect(try text(result) == String(decoding: data, as: UTF8.self))
        #expect(await probe.captured().count == 1)
        #expect(await probe.captured().first?.value(forHTTPHeaderField: "API-Key") == "us-screen-key")
    }

    @Test(arguments: [400, 403, 404])
    func `detail failure retains HTTP errors without a PDF request`(status: Int) async throws {
        let provider = try provider()
        let probe = ScreenDetailRequestProbe()
        let responseRequest: ScreenResponseRequest = { request, _ in
            await probe.capture(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status,
                                                        httpVersion: nil, headerFields: nil))
            return (Data(#"{"code":"FeatureNotAvailable"}"#.utf8), response)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(responseRequest) {
            try await provider.callTool("screen_get_test", arguments: ["test": .int(42)])
        }
        #expect(result.isError == true)
        #expect(try text(result).contains(String(status)))
        #expect(await probe.captured().count == 1)
    }

    @Test(arguments: [Value.string("true"), .int(1), .null, .array([]), .object([:])])
    func `community statistics require a Boolean before transport`(value: Value) async throws {
        let provider = try provider()
        let responseRequest: ScreenResponseRequest = { _, _ in
            Issue.record("Invalid argument reached transport")
            throw URLError(.badURL)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(responseRequest) {
            try await provider.callTool("screen_get_test", arguments: ["test": .int(42), "withCommunityStats": value])
        }
        #expect(result.isError == true)
        #expect(try text(result) == "withCommunityStats must be a boolean.")
    }

    @Test
    func `tool schema includes community option only with Screen tools enabled`() throws {
        let tools = availableTools(screenEnabled: true, writesEnabled: false)
        let tool = try #require(tools.first { $0.name == "screen_get_test" })
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(flag)? = properties["withCommunityStats"]
        else {
            Issue.record("Missing Boolean schema")
            return
        }
        #expect(flag["type"] == .string("boolean"))
        #expect(schema["required"] == .array([.string("test")]))
        #expect(availableTools(screenEnabled: false, writesEnabled: false).contains { $0.name == "screen_get_test" } == false)
    }

    private func provider() throws -> CoderPadProvider {
        let base = try #require(URL(string: "https://app.coderpad.io"))
        let us = try MCPAccount(name: "US", apiKey: "interview-key", baseURL: base,
                                screenAPIKey: "us-screen-key", screenRegion: "us")
        let eu = try MCPAccount(name: "Europe", apiKey: "europe-interview-key", baseURL: base,
                                screenAPIKey: "europe-screen-key", screenRegion: "eu")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [us, eu], defaultName: "US", allowWrites: false))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return text
    }
}
