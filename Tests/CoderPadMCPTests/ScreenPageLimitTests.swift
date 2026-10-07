@testable import CoderPadMCP
import Foundation
import MCP
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("Screen session page limit")
struct ScreenPageLimitTests {
    @Test(arguments: [1, 50])
    func `valid boundary limits reach Screen unchanged`(limit: Int) async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { request, responseLimit in
            #expect(request.url?.absoluteString == "https://screen.coderpad.io/assessment/api/v1.1/tests?limit=\(limit)")
            #expect(responseLimit == 8 * 1024 * 1024)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("[]".utf8), response)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_list_tests", arguments: ["limit": .int(limit)])
        }
        #expect(result.isError != true)
    }

    @Test
    func `limit above fifty fails before network access`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, _ in
            Issue.record("Unsupported limits must not make requests")
            throw CancellationError()
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_list_tests", arguments: ["limit": .int(51)])
        }
        #expect(result.isError == true)
        guard case let .text(message, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        #expect(message == "limit must be 50 or less.")
    }

    private func provider() throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://configured.example"))
        let account = try MCPAccount(name: "Pages", apiKey: "key", baseURL: url, screenAPIKey: "screen-key", screenRegion: "us")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false))
    }
}
