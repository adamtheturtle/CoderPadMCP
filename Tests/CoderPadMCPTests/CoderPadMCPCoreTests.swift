//
//  CoderPadMCPCoreTests.swift
//  CoderPadMCPTests
//
//  Unit tests for the standalone MCP server's network-free core (#522): argument
//  coercion, the advertised tool catalog and its schemas, and the pad
//  code/count/aggregate transforms.
//

@testable import CoderPadMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("Bounded HTTP responses")
struct BoundedHTTPResponseTests {
    @Test
    func `buffer rejects a chunk before crossing its byte limit`() throws {
        var buffer = BoundedDataBuffer(limit: 5)

        try buffer.append(Data([1, 2, 3]))
        #expect(buffer.data == Data([1, 2, 3]))
        #expect(throws: BoundedHTTPResponseError(limit: 5)) {
            try buffer.append(Data([4, 5, 6]))
        }
        #expect(buffer.data == Data([1, 2, 3]))
    }

    @Test
    func `cross-origin redirects are refused before sensitive headers can be resent`() throws {
        let source = try #require(URL(string: "https://www.codingame.com/start"))
        let target = try #require(URL(string: "https://attacker.example/collect"))
        let response = try #require(HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": target.absoluteString],
        ))
        var proposed = URLRequest(url: target)
        proposed.setValue("secret", forHTTPHeaderField: "API-Key")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let loader = BoundedHTTPResponseLoader(limit: 1024)
        let decision = RedirectDecision()

        loader.urlSession(
            session,
            task: session.dataTask(with: source),
            willPerformHTTPRedirection: response,
            newRequest: proposed,
            completionHandler: { decision.record($0) },
        )

        #expect(decision.request == nil)
    }

    @Test
    func `same-origin redirects retain their proposed request`() throws {
        let source = try #require(URL(string: "https://www.codingame.com/start"))
        let target = try #require(URL(string: "https://www.codingame.com:443/next"))
        let response = try #require(HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": target.absoluteString],
        ))
        var proposed = URLRequest(url: target)
        proposed.setValue("secret", forHTTPHeaderField: "API-Key")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let loader = BoundedHTTPResponseLoader(limit: 1024)
        let decision = RedirectDecision()

        loader.urlSession(
            session,
            task: session.dataTask(with: source),
            willPerformHTTPRedirection: response,
            newRequest: proposed,
            completionHandler: { decision.record($0) },
        )

        #expect(decision.request?.value(forHTTPHeaderField: "API-Key") == "secret")
    }
}

private final class RedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URLRequest?

    func record(_ request: URLRequest?) {
        lock.withLock { storage = request }
    }

    var request: URLRequest? {
        lock.withLock { storage }
    }
}

// MARK: - Argument coercion

@Suite("Argument coercion")
struct ArgumentTests {
    @Test
    func `stringArgument coerces ints, doubles, and strings; nil otherwise`() {
        let args: [String: Value] = [
            "s": .string("hi"), "i": .int(42), "d": .double(3.5), "b": .bool(true),
        ]
        #expect(stringArgument(args, "s") == "hi")
        #expect(stringArgument(args, "i") == "42")
        #expect(stringArgument(args, "d") == "3.5")
        #expect(stringArgument(args, "b") == nil)
        #expect(stringArgument(args, "missing") == nil)
        #expect(stringArgument(nil, "s") == nil)
    }

    @Test
    func `intArgument coerces ints, truncates doubles, parses numeric strings`() {
        let args: [String: Value] = [
            "i": .int(7), "d": .double(9.9), "ns": .string("13"), "bad": .string("x"),
        ]
        #expect(intArgument(args, "i") == 7)
        #expect(intArgument(args, "d") == 9)
        #expect(intArgument(args, "ns") == 13)
        #expect(intArgument(args, "bad") == nil)
        #expect(intArgument(args, "missing") == nil)
    }

    @Test
    func `strict integer arguments reject lossy doubles`() {
        let args: [String: Value] = [
            "integer": .int(7),
            "integralDouble": .double(9.0),
            "fraction": .double(9.9),
            "infinity": .double(.infinity),
            "string": .string("13"),
        ]

        #expect(strictIntArgument(args, "integer") == 7)
        #expect(strictIntArgument(args, "integralDouble") == 9)
        #expect(strictIntArgument(args, "fraction") == nil)
        #expect(strictIntArgument(args, "infinity") == nil)
        #expect(strictIntArgument(args, "string") == 13)
        #expect(invalidIntegerArgument(args, names: ["integer", "string"]) == nil)
        #expect(invalidIntegerArgument(args, names: ["fraction", "infinity"]) == "fraction")
    }

    @Test
    func `optionalString trims and rejects empties`() {
        let args: [String: Value] = ["a": .string("  hello  "), "blank": .string("   ")]
        #expect(optionalString(args, "a") == "hello")
        #expect(optionalString(args, "blank") == nil)
        #expect(optionalString(args, "missing") == nil)
    }

    @Test
    func `dry run parsing rejects every present ambiguous value`() {
        #expect(strictDryRunArgument(nil) == .absent)
        #expect(strictDryRunArgument(["dry_run": .bool(true)]) == .value(true))
        #expect(strictDryRunArgument(["dry_run": .string("false")]) == .value(false))
        #expect(strictDryRunArgument(["dry_run": .string("TRUE")]) == .invalid)
        #expect(strictDryRunArgument(["dry_run": .int(1)]) == .invalid)
    }

    @Test
    func `present write strings preserve explicit emptiness`() {
        #expect(presentWriteString(["contents": .string("")], "contents") == "")
        #expect(presentWriteString(["contents": .string("  code\n")], "contents") == "  code\n")
        #expect(presentWriteString(["contents": .string("\n    print(1)\n\n")], "contents") == "\n    print(1)\n\n")
        #expect(presentWriteString(nil, "contents") == nil)
    }

    @Test
    func `question content fields retain markdown and code whitespace`() {
        let arguments: [String: Value] = [
            "description": .string("\n  indented prompt\n"),
            "solution": .string("  answer  \n"),
            "contents": .string("\n    starter()\n"),
        ]

        #expect(presentWriteString(arguments, "description") == "\n  indented prompt\n")
        #expect(presentWriteString(arguments, "solution") == "  answer  \n")
        #expect(presentWriteString(arguments, "contents") == "\n    starter()\n")
    }

