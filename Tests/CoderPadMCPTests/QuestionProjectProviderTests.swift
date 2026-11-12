@testable import CoderPadMCP
import CoderPadToolCore
import Foundation
import MCP
import Testing

@Suite("Parent question project files")
struct QuestionProjectProviderTests {
    @Test(arguments: ["create_question", "update_question"])
    func `structured files use JSON strings under the question object`(tool: String) async throws {
        let provider = try provider { method, path, account, query, body, limit in
            #expect(method == (tool == "create_question" ? "POST" : "PUT"))
            #expect(path == "/api/questions/" + (tool == "update_question" ? "42" : ""))
            #expect(account.apiKey == "project-key")
            #expect(query == [])
            #expect(limit == 1024 * 1024)
            let data = try #require(body)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let question = try #require(root["question"] as? [String: Any])
            #expect(question["language"] as? String == "multifile_custom")
            let encoded = try #require(question["file_contents"] as? String)
            let files = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? NSArray)
            #expect(files == NSArray(array: [
                ["path": "src/old.py", "deleted": true],
                ["path": "src/main.py", "contents": "", "hidden": false, "deleted": false],
            ]))
            #expect(root["contents"] == nil)
            #expect(root["file_contents"] == nil)
            return APIResponse(status: 200, body: #"{"id":42,"file_contents":[]}"#)
        }
        var arguments: [String: Value] = ["language": .string("multifile_custom"), "file_contents": .array([
            .object(["path": .string("src/old.py"), "deleted": .bool(true)]),
            .object(["path": .string("src/main.py"), "contents": .string(""), "hidden": .bool(false), "deleted": .bool(false)]),
        ])]
        if tool == "create_question" {
            arguments["title"] = .string("Project")
        } else {
            arguments["question"] = .int(42)
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError != true)
    }

    @Test
    func `empty arrays remain explicit and single-file requests keep their shape`() async throws {
        let provider = try provider { _, _, _, _, _, _ in
            Issue.record("Dry runs must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let empty = try await provider.callTool("update_question", arguments: [
            "question": .int(42), "file_contents": .array([]), "dry_run": .bool(true),
        ])
        let emptyPreview = try object(empty)
        #expect(emptyPreview["body"] as? NSDictionary == NSDictionary(dictionary: ["question": ["file_contents": "[]"]]))
        let single = try await provider.callTool("create_question", arguments: [
            "title": .string("Single"), "language": .string("python"), "contents": .string("print(1)"), "dry_run": .bool(true),
        ])
        let singlePreview = try object(single)
        #expect(singlePreview["body"] as? NSDictionary == NSDictionary(dictionary: [
            "question": ["title": "Single", "language": "python"], "contents": "print(1)",
        ]))
    }

    @Test(arguments: ["create_question", "update_question"])
    func `unsafe malformed conflicting and oversized files fail locally`(tool: String) async throws {
        let provider = try provider { _, _, _, _, _, _ in
            Issue.record("Invalid files must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let file: Value = .object(["path": .string("main.py"), "contents": .string("x")])
        var invalid: [[String: Value]] = [
            ["file_contents": .string("[]")], ["file_contents": .null],
            ["contents": .string("x"), "file_contents": .array([])], ["file_contents": .array([file, file])],
            ["file_contents": .array([.object(["path": .string("main.py")])])],
            ["file_contents": .array([.object(["path": .string(".cpad"), "deleted": .bool(true)])])],
            ["file_contents": .array([.object(["path": .string("main.py"), "contents": .string("x"), "hidden": .string("false")])])],
            ["file_contents": .array([.object(["path": .string("main.py"), "contents": .string("x"), "unknown": .bool(false)])])],
            ["file_contents": .array(Array(repeating: file, count: 201))],
            ["language": .string(" ")], ["language": .bool(false)],
        ]
        for path in ["../x", "/x", "a/../x", "a//x", "a\\x", "a:x", "a\u{0000}x", String(repeating: "a", count: 1025)] {
            invalid.append(["file_contents": .array([.object(["path": .string(path), "contents": .string("x")])])])
        }
        invalid.append(["file_contents": .array([.object([
            "path": .string("main.py"), "contents": .string(String(repeating: "a", count: 524_289)),
        ])])])
        for var arguments in invalid {
            if tool == "create_question" {
                arguments["title"] = .string("Project")
            } else {
                arguments["question"] = .int(42)
            }
            let result = try await provider.callTool(tool, arguments: arguments)
            #expect(result.isError == true)
        }
    }

    @Test
    func `project catalog permits template slugs with bounded file descriptors`() {
        #expect(questionProjectProperties["language"]?["enum"] == nil)
        #expect(questionProjectProperties["language"]?["maxLength"] as? Int == 100)
        #expect(questionProjectProperties["file_contents"]?["maxItems"] as? Int == 200)
    }

    @Test
    func `project pad creation retains overlay flags and rejects conflicting seeds`() async throws {
        let provider = try provider { method, path, _, _, body, _ in
            #expect(method == "POST")
            #expect(path == "/api/pads/")
            let data = try #require(body)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(root["language"] as? String == "multifile_python")
            let files = try #require(root["file_contents"] as? String)
            #expect(try (JSONSerialization.jsonObject(with: Data(files.utf8)) as? NSArray)?.count == 2)
            return APIResponse(status: 200, body: #"{"id":"abcdefgh","language":null,"pad_environment_ids":[42]}"#)
        }
        let files: Value = .array([
            .object(["path": .string("main.py"), "contents": .string(""), "hidden": .bool(true)]),
            .object(["path": .string("old.py"), "deleted": .bool(true)]),
        ])
        let valid = try await provider.callTool("create_pad", arguments: [
            "language": .string("multifile_python"), "file_contents": files,
        ])
        #expect(valid.isError != true)
        for seed: [String: Value] in [["question_id": .int(42)], ["contents": .string("x")]] {
            let result = try await provider.callTool("create_pad", arguments: seed.merging([
                "file_contents": files, "dry_run": .bool(true),
            ]) { _, new in new })
            #expect(result.isError == true)
        }
    }

    @Test(arguments: ["list_languages", "get_language"])
    func `environment discovery makes read only catalogue requests`(tool: String) async throws {
        let provider = try provider { method, path, _, query, body, _ in
            #expect(method == "GET")
            #expect(path == "/api/languages" + (tool == "get_language" ? "/multifile_python" : ""))
            #expect(query == [])
            #expect(body == nil)
            return APIResponse(status: 200, body: #"{"future_metadata":["starter",null]}"#)
        }
        let result = try await provider.callTool(tool, arguments: tool == "get_language" ? ["language": .string("multifile_python")] : [:])
        #expect(result.isError != true)
        let invalid = try await provider.callTool("get_language", arguments: ["language": .string("../pads")])
        #expect(invalid.isError == true)
    }

    private func provider(request: @escaping InterviewRequest) throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://configured.example"))
        let account = try MCPAccount(name: "Project", apiKey: "project-key", baseURL: url, screenAPIKey: nil, screenRegion: "us")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: true),
                                    interviewRequest: request)
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
