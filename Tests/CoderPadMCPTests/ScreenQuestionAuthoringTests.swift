@testable import CoderPadMCP
import Foundation
import MCP
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor AuthoringRequestProbe {
    private var count = 0
    func capture() {
        count += 1
    }

    func capturedCount() -> Int {
        count
    }
}

@Suite("Screen question authoring")
struct ScreenQuestionAuthoringTests {
    private let questionID = "4143ca74-2f0e-4151-90d6-e1428739450b"

    @Test(arguments: ["MCQ", "CODE", "TEXT", "FILE_UPLOAD", "VIDEO", "PROJECT"])
    func `all writable types send one exact JSON request and retain creation Location`(kind: String) async throws {
        let provider = try provider()
        let fields = payload(kind)
        let probe = AuthoringRequestProbe()
        let expectedData = try JSONEncoder().encode(Value.object(fields))
        let loader: ScreenResponseRequest = { request, limit in
            await probe.capture()
            #expect(request.url?.absoluteString == "https://screen.coderpad.io/assessment/api/v1.1/questions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "API-Key") == "screen-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(limit == 1024 * 1024)
            let data = try #require(request.httpBody)
            #expect(request.value(forHTTPHeaderField: "Content-Length") == String(data.count))
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expected = try #require(JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
            #expect(NSDictionary(dictionary: body) == expected)
            #expect(body["type"] as? String == kind)
            #expect(body["automatically_selectable"] as? Bool == false)
            #expect(body["points"] as? Int == 0)
            #expect(body["title"] as? [String: String] == ["en": "Unicode 雪"])
            return try response(request, status: 201, body: #"{"id":"4143ca74-2f0e-4151-90d6-e1428739450b","retained":false}"#,
                                headers: ["Location": "https://screen.coderpad.io/assessment/api/v1.1/questions/" + questionID])
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_question", arguments: ["payload": .object(fields)])
        }
        #expect(result.isError != true)
        #expect(await probe.capturedCount() == 1)
        let output = try object(result)
        #expect(output["status"] as? Int == 201)
        #expect(output["location"] as? String == "https://screen.coderpad.io/assessment/api/v1.1/questions/" + questionID)
        let question = try #require(output["question"] as? [String: Any])
        #expect(question["retained"] as? Bool == false)
    }

