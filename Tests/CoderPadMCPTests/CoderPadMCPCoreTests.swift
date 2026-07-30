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
    func `pagination validation rejects invalid domains`() {
        #expect(pageValidationError(nil) == nil)
        #expect(pageValidationError(1) == nil)
        #expect(pageValidationError(0)?.contains("page") == true)
        #expect(screenPaginationValidationError(start: 0, limit: 1) == nil)
        #expect(screenPaginationValidationError(start: -1, limit: nil)?.contains("start") == true)
        #expect(screenPaginationValidationError(start: nil, limit: 0)?.contains("limit") == true)
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
    func `pagination schemas declare numeric minima`() throws {
        #expect(try property("page", of: "list_pads")["minimum"] as? Int == 1)
        #expect(try property("page", of: "list_questions")["minimum"] as? Int == 1)
        #expect(try property("start", of: "screen_list_tests")["minimum"] as? Int == 0)
        #expect(try property("limit", of: "screen_list_tests")["minimum"] as? Int == 1)
        #expect(try property("question", of: "get_question")["minimum"] as? Int == 1)
        #expect(try property("test", of: "screen_get_test")["minimum"] as? Int == 1)
        #expect(try property("question", of: "update_question")["minimum"] as? Int == 1)
        #expect(try property("question_id", of: "create_pad")["minimum"] as? Int == 1)
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
    func `nextPageToken reads continuation URLs strings and ints, nil when absent or empty`() {
        #expect(nextPageToken(
            "https://app.coderpad.io/api/pads?sort=updated_at,desc&page=2",
        ) == "2")
        #expect(nextPageToken("/api/questions/?page=3") == "3")
        #expect(nextPageToken("abc") == "abc")
        #expect(nextPageToken(2) == "2")
        #expect(nextPageToken("") == nil)
        #expect(nextPageToken(nil) == nil)
        #expect(nextPageToken(NSNull()) == nil)
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
    @Test
    func `truncate appends a marker only when over the limit`() {
        #expect(truncate("hello", to: nil) == "hello")
        #expect(truncate("hello", to: 0) == "hello")
        #expect(truncate("hello", to: 10) == "hello")
        let cut = truncate("hello", to: 3)
        #expect(cut.hasPrefix("hel"))
        #expect(cut.contains("2 more bytes"))
        // Budgets are UTF-8 bytes, cut on a character boundary (#1588), and a
        // nil/non-positive limit means the bounded default, not unlimited (#1589).
        #expect(truncate("é1234", to: 3) == "é1\n… [truncated, 3 more bytes]")
        let unbounded = String(repeating: "x", count: defaultMaxFileChars + 10)
        #expect(truncate(unbounded, to: nil).contains("10 more bytes"))
        #expect(truncate(unbounded, to: 0).contains("10 more bytes"))
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
        #expect(synthesizedFilename(language: "ocaml") == "main.ocaml")
        #expect(synthesizedFilename(language: nil) == "main.txt")
        #expect(synthesizedFilename(language: "") == "main.txt")
    }

    @Test
    func `environmentIDs coerces int and string ids and drops duplicates`() {
        let pad: [String: Any] = ["pad_environment_ids": [1, "2", 3, "2", 1]]
        #expect(environmentIDs(in: pad) == [1, 2, 3])
        #expect(environmentIDs(in: [:]).isEmpty)
    }

    @Test
    func `multi-file environments take precedence and carry filenames + ids`() {
        let pad: [String: Any] = ["title": "Interview", "contents": "legacy code", "language": "python"]
        let env = PadCodeEnvironment(id: 9, object: [
            "language": "javascript",
            "file_contents": [
                ["path": "index.js", "contents": "console.log(1)"],
                ["contents": "no path here"], // inherits env language -> synthesized name
            ],
        ])
        let files = padCodeFiles(pad: pad, environments: [env], maxFileChars: nil)
        #expect(files.count == 2)
        #expect(files[0]["filename"] as? String == "index.js")
        #expect(files[0]["language"] as? String == "javascript")
        #expect(files[0]["environment_id"] as? Int == 9)
        #expect(files[1]["filename"] as? String == "main.js")
        // The legacy single-file contents must NOT appear when env files exist.
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
    func `max_file_chars truncates each file's contents`() {
        let pad: [String: Any] = ["contents": "0123456789", "language": "python"]
        let files = padCodeFiles(pad: pad, environments: [], maxFileChars: 4)
        let contents = files[0]["contents"] as? String ?? ""
        #expect(contents.hasPrefix("0123"))
        #expect(contents.contains("6 more bytes"))
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
    func `padCodePayload marks failed environment fetches as incomplete`() {
        let pad: [String: Any] = ["title": "T", "pad_environment_ids": [1, 2]]
        let env = PadCodeEnvironment(id: 1, object: [
            "file_contents": [["path": "a.py", "contents": "print(1)"]],
        ])
        let payload = padCodePayload(
            id: "abc", pad: pad, environments: [env], maxFileChars: nil, failedEnvironmentIDs: [2],
        )
        #expect(payload["incomplete"] as? Bool == true)
        #expect(payload["missing_environment_ids"] as? [Int] == [2])
        #expect((payload["files"] as? [[String: Any]])?.count == 1)

        // Completeness is derived from the pad's referenced environments, not
        // just the caller's report: environment 2 was never fetched, so the
        // payload is incomplete even with no failed ids reported (#1598).
        let derived = padCodePayload(id: "abc", pad: pad, environments: [env], maxFileChars: nil)
        #expect(derived["incomplete"] as? Bool == true)
        #expect(derived["missing_environment_ids"] as? [Int] == [2])

        let both = [env, PadCodeEnvironment(id: 2, object: [:])]
        let complete = padCodePayload(id: "abc", pad: pad, environments: both, maxFileChars: nil)
        #expect(complete["incomplete"] == nil)
        #expect(complete["missing_environment_ids"] == nil)
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
}
