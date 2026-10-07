@testable import CoderPadMCP
import Foundation
import MCP
import Testing

private actor CursorRequestProbe {
    var queries: [[URLQueryItem]] = []

    func capture(_ query: [URLQueryItem]) -> Int {
        queries.append(query)
        return queries.count
    }

    func captured() -> [[URLQueryItem]] {
        queries
    }
}

@Suite("Cursor paging provider")
struct CursorPagingProviderTests {
    @Test(arguments: ["count_pads", "aggregate_pads"])
    func `cursor chains preserve configured account and complete filtered results`(tool: String) async throws {
        let probe = CursorRequestProbe()
        let provider = try provider { method, path, account, query, body, limit in
            #expect(method == "GET")
            #expect(path == "/api/pads/")
            #expect(account.baseURL.absoluteString == "https://configured.example")
            #expect(account.apiKey == "account-key")
            #expect(body == nil)
            #expect(limit == 8 * 1024 * 1024)
            let count = await probe.capture(query)
            return APIResponse(status: 200, body: count == 1
                ? #"{"pads":[{"id":"a","language":"python"}],"next_page":"https://other.example/api/pads?cursor=a%26b%2Bc%3D","total":2}"#
                : #"{"pads":[{"id":"b","language":"python"}],"total":2}"#)
        }
        var arguments: [String: Value] = ["language": .string("python")]
        if tool == "aggregate_pads" {
            arguments["group_by"] = .string("language")
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError != true)
        let object = try object(result)
        #expect(object["scanned"] as? Int == 2)
        #expect(object["matched"] as? Int == 2)
        #expect(object["pages_fetched"] as? Int == 2)
        #expect(object["truncated"] as? Bool == false)
        #expect(await probe.captured() == [[], [URLQueryItem(name: "cursor", value: "a&b+c=")]])
    }

    @Test
    func `page and cursor chains can reuse values while same-key cycles fail`() async throws {
        let probe = CursorRequestProbe()
        let provider = try provider { _, _, _, query, _, _ in
            let count = await probe.capture(query)
            let token = count == 1 ? "?page=same" : "?cursor=same"
            return APIResponse(status: 200, body: "{\"pads\":[{\"id\":\"\(count)\"}],\"next_page\":\"\(token)\"}")
        }
        let result = try await provider.callTool("count_pads", arguments: ["language": .string("python")])
        #expect(result.isError == true)
        #expect(await probe.captured() == [[], [URLQueryItem(name: "page", value: "same")],
                                           [URLQueryItem(name: "cursor", value: "same")]])
        #expect(try text(result).contains("repeated next_page"))
    }

    @Test
    func `numeric page continuation remains compatible and errors stop cursor scans`() async throws {
        let probe = CursorRequestProbe()
        let provider = try provider { _, _, _, query, _, _ in
            let count = await probe.capture(query)
            if count == 1 {
                return APIResponse(status: 200, body: #"{"pads":[{"id":"a"}],"next_page":2}"#)
            }
            if count == 2 {
                return APIResponse(status: 200, body: #"{"pads":[{"id":"b"}],"next_page":"?cursor=last"}"#)
            }
            return APIResponse(status: 403, body: #"{"message":"denied"}"#)
        }
        let result = try await provider.callTool("count_pads", arguments: ["language": .string("python")])
        #expect(result.isError == true)
        #expect(await probe.captured() == [[], [URLQueryItem(name: "page", value: "2")],
                                           [URLQueryItem(name: "cursor", value: "last")]])
        #expect(try text(result).contains("403"))
    }

    private func provider(request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let account = try MCPAccount(name: "Configured", apiKey: "account-key",
                                     baseURL: #require(URL(string: "https://configured.example")),
                                     screenAPIKey: nil, screenRegion: "us")
        return try CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            interviewRequest: request,
        )
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else {
            throw CocoaError(.coderReadCorrupt)
        }
        return text
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
    }
}
