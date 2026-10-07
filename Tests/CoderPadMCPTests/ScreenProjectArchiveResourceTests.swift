@testable import CoderPadMCP
import Foundation
import MCP
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor ProjectArchiveProbe {
    var requests: [URLRequest] = []
    func capture(_ request: URLRequest) {
        requests.append(request)
    }

    func captured() -> [URLRequest] {
        requests
    }

    func waitUntilStarted() async throws {
        for _ in 0 ..< 200 {
            if !requests.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderReadCorrupt)
    }
}

@Suite("Screen project archive resource")
struct ScreenProjectArchiveResourceTests {
    private let questionID = "4143ca74-2f0e-4151-90d6-e1428739450b"
    private let accountID = "Chosen / EU"
    private var uri: String {
        "coderpad://account/Chosen%20%2F%20EU/screen-project/42/" + questionID
    }

    @Test(arguments: ["us", "eu"])
    func `resource links resolve to bounded binary archives for the selected account`(region: String) async throws {
        let provider = try provider(region: region)
        let link = try await provider.callTool("screen_project_archive", arguments: [
            "account": .string(accountID), "test": .int(42), "question": .string(questionID.uppercased()),
        ])
        #expect(link.isError != true)
        guard case let .resourceLink(linkURI, name, _, _, mimeType, _)? = link.content.first else {
            throw CocoaError(.coderReadCorrupt)
        }
        #expect(linkURI == uri)
        #expect(name == "candidate-project-42-\(questionID).tar.gz")
        #expect(mimeType == "application/gzip")
        let archive = try archiveData()
        let probe = ProjectArchiveProbe()
        let loader: ScreenResponseRequest = { request, limit in
            await probe.capture(request)
            #expect(limit == maximumScreenProjectArchiveBytes)
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == (region == "eu" ? "www.codingame.eu" : "screen.coderpad.io"))
            #expect(request.url?.path == "/assessment/api/v1.1/tests/42/questions/\(questionID)/project")
            #expect(request.value(forHTTPHeaderField: "API-Key") == "selected-screen-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/gzip")
            #expect(request.timeoutInterval == 120)
            return try response(request, status: 200, data: archive)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.readResource(linkURI)
        }
        let content = try #require(result.contents.first)
        #expect(result.contents.count == 1)
        #expect(content.uri == uri)
        #expect(content.text == nil)
        #expect(content.mimeType == "application/gzip")
        #expect(content.blob == archive.base64EncodedString())
        #expect(await probe.captured().count == 1)
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(ReadResource.Result.self, from: encoded) == result)
    }

    @Test
    func `malformed identifiers unknown fields and unsafe URIs fail without requests`() async throws {
        let provider = try provider()
        let loader: ScreenResponseRequest = { _, _ in
            Issue.record("Invalid archives must not make requests")
            throw CancellationError()
        }
        let invalid: [[String: Value]] = [
            ["test": .int(0)], ["test": .int(Int(Int32.max) + 1)], ["test": .bool(true)],
            ["test": .double(1.5)], ["test": .string("42")], ["question": .string("../secret")],
            ["question": .bool(false)], ["extra": .string("bad")],
        ]
        for replacement in invalid {
            var arguments: [String: Value] = ["account": .string(accountID), "test": .int(42), "question": .string(questionID)]
            arguments.merge(replacement) { _, new in new }
            let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
                try await provider.callTool("screen_project_archive", arguments: arguments)
            }
            #expect(result.isError == true)
        }
        for invalidURI in [uri + "?api_key=secret", uri + "#fragment", uri.replacingOccurrences(of: "/42/", with: "/0/"),
                           uri.replacingOccurrences(of: questionID, with: "%2Fsecret"),
                           "coderpad://account/unknown/screen-project/42/" + questionID]
        {
            await #expect(throws: MCPError.self) {
                try await ProviderRequestContext.$screenResponse.withValue(loader) {
                    try await provider.readResource(invalidURI)
                }
            }
        }
    }

    @Test(arguments: [400, 403, 404, 409, 500])
    func `API failures stop the download and redact response bodies`(status: Int) async throws {
        let provider = try provider()
        let probe = ProjectArchiveProbe()
        let loader: ScreenResponseRequest = { request, _ in
            await probe.capture(request)
            return try response(request, status: status, data: Data("private-secret-body".utf8))
        }
        do {
            _ = try await ProviderRequestContext.$screenResponse.withValue(loader) { try await provider.readResource(uri) }
            Issue.record("Expected an API error")
        } catch let error as MCPError {
            #expect(!String(describing: error).contains("private-secret-body"))
            #expect(String(describing: error).contains(String(status)))
        }
        #expect(await probe.captured().count == 1)
    }

    @Test
    func `oversized downloads and invalid gzip payloads return explicit failures`() async throws {
        let provider = try provider()
        let bounded: ScreenResponseRequest = { _, limit in throw BoundedHTTPResponseError(limit: limit) }
        await #expect(throws: MCPError.internalError("Transport failure: response_too_large")) {
            try await ProviderRequestContext.$screenResponse.withValue(bounded) { try await provider.readResource(uri) }
        }
        let invalid: ScreenResponseRequest = { request, _ in try response(request, status: 200, data: Data("{}".utf8)) }
        await #expect(throws: MCPError.internalError("Screen returned an invalid gzip archive.")) {
            try await ProviderRequestContext.$screenResponse.withValue(invalid) { try await provider.readResource(uri) }
        }
        let oversized: ScreenResponseRequest = { request, limit in
            let data = Data([0x1F, 0x8B]) + Data(repeating: 0, count: limit - 1)
            return try response(request, status: 200, data: data)
        }
        await #expect(throws: MCPError.internalError("Transport failure: response_too_large")) {
            try await ProviderRequestContext.$screenResponse.withValue(oversized) { try await provider.readResource(uri) }
        }
    }

    @Test
    func `cancelling slow generation stops the resource request`() async throws {
        let provider = try provider()
        let probe = ProjectArchiveProbe()
        let loader: ScreenResponseRequest = { request, _ in
            await probe.capture(request)
            try await Task.sleep(for: .seconds(120))
            return try response(request, status: 200, data: archiveData())
        }
        let task = Task {
            try await ProviderRequestContext.$screenResponse.withValue(loader) { try await provider.readResource(uri) }
        }
        try await probe.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.captured().count == 1)
    }

    @Test
    func `binary templates and links require Screen but no write opt-in`() async throws {
        let provider = try provider()
        let tools = await provider.tools()
        let tool = try #require(tools.first { $0.name == "screen_project_archive" })
        #expect(tool.annotations.readOnlyHint == true)
        #expect(tool.annotations.destructiveHint == false)
        let templates = await provider.resourceTemplates()
        #expect(templates.last?.uriTemplate == "coderpad://account/{account}/screen-project/{test}/{question}")
        #expect(templates.last?.mimeType == "application/gzip")
        let question = try #require(UUID(uuidString: questionID))
        #expect(parseResourceURI(uri) == .accountScreenProjectArchive(account: accountID, test: 42, question: question))
        #expect(parseResourceURI(uri)?.unqualified == .screenProjectArchive(test: 42, question: question))
    }

    private func provider(region: String = "eu") throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://configured.example"))
        let other = try MCPAccount(id: "other", name: "Other", apiKey: "other-key", baseURL: url,
                                   screenAPIKey: nil, screenRegion: "us")
        let chosen = try MCPAccount(id: accountID, name: "Chosen", apiKey: "selected-interview-key", baseURL: url,
                                    screenAPIKey: "selected-screen-key", screenRegion: region)
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [other, chosen], defaultName: other.id, allowWrites: false))
    }

    private func response(_ request: URLRequest, status: Int, data: Data) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (data, response)
    }

    private func archiveData() throws -> Data {
        let encoded = "H4sIAAAAAAAC/+3NsQrCMAAE0Mx+hVt1kdCW+j3BOmQwlBoH/97SRXC3CL633HHL3VIup+kZvikuhr5fc/GZMbbdu6"
            + "/7ue2GsI9hA497TfNyGf7TNOdSD80llTGPqV6b4y4AAAAAAAAAAADw+16TU1FaACgAAA=="
        return try #require(Data(base64Encoded: encoded))
    }
}