    @Test
    func `updates use UUID paths and dry runs preserve omission and empty values`() async throws {
        let provider = try provider(region: "eu")
        let loader: ScreenResponseRequest = { request, _ in
            #expect(request.url?.absoluteString == "https://www.codingame.eu/assessment/api/v1.1/questions/" + questionID)
            #expect(request.httpMethod == "PUT")
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body.keys.sorted() == ["comment", "type"])
            #expect(body["comment"] as? String == "")
            return try response(request, status: 200, body: #"{"id":"4143ca74-2f0e-4151-90d6-e1428739450b"}"#)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_update_question", arguments: ["question": .string(questionID),
                                                                              "payload": .object(["type": .string("TEXT"), "comment": .string("")])])
        }
        #expect(result.isError != true)
        let preview = try await provider.callTool("screen_create_question", arguments: ["payload": .object(payload("MCQ")), "dry_run": .bool(true)])
        #expect(preview.isError != true)
        #expect(try object(preview)["changed"] as? Bool == false)
    }

    @Test
    func `partial updates leave existing locale coverage to the server`() async throws {
        let provider = try provider()
        let result = try await provider.callTool("screen_update_question", arguments: [
            "question": .string(questionID), "dry_run": .bool(true),
            "payload": .object(["type": .string("MCQ"), "mcq_details": .object([
                "choices": .array([.object(["label": .object(["en": .string("Choice")])])]),
            ])]),
        ])
        #expect(result.isError != true)
    }

    @Test
    func `read only fields invalid types locales and project replacement fail locally`() async throws {
        let provider = try provider()
        let invalid: [[String: Value]] = [
            ["id": .string(questionID)], ["type": .string("GAME")], ["points": .bool(false)],
            ["title": .object(["fr": .string("Titre")])], ["locales": .array([.string("en"), .string("en")])],
            ["file_upload_details": .object([:])], ["mcq_details": .object(["unknown": .bool(false)])],
            ["evaluation": .object(["test_report": .object([:])])],
            ["code_details": .object(["available_programming_language_ids": .array([])])],
            ["comment": .string(String(repeating: "a", count: 524_289))],
        ]
        let loader: ScreenResponseRequest = { _, _ in Issue.record("Invalid payload made a request"); throw CancellationError() }
        try await ProviderRequestContext.$screenResponse.withValue(loader) {
            for replacement in invalid {
                var fields = payload("MCQ")
                fields.merge(replacement) { _, new in new }
                #expect(try await provider.callTool("screen_create_question", arguments: ["payload": .object(fields)]).isError == true)
            }
            #expect(try await provider.callTool("screen_update_question", arguments: ["question": .string(questionID),
                                                                                      "payload": .object(payload("PROJECT"))]).isError == true)
            let projectResult = try await provider.callTool("screen_create_question", arguments: ["payload": .object(["type": .string("PROJECT")])])
            #expect(projectResult.isError == true)
        }
    }

    @Test
    func `nested evaluation localized labels and arbitrary function JSON schemas survive validation`() async throws {
        let provider = try provider()
        var fields = payload("CODE")
        fields["code_details"] = .object(["mode": .string("MULTI_LANGUAGE"), "function_signature": .object([
            "name": .string("compute"), "parameters": .array([.object(["title": .string("values"), "type": .string("array"),
                                                                       "items": .object(["type": .string("integer"), "minimum": .int(-5)])])]),
            "return_type": .object(["type": .string("boolean"), "default": .bool(false)]),
        ])])
        fields["evaluation"] = .object(["input_output": .object(["test_cases": .array([.object([
            "label": .object(["en": .string("Example")]), "input": .string(""), "output": .string("0"),
            "contributes_to_score": .bool(false), "points": .int(0),
            "timeout_ms_by_programming_language_id": .object(["Python3": .int(5000)]),
        ])])])])
        let result = try await provider.callTool("screen_create_question", arguments: ["payload": .object(fields), "dry_run": .bool(true)])
        #expect(result.isError != true)
        let body = try #require(object(result)["body"] as? [String: Any])
        let evaluation = try #require(body["evaluation"] as? [String: Any])
        #expect(evaluation.keys.sorted() == ["input_output"])
    }

    @Test(arguments: [400, 403, 409, 500])
    func `failed writes make one attempt`(status: Int) async throws {
        let provider = try provider()
        let probe = AuthoringRequestProbe()
        let loader: ScreenResponseRequest = { request, _ in
            await probe.capture()
            return try response(request, status: status, body: #"{"message":"rejected"}"#)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_create_question", arguments: ["payload": .object(payload("TEXT"))])
        }
        #expect(result.isError == true)
        #expect(await probe.capturedCount() == 1)
    }

    @Test
    func `writes require both selected account capabilities`() async throws {
        let provider = try provider(writes: false)
        let tools = await provider.tools().map(\.name)
        #expect(tools.contains("screen_create_question") == false)
        let result = try await provider.callTool("screen_upload_project", arguments: ["archive_uri": .string("file:///tmp/archive.tar.gz")])
        #expect(result.isError == true)
    }

    private func payload(_ kind: String) -> [String: Value] {
        var fields: [String: Value] = ["type": .string(kind), "title": .object(["en": .string("Unicode 雪")]),
                                       "statement": .object(["en": .string("<p>Prompt</p>")]),
                                       "automatically_selectable": .bool(false), "points": .int(0)]
        if kind == "PROJECT" {
            fields["project_details"] = .object(["temporary_file_id": .string(questionID), "ai_assist_allowed": .bool(false)])
        }
        return fields
    }

    private func provider(region: String = "us", writes: Bool = true) throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://app.coderpad.io"))
        let account = try MCPAccount(id: "primary", name: "Primary", apiKey: "interview-key", baseURL: url,
                                     screenAPIKey: "screen-key", screenRegion: region, allowWrites: writes)
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.id, allowWrites: writes))
    }

    private func response(_ request: URLRequest, status: Int, body: String,
                          headers: [String: String] = [:]) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
        return (Data(body.utf8), response)
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
