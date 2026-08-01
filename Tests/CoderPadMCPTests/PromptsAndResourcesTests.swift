//
//  PromptsAndResourcesTests.swift
//  CoderPadMCPTests
//
//  Tests for the MCP prompts and resources the server exposes (#517): the prompt
//  catalog and its rendering, and the resource catalog plus URI parsing.
//

@testable import CoderPadMCP
import Foundation
import MCP
import Testing

// MARK: - Prompts

@Suite("Prompts")
struct PromptsTests {
    @Test
    func `the catalog advertises the expected prompts`() {
        let names = interviewPrompts.map(\.name)
        #expect(names == ["review_pad_code", "summarize_pad", "compare_pads", "draft_question"])
        // Every prompt declares at least one required argument.
        for prompt in interviewPrompts {
            #expect(prompt.arguments?.contains { $0.required == true } == true)
        }
    }

    @Test
    func `review_pad_code renders a user message naming the pad and the tool`() throws {
        let result = try renderPrompt(name: "review_pad_code", arguments: ["pad_id": "abc123"])
        #expect(result.messages.count == 1)
        let message = try #require(result.messages.first)
        #expect(message.role == .user)
        guard case let .text(text) = message.content else {
            Issue.record("expected text content")
            return
        }

        #expect(text.contains("abc123"))
        #expect(text.contains("get_pad_code"))
        #expect(text.contains("get_pad_code tool with pad: \"abc123\""))
        #expect(text.contains("get_pad with pad: \"abc123\""))
        #expect(!text.contains("with id"))
    }

    @Test
    func `pad prompts name the pad tool argument`() throws {
        let promptArguments = ["pad_id": "abc123"]
        for name in ["review_pad_code", "summarize_pad"] {
            let result = try renderPrompt(name: name, arguments: promptArguments)
            guard case let .text(text) = try #require(result.messages.first).content else {
                Issue.record("expected text content")
                return
            }

            #expect(text.contains("pad: \"abc123\""))
            #expect(!text.contains("with id"))
        }

        let comparison = try renderPrompt(name: "compare_pads", arguments: ["pad_ids": "abc123, def456"])
        guard case let .text(text) = try #require(comparison.messages.first).content else {
            Issue.record("expected text content")
            return
        }

        #expect(text.contains("pad argument"))
    }

    @Test
    func `compare_pads splits and quotes each id`() throws {
        let result = try renderPrompt(name: "compare_pads", arguments: ["pad_ids": "a, b ,c"])
        guard case let .text(text) = try #require(result.messages.first).content else {
            Issue.record("expected text content")
            return
        }

        #expect(text.contains("\"a\""))
        #expect(text.contains("\"b\""))
        #expect(text.contains("\"c\""))
    }

    @Test
    func `draft_question folds in optional language and difficulty`() throws {
        let result = try renderPrompt(
            name: "draft_question",
            arguments: ["topic": "binary trees", "language": "python", "difficulty": "medium"],
        )
        guard case let .text(text) = try #require(result.messages.first).content else {
            Issue.record("expected text content")
            return
        }

        #expect(text.contains("binary trees"))
        #expect(text.contains("python"))
        #expect(text.contains("medium"))
    }

    @Test
    func `a missing required argument throws missingArgument`() {
        #expect(throws: PromptError.missingArgument("pad_id")) {
            try renderPrompt(name: "review_pad_code", arguments: nil)
        }
        // Whitespace-only counts as missing.
        #expect(throws: PromptError.missingArgument("pad_id")) {
            try renderPrompt(name: "summarize_pad", arguments: ["pad_id": "   "])
        }
        // An all-empty comma list is treated as missing.
        #expect(throws: PromptError.missingArgument("pad_ids")) {
            try renderPrompt(name: "compare_pads", arguments: ["pad_ids": " , , "])
        }
    }

    @Test
    func `an unknown prompt throws unknownPrompt`() {
        #expect(throws: PromptError.unknownPrompt("nope")) {
            try renderPrompt(name: "nope", arguments: nil)
        }
    }

    @Test
    func `prompts encode to valid JSON-RPC descriptors`() throws {
        let data = try JSONEncoder().encode(interviewPrompts[0])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] as? String == "review_pad_code")
        #expect(object["arguments"] is [Any])
    }
}

// MARK: - Resources

