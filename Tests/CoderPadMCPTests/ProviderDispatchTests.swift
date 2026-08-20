@testable import CoderPadMCP
import Foundation
import MCP
import Testing

private actor BlockingRequestProbe {
    private struct Timeout: Error {}

    private var startedCount = 0
    private var cancelledCount = 0

    func block() async throws -> APIResponse {
        startedCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelledCount += 1
            throw CancellationError()
        }
        return APIResponse(status: 200, body: "{}")
    }

    func waitUntilStarted(_ count: Int) async throws {
        for _ in 0 ..< 200 {
            if startedCount >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout()
    }

    func cancellations() -> Int {
        cancelledCount
    }
}

@Suite("Provider dispatch")
struct ProviderDispatchTests {
    @Test
    func `unknown tools are rejected before account resolution`() async throws {
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [], defaultName: "", allowWrites: false),
        )

        let result = try await provider.callTool("does_not_exist", arguments: nil)

        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }

        #expect(text == "Unknown tool: does_not_exist")
    }

    @Test
    func `cancelling a paginated scan stops the next page request`() async throws {
        let probe = BlockingRequestProbe()
        let provider = try provider { _, path, _, query, _, _ in
            if path == "/api/pads/", query.contains(where: { $0.name == "page" }) {
                return try await probe.block()
            }
            return APIResponse(
                status: 200,
                body: #"{"pads":[{"id":"first"}],"next_page":"next","total":1}"#,
            )
        }

        let task = Task { try await provider.callTool("count_pads", arguments: nil) }
        try await probe.waitUntilStarted(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await probe.cancellations() == 1)
    }

    @Test
    func `cancelling get pad code stops its environment fanout`() async throws {
        let probe = BlockingRequestProbe()
        let provider = try provider { _, path, _, _, _, _ in
            if path == "/api/pads/abc" {
                return APIResponse(status: 200, body: #"{"pad_environment_ids":[1,2]}"#)
            }
            if path.hasPrefix("/api/pad_environments/") {
                return try await probe.block()
            }
            return APIResponse(status: 404, body: "{}")
        }

        let task = Task {
            try await provider.callTool("get_pad_code", arguments: ["pad": .string("abc")])
        }
        try await probe.waitUntilStarted(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await probe.cancellations() == 1)
    }

    @Test
    func `global write denial names the host switch`() async throws {
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
            allowWrites: true,
        )
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            interviewRequest: { _, _, _, _, _, _ in
                APIResponse(status: 500, body: "should not run")
            },
        )

        let result = try await provider.callTool("create_question", arguments: [
            "title": .string("Title"),
            "language": .string("python"),
            "description": .string("Desc"),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text.contains("disabled globally"))
        #expect(text.contains("CODERPAD_MCP_ALLOW_WRITES"))
        #expect(!text.contains("account \"Acme\""))
    }

    @Test
    func `per-account write denial names the account switch`() async throws {
        let denied = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
            allowWrites: false,
        )
        let allowed = try MCPAccount(
            name: "Other",
            apiKey: "secret-2",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
            allowWrites: true,
        )
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(
                accounts: [denied, allowed],
                defaultName: denied.name,
                allowWrites: true,
            ),
            interviewRequest: { _, _, _, _, _, _ in
                APIResponse(status: 500, body: "should not run")
            },
        )

        let result = try await provider.callTool("create_question", arguments: [
            "title": .string("Title"),
            "language": .string("python"),
            "description": .string("Desc"),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text.contains("account \"Acme\""))
        #expect(text.contains("global writes are already enabled"))
        #expect(!text.contains("CODERPAD_MCP_ALLOW_WRITES"))
    }

    @Test
    func `create_pad dry run maps owner_email to user_email`() async throws {
        let provider = try writeProvider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        let result = try await provider.callTool("create_pad", arguments: [
            "title": .string("Interview"),
            "owner_email": .string("owner@example.com"),
            "language": .string("python"),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true)
        let body = try #require(try dryRunBody(result))
        #expect(body["user_email"] as? String == "owner@example.com")
        #expect(body["owner_email"] == nil)
        #expect(body["language"] as? String == "python")
    }

    @Test
    func `misspelled dry_run never reaches the network`() async throws {
        let provider = try writeProvider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        let result = try await provider.callTool("create_pad", arguments: [
            "title": .string("Interview"),
            "dryrun": .bool(true),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text.contains("Unknown argument: dryrun"))
    }

    @Test
    func `wrong-typed write fields are rejected before mutation`() async throws {
        let provider = try writeProvider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        let result = try await provider.callTool("update_pad", arguments: [
            "pad": .string("ABC123"),
            "title": .string("Renamed"),
            "notes": .bool(true),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text == "notes must be a string.")
    }

    private func writeProvider(request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
            allowWrites: true,
        )
        return CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: true),
            interviewRequest: request,
        )
    }

    private func dryRunBody(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["body"] as? [String: Any]
        else {
            throw NSError(domain: "test", code: 1)
        }
        return body
    }

    private func provider(request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
        )
        return CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            interviewRequest: request,
        )
    }
}
