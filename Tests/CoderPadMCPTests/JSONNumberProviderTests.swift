@testable import CoderPadMCP
import Foundation
import MCP
import Testing

@Suite("Parsed JSON provider totals")
struct JSONNumberProviderTests {
    @Test(arguments: ["count_questions", "list_questions_compact", "count_pads", "list_pads_compact"])
    func `single-record JSON results retain id and total one`(tool: String) async throws {
        let url = try #require(URL(string: "https://configured.example"))
        let account = try MCPAccount(name: "Numbers", apiKey: "key", baseURL: url, screenAPIKey: nil, screenRegion: "us")
        let provider = try CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            interviewRequest: { _, path, _, _, _, _ in
                let records = path == "/api/questions/" ? "questions" : "pads"
                return APIResponse(status: 200, body: "{\"\(records)\":[{\"id\":1}],\"total\":1}")
            },
        )
        let result = try await provider.callTool(tool, arguments: nil)
        #expect(result.isError != true)
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if tool.hasPrefix("count_") {
            #expect(object["matched"] as? Int == 1)
            #expect(object["pages_fetched"] as? Int == 1)
        } else {
            #expect(object["count"] as? Int == 1)
            #expect(object["total"] as? Int == 1)
            let key = tool == "list_questions_compact" ? "questions" : "pads"
            let records = try #require(object[key] as? [[String: Any]])
            #expect(records.first?["id"] as? Int == 1)
        }
    }

    @Test
    func `zero total completes an empty count in one request`() async throws {
        let url = try #require(URL(string: "https://configured.example"))
        let account = try MCPAccount(name: "Numbers", apiKey: "key", baseURL: url, screenAPIKey: nil, screenRegion: "us")
        let provider = try CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            interviewRequest: { _, _, _, _, _, _ in APIResponse(status: 200, body: #"{"questions":[],"total":0}"#) },
        )
        let result = try await provider.callTool("count_questions", arguments: nil)
        #expect(result.isError != true)
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["matched"] as? Int == 0)
        #expect(object["pages_fetched"] as? Int == 1)
    }
}
