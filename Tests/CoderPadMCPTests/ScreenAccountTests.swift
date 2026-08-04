//
//  ScreenAccountTests.swift
//  CoderPadMCPTests
//

@testable import CoderPadMCP
import Foundation
import Testing

@Suite("Screen account credentials")
struct ScreenAccountTests {
    @Test
    func `direct accounts require a nonblank Screen key`() throws {
        let baseURL = try #require(URL(string: "https://app.coderpad.io"))
        let account: (String?) throws -> MCPAccount = { key in
            try MCPAccount(name: "Acme", apiKey: "key", baseURL: baseURL,
                           screenAPIKey: key, screenRegion: "us")
        }

        for key in [nil, "", " \n\t "] as [String?] {
            let disabled = try account(key)
            #expect(!disabled.screenEnabled)
            #expect(!MCPAccountSet(accounts: [disabled], defaultName: "Acme", allowWrites: false).anyScreenEnabled)
        }
        #expect(try account(" screen-key ").screenEnabled)
    }
}