@Suite("Resources")
struct ResourcesTests {
    private func accountSet() throws -> MCPAccountSet {
        let baseURL = try #require(URL(string: "https://example.com"))
        return MCPAccountSet(
            accounts: [
                MCPAccount(name: "Acme EU", apiKey: "a", baseURL: baseURL, screenAPIKey: nil, screenRegion: "us"),
                MCPAccount(name: "Beta", apiKey: "b", baseURL: baseURL, screenAPIKey: nil, screenRegion: "us"),
            ],
            defaultName: "Acme EU",
            allowWrites: false,
        )
    }

    @Test
    func `static resources cover quota and organization`() {
        let uris = staticResources.map(\.uri)
        #expect(uris.contains("coderpad://quota"))
        #expect(uris.contains("coderpad://organization"))
    }

    @Test
    func `multi-account static resources are account-qualified`() throws {
        let uris = try staticResources(for: accountSet()).map(\.uri)
        #expect(uris.contains("coderpad://account/Acme%20EU/quota"))
        #expect(uris.contains("coderpad://account/Beta/organization"))
        #expect(!uris.contains("coderpad://quota"))
    }

    @Test
    func `templates cover pad, pad code, and question`() {
        let patterns = resourceTemplates.map(\.uriTemplate)
        #expect(patterns.contains("coderpad://pad/{id}"))
        #expect(patterns.contains("coderpad://pad/{id}/code"))
        #expect(patterns.contains("coderpad://question/{id}"))
    }

    @Test
    func `single-account catalog advertises only canonical unqualified templates`() throws {
        let account = try #require(accountSet().accounts.first)
        let single = MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false)
        let patterns = resourceTemplates(for: single).map(\.uriTemplate)

