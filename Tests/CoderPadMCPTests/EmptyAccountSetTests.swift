//
//  EmptyAccountSetTests.swift
//  CoderPadMCPTests
//

@testable import CoderPadMCP
import MCP
import Testing

@Suite("Empty MCP account sets")
struct EmptyAccountSetTests {
    @Test
    func `default and unqualified resolution are safely unavailable`() throws {
        let empty = try MCPAccountSet(accounts: [], defaultName: "missing", allowWrites: false)
        #expect(empty.defaultAccount == nil)
        #expect(empty.resolve(nil) == nil)
        #expect(empty.resolve("") == nil)
        #expect(resolveResourceAccount(.quota, accountSet: empty) == .noAccounts)
    }

    @Test
    func `empty sets advertise no account-scoped resources or templates`() async throws {
        let empty = try MCPAccountSet(accounts: [], defaultName: "missing", allowWrites: false)
        #expect(staticResources(for: empty).isEmpty)
        #expect(resourceTemplates(for: empty).isEmpty)

        let provider = CoderPadProvider(accountSet: empty)
        #expect(await provider.resources().isEmpty)
        #expect(await provider.resourceTemplates().isEmpty)
        await #expect(throws: MCPError.self) {
            try await provider.readResource("coderpad://quota")
        }
    }
}
