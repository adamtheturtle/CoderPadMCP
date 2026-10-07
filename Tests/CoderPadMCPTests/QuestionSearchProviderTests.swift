@testable import CoderPadMCP
import Foundation
import MCP
import Testing

private actor QuestionSearchProbe {
    private var queries: [[URLQueryItem]] = []
    func capture(_ query: [URLQueryItem]) -> Int {
        queries.append(query)
        return queries.count
    }

    func captured() -> [[URLQueryItem]] {
        queries
    }
}

@Suite("Question search")
struct QuestionSearchProviderTests {
    @Test(arguments: ["list_questions", "list_questions_compact"])
    func `search sends repeated categories and question-specific sorting`(tool: String) async throws {
        let probe = QuestionSearchProbe()
        let provider = try provider { method, path, account, query, body, _ in
            #expect(method == "GET")
            #expect(path == "/api/questions/")
            #expect(account.apiKey == "search-key")
            #expect(body == nil)
            _ = await probe.capture(query)
            return APIResponse(status: 200, body: #"{"questions":[{"id":12,"title":"C++"},{"id":12,"title":"duplicate"}],"total":2,"next_page":2}"#)
        }
        let result = try await provider.callTool(tool, arguments: [
            "text": .string("C++ / & ="), "pad_types": .array([.string("live"), .string("take_home"), .string("live")]),
            "sort": .string("title,asc"), "page": .int(2),
        ])
        #expect(result.isError != true)
        #expect(await probe.captured() == [[
            URLQueryItem(name: "page", value: "2"), URLQueryItem(name: "sort", value: "title,asc"),
            URLQueryItem(name: "text", value: "C++ / & ="), URLQueryItem(name: "pad_types[]", value: "live"),
            URLQueryItem(name: "pad_types[]", value: "take_home"), URLQueryItem(name: "pad_types[]", value: "live"),
        ]])
        if tool == "list_questions_compact" {
            let object = try object(result)
            #expect(object["count"] as? Int == 1)
            #expect(object["total"] as? Int == 2)
            #expect(object["next_page"] as? Int == 2)
        }
    }

    @Test
    func `omitted and empty search inputs keep their wire distinctions`() async throws {
        let probe = QuestionSearchProbe()
        let provider = try provider { _, _, _, query, _, _ in
            _ = await probe.capture(query)
            return APIResponse(status: 200, body: #"{"questions":[]}"#)
        }
        let omitted = try await provider.callTool("list_questions", arguments: nil)
        let empty = try await provider.callTool("list_questions", arguments: ["text": .string(""), "pad_types": .array([])])
        let used = try await provider.callTool("list_questions", arguments: ["sort": .string("-used")])
        #expect(omitted.isError != true)
        #expect(empty.isError != true)
        #expect(used.isError != true)
        #expect(await probe.captured() == [[], [URLQueryItem(name: "text", value: "")],
                                           [URLQueryItem(name: "sort", value: "used,desc")]])
    }

    @Test(arguments: ["count_questions", "aggregate_questions"])
    func `server filters survive cursor scans and bypass unfiltered caches`(tool: String) async throws {
        let probe = QuestionSearchProbe()
        let cache = CoderPadMCPCache(load: { _, _, _ in
            Data(#"[{"id":999,"language":"cached"}]"#.utf8)
        }, invalidate: { _, _ in Issue.record("Read tools must not invalidate caches") })
        let provider = try provider(cache: cache) { _, _, _, query, _, _ in
            let count = await probe.capture(query)
            return APIResponse(status: 200, body: count == 1
                ? #"{"questions":[{"id":12,"language":"swift"}],"next_page":"?cursor=a%2Bb%26c%3D","total":2}"#
                : #"{"questions":[{"id":12,"language":"swift"},{"id":13,"language":"swift"}],"total":2}"#)
        }
        var arguments: [String: Value] = ["text": .string("C++"), "pad_types": .array([.string("any"), .string("live")])]
        if tool == "aggregate_questions" {
            arguments["group_by"] = .string("language")
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError != true)
        let object = try object(result)
        #expect(object["matched"] as? Int == 2)
        #expect(object["scanned"] as? Int == 2)
        #expect(object["pages_fetched"] as? Int == 2)
        #expect(object["truncated"] as? Bool == false)
        let filters = try #require(object["filters"] as? [String: Any])
        #expect(filters["text"] as? String == "C++")
        #expect(filters["pad_types"] as? [String] == ["any", "live"])
        let search = [URLQueryItem(name: "text", value: "C++"), URLQueryItem(name: "pad_types[]", value: "any"),
                      URLQueryItem(name: "pad_types[]", value: "live")]
        #expect(await probe.captured() == [search, search + [URLQueryItem(name: "cursor", value: "a+b&c=")]])
        if tool == "aggregate_questions" {
            let groups = try #require(object["groups"] as? [[String: Any]])
            #expect(groups.count == 1)
            #expect(groups.first?["value"] as? String == "swift")
            #expect(groups.first?["count"] as? Int == 2)
        }
    }

    @Test(arguments: ["list_questions", "list_questions_compact", "count_questions", "aggregate_questions"])
    func `invalid searches fail before network access`(tool: String) async throws {
        let provider = try provider { _, _, _, _, _, _ in
            Issue.record("Invalid searches must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let invalid: [[String: Value]] = [
            ["text": .bool(false)], ["text": .string(String(repeating: "é", count: 2049))],
            ["pad_types": .string("live")], ["pad_types": .array([.bool(true)])],
            ["pad_types": .array([.string("unknown")])],
            ["pad_types": .array(Array(repeating: .string("live"), count: 101))], ["typo": .string("value")],
        ]
        for var arguments in invalid {
            if tool == "aggregate_questions" {
                arguments["group_by"] = .string("language")
            }
            let result = try await provider.callTool(tool, arguments: arguments)
            #expect(result.isError == true)
        }
        let pads = try await provider.callTool("list_pads", arguments: ["sort": .string("title")])
        #expect(pads.isError == true)
    }

    @Test(arguments: ["list_questions", "list_questions_compact", "count_questions", "aggregate_questions"])
    func `search HTTP failures remain errors`(tool: String) async throws {
        let provider = try provider { _, _, _, _, _, _ in APIResponse(status: 403, body: #"{"message":"denied"}"#) }
        var arguments: [String: Value] = ["text": .string("search")]
        if tool == "aggregate_questions" {
            arguments["group_by"] = .string("language")
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError == true)
    }

    private func provider(cache: CoderPadMCPCache? = nil, request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://configured.example"))
        let account = try MCPAccount(name: "Search", apiKey: "search-key", baseURL: url,
                                     screenAPIKey: nil, screenRegion: "us")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
                                    cache: cache, interviewRequest: request)
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
