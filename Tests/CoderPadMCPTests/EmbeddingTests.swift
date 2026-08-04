@testable import CoderPadMCP
import Foundation
import Testing

@Suite("Embedding")
struct EmbeddingTests {
    private func account(id: String, allowWrites: Bool) -> MCPAccount {
        MCPAccount(
            id: id,
            name: id.capitalized,
            userEmail: "\(id)@example.com",
            apiKey: "secret",
            baseURL: URL(string: "https://app.coderpad.io")!,
            screenAPIKey: nil,
            screenRegion: "us",
            allowWrites: allowWrites,
        )
    }

    @Test
    func `write authorization combines the host and account switches`() {
        let allowed = account(id: "allowed", allowWrites: true)
        let denied = account(id: "denied", allowWrites: false)
        let enabled = MCPAccountSet(
            accounts: [allowed, denied],
            defaultName: allowed.name,
            allowWrites: true,
        )

        #expect(enabled.anyWritesEnabled)
        #expect(enabled.allowsWrites(to: allowed))
        #expect(!enabled.allowsWrites(to: denied))

        let disabled = MCPAccountSet(
            accounts: [allowed],
            defaultName: allowed.name,
            allowWrites: false,
        )
        #expect(!disabled.anyWritesEnabled)
        #expect(!disabled.allowsWrites(to: allowed))
    }

    @Test
    func `directory exposes host identity without credentials`() throws {
        let value = try #require(
            MCPAccountSet(
                accounts: [account(id: "acme", allowWrites: true)],
                defaultName: "Acme",
                allowWrites: true,
            ).directory().first,
        )

        #expect(value["id"] as? String == "acme")
        #expect(value["user_email"] as? String == "acme@example.com")
        #expect(value["writes_enabled"] as? Bool == true)
        #expect(value["api_key"] == nil)
    }

    @Test
    func `stable ids resolve duplicate display names and select the default`() throws {
        let first = try MCPAccount(
            id: "first",
            name: "Acme",
            apiKey: "one",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
        )
        let second = try MCPAccount(
            id: "second",
            name: "Acme",
            apiKey: "two",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
        )
        let set = MCPAccountSet(
            accounts: [first, second],
            defaultName: second.id,
            allowWrites: false,
        )

        #expect(set.defaultAccount?.id == second.id)
        #expect(set.resolve(first.id)?.id == first.id)
        #expect(set.resolve("Acme") == nil)
        let defaults = set.directory().filter { $0["is_default"] as? Bool == true }
        #expect(defaults.count == 1)
        #expect(defaults.first?["id"] as? String == second.id)
    }

    @Test
    func `public accounts normalize the Screen region before routing`() throws {
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: "screen-secret",
            screenRegion: "  EU\n",
        )

        #expect(account.screenRegion == "eu")
        #expect(account.screenBaseURL.absoluteString == "https://www.codingame.eu")
    }

    @Test
    func `cache hooks preserve opaque encoded records`() async {
        let expected = Data(#"[{"id":"pad-1"}]"#.utf8)
        let cache = CoderPadMCPCache(
            load: { kind, accountID, requireFresh in
                #expect(kind == .pads)
                #expect(accountID == "acme")
                #expect(requireFresh)
                return expected
            },
            invalidate: { _, _ in },
        )

        #expect(cache.load(.pads, "acme", true) == expected)
        await cache.invalidate(.pads, "acme")
    }
}
