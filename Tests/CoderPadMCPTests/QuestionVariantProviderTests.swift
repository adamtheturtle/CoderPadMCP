@testable import CoderPadMCP
import Foundation
import MCP
import Testing

private actor VariantRequestProbe {
    var calls = 0
    var invalidations: [String] = []
    func requested() {
        calls += 1
    }

    func invalidated(_ kind: CoderPadMCPRecordKind, _ account: String) {
        invalidations.append("\(kind.rawValue):\(account)")
    }

    func count() -> Int {
        calls
    }

    func cleared() -> [String] {
        invalidations
    }
}

@Suite("Question variant provider")
struct QuestionVariantProviderTests {
    @Test(arguments: ["list_question_variants", "get_question_variant"])
    func `reads use nested identities and preserve nullable environment metadata`(tool: String) async throws {
        let payload = #"""
        {
          "id": 3,
          "question_id": 42,
          "language": null,
          "project_template_id": 12,
          "project_template_slug": "react",
          "contents": null,
          "file_contents": [],
          "solution": ""
        }
        """#
        let probe = VariantRequestProbe()
        let provider = try provider(writes: false, probe: probe) { method, path, account, query, body, limit in
            await probe.requested()
            #expect(method == "GET")
            #expect(path == "/api/questions/42/variants" + (tool == "get_question_variant" ? "/3" : ""))
            #expect(account.apiKey == "selected-key")
            #expect(account.baseURL.absoluteString == "https://configured.example")
            #expect(query == [])
            #expect(body == nil)
            #expect(limit == 8 * 1024 * 1024)
            return APIResponse(status: 200, body: payload)
        }
        var arguments: [String: Value] = ["question": .int(42)]
        if tool == "get_question_variant" {
            arguments["variant"] = .int(3)
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError != true)
        #expect(try text(result) == payload)
        #expect(await probe.count() == 1)
        #expect(await probe.cleared() == [])
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func `create distinguishes omitted empty null reset and structured overlays`(option: Int) async throws {
        let probe = VariantRequestProbe()
        var arguments: [String: Value] = ["question": .int(42), "language": .string("react"), "solution": .string("")]
        var expected: [String: Any] = ["language": "react", "solution": ""]
        switch option {
        case 1:
            arguments["contents"] = .string("")
            expected["contents"] = ""
        case 2:
            arguments["contents"] = .null
            expected["contents"] = NSNull()
        case 3:
            arguments["file_contents"] = .array([])
            expected["file_contents"] = [[String: Any]]()
        case 4:
            arguments["file_contents"] = .array([
                .object(["path": .string("src/main.js"), "contents": .string(""), "hidden": .bool(false), "deleted": .bool(false)]),
                .object(["path": .string("src/template.js"), "deleted": .bool(true)]),
            ])
            expected["file_contents"] = [
                ["path": "src/main.js", "contents": "", "hidden": false, "deleted": false],
                ["path": "src/template.js", "deleted": true],
            ]
        default: break
        }
        let expectedData = try JSONSerialization.data(withJSONObject: expected)
        let provider = try provider(writes: true, probe: probe) { method, path, _, query, body, limit in
            await probe.requested()
            #expect(method == "POST")
            #expect(path == "/api/questions/42/variants")
            #expect(query == [])
            #expect(limit == 1024 * 1024)
            let actual = try #require(body)
            #expect(try JSONSerialization.jsonObject(with: actual) as? NSDictionary
                == JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
            return APIResponse(status: 201, body: #"{"id":3,"question_id":42,"language":null}"#)
        }
        let result = try await provider.callTool("create_question_variant", arguments: arguments)
        #expect(result.isError != true)
        #expect(await probe.count() == 1)
        #expect(await probe.cleared() == ["questions:chosen"])
    }

    @Test
    func `update dry run exposes exact PUT without transport or cache changes`() async throws {
        let probe = VariantRequestProbe()
        let provider = try provider(writes: true, probe: probe) { _, _, _, _, _, _ in
            await probe.requested()
            return APIResponse(status: 500, body: "unexpected")
        }
        let result = try await provider.callTool("update_question_variant", arguments: [
            "question": .int(42), "variant": .int(3), "contents": .null, "dry_run": .bool(true),
        ])
        #expect(result.isError != true)
        #expect(try object(result) == NSDictionary(dictionary: [
            "dry_run": true, "changed": false, "method": "PUT", "path": "/api/questions/42/variants/3",
            "body": ["contents": NSNull()],
        ]))
        #expect(await probe.count() == 0)
        #expect(await probe.cleared() == [])
    }

    @Test(arguments: [200, 400, 403, 404, 409, 500])
    func `updates run once and only successful writes invalidate questions`(status: Int) async throws {
        let probe = VariantRequestProbe()
        let provider = try provider(writes: true, probe: probe) { method, path, _, _, body, _ in
            await probe.requested()
            #expect(method == "PUT")
            #expect(path == "/api/questions/42/variants/3")
            let actual = try #require(body)
            let decoded = try JSONSerialization.jsonObject(with: actual) as? NSDictionary
            #expect(decoded == NSDictionary(dictionary: ["solution": "answer"]))
            return APIResponse(status: status, body: status == 200
                ? #"{"id":3,"question_id":42,"contents":null,"language":"python"}"# : #"{"message":"denied"}"#)
        }
        let result = try await provider.callTool("update_question_variant", arguments: [
            "question": .int(42), "variant": .int(3), "solution": .string("answer"),
        ])
        #expect(result.isError == (status == 200 ? nil : true))
        #expect(await probe.count() == 1)
        #expect(await probe.cleared() == (status == 200 ? ["questions:chosen"] : []))
    }

    @Test(arguments: [
        ["contents": Value.string(""), "file_contents": .array([])],
        ["contents": .bool(false)], ["file_contents": .null], ["language": .string(" ")],
        ["file_contents": .array([.object(["path": .string("../file"), "contents": .string("")])])],
        ["file_contents": .array([.object(["path": .string(".cpad"), "deleted": .bool(true)])])],
        ["file_contents": .array([.object(["path": .string("file"), "hidden": .string("false"), "contents": .string("")])])],
        ["file_contents": .array([.object(["path": .string("file")])])],
        ["file_contents": .array([.object(["path": .string("file"), "contents": .string(""), "unknown": .bool(true)])])],
        ["dry_run": .null], ["dryrun": .bool(true)], ["variant": .double(1.5)],
        ["question": .int(0)], ["variant": .int(0)], [:],
    ])
    func `invalid mutation inputs fail before transport`(fields: [String: Value]) async throws {
        let probe = VariantRequestProbe()
        let provider = try provider(writes: true, probe: probe) { _, _, _, _, _, _ in
            await probe.requested()
            return APIResponse(status: 500, body: "unexpected")
        }
        let arguments = ["question": Value.int(42), "variant": .int(3)].merging(fields) { _, new in new }
        #expect(try await provider.callTool("update_question_variant", arguments: arguments).isError == true)
        #expect(await probe.count() == 0)
    }

    @Test
    func `write opt in applies to invocation and catalog without exposing deletion`() async throws {
        let probe = VariantRequestProbe()
        let provider = try provider(writes: false, probe: probe) { _, _, _, _, _, _ in
            await probe.requested()
            return APIResponse(status: 500, body: "unexpected")
        }
        let names = await provider.tools().map(\.name)
        #expect(names.contains("list_question_variants"))
        #expect(names.contains("create_question_variant") == false)
        #expect(try await provider.callTool("create_question_variant", arguments: [
            "question": .int(42), "language": .string("python"), "dry_run": .bool(true),
        ]).isError == true)
        #expect(try await provider.callTool("delete_question_variant", arguments: nil).isError == true)
        #expect(await probe.count() == 0)
    }

    @Test(arguments: [0, 1, 2])
    func `file count string and aggregate encoding budgets fail before writes`(option: Int) async throws {
        let probe = VariantRequestProbe()
        let provider = try provider(writes: true, probe: probe) { _, _, _, _, _, _ in
            await probe.requested()
            return APIResponse(status: 500, body: "unexpected")
        }
        var arguments: [String: Value] = ["question": .int(42), "language": .string("python")]
        if option == 0 {
            arguments["contents"] = .string(String(repeating: "a", count: maxMCPWriteFieldBytes + 1))
        } else if option == 1 {
            arguments["file_contents"] = .array(Array(repeating: .object(["path": .string("file"), "contents": .string("")]), count: 201))
        } else {
            arguments["file_contents"] = .array([
                .object(["path": .string("file"), "contents": .string(String(repeating: "\n", count: maxMCPWriteFieldBytes))]),
            ])
        }
        #expect(try await provider.callTool("create_question_variant", arguments: arguments).isError == true)
        #expect(await probe.count() == 0)
    }

    @Test
    func `variant schemas advertise reset semantics and write annotations`() throws {
        let tools = availableTools(screenEnabled: false, writesEnabled: true)
        let create = try #require(tools.first { $0.name == "create_question_variant" })
        let update = try #require(tools.first { $0.name == "update_question_variant" })
        #expect(create.annotations.readOnlyHint == false)
        #expect(create.annotations.destructiveHint == false)
        #expect(update.annotations.destructiveHint == true)
        guard case let .object(schema) = create.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(contents)? = properties["contents"],
              case let .object(files)? = properties["file_contents"]
        else {
            Issue.record("Missing variant mutation schema")
            return
        }
        #expect(schema["required"] == .array([.string("question"), .string("language")]))
        #expect(contents["type"] == .array([.string("string"), .string("null")]))
        #expect(files["type"] == .string("array"))
        #expect(files["maxItems"] == .int(200))
    }

    @Test(arguments: [false, true])
    func `maximum field byte count is accepted for code and files`(project: Bool) async throws {
        let probe = VariantRequestProbe()
        let contents = String(repeating: "a", count: maxMCPWriteFieldBytes)
        let provider = try provider(writes: true, probe: probe) { _, _, _, _, body, _ in
            await probe.requested()
            let data = try #require(body)
            #expect(data.count <= maxMCPWriteBodyBytes)
            return APIResponse(status: 201, body: #"{"id":3,"question_id":42}"#)
        }
        var arguments: [String: Value] = ["question": .int(42), "language": .string("python")]
        if project {
            arguments["file_contents"] = .array([.object(["path": .string("file"), "contents": .string(contents)])])
        } else {
            arguments["contents"] = .string(contents)
        }
        #expect(try await provider.callTool("create_question_variant", arguments: arguments).isError != true)
        #expect(await probe.count() == 1)
    }

    private func provider(writes: Bool, probe: VariantRequestProbe, request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let account = try MCPAccount(id: "chosen", name: "Chosen", apiKey: "selected-key",
                                     baseURL: #require(URL(string: "https://configured.example")),
                                     screenAPIKey: nil, screenRegion: "us")
        let cache = CoderPadMCPCache(load: { _, _, _ in nil }, invalidate: { await probe.invalidated($0, $1) })
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: writes),
                                    cache: cache, interviewRequest: request)
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return text
    }

    private func object(_ result: CallTool.Result) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? NSDictionary)
    }
}
