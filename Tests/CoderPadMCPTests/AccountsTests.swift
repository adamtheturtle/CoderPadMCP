//
//  AccountsTests.swift
//  CoderPadMCPTests
//
//  The multi-account configuration parsing (#521): env fallback, JSON config, name
//  resolution, and the list_accounts directory. Pure, no filesystem.
//

@testable import CoderPadMCP
import Foundation
import Testing

@Suite("Account configuration")
struct AccountsTests {
    @Test
    func `env fallback builds one default account and requires the key`() throws {
        let set = try makeAccountSet(config: nil, environment: [
            "CODERPAD_API_KEY": "k1",
            "CODERPAD_BASE_URL": "https://coderpad.acme.internal",
        ])
        #expect(set.accounts.count == 1)
        let defaultAccount = try #require(set.defaultAccount)
        #expect(defaultAccount.name == "default")
        #expect(defaultAccount.apiKey == "k1")
        #expect(defaultAccount.baseURL.absoluteString == "https://coderpad.acme.internal")
        #expect(!set.allowWrites)

        #expect(throws: MCPConfigError.noAccounts) {
            try makeAccountSet(config: nil, environment: [:])
        }
    }

    @Test
    func `present malformed accounts never fall back to environment`() {
        let environment = ["CODERPAD_API_KEY": "environment-key"]
        for config: [String: Any] in [
            [:],
            ["accounts": []],
            ["accounts": "not-an-array"],
            ["accounts": ["not-an-object"]],
        ] {
            #expect(throws: MCPConfigError.noAccounts) {
                try makeAccountSet(config: config, environment: environment)
            }
        }
    }

    @Test
    func `present account names must be nonempty strings`() {
        for name: Any in [123, "", " \n"] {
            #expect(throws: MCPConfigError.invalidCredential(account: "account-1", field: "name")) {
                try makeAccountSet(config: [
                    "accounts": [["name": name, "api_key": "key"]],
                ], environment: [:])
            }
        }
    }

    @Test
    func `present Screen API keys must be strings`() {
        #expect(throws: MCPConfigError.invalidCredential(account: "Acme", field: "screen_api_key")) {
            try makeAccountSet(config: [
                "accounts": [["name": "Acme", "api_key": "key", "screen_api_key": 123]],
            ], environment: [:])
        }
    }

    @Test
    func `present Screen regions must be strings`() {
        #expect(throws: MCPConfigError.invalidScreenRegion(account: "Acme", region: "123")) {
            try makeAccountSet(config: [
                "accounts": [["name": "Acme", "api_key": "key", "screen_region": 123]],
            ], environment: [:])
        }
    }

    @Test
    func `env base URL rejects non-HTTP and hostless values`() {
        #expect(throws: MCPConfigError.invalidBaseURL(account: "default", baseURL: "mailto:user@example.com")) {
            try makeAccountSet(config: nil, environment: [
                "CODERPAD_API_KEY": "k1",
                "CODERPAD_BASE_URL": "mailto:user@example.com",
            ])
        }

        #expect(throws: MCPConfigError.invalidBaseURL(account: "default", baseURL: "https:///missing-host")) {
            try makeAccountSet(config: nil, environment: [
                "CODERPAD_API_KEY": "k1",
                "CODERPAD_BASE_URL": "https:///missing-host",
            ])
        }
    }

    @Test
    func `env writes flag and screen key carry through`() throws {
        let set = try makeAccountSet(config: nil, environment: [
            "CODERPAD_API_KEY": "k1",
            "CODERPAD_MCP_ALLOW_WRITES": "yes",
            "CODERPAD_SCREEN_API_KEY": "s1",
            "CODERPAD_SCREEN_REGION": "EU",
        ])
        #expect(set.allowWrites)
        #expect(set.anyScreenEnabled)
        #expect(try #require(set.defaultAccount).screenBaseURL.absoluteString == "https://www.codingame.eu")
    }

    @Test
    func `env screen region rejects unknown non-empty values`() {
        #expect(throws: MCPConfigError.invalidScreenRegion(account: "default", region: "europe")) {
            try makeAccountSet(config: nil, environment: [
                "CODERPAD_API_KEY": "k1",
                "CODERPAD_SCREEN_REGION": "europe",
            ])
        }
    }

    @Test
    func `config accounts parse, pick the marked default, and OR the write flag`() throws {
        let config: [String: Any] = [
            "accounts": [
                ["name": "Acme", "api_key": "a", "base_url": "https://app.coderpad.io"],
                ["name": "Beta", "api_key": "b", "screen_api_key": "sb", "default": true],
            ],
            "allow_writes": true,
        ]
        let set = try makeAccountSet(config: config, environment: [:])
        #expect(set.accounts.count == 2)
        #expect(try #require(set.defaultAccount).name == "Beta")
        #expect(set.allowWrites)
        #expect(set.anyScreenEnabled)
    }

    @Test
    func `config base URL rejects plaintext HTTP even with a host`() throws {
        let config: [String: Any] = ["accounts": [
            ["name": "Acme", "api_key": "a", "base_url": "http://coderpad.acme.internal"],
        ]]
        #expect(throws: MCPConfigError.invalidBaseURL(
            account: "Acme", baseURL: "http://coderpad.acme.internal",
        )) {
            try makeAccountSet(config: config, environment: [:])
        }
        #expect(throws: MCPConfigError.invalidBaseURL(
            account: "default", baseURL: "http://localhost:3000",
        )) {
            try makeAccountSet(config: nil, environment: [
                "CODERPAD_API_KEY": "a", "CODERPAD_BASE_URL": "http://localhost:3000",
            ])
        }
    }

    @Test
    func `config base URL rejects non-HTTP and hostless values`() {
        #expect(throws: MCPConfigError.invalidBaseURL(account: "Acme", baseURL: "file:///tmp")) {
            try makeAccountSet(config: ["accounts": [
                ["name": "Acme", "api_key": "a", "base_url": "file:///tmp"],
            ]], environment: [:])
        }

        #expect(throws: MCPConfigError.invalidBaseURL(account: "Beta", baseURL: "https:///missing-host")) {
            try makeAccountSet(config: ["accounts": [
                ["name": "Beta", "api_key": "b", "base_url": "https:///missing-host"],
            ]], environment: [:])
        }
    }

    @Test
    func `config base URL rejects present non-string values`() {
        #expect(throws: MCPConfigError.invalidBaseURL(account: "Acme", baseURL: "123")) {
            try makeAccountSet(config: ["accounts": [
                ["name": "Acme", "api_key": "a", "base_url": 123],
            ]], environment: [:])
        }
    }

    @Test
    func `config screen regions accept documented values case-insensitively`() throws {
        let config: [String: Any] = ["accounts": [
            ["name": "Acme", "api_key": "a", "screen_region": "US", "default": true],
            ["name": "Beta", "api_key": "b", "screen_region": " eu "],
        ]]
        let set = try makeAccountSet(config: config, environment: [:])
        #expect(set.accounts[0].screenRegion == "us")
        #expect(set.accounts[1].screenRegion == "eu")
    }

    @Test
    func `config screen region rejects unknown non-empty values`() {
        let config: [String: Any] = ["accounts": [
            ["name": "Acme", "api_key": "a", "screen_region": "ue"],
        ]]

        #expect(throws: MCPConfigError.invalidScreenRegion(account: "Acme", region: "ue")) {
            try makeAccountSet(config: config, environment: [:])
        }
    }

    /// A single-account config still needs no explicit default; a multi-account
    /// config must mark one, so a JSON reformat can never silently redirect
    /// unqualified tool calls to another organization (#1586).
    @Test
    func `multi-account config without a marked default is rejected`() throws {
        let single: [String: Any] = ["accounts": [["name": "Acme", "api_key": "a"]]]
        let accountSet = try makeAccountSet(config: single, environment: [:])
        #expect(try #require(accountSet.defaultAccount).name == "Acme")

        let config: [String: Any] = ["accounts": [
            ["name": "Acme", "api_key": "a"],
            ["name": "Beta", "api_key": "b"],
        ]]
        #expect(throws: MCPConfigError.noDefaultAccount) {
            try makeAccountSet(config: config, environment: [:])
        }
    }

    @Test
    func `default flag must be Boolean when present`() {
        #expect(throws: MCPConfigError.invalidDefaultFlag(account: "Acme")) {
            try makeAccountSet(config: ["accounts": [[
                "name": "Acme", "api_key": "a", "default": "true",
            ]]], environment: [:])
        }
    }

    /// A name matching more than one configured account is ambiguous and
    /// resolves to nil instead of whichever was listed first (#1582).
    @Test
    func `resolve returns nil for ambiguous case-insensitive matches`() {
        let make: (String, String) -> MCPAccount = { id, name in
            MCPAccount(id: id, name: name, apiKey: "k", baseURL: URL(string: "https://app.coderpad.io")!,
                       screenAPIKey: nil, screenRegion: "us")
        }
        let set = MCPAccountSet(
            accounts: [make("first", "Acme"), make("second", "ACME")],
            defaultName: "first",
            allowWrites: false,
        )
        #expect(set.resolve("acme") == nil)
        #expect(set.resolve("Acme") == nil)
    }

    @Test
    func `config with multiple marked defaults is rejected`() {
        let config: [String: Any] = ["accounts": [
            ["name": "Acme", "api_key": "a", "default": true],
            ["name": "Beta", "api_key": "b", "default": true],
        ]]

        #expect(throws: MCPConfigError.multipleDefaultAccounts(["Acme", "Beta"])) {
            try makeAccountSet(config: config, environment: [:])
        }
    }

    @Test
    func `resolve matches by name case-insensitively, defaults on nil, nil on unknown`() throws {
        let config: [String: Any] = ["accounts": [
            ["name": "Acme", "api_key": "a", "default": true],
            ["name": "Beta", "api_key": "b"],
        ]]
        let set = try makeAccountSet(config: config, environment: [:])
        #expect(set.resolve(nil)?.name == "Acme")
        #expect(set.resolve("")?.name == "Acme")
        #expect(set.resolve("beta")?.name == "Beta")
        #expect(set.resolve("  BETA ")?.name == "Beta")
        #expect(set.resolve("nope") == nil)
    }

    @Test
    func `missing key and duplicate names are rejected`() {
        #expect(throws: MCPConfigError.missingAPIKey(account: "Acme")) {
            try makeAccountSet(config: ["accounts": [["name": "Acme"]]], environment: [:])
        }
        #expect(throws: MCPConfigError.invalidCredential(account: "Acme", field: "api_key")) {
            try makeAccountSet(config: ["accounts": [["name": "Acme", "api_key": 123]]], environment: [:])
        }
        #expect(throws: MCPConfigError.duplicateName("acme")) {
            try makeAccountSet(config: ["accounts": [
                ["name": "Acme", "api_key": "a"],
                ["name": "acme", "api_key": "b"],
            ]], environment: [:])
        }
    }

    @Test
    func `credentials are bounded and reject control characters`() throws {
        let oversized = String(repeating: "k", count: 4097)
        #expect(throws: MCPConfigError.invalidCredential(account: "Acme", field: "api_key")) {
            try makeAccountSet(config: ["accounts": [["name": "Acme", "api_key": oversized]]], environment: [:])
        }
        #expect(throws: MCPConfigError.invalidCredential(account: "Acme", field: "screen_api_key")) {
            try makeAccountSet(config: ["accounts": [[
                "name": "Acme", "api_key": "valid", "screen_api_key": "bad\u{0000}key",
            ]]], environment: [:])
        }

        let set = try makeAccountSet(config: nil, environment: [
            "CODERPAD_API_KEY": "  valid-key  ",
            "CODERPAD_ACCOUNT_NAME": "  Demo\u{0007}" + String(repeating: "x", count: 150),
        ])
        #expect(set.defaultAccount?.apiKey == "valid-key")
        #expect(set.defaultAccount?.name.count == 100)
        #expect(set.defaultAccount?.name.contains("\u{0007}") == false)
    }

    @Test
    func `environment credentials use the same validation`() {
        #expect(throws: MCPConfigError.invalidCredential(
            account: "default", field: "CODERPAD_SCREEN_API_KEY",
        )) {
            try makeAccountSet(config: nil, environment: [
                "CODERPAD_API_KEY": "valid", "CODERPAD_SCREEN_API_KEY": String(repeating: "s", count: 4097),
            ])
        }
    }

    @Test
    func `the list_accounts directory carries names and flags but never keys`() throws {
        let set = try makeAccountSet(config: ["accounts": [
            ["name": "Acme", "api_key": "secret", "default": true],
            ["name": "Beta", "api_key": "secret2", "screen_api_key": "s"],
        ]], environment: [:])
        let directory = set.directory()
        #expect(directory.count == 2)
        let acme = directory[0]
        #expect(acme["name"] as? String == "Acme")
        #expect(acme["is_default"] as? Bool == true)
        #expect(acme["screen_configured"] as? Bool == false)
        #expect(directory[1]["screen_configured"] as? Bool == true)
        // No value anywhere is the API key.
        let flattened = directory.flatMap { $0.values.compactMap { $0 as? String } }
        #expect(!flattened.contains("secret"))
        #expect(!flattened.contains("secret2"))
    }
}