    @Test
    func `write string budgets bound fields and escaped aggregate JSON`() {
        let oversized = String(repeating: "x", count: maxMCPWriteFieldBytes + 1)
        #expect(writeStringBudgetValidationError(
            ["contents": .string(oversized)], fields: ["contents"],
        ) == "contents must be at most \(maxMCPWriteFieldBytes) UTF-8 bytes.")

        let controlHeavy = String(repeating: "\u{0001}", count: 100_000)
        #expect(writeStringBudgetValidationError(
            ["description": .string(controlHeavy), "solution": .string(controlHeavy)],
            fields: ["description", "solution"],
        ) == "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes.")
        #expect(writeStringBudgetValidationError(
            ["contents": .string("small")], fields: ["contents"],
        ) == nil)

        // Foundation JSONSerialization escapes `/` as `\/`; the estimator must match (#161).
        let slashHeavy = String(repeating: "/", count: (maxMCPWriteBodyBytes - 256) / 2)
        #expect(writeStringBudgetValidationError(
            ["contents": .string(slashHeavy)], fields: ["contents"],
        ) == "The write body must be at most \(maxMCPWriteBodyBytes) JSON bytes.")
        #expect(jsonEncodedStringByteCount("/") == 4)
    }

    @Test
    func `wrong-typed write strings are distinguished from absent values`() {
        #expect(strictWriteString(nil, "title") == .absent)
        #expect(strictWriteString(["title": .string("ok")], "title") == .value("ok"))
        #expect(strictWriteString(["title": .bool(true)], "title") == .invalid)
        #expect(strictWriteString(["title": .null], "title") == .invalid)
        #expect(invalidWriteStringArgument(
            ["title": .string("ok"), "notes": .bool(false)],
            names: ["title", "notes"],
        ) == "notes")
        #expect(unknownWriteArgumentError(
            ["dryrun": .bool(true), "title": .string("x")],
            allowed: ["title", "dry_run"],
        ) == "Unknown argument: dryrun.")
    }

    @Test
    func `pagination validation rejects invalid domains`() {
        #expect(pageValidationError(nil) == nil)
        #expect(pageValidationError(1) == nil)
        #expect(pageValidationError(0)?.contains("page") == true)
        #expect(screenPaginationValidationError(start: 0, limit: 1) == nil)
        #expect(screenPaginationValidationError(start: nil, limit: 50) == nil)
        #expect(screenPaginationValidationError(start: -1, limit: nil)?.contains("start") == true)
        #expect(screenPaginationValidationError(start: nil, limit: 0)?.contains("limit") == true)
        #expect(screenPaginationValidationError(start: nil, limit: 51) == "limit must be 50 or less.")
    }

    @Test
    func `paging sorts use API syntax and normalize the legacy descending spelling`() {
        #expect(normalizedPagingSort(nil) == nil)
        #expect(normalizedPagingSort("created_at,asc") == "created_at,asc")
        #expect(normalizedPagingSort("created_at,desc") == "created_at,desc")
        #expect(normalizedPagingSort("created_at") == "created_at,desc")
        #expect(normalizedPagingSort("updated_at") == "updated_at,desc")
        #expect(normalizedPagingSort("-created_at") == "created_at,desc")
        #expect(normalizedPagingSort("title") == nil)
        #expect(normalizedPagingSort("foo") == nil)
        #expect(pagingSortValidationError(nil) == nil)
        #expect(pagingSortValidationError("-created_at") == nil)
        #expect(pagingSortValidationError("created_at") == nil)
        #expect(pagingSortValidationError("updated_at,asc") == nil)
        #expect(pagingSortValidationError("title") != nil)
        #expect(pagingSortValidationError("created_at,descending") != nil)
        #expect(pagingSortValidationError("created-at,desc") != nil)
        #expect(pagingSortValidationError("") != nil)
    }

    @Test
    func `server object identifiers reject non-positive numeric values`() {
        #expect(positiveID(nil) == nil)
        #expect(positiveID(0) == nil)
        #expect(positiveID(-1) == nil)
        #expect(positiveID(1) == 1)
        #expect(validatedPadID(nil) == nil)
        #expect(validatedPadID("0") == nil)
        #expect(validatedPadID("-8") == nil)
        #expect(validatedPadID("999999999999999999999999") == nil)
        #expect(validatedPadID("+999999999999999999999999") == nil)
        #expect(validatedPadID(" \n ") == nil)
        #expect(validatedPadID(" pad-slug \n") == "pad-slug")
        #expect(validatedPadID("../quota") == nil)
        #expect(validatedPadID("abc/../../organization") == nil)
        #expect(validatedPadID(".") == nil)
        #expect(validatedPadID(String(repeating: "a", count: 65)) == nil)
        #expect(validatedPadID("abc_123-XYZ") == "abc_123-XYZ")
    }
}

// MARK: - Tool catalog

@Suite("Tool catalog")
struct ToolCatalogTests {
    @Test
    func `read tools only by default`() {
        let names = availableTools(screenEnabled: false, writesEnabled: false).map(\.name)
        #expect(names == coderPadReadToolDescriptors.compactMap { $0["name"] as? String })
        #expect(names.contains("whoami"))
        #expect(!names.contains("screen_list_campaigns"))
        #expect(!names.contains("create_pad"))
    }

    @Test
    func `screen tools appear only when Screen is enabled`() {
        let names = availableTools(screenEnabled: true, writesEnabled: false).map(\.name)
        #expect(names.contains("screen_list_campaigns"))
        #expect(names.contains("screen_list_tests"))
        #expect(names.contains("screen_get_test"))
        #expect(!names.contains("create_pad"))
    }

    @Test
    func `write tools appear only when writes are enabled`() {
        let names = availableTools(screenEnabled: false, writesEnabled: true).map(\.name)
        #expect(names.contains("create_pad"))
        #expect(names.contains("update_pad"))
        #expect(names.contains("create_question"))
        #expect(names.contains("update_question"))
        #expect(!names.contains("screen_list_campaigns"))
    }

