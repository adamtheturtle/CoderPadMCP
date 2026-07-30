//
//  EmptyAccountSetTests.swift
//  CoderPadMCPTests
//

@testable import CoderPadMCP
import Testing

@Suite("Empty MCP account sets")
struct EmptyAccountSetTests {
    private let empty = MCPAccountSet(accounts: [], defaultName: "missing", allowWrites: false)

    @Test
    func `default and unqualified resolution are safely unavailable`() {
        #expect(empty.defaultAccount == nil)
        #expect(empty.resolve(nil) == nil)
        #expect(empty.resolve("") == nil)
        #expect(resolveResourceAccount(.quota, accountSet: empty) == .noAccounts)
    }
}
