@testable import CoderPadMCP
import Foundation
import Testing

@Suite("Embedding")
struct EmbeddingTests {
    private func account(id: String, allowWrites: Bool) throws -> MCPAccount {
        try MCPAccount(
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
    func `write authorization combines the host and account switches`() throws {
        let allowed = try account(id: "allowed", allowWrites: true)
        let denied = try account(id: "denied", allowWrites: false)
        let enabled = try MCPAccountSet(
            accounts: [allowed, denied],
            defaultName: allowed.name,
            allowWrites: true,
        )

        #expect(enabled.anyWritesEnabled)
        #expect(enabled.allowsWrites(to: allowed))
        #expect(!enabled.allowsWrites(to: denied))

        let disabled = try MCPAccountSet(
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
            try MCPAccountSet(
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
        let set = try MCPAccountSet(
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
    func `public account construction rejects invalid model fields`() throws {
        let https = try #require(URL(string: "https://app.coderpad.io"))
        let http = try #require(URL(string: "http://app.coderpad.io"))

        #expect(throws: MCPConfigError.missingAPIKey(account: "Acme")) {
            try MCPAccount(name: "Acme", apiKey: "  ", baseURL: https,
                           screenAPIKey: nil, screenRegion: "us")
        }
        #expect(throws: MCPConfigError.invalidBaseURL(
            account: "Acme", baseURL: "http://app.coderpad.io",
        )) {
            try MCPAccount(name: "Acme", apiKey: "key", baseURL: http,
                           screenAPIKey: nil, screenRegion: "us")
        }
        #expect(throws: MCPConfigError.invalidScreenRegion(account: "Acme", region: "europe")) {
            try MCPAccount(name: "Acme", apiKey: "key", baseURL: https,
                           screenAPIKey: nil, screenRegion: "europe")
        }
        #expect(throws: MCPConfigError.invalidCredential(account: "Acme", field: "user_email")) {
            try MCPAccount(name: "Acme", userEmail: "user\u{202E}@example.com", apiKey: "key",
                           baseURL: https, screenAPIKey: nil, screenRegion: "us")
        }
    }

    @Test
    func `multi-account static resources use stable ids`() throws {
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
        let set = try MCPAccountSet(
            accounts: [first, second],
            defaultName: first.id,
            allowWrites: false,
        )
        let uris = staticResources(for: set).map(\.uri)
        #expect(uris.contains("coderpad://account/first/quota"))
        #expect(uris.contains("coderpad://account/second/organization"))
        #expect(!uris.contains("coderpad://account/Acme/quota"))
        #expect(Set(uris).count == uris.count)
    }

    @Test
    func `duplicate account ids and id-name collisions are rejected`() throws {
        let https = try #require(URL(string: "https://app.coderpad.io"))
        let first = try MCPAccount(id: "shared", name: "Acme", apiKey: "a", baseURL: https,
                                   screenAPIKey: nil, screenRegion: "us")
        let duplicateID = try MCPAccount(id: "shared", name: "Beta", apiKey: "b", baseURL: https,
                                         screenAPIKey: nil, screenRegion: "us")
        #expect(throws: MCPConfigError.duplicateID("shared")) {
            try MCPAccountSet(accounts: [first, duplicateID], defaultName: "shared", allowWrites: false)
        }

        let hijacker = try MCPAccount(id: "Beta", name: "Acme", apiKey: "a", baseURL: https,
                                      screenAPIKey: nil, screenRegion: "us")
        let victim = try MCPAccount(id: "other", name: "Beta", apiKey: "b", baseURL: https,
                                    screenAPIKey: nil, screenRegion: "us")
        #expect(throws: MCPConfigError.selectorCollision(id: "Beta", name: "Beta")) {
            try MCPAccountSet(accounts: [hijacker, victim], defaultName: "other", allowWrites: false)
        }
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