    @Test
    func `both flags advertise the full set with no duplicates`() {
        let names = availableTools(screenEnabled: true, writesEnabled: true).map(\.name)
        #expect(names.count == coderPadReadToolDescriptors.count
            + coderPadScreenToolDescriptors.count + coderPadWriteToolDescriptors.count)
        #expect(Set(names).count == names.count)
    }

    @Test
    func `write tools carry non-read-only annotations; updates are destructive`() {
        let create = tool("create_pad")
        let update = tool("update_pad")
        #expect(create.annotations.readOnlyHint == false)
        #expect(create.annotations.destructiveHint == false)
        #expect(update.annotations.destructiveHint == true)
    }

    @Test
    func `required fields are declared in the right schemas`() {
        #expect(requiredKeys(of: tool("get_pad")) == ["pad"])
        #expect(requiredKeys(of: tool("get_question")) == ["question"])
        #expect(requiredKeys(of: tool("aggregate_pads")) == ["group_by"])
        #expect(requiredKeys(of: tool("create_question")) == ["title"])
        #expect(requiredKeys(of: tool("list_pads")).isEmpty)
    }

    @Test
    func `account selectors declare a maxLength and prefer stable ids`() throws {
        let schema = try property("account", of: "whoami")
        #expect(schema["maxLength"] as? Int == maxAccountSelectorCharacters)
        #expect((schema["description"] as? String)?.contains("stable id") == true)

        let listAccounts = tool("list_accounts")
        #expect(listAccounts.description?.contains("stable id") == true)
    }

    @Test
    func `screen and write tools can require account when defaults cannot invoke them`() throws {
        let descriptors = coderPadToolDescriptors(
            screenEnabled: true,
            writesEnabled: true,
            requireAccountForScreen: true,
            requireAccountForWrites: true,
        )
        let screen = try #require(descriptors.first { $0["name"] as? String == "screen_list_campaigns" })
        let create = try #require(descriptors.first { $0["name"] as? String == "create_pad" })
        let screenRequired = try #require(
            (screen["inputSchema"] as? [String: Any])?["required"] as? [String],
        )
        let createRequired = try #require(
            (create["inputSchema"] as? [String: Any])?["required"] as? [String],
        )
        #expect(screenRequired.contains("account"))
        #expect(createRequired.contains("account"))
    }

    @Test
    func `pagination schemas declare numeric bounds`() throws {
        #expect(try property("page", of: "list_pads")["minimum"] as? Int == 1)
        #expect(try property("page", of: "list_questions")["minimum"] as? Int == 1)
        #expect(try property("start", of: "screen_list_tests")["minimum"] as? Int == 0)
        #expect(try property("campaignId", of: "screen_list_tests")["minimum"] as? Int == 1)
        #expect(try property("limit", of: "screen_list_tests")["minimum"] as? Int == 1)
        #expect(try property("limit", of: "screen_list_tests")["maximum"] as? Int == 50)
        #expect(try property("question", of: "get_question")["minimum"] as? Int == 1)
        #expect(try property("test", of: "screen_get_test")["minimum"] as? Int == 1)
        #expect(try property("question", of: "update_question")["minimum"] as? Int == 1)
        #expect(try property("question_id", of: "create_pad")["minimum"] as? Int == 1)
    }

    @Test
    func `create pad schema declares the title limit`() throws {
        #expect(try property("title", of: "create_pad")["maxLength"] as? Int == maxPadTitleCharacters)
        #expect(try property("title", of: "update_pad")["minLength"] as? Int == 1)
        #expect(try property("title", of: "update_pad")["maxLength"] as? Int == maxPadTitleCharacters)
        #expect(try property("language", of: "create_pad")["enum"] as? [String] == creatablePadLanguages)
        #expect(try property("language", of: "update_pad")["enum"] as? [String] == creatablePadLanguages)
        #expect(try property("language", of: "create_question")["enum"] as? [String] == creatablePadLanguages)
        #expect(try property("contents", of: "create_pad")["maxLength"] == nil)
        #expect(try property("description", of: "create_question")["maxLength"] == nil)
        #expect(
            try (property("contents", of: "create_pad")["description"] as? String)?
                .contains("UTF-8 bytes") == true,
        )
        #expect(try property("title", of: "create_question")["minLength"] as? Int == 1)
        #expect(try property("max_file_chars", of: "get_pad_code")["minimum"] as? Int == 1)
        #expect(try property("team_id", of: "create_pad")["minLength"] as? Int == 36)
        #expect(try inputSchema(of: "create_pad")["additionalProperties"] as? Bool == false)
    }

    @Test
    func `create pad schema rejects conflicting seed sources`() throws {
        let schema = try inputSchema(of: "create_pad")
        let notSchema = try #require(schema["not"] as? [String: Any])
        #expect(notSchema["required"] as? [String] == ["question_id", "contents"])
    }

    @Test
    func `tools encode to valid JSON-RPC tool descriptors`() throws {
        // This mirrors what tools/list serializes onto the wire, so a malformed
        // schema (wrong nesting, non-object inputSchema) is caught here.
        let encoded = try JSONEncoder().encode(tool("get_pad"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
        )
        #expect(object["name"] as? String == "get_pad")
        #expect((object["description"] as? String)?.isEmpty == false)

        let schema = try #require(object["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["properties"] is [String: Any])
        #expect(schema["required"] as? [String] == ["pad"])
    }

    @Test
    func `every advertised tool round-trips through JSON encoding`() throws {
        let encoder = JSONEncoder()
        for descriptor in availableTools(screenEnabled: true, writesEnabled: true) {
            let data = try encoder.encode(descriptor)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["name"] as? String == descriptor.name)
            #expect((object?["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
    }

    // Helpers ----------------------------------------------------------------

    private func tool(_ name: String) -> Tool {
        let all = availableTools(screenEnabled: true, writesEnabled: true)
        return all.first { $0.name == name }!
    }

    private func requiredKeys(of tool: Tool) -> [String] {
        guard case let .object(schema) = tool.inputSchema,
              case let .array(required)? = schema["required"]
        else { return [] }

        return required.compactMap {
            if case let .string(value) = $0 {
                value
            } else {
                nil
            }
        }
    }

    private func property(_ name: String, of toolName: String) throws -> [String: Any] {
        let inputSchema = try inputSchema(of: toolName)
        let properties = try #require(inputSchema["properties"] as? [String: [String: Any]])
        return try #require(properties[name])
    }

    private func inputSchema(of toolName: String) throws -> [String: Any] {
        let descriptor = try #require(
            (coderPadReadToolDescriptors + coderPadScreenToolDescriptors + coderPadWriteToolDescriptors)
                .first { $0["name"] as? String == toolName },
        )
        return try #require(descriptor["inputSchema"] as? [String: Any])
    }
}

