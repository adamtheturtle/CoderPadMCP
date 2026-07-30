//
//  WritePolicyConfigTests.swift
//  CoderPadMCPTests
//

@testable import CoderPadMCP
import Foundation
import Testing

@Suite("MCP write-policy config")
struct WritePolicyConfigTests {
    private let accounts: [[String: Any]] = [["name": "Acme", "api_key": "key"]]

    @Test
    func `allow writes accepts only JSON booleans`() throws {
        for invalid: Any in ["true", 1, NSNull()] {
            #expect(throws: MCPConfigError.invalidAllowWrites) {
                try makeAccountSet(
                    config: ["accounts": accounts, "allow_writes": invalid],
                    environment: [:],
                )
            }
        }

        #expect(try makeAccountSet(
            config: ["accounts": accounts, "allow_writes": true],
            environment: [:],
        ).allowWrites)
        #expect(try !makeAccountSet(
            config: ["accounts": accounts, "allow_writes": false],
            environment: [:],
        ).allowWrites)
    }

    @Test
    func `invalid write policy is rejected before environment fallback`() {
        #expect(throws: MCPConfigError.invalidAllowWrites) {
            try makeAccountSet(
                config: ["allow_writes": "false"],
                environment: ["CODERPAD_API_KEY": "key"],
            )
        }
    }

    @Test
    func `explicit config write policy overrides inherited environment`() throws {
        let set = try makeAccountSet(
            config: ["accounts": accounts, "allow_writes": false],
            environment: ["CODERPAD_MCP_ALLOW_WRITES": "true"],
        )

        #expect(!set.allowWrites)
    }
}
