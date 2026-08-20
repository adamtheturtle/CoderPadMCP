//
//  DocumentationSnippetTests.swift
//  CoderPadMCPTests
//
//  Keeps the README / DocC embedding snippet compiling after MCPAccount and
//  MCPAccountSet became throwing (#151).
//

@testable import CoderPadMCP
import Foundation
import Testing

@Suite("Documentation snippets")
struct DocumentationSnippetTests {
    @Test
    func `README embedding snippet compiles with try`() throws {
        let apiKey = "documentation-snippet-key"
        let account = try MCPAccount(
            name: "Acme",
            apiKey: apiKey,
            baseURL: URL(string: "https://app.coderpad.io")!,
            screenAPIKey: nil,
            screenRegion: "us",
        )
        let accounts = try MCPAccountSet(
            accounts: [account],
            defaultName: account.id,
            allowWrites: false,
        )
        let provider = CoderPadProvider(accountSet: accounts)
        #expect(provider.accountSet.accounts.count == 1)
        #expect(provider.accountSet.defaultAccount?.name == "Acme")
    }
}