// MARK: - Paging

@Suite("Paging")
struct PagingTests {
    @Test
    func `nextPageContinuation distinguishes finished malformed and usable tokens`() {
        #expect(nextPageContinuation(
            "https://app.coderpad.io/api/pads?sort=updated_at,desc&page=2",
        ) == .page("2"))
        #expect(nextPageContinuation("/api/questions/?page=3") == .page("3"))
        #expect(nextPageContinuation("abc") == .page("abc"))
        #expect(nextPageContinuation(2) == .page("2"))
        #expect(nextPageContinuation(0) == .malformed)
        #expect(nextPageContinuation(-1) == .malformed)
        #expect(nextPageContinuation(true) == .malformed)
        #expect(nextPageContinuation(false) == .malformed)
        #expect(nextPageContinuation([1, 2]) == .malformed)
        #expect(nextPageContinuation(["page": 2]) == .malformed)
        #expect(nextPageContinuation(NSNumber(value: 2.5)) == .malformed)
        #expect(nextPageContinuation(String(repeating: "a", count: maxPaginationTokenBytes + 1)) == .malformed)
        #expect(nextPageContinuation("") == .finished)
        #expect(nextPageContinuation(nil) == .finished)
        #expect(nextPageContinuation(NSNull()) == .finished)
    }

    @Test
    func `URL-shaped continuations require exactly one nonempty page parameter`() {
        #expect(nextPageContinuation("https://app.coderpad.io/api/pads") == .malformed)
        #expect(nextPageContinuation("/api/pads/?sort=created_at,desc") == .malformed)
        #expect(nextPageContinuation("https://app.coderpad.io/api/pads?page=2&page=3") == .malformed)
        #expect(nextPageContinuation("https://app.coderpad.io/api/pads?page=&sort=desc") == .malformed)
        #expect(nextPageContinuation("/api/pads/?page=2&page=2") == .malformed)
        #expect(nextPageToken("https://app.coderpad.io/api/pads?page=4") == "4")
    }
}

// MARK: - Filtering and aggregation

@Suite("Filtering and aggregation")
struct AggregationTests {
    private let pads: [[String: Any]] = [
        ["owner_email": "a@x.com", "state": "active", "language": "python", "created_at": "2026-01-04T00:00:00Z"],
        ["owner_email": "A@x.com", "state": "ended", "language": "Python", "created_at": "2026-01-20T00:00:00Z"],
        ["owner_email": "b@x.com", "state": "active", "language": "ruby", "created_at": "2026-02-02T00:00:00Z"],
        ["state": "active", "language": "ruby"], // no owner / no created_at
    ]

    @Test
    func `padMatches is case-insensitive and treats empty filters as wildcards`() {
        #expect(padMatches(pads[0], owner: "A@X.COM", state: nil, language: nil))
        #expect(padMatches(pads[0], owner: nil, state: "active", language: "PYTHON"))
        #expect(!padMatches(pads[0], owner: "b@x.com", state: nil, language: nil))
        #expect(padMatches(pads[0], owner: "", state: "", language: ""))
        #expect(!padMatches(pads[3], owner: "a@x.com", state: nil, language: nil))
    }

    @Test
    func `padMatches folds state synonyms so "active" matches "started" (#1014)`() {
        let started: [String: Any] = ["state": "started", "language": "python3"]
        #expect(padMatches(started, owner: nil, state: "active", language: nil))
        #expect(padMatches(started, owner: nil, state: "Started", language: nil))
        #expect(!padMatches(started, owner: nil, state: "ended", language: nil))
        #expect(padMatches(["state": "finished"], owner: nil, state: "ended", language: nil))

        #expect(canonicalPadState("running") == "active")
        #expect(canonicalPadState("draft") == "pending")
        #expect(canonicalPadState("weird") == "weird")
    }

    @Test
    func `aggregateCounts buckets state by canonical spelling (#1014)`() {
        let raw: [[String: Any]] = [
            ["state": "started"], ["state": "active"], ["state": "finished"], ["state": "ended"],
        ]
        #expect(aggregateCounts(pads: raw, field: "state") == ["active": 2, "ended": 2])
    }

    @Test
    func `filtersEcho includes only non-empty filters`() {
        let echo = filtersEcho(owner: "a@x.com", state: "", language: nil)
        #expect(echo["owner"] as? String == "a@x.com")
        #expect(echo["state"] == nil)
        #expect(echo["language"] == nil)
    }

    @Test
    func `aggregateField normalizes synonyms and rejects unknown`() {
        #expect(aggregateField(for: "owner") == "owner_email")
        #expect(aggregateField(for: "Owner_Email") == "owner_email")
        #expect(aggregateField(for: "language") == "language")
        #expect(aggregateField(for: "created_at") == "month")
        #expect(aggregateField(for: "month") == "month")
        #expect(aggregateField(for: "bogus") == nil)
    }

    @Test
    func `aggregateCounts canonicalizes case-insensitive owner groups`() {
        let counts = aggregateCounts(pads: pads, field: "owner_email")
        #expect(counts["a@x.com"] == 2)
        #expect(counts["A@x.com"] == nil)
        #expect(counts["b@x.com"] == 1)
        #expect(counts[aggregateMissingGroup] == 1)
    }

    @Test
    func `aggregateCounts buckets months by YYYY-MM`() {
        let counts = aggregateCounts(pads: pads, field: "month")
        #expect(counts["2026-01"] == 2)
        #expect(counts["2026-02"] == 1)
        #expect(counts[aggregateMissingGroup] == 1)
    }

    @Test
    func `month buckets and month-date bounds normalize non-UTC created_at (#1034, #1035)`() {
        let offset: [String: Any] = ["created_at": "2024-03-31T23:00:00-05:00"]
        let utc: [String: Any] = ["created_at": "2024-04-01T04:00:00Z"]

        #expect(aggregateCounts(pads: [offset, utc], field: "month") == ["2024-04": 2])
        #expect(withinDateRange(offset, after: "2024-04", before: nil))
        #expect(!withinDateRange(offset, after: nil, before: "2024-03-31"))
        #expect(withinDateRange(offset, after: "2024-04-01", before: "2024-04-01"))
    }