        #expect(patterns == resourceTemplates.map(\.uriTemplate))
        #expect(!patterns.contains { $0.contains("/{account}/") })
    }

    @Test
    func `multi-account templates require an account segment`() throws {
        let patterns = try resourceTemplates(for: accountSet()).map(\.uriTemplate)
        #expect(patterns.contains("coderpad://account/{account}/pad/{id}"))
        #expect(patterns.contains("coderpad://account/{account}/pad/{id}/code"))
        #expect(patterns.contains("coderpad://account/{account}/question/{id}"))
        #expect(!patterns.contains("coderpad://pad/{id}"))
    }

    @Test
    func `parseResourceURI maps each known shape`() {
        #expect(parseResourceURI("coderpad://quota") == .quota)
        #expect(parseResourceURI("coderpad://organization") == .organization)
        #expect(parseResourceURI("coderpad://pad/abc123") == .pad("abc123"))
        #expect(parseResourceURI("coderpad://pad/abc123/code") == .padCode("abc123"))
        #expect(parseResourceURI("coderpad://question/42") == .question(42))
    }

    @Test
    func `parseResourceURI rejects query components`() {
        #expect(parseResourceURI("coderpad://quota?account=other") == nil)
        #expect(parseResourceURI("coderpad://pad/abc123?view=code") == nil)
        #expect(parseResourceURI("coderpad://quota?") == nil)
    }

    /// URI schemes and route literals are case-insensitive per standard; ids
    /// keep their exact case (#1581).
    @Test
    func `parseResourceURI accepts mixed-case schemes and route literals`() {
        #expect(parseResourceURI("CODERPAD://Quota") == .quota)
        #expect(parseResourceURI("CoderPad://PAD/AbC123") == .pad("AbC123"))
        #expect(parseResourceURI("coderpad://pad/abc123/CODE") == .padCode("abc123"))
    }

    /// Decoded dot navigation, separators inside pad ids, and control characters
    /// must never be treated as identifiers (#1580).
    @Test
    func `parseResourceURI rejects traversal and control segments`() {
        #expect(parseResourceURI("coderpad://pad/%2E%2E") == nil)
        #expect(parseResourceURI("coderpad://pad/a%2Fb") == nil)
        #expect(parseResourceURI("coderpad://account/%2E%2E/quota") == nil)
        #expect(parseResourceURI("coderpad://pad/a%00b") == nil)
    }

    @Test
    func `parseResourceURI maps account-qualified shapes`() {
        #expect(parseResourceURI("coderpad://account/Acme%20EU/quota") == .accountQuota("Acme EU"))
        #expect(parseResourceURI("coderpad://account/Acme%20EU/organization") == .accountOrganization("Acme EU"))
        #expect(
            parseResourceURI("coderpad://account/Acme%20EU/pad/abc123")
                == .accountPad(account: "Acme EU", id: "abc123"),
        )
        #expect(
            parseResourceURI("coderpad://account/Acme%20EU/pad/abc123/code")
                == .accountPadCode(account: "Acme EU", id: "abc123"),
        )
        #expect(
            parseResourceURI("coderpad://account/Acme%20EU/question/42")
                == .accountQuestion(account: "Acme EU", id: 42),
        )
    }

    @Test
    func `parseResourceURI accepts canonical pad ids`() {
        #expect(parseResourceURI("coderpad://pad/abc-123_X") == .pad("abc-123_X"))
        #expect(
            parseResourceURI("coderpad://account/Acme%20EU/pad/a%62c")
                == .accountPad(account: "Acme EU", id: "abc"),
        )
        #expect(parseResourceURI("coderpad://pad/\(String(repeating: "a", count: 64))") != nil)
    }

    @Test
    func `parseResourceURI decodes each segment exactly once (#1030)`() {
        // An encoded "/" inside a segment must not split it into extra segments.
        #expect(parseResourceURI("coderpad://account/Team%20A%2FB/quota") == .accountQuota("Team A/B"))
        // A value whose single decode yields a %-sequence must not be decoded again.
        #expect(parseResourceURI("coderpad://account/50%2520off/quota") == .accountQuota("50%20off"))
        #expect(parseResourceURI("coderpad://pad/a%2520b") == nil)
    }

    @Test
    func `parseResourceURI rejects noncanonical pad ids`() {
        for id in ["a%20b", "a%3Fb", "a%23b", "a.b", "%C3%A9", String(repeating: "a", count: 65)] {
            #expect(parseResourceURI("coderpad://pad/\(id)") == nil)
            #expect(parseResourceURI("coderpad://account/Acme/pad/\(id)") == nil)
        }
    }

    @Test
    func `parseResourceURI rejects unknown or malformed URIs`() {
        #expect(parseResourceURI("https://example.com/pad/1") == nil)
        #expect(parseResourceURI("coderpad://unknown") == nil)
        #expect(parseResourceURI("coderpad://question/not-a-number") == nil)
        #expect(parseResourceURI("coderpad://pad") == nil)
        #expect(parseResourceURI("coderpad://account/Acme/pad") == nil)
        #expect(parseResourceURI("coderpad://account/Acme/question/not-a-number") == nil)
        #expect(parseResourceURI("not a uri") == nil)
    }

    @Test
    func `parseResourceURI bounds encoded input before decoding`() {
        let oversizedSegment = String(repeating: "%41", count: 342)
        #expect(oversizedSegment.utf8.count == 1026)
        #expect(parseResourceURI("coderpad://account/\(oversizedSegment)/quota") == nil)
        #expect(parseResourceURI("coderpad://account/a/pad/id/code/extra") == nil)

        let oversizedURI = "coderpad://account/" + String(repeating: "a", count: 5101) + "/quota"
        #expect(oversizedURI.utf8.count > 5120)
        #expect(parseResourceURI(oversizedURI) == nil)
    }

    @Test
    func `question resource ids must be positive integers`() {
        for id in ["0", "-1", "-999"] {
            #expect(parseResourceURI("coderpad://question/\(id)") == nil)
            #expect(parseResourceURI("coderpad://account/Acme/question/\(id)") == nil)
        }
        #expect(parseResourceURI("coderpad://question/1") == .question(1))
        #expect(parseResourceURI("coderpad://question/\(Int.max)") == .question(Int.max))
    }

    @Test
    func `resource account resolution requires account in multi-account configs`() throws {
        let set = try accountSet()
        #expect(resolveResourceAccount(.pad("abc123"), accountSet: set) == .requiresAccount)
        #expect(
            resolveResourceAccount(.accountPad(account: "beta", id: "abc123"), accountSet: set)
                == .account(set.accounts[1]),
        )
        #expect(
            resolveResourceAccount(.accountQuestion(account: "Nope", id: 42), accountSet: set)
                == .unknownAccount("Nope"),
        )
    }

    @Test
    func `resources encode to valid JSON-RPC descriptors`() throws {
        let data = try JSONEncoder().encode(staticResources[0])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["uri"] as? String == "coderpad://quota")
        #expect(object["mimeType"] as? String == "application/json")
    }
}
