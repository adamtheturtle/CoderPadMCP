//
//  ConfigurationFailureTests.swift
//  CoderPadMCPTests
//

@testable import CoderPadMCP
import Foundation
import Testing

@Suite("Standalone configuration failure messages")
struct ConfigurationFailureTests {
    @Test
    func `every MCPConfigError case produces an actionable stderr line`() {
        let cases: [(MCPConfigError, String)] = [
            (.noAccounts,
             "coderpad-mcp: no accounts configured. Set CODERPAD_API_KEY, or point "
                 + "CODERPAD_MCP_CONFIG at a config file with an \"accounts\" array.\n"),
            (.tooManyAccounts(limit: 100),
             "coderpad-mcp: the account configuration exceeds the 100-account limit.\n"),
            (.missingAPIKey(account: "Acme"),
             "coderpad-mcp: account \"Acme\" is missing its \"api_key\".\n"),
            (.duplicateName("acme"),
             "coderpad-mcp: two accounts share the name \"acme\"; names must be unique.\n"),
            (.duplicateID("shared"),
             "coderpad-mcp: two accounts share the stable id \"shared\"; ids must be unique.\n"),
            (.selectorCollision(id: "Beta", name: "Beta"),
             "coderpad-mcp: account id \"Beta\" collides with another account's name \"Beta\"; "
                 + "ids and names must not overlap across accounts.\n"),
            (.multipleDefaultAccounts(["Acme", "Beta"]),
             "coderpad-mcp: multiple accounts are marked as default (Acme, Beta); "
                 + "mark only one as the default.\n"),
            (.noDefaultAccount,
             "coderpad-mcp: a config with multiple accounts must mark one as the default.\n"),
            (.invalidDefaultFlag(account: "Acme"),
             "coderpad-mcp: account \"Acme\" has a non-Boolean \"default\" value.\n"),
            (.invalidAllowWrites,
             "coderpad-mcp: \"allow_writes\" must be a JSON boolean (true or false).\n"),
            (.invalidScreenRegion(account: "Acme", region: "europe"),
             "coderpad-mcp: account \"Acme\" has unsupported screen_region \"europe\".\n"),
            (.invalidBaseURL(account: "Acme", baseURL: "http://example.com"),
             "coderpad-mcp: account \"Acme\" has unsupported base_url \"http://example.com\".\n"),
            (.invalidCredential(account: "Acme", field: "api_key"),
             "coderpad-mcp: account \"Acme\" has an invalid \"api_key\" value.\n"),
        ]

        for (error, expected) in cases {
            #expect(configurationFailureMessage(error) == expected)
        }
    }

    @Test
    func `config load errors surface their LocalizedError text on stderr`() {
        #expect(configurationFailureMessage(MCPConfigLoadError.emptyConfigPath)
            == "coderpad-mcp: CODERPAD_MCP_CONFIG is set but empty; "
            + "provide a config file path or unset the variable.\n")
        #expect(configurationFailureMessage(MCPConfigLoadError.missingConfig(path: "/tmp/x.json"))
            == "coderpad-mcp: Config file does not exist at /tmp/x.json.\n")
    }
}