    @Test
    func `topGroups sorts by count desc then key asc, and caps`() {
        let counts = ["python": 5, "ruby": 5, "go": 3, "rust": 1]
        let top = topGroups(counts, limit: 3)
        #expect(top == [
            AggregateGroup(value: "python", count: 5),
            AggregateGroup(value: "ruby", count: 5),
            AggregateGroup(value: "go", count: 3),
        ])
    }

    @Test
    func `withinDateRange honors month, date and timestamp bounds, inclusively`() {
        let pad = pads[0] // created_at 2026-01-04T00:00:00Z
        #expect(withinDateRange(pad, after: nil, before: nil))
        #expect(withinDateRange(pad, after: "", before: ""))
        #expect(withinDateRange(pad, after: "2026-01", before: "2026-01"))
        #expect(!withinDateRange(pad, after: "2026-02", before: nil))
        #expect(!withinDateRange(pad, after: nil, before: "2025-12"))
        #expect(withinDateRange(pad, after: "2026-01-04", before: "2026-01-04"))
        #expect(!withinDateRange(pad, after: "2026-01-05", before: nil))
        #expect(!withinDateRange(pads[3], after: "2026-01", before: nil)) // no created_at
        #expect(withinDateRange(pads[3], after: nil, before: nil))
    }

    @Test
    func `withinDateRange compares timestamp offsets chronologically`() {
        let record = ["created_at": "2026-03-01T00:00:00Z"]

        #expect(withinDateRange(record, after: "2026-03-01T01:00:00+02:00", before: nil))
        #expect(!withinDateRange(record, after: "2026-03-01T03:00:00+02:00", before: nil))
        #expect(withinDateRange(record, after: nil, before: "2026-02-28T22:30:00-02:00"))
        #expect(!withinDateRange(record, after: nil, before: "2026-02-28T21:30:00-02:00"))
    }

    @Test
    func `date bound validation rejects malformed bounds`() {
        #expect(dateBoundValidationError(after: nil, before: "") == nil)
        #expect(dateBoundValidationError(after: "2026-01", before: "2026-01-31") == nil)
        #expect(dateBoundValidationError(after: "2026-01-04T00:00:00Z", before: nil) == nil)
        #expect(dateBoundValidationError(after: "yesterday", before: nil)?.contains("created_after") == true)
        #expect(dateBoundValidationError(after: "2026-99-99", before: nil)?.contains("created_after") == true)
        #expect(dateBoundValidationError(after: nil, before: "2026-02-31")?.contains("created_before") == true)
        #expect(dateBoundValidationError(after: "１２３４-01", before: nil)?.contains("created_after") == true)
        #expect(dateBoundValidationError(after: nil, before: "１２３４-01-01")?.contains("created_before") == true)
    }

    @Test
    func `date filter echo trims bounds and omits whitespace-only values`() {
        var filters: [String: Any] = [:]

        addDateFilters(&filters, after: "   ", before: " 2026-01-31\n")

        #expect(filters["created_after"] == nil)
        #expect(filters["created_before"] as? String == "2026-01-31")
    }

    @Test
    func `compactPads keeps only the compact keys`() {
        let rich: [[String: Any]] = [[
            "id": "abc", "title": "T", "owner_email": "a@x.com", "state": "active",
            "language": "python", "created_at": "2026-01-01", "contents": "huge blob", "notes": "secret",
        ]]
        let compact = compactPads(rich)
        #expect(compact.count == 1)
        #expect(Set(compact[0].keys) == Set(compactPadKeys))
        #expect(compact[0]["contents"] == nil)
        #expect(compact[0]["notes"] == nil)
    }
}

// MARK: - Question filtering and aggregation

@Suite("Question filtering and aggregation")
struct QuestionAggregationTests {
    private let questions: [[String: Any]] = [
        ["owner_email": "a@x.com", "author_name": "Ada", "language": "python",
         "pad_type": "sandbox", "created_at": "2026-01-04T00:00:00Z"],
        ["owner_email": "A@x.com", "author_name": "ada", "language": "Python",
         "pad_type": "take_home", "created_at": "2026-01-20T00:00:00Z"],
        ["owner_email": "b@x.com", "author_name": "Bo", "language": "ruby",
         "pad_type": "sandbox", "created_at": "2026-02-02T00:00:00Z"],
        ["language": "ruby"], // no owner / author / created_at
    ]

    @Test
    func `questionMatches filters by owner, author, language and type, case-insensitively`() {
        #expect(questionMatches(questions[0], owner: "A@X.COM", author: nil, language: nil, type: nil))
        #expect(questionMatches(questions[0], owner: nil, author: "ada", language: "PYTHON", type: nil))
        #expect(questionMatches(questions[1], owner: nil, author: nil, language: nil, type: "TAKE_HOME"))
        #expect(!questionMatches(questions[0], owner: nil, author: "Bo", language: nil, type: nil))
        #expect(questionMatches(questions[0], owner: "", author: "", language: "", type: ""))
        #expect(!questionMatches(questions[3], owner: "a@x.com", author: nil, language: nil, type: nil))
    }

    @Test
    func `questionFiltersEcho includes only non-empty filters`() {
        let echo = questionFiltersEcho(owner: "a@x.com", author: nil, language: "", type: "sandbox")
        #expect(echo["owner"] as? String == "a@x.com")
        #expect(echo["type"] as? String == "sandbox")
        #expect(echo["author"] == nil)
        #expect(echo["language"] == nil)
    }

    @Test
    func `questionAggregateField normalizes synonyms and rejects unknown`() {
        #expect(questionAggregateField(for: "owner") == "owner_email")
        #expect(questionAggregateField(for: "Author") == "author_name")
        #expect(questionAggregateField(for: "type") == "pad_type")
        #expect(questionAggregateField(for: "created_at") == "month")
        #expect(questionAggregateField(for: "state") == nil)
    }

    @Test
    func `aggregateCounts canonicalizes question authors and groups months`() {
        let authors = aggregateCounts(pads: questions, field: "author_name")
        #expect(authors["ada"] == 2)
        #expect(authors["bo"] == 1)
        #expect(authors[aggregateMissingGroup] == 1)

        #expect(aggregateCounts(pads: questions, field: "owner_email")["a@x.com"] == 2)
        #expect(aggregateCounts(pads: questions, field: "language")["python"] == 2)

        let months = aggregateCounts(pads: questions, field: "month")
        #expect(months["2026-01"] == 2)
        #expect(months["2026-02"] == 1)
        #expect(months[aggregateMissingGroup] == 1)
    }

