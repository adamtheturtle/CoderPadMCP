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

private actor RequestCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
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

        // A filter forces a full scan so unfiltered total short-circuit cannot skip paging.
        let task = Task {
            try await provider.callTool("count_pads", arguments: ["owner": .string("ada@example.com")])
        }
        try await probe.waitUntilStarted(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await probe.cancellations() == 1)
    }

    @Test
    func `whoami ignores irrelevant integer-named arguments`() async throws {
        let provider = try provider { _, path, _, _, _, _ in
            #expect(path == "/api/organization")
            return APIResponse(status: 200, body: #"{"name":"Acme Org"}"#)
        }

        let result = try await provider.callTool("whoami", arguments: [
            "page": .bool(false),
            "question_id": .object([:]),
        ])
        #expect(result.isError != true)
    }

    @Test
    func `list tools reject wrong-typed sort before calling the API`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        for name in ["list_pads", "list_pads_compact", "list_questions", "list_questions_compact"] {
            let result = try await provider.callTool(name, arguments: ["sort": .bool(true)])
            #expect(result.isError == true)
            guard case let .text(text, _, _)? = result.content.first else {
                Issue.record("Expected a text error for \(name)")
                continue
            }
            #expect(text.contains("sort"))
        }
    }

    @Test
    func `list tools reject undocumented sort fields`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        for name in ["list_pads", "list_questions"] {
            let result = try await provider.callTool(name, arguments: ["sort": .string("title")])
            #expect(result.isError == true)
        }
    }

    @Test
    func `count and aggregate reject wrong-typed pad filters`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        let count = try await provider.callTool("count_pads", arguments: ["owner": .bool(true)])
        #expect(count.isError == true)

        let aggregate = try await provider.callTool("aggregate_pads", arguments: [
            "group_by": .string("language"),
            "state": .array([.string("active")]),
        ])
        #expect(aggregate.isError == true)
    }

    @Test
    func `count and aggregate reject wrong-typed question filters and date bounds`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            APIResponse(status: 500, body: "should not run")
        }

        let count = try await provider.callTool("count_questions", arguments: [
            "author": .object([:]),
            "created_after": .bool(false),
        ])
        #expect(count.isError == true)

        let aggregate = try await provider.callTool("aggregate_questions", arguments: [
            "group_by": .string("month"),
            "type": .null,
        ])
        #expect(aggregate.isError == true)
    }

    @Test
    func `screen_list_tests rejects a wrong-typed candidateEmail`() async throws {
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: "screen-secret",
            screenRegion: "us",
        )
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            interviewRequest: { _, _, _, _, _, _ in
                APIResponse(status: 500, body: "should not run")
            },
        )

        let result = try await provider.callTool("screen_list_tests", arguments: [
            "candidateEmail": .bool(true),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text.contains("candidateEmail"))
    }

    @Test
    func `unfiltered count_pads uses the first page total without further requests`() async throws {
        let provider = try countingProvider(path: "/api/pads/", body: { count in
            #expect(count == 1)
            return #"{"pads":[{"id":"a"},{"id":"b"}],"next_page":"2","total":100}"#
        })

        let result = try await provider.callTool("count_pads", arguments: nil)
        #expect(result.isError != true)
        let object = try resultObject(result)
        #expect(object["matched"] as? Int == 100)
        #expect(object["pages_fetched"] as? Int == 1)
        #expect(object["truncated"] as? Bool == false)
    }

    @Test
    func `unfiltered count_questions uses the first page total without further requests`() async throws {
        let provider = try countingProvider(path: "/api/questions/", body: { count in
            #expect(count == 1)
            return #"{"questions":[{"id":1},{"id":2}],"next_page":"2","total":50}"#
        })

        let result = try await provider.callTool("count_questions", arguments: nil)
        #expect(result.isError != true)
        let object = try resultObject(result)
        #expect(object["matched"] as? Int == 50)
        #expect(object["pages_fetched"] as? Int == 1)
    }

    @Test
    func `malformed next_page fails a filtered pad count instead of ending early`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            APIResponse(
                status: 200,
                body: #"{"pads":[{"id":"a"}],"next_page":true,"total":1}"#,
            )
        }

        let result = try await provider.callTool("count_pads", arguments: [
            "owner": .string("ada@example.com"),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text.contains("malformed next_page"))
    }

    @Test
    func `pad counts fail when total proves pagination ended early`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            APIResponse(
                status: 200,
                body: #"{"pads":[{"id":"a"},{"id":"b"}],"total":10}"#,
            )
        }

        let result = try await provider.callTool("count_pads", arguments: [
            "language": .string("python"),
        ])
        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }
        #expect(text.contains("ended early"))
    }

    @Test
    func `fresh cache scans reject identity-less pads and dedupe duplicates`() async throws {
        let cached = try JSONSerialization.data(withJSONObject: [
            ["id": "pad-1"],
            ["id": "pad-1"],
            ["title": "missing"],
        ])
        let cache = CoderPadMCPCache(
            load: { _, _, _ in cached },
            invalidate: { _, _ in },
        )
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
        )
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            cache: cache,
            interviewRequest: { _, _, _, _, _, _ in
                APIResponse(status: 500, body: "should not run")
            },
        )

        let result = try await provider.callTool("count_pads", arguments: [
            "owner": .string("ada@example.com"),
        ])
        #expect(result.isError == true)
    }

    @Test
    func `fresh cache scans deduplicate valid pads`() async throws {
        let cached = try JSONSerialization.data(withJSONObject: [
            ["id": "pad-1", "owner_email": "ada@example.com"],
            ["id": "pad-1", "owner_email": "ada@example.com"],
            ["id": "pad-2", "owner_email": "ada@example.com"],
        ])
        let cache = CoderPadMCPCache(
            load: { _, _, _ in cached },
            invalidate: { _, _ in },
        )
        let account = try MCPAccount(
            name: "Acme",
            apiKey: "secret",
            baseURL: #require(URL(string: "https://app.coderpad.io")),
            screenAPIKey: nil,
            screenRegion: "us",
        )
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
            cache: cache,
            interviewRequest: { _, _, _, _, _, _ in
                APIResponse(status: 500, body: "should not run")
            },
        )

        let result = try await provider.callTool("count_pads", arguments: [
            "owner": .string("ada@example.com"),
        ])
        #expect(result.isError != true)
        let object = try resultObject(result)
        #expect(object["matched"] as? Int == 2)
        #expect(object["scanned"] as? Int == 2)
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

    private func countingProvider(
        path: String,
        body: @escaping @Sendable (Int) -> String,
    ) throws -> CoderPadProvider {
        let counter = RequestCounter()
        return try provider { _, requestPath, _, _, _, _ in
            #expect(requestPath == path)
            let current = await counter.next()
            return APIResponse(status: 200, body: body(current))
        }
    }

    private func resultObject(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected JSON text content")
            return [:]
        }
        let data = Data(text.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