    @Test
    func `compactQuestions keeps only the compact keys`() {
        let rich: [[String: Any]] = [[
            "id": 7, "title": "T", "owner_email": "a@x.com", "author_name": "Ada",
            "language": "python", "pad_type": "sandbox", "is_draft": false,
            "created_at": "2026-01-01", "solution": "secret", "contents": "blob",
        ]]
        let compact = compactQuestions(rich)
        #expect(compact.count == 1)
        #expect(Set(compact[0].keys) == Set(compactQuestionKeys))
        #expect(compact[0]["solution"] == nil)
        #expect(compact[0]["contents"] == nil)
    }
}

// MARK: - Pad code assembly

@Suite("Pad code")
struct PadCodeTests {
    private func ownedEnvironment(
        id: Int,
        padID: String = "abc",
        object: [String: Any],
    ) -> PadCodeEnvironment {
        var object = object
        if object["id"] == nil {
            object["id"] = id
        }
        if object["pad_id"] == nil {
            object["pad_id"] = padID
        }
        return PadCodeEnvironment(id: id, object: object)
    }

    @Test
    func `truncate appends a marker only when over the limit`() {
        #expect(truncate("hello", to: nil) == "hello")
        #expect(truncate("hello", to: 0) == "hello")
        #expect(truncate("hello", to: 10) == "hello")
        // Budgets are UTF-8 bytes (#127/#1588). Nil/non-positive uses the documented
        // default (#126). The marker stays inside the returned budget (#128).
        let unbounded = String(repeating: "x", count: defaultMaxFileChars + 10)
        let truncatedDefault = truncate(unbounded, to: nil)
        #expect(truncatedDefault.contains("more bytes"))
        #expect(truncatedDefault.utf8.count <= defaultMaxFileChars)
        #expect(truncate(unbounded, to: 0).utf8.count <= defaultMaxFileChars)
        let tight = truncate(String(repeating: "a", count: 100), to: 40)
        #expect(tight.utf8.count <= 40)
        #expect(tight.contains("more bytes"))
        let accented = truncate(String(repeating: "é", count: 50), to: 40)
        #expect(accented.utf8.count <= 40)
    }

    @Test
    func `truncate never exceeds the UTF-8 byte budget including the marker`() {
        for limit in [8, 16, 32, 64, 200] {
            let body = String(repeating: "é", count: 200)
            #expect(truncate(body, to: limit).utf8.count <= limit)
        }
    }

    @Test
    func `max file char validation rejects non-positive explicit limits`() {
        #expect(maxFileCharsValidationError(nil) == nil)
        #expect(maxFileCharsValidationError(1) == nil)
        #expect(maxFileCharsValidationError(0) != nil)
        #expect(maxFileCharsValidationError(-1) != nil)
    }

    @Test
    func `synthesizedFilename maps known languages and falls back`() {
        #expect(synthesizedFilename(language: "python") == "main.py")
        #expect(synthesizedFilename(language: "C++") == "main.cpp")
        #expect(synthesizedFilename(language: "ocaml") == "main.ml")
        #expect(synthesizedFilename(language: "nodejs") == "main.js")
        #expect(synthesizedFilename(language: "python2") == "main.py")
        #expect(synthesizedFilename(language: "plaintext") == "main.txt")
        #expect(synthesizedFilename(language: nil) == "main.txt")
        #expect(synthesizedFilename(language: "") == "main.txt")
        for language in creatablePadLanguages {
            let name = synthesizedFilename(language: language)
            #expect(name.hasPrefix("main."))
            let mapped = languageExtensions[language]
            if let mapped {
                #expect(name == "main.\(mapped)")
            }
        }
    }

    @Test
    func `environmentIDs coerces int and string ids and drops duplicates`() {
        let pad: [String: Any] = ["pad_environment_ids": [1, "2", 3, "2", 1, "\n4\t"]]
        #expect(environmentIDs(in: pad) == [1, 2, 3, 4])
        #expect(environmentIDs(in: [:]).isEmpty)
    }

    @Test
    func `malformed environment id containers mark pad code incomplete`() throws {
        let badContainer = padCodePayload(
            id: "abc",
            pad: ["pad_environment_ids": "1,2,3", "contents": "legacy", "language": "python"],
            environments: [],
            maxFileChars: nil,
        )
        #expect(badContainer["incomplete"] as? Bool == true)
        #expect((badContainer["files"] as? [[String: Any]])?.isEmpty == true)
        let errors = try #require(badContainer["schema_errors"] as? [String])
        #expect(errors.contains { $0.contains("pad_environment_ids") })

        let rejected = padCodePayload(
            id: "abc",
            pad: ["pad_environment_ids": [1, true, 2.5, 0, "nope", 2]],
            environments: [],
            maxFileChars: nil,
        )
        #expect(rejected["incomplete"] as? Bool == true)
        #expect(parsePadEnvironmentIDs(in: ["pad_environment_ids": [1, true, 2]]).ids == [1, 2])
        let rejectedErrors = try #require(rejected["schema_errors"] as? [String])
        #expect(rejectedErrors.contains { $0.contains("positive integer") })
    }

    @Test
    func `environment count validation bounds provider fanout`() {
        #expect(environmentCountValidationError(Array(1 ... maxPadCodeEnvironments)) == nil)
        #expect(environmentCountValidationError(Array(1 ... (maxPadCodeEnvironments + 1))) != nil)
        #expect(maxConcurrentPadCodeEnvironmentRequests < maxPadCodeEnvironments)
    }

    @Test
    func `multi-file environments take precedence and carry filenames + ids`() {
        let pad: [String: Any] = ["title": "Interview", "contents": "legacy code", "language": "python"]
        let env = PadCodeEnvironment(id: 9, object: [
            "language": "javascript",
            "file_contents": [
                ["path": "index.js", "contents": "console.log(1)"],
                ["contents": "no path here"],
            ],
        ])
        let files = padCodeFiles(pad: pad, environments: [env], maxFileChars: nil)
        #expect(files.count == 2)
        #expect(files[0]["filename"] as? String == "index.js")
        #expect(files[0]["language"] as? String == "javascript")
        #expect(files[0]["environment_id"] as? Int == 9)
        #expect(files[1]["filename"] as? String == "main.js")
        #expect(!files.contains { ($0["contents"] as? String) == "legacy code" })
    }

    @Test
    func `legacy single-file pad is the fallback when no environment files exist`() {
        let pad: [String: Any] = ["title": "Legacy", "contents": "print('hi')", "language": "python"]
        let files = padCodeFiles(pad: pad, environments: [], maxFileChars: nil)
        #expect(files.count == 1)
        #expect(files[0]["filename"] as? String == "main.py")
        #expect(files[0]["contents"] as? String == "print('hi')")
    }

    @Test
    func `declared environments never fall back to stale legacy contents`() {
        let pad: [String: Any] = [
            "contents": "stale legacy code",
            "pad_environment_ids": [1, 2],
        ]
        let files = padCodeFiles(pad: pad, environments: [], maxFileChars: nil)
        let payload = padCodePayload(id: "abc", pad: pad, environments: [], maxFileChars: nil)
        #expect(files.isEmpty)
        #expect((payload["files"] as? [[String: Any]])?.isEmpty == true)
        #expect(payload["incomplete"] as? Bool == true)
        #expect(payload["missing_environment_ids"] as? [Int] == [1, 2])
    }

    @Test
    func `empty pad yields no files`() {
        let files = padCodeFiles(pad: ["title": "Empty"], environments: [], maxFileChars: nil)
        #expect(files.isEmpty)
    }

    @Test
    func `max_file_chars truncates each file's contents within the byte budget`() {
        let pad: [String: Any] = [
            "contents": String(repeating: "0123456789abcdef", count: 8),
            "language": "python",
        ]
        let files = padCodeFiles(pad: pad, environments: [], maxFileChars: 40)
        let contents = files[0]["contents"] as? String ?? ""
        #expect(contents.contains("more bytes"))
        #expect(contents.utf8.count <= 40)
    }

    @Test
    func `padCodePayload wraps id, title, and files`() {
        let pad: [String: Any] = ["title": "T", "contents": "x", "language": "python"]
        let payload = padCodePayload(id: "abc123", pad: pad, environments: [], maxFileChars: nil)
        #expect(payload["pad_id"] as? String == "abc123")
        #expect(payload["title"] as? String == "T")
        #expect((payload["files"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func `pad titles strip Unicode format controls`() {
        let payload = padCodePayload(
            id: "pad\u{202E}id",
            pad: ["title": "Title\u{2066}hidden", "contents": "x", "language": "python"],
            environments: [],
            maxFileChars: nil,
        )
        #expect(payload["pad_id"] as? String == "padid")
        #expect(payload["title"] as? String == "Titlehidden")
    }

    @Test
    func `padCodePayload reports files omitted by aggregate budgets`() throws {
        let fileContents: [[String: Any]] = (0 ... maxPadCodeFiles).map {
            ["path": "file-\($0).txt", "contents": "x"]
        }
        let environment = ownedEnvironment(id: 7, object: ["file_contents": fileContents])
        let payload = padCodePayload(id: "abc", pad: [:], environments: [environment], maxFileChars: nil)
        let files = try #require(payload["files"] as? [[String: Any]])
        #expect(files.count == maxPadCodeFiles)
        #expect(payload["incomplete"] as? Bool == true)
        #expect(payload["omitted_file_count"] as? Int == 1)
        #expect(payload["omitted_environment_ids"] as? [Int] == [7])
    }

    @Test
    func `padCodePayload bounds aggregate content bytes`() throws {
        let fileContents: [[String: Any]] = (0 ..< 6).map {
            ["path": "file-\($0).txt", "contents": String(repeating: "x", count: defaultMaxFileChars)]
        }
        let environment = ownedEnvironment(id: 9, object: ["file_contents": fileContents])
        let payload = padCodePayload(id: "abc", pad: [:], environments: [environment], maxFileChars: nil)
        let files = try #require(payload["files"] as? [[String: Any]])
        let contentBytes = files.compactMap { $0["contents"] as? String }.reduce(0) { $0 + $1.utf8.count }
        #expect(contentBytes <= maxPadCodeContentBytes)
        #expect((payload["omitted_file_count"] as? Int ?? 0) >= 1)
        #expect(payload["omitted_environment_ids"] as? [Int] == [9])
    }

    @Test
    func `binary files are kept after the text content budget is exhausted`() {
        let huge = String(repeating: "x", count: maxPadCodeContentBytes)
        let environment = PadCodeEnvironment(id: 1, object: [
            "file_contents": [
                ["path": "big.txt", "contents": huge],
                ["path": "asset.bin", "binary": true],
            ],
        ])
        let files = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)
        #expect(files.count == 2)
        #expect(files[1]["binary"] as? Bool == true)
    }

    @Test
    func `missing and null nonbinary contents are schema errors`() throws {
        let env = ownedEnvironment(id: 1, object: [
            "file_contents": [
                ["path": "missing.py"],
                ["path": "null.py", "contents": NSNull()],
                ["path": "ok.py", "contents": "print(1)"],
                ["path": "bin.dat", "binary": true],
                ["path": "bad-flag.py", "contents": "x", "binary": "yes"],
            ],
        ])
        let payload = padCodePayload(id: "abc", pad: [:], environments: [env], maxFileChars: nil)
        #expect(payload["incomplete"] as? Bool == true)
        let files = try #require(payload["files"] as? [[String: Any]])
        #expect(files.contains { ($0["filename"] as? String) == "missing.py" && $0["error"] != nil })
        #expect(files.contains { ($0["filename"] as? String) == "null.py" && $0["error"] != nil })
        #expect(files.contains { ($0["filename"] as? String) == "ok.py" && ($0["contents"] as? String) == "print(1)" })
        #expect(files.contains { ($0["filename"] as? String) == "bin.dat" && ($0["binary"] as? Bool) == true })
        #expect(files.contains { ($0["filename"] as? String) == "bad-flag.py" && $0["error"] != nil })
    }

    @Test
    func `missing environment file_contents marks the payload incomplete`() throws {
        let environment = ownedEnvironment(id: 4, object: [:])
        let payload = padCodePayload(id: "abc", pad: [:], environments: [environment], maxFileChars: nil)
        let errors = try #require(payload["schema_errors"] as? [String])
        #expect(payload["incomplete"] as? Bool == true)
        #expect(errors == ["Environment 4 is missing file_contents."])
    }

    @Test
    func `unsafe paths and languages are reported while keeping safe fallbacks`() throws {
        let environment = ownedEnvironment(id: 5, object: [
            "file_contents": [
                ["path": "../secret.py", "language": "bad\nlang", "contents": "x"],
                ["path": "src//main.py", "contents": "y"],
                ["path": "src/", "contents": "z"],
            ],
        ])
        let payload = padCodePayload(id: "abc", pad: [:], environments: [environment], maxFileChars: nil)
        let files = try #require(payload["files"] as? [[String: Any]])
        let errors = try #require(payload["schema_errors"] as? [String])
        #expect(payload["incomplete"] as? Bool == true)
        #expect(files.count == 3)
        #expect(errors.contains { $0.contains("file path was unsafe") })
        #expect(errors.contains { $0.contains("language metadata was malformed") })
    }

    @Test
    func `flattened ancestor conflicts stay within the component byte limit`() {
        let path = String(repeating: "a", count: 128) + "/" + String(repeating: "b", count: 127)
        #expect(path.utf8.count == 256)
        let environment = PadCodeEnvironment(id: 1, object: [
            "file_contents": [
                ["path": String(repeating: "a", count: 128), "contents": "file"],
                ["path": path, "contents": "nested"],
            ],
        ])
        let names = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)
            .compactMap { $0["filename"] as? String }
        #expect(names.count == 2)
        #expect(names[1].utf8.count <= maxPadCodePathComponentBytes)
        #expect(!names[1].contains("/"))
    }

    @Test
    func `duplicate nested filenames stay within the total path byte limit`() {
        let directory = String(repeating: "d", count: 200)
        let file = String(repeating: "f", count: 55)
        let path = "\(directory)/\(file)"
        #expect(path.utf8.count == 256)
        let environment = PadCodeEnvironment(id: 1, object: [
            "file_contents": [
                ["path": path, "contents": "one"],
                ["path": path, "contents": "two"],
            ],
        ])
        let names = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)
            .compactMap { $0["filename"] as? String }
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.utf8.count <= maxPadCodePathBytes })
        #expect(names[1].contains("-2"))
    }

    @Test
    func `padCodePayload marks failed environment fetches as incomplete`() {
        let pad: [String: Any] = ["title": "T", "pad_environment_ids": [1, 2]]
        let env = ownedEnvironment(id: 1, object: [
            "file_contents": [["path": "a.py", "contents": "print(1)"]],
        ])
        let payload = padCodePayload(
            id: "abc", pad: pad, environments: [env], maxFileChars: nil, failedEnvironmentIDs: [2],
        )
        #expect(payload["incomplete"] as? Bool == true)
        #expect(payload["missing_environment_ids"] as? [Int] == [2])
        #expect((payload["files"] as? [[String: Any]])?.count == 1)

        let derived = padCodePayload(id: "abc", pad: pad, environments: [env], maxFileChars: nil)
        #expect(derived["incomplete"] as? Bool == true)
        #expect(derived["missing_environment_ids"] as? [Int] == [2])

        let both = [
            env,
            ownedEnvironment(id: 2, object: ["file_contents": [] as [[String: Any]]]),
        ]
        let complete = padCodePayload(id: "abc", pad: pad, environments: both, maxFileChars: nil)
        #expect(complete["incomplete"] == nil)
        #expect(complete["missing_environment_ids"] == nil)
    }

    @Test
    func `environment response id and pad ownership mismatches are incomplete`() throws {
        let wrongID = ownedEnvironment(id: 1, object: [
            "id": 99,
            "file_contents": [["path": "a.py", "contents": "stolen"]],
        ])
        let wrongPad = ownedEnvironment(id: 2, object: [
            "pad_id": "other-pad",
            "file_contents": [["path": "b.py", "contents": "leak"]],
        ])
        let payload = padCodePayload(
            id: "abc",
            pad: ["pad_environment_ids": [1, 2]],
            environments: [wrongID, wrongPad],
            maxFileChars: nil,
        )
        let errors = try #require(payload["schema_errors"] as? [String])
        #expect(payload["incomplete"] as? Bool == true)
        #expect((payload["files"] as? [[String: Any]])?.isEmpty == true)
        #expect(errors.contains { $0.contains("response id did not match") })
        #expect(errors.contains { $0.contains("belongs to a different pad") })
    }

    @Test
    func `padCodePayload reports malformed environment file contents`() throws {
        let environment = ownedEnvironment(id: 7, object: ["file_contents": "not-an-array"])
        let payload = padCodePayload(id: "abc", pad: [:], environments: [environment], maxFileChars: nil)
        let errors = try #require(payload["schema_errors"] as? [String])
        #expect(payload["incomplete"] as? Bool == true)
        #expect((payload["files"] as? [[String: Any]])?.isEmpty == true)
        #expect(errors == ["Environment 7 file_contents was not an array of file objects."])
    }

    @Test
    func `padCodePayload reports malformed legacy contents`() throws {
        let payload = padCodePayload(
            id: "abc",
            pad: ["contents": ["not": "a string"]],
            environments: [],
            maxFileChars: nil,
        )
        let errors = try #require(payload["schema_errors"] as? [String])
        #expect(payload["incomplete"] as? Bool == true)
        #expect((payload["files"] as? [[String: Any]])?.isEmpty == true)
        #expect(errors == ["The legacy pad contents were not a string in the API response."])
    }

    @Test
    func `jsonObject parses objects and rejects non-objects`() {
        #expect(jsonObject(#"{"a":1}"#)?["a"] as? Int == 1)
        #expect(jsonObject("[1,2,3]") == nil)
        #expect(jsonObject("not json") == nil)
    }

    @Test
    func `an APIResponse exposes the same body whether built from bytes or text (#2120)`() {
        let fromBytes = APIResponse(status: 200, data: Data(#"{"a":1}"#.utf8))
        #expect(fromBytes.body == #"{"a":1}"#)
        #expect(jsonObject(fromBytes.data)?["a"] as? Int == 1)

        let fromText = APIResponse(status: 0, body: "Request failed")
        #expect(fromText.body == "Request failed")
        #expect(jsonObject(fromText.data) == nil)
    }

    @Test
    func `JSON response validation rejects successful proxy pages`() {
        #expect(isValidJSON(Data(#"{"quota":1}"#.utf8)))
        #expect(isValidJSON(Data("[1,2,3]".utf8)))
        #expect(!isValidJSON(Data("<html>Sign in</html>".utf8)))
        #expect(!isValidJSON(Data([0xFF])))
    }
}
