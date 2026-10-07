@testable import CoderPadMCP
import Foundation
import MCP
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("Screen project binary upload")
struct ScreenProjectUploadTests {
    private let archive = Data(base64Encoded:
        "H4sIAAAAAAACA+3SsQrCMBCE4cz7FJ2qQ53EV2ks0KIgJTaSXHs6EYfgVAz+v3EQcgdx55aVwdOmblzLSFIiwvsq" +
            "LSavJXG/oROBFzi1vUm+//A1BtsSRVmmbVBWUzYqa7IOb63Id5RqK/NeVt9/TvL1//EhxsGBAb/GevWNlpDT5K85" +
            "cnOzx/dOdLlKuZGXnnZ04jmPeDb3dAAAAAAAAAAAAAAAAAOAXHgCP+zsnACgAAA==") ?? Data()

    @Test
    func `host resource bytes are sent once with their exact length and gzip content type`() async throws {
        let provider = try provider(archiveInput: { uri, limit in
            #expect(uri == "resource://selected/archive")
            #expect(limit == 52_428_800)
            return archive
        })
        let loader: ScreenResponseRequest = { request, limit in
            #expect(request.url?.absoluteString == "https://screen.coderpad.io/assessment/api/v1.1/temporary-file")
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == archive)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/gzip")
            #expect(request.value(forHTTPHeaderField: "Content-Length") == String(archive.count))
            #expect(request.value(forHTTPHeaderField: "API-Key") == "screen-key")
            #expect(limit == 1024 * 1024)
            return try response(request, status: 200)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_upload_project", arguments: ["archive_uri": .string("resource://selected/archive")])
        }
        #expect(result.isError != true)
    }

    @Test
    func `dry run reads the explicit archive without uploading or returning binary data`() async throws {
        let provider = try provider(archiveInput: { _, _ in archive })
        let result = try await provider.callTool("screen_upload_project", arguments: [
            "archive_uri": .string("resource://selected/archive"), "dry_run": .bool(true),
        ])
        #expect(result.isError != true)
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        let preview = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(preview["body"] == nil)
        #expect(preview["id"] == nil)
        #expect(preview["headers"] as? [String: String] == ["Content-Type": "application/gzip", "Content-Length": String(archive.count)])
    }

    @Test
    func `explicit regular file input preserves bytes and rejects unsupported locations`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("project.tar.gz")
        try archive.write(to: url)
        #expect(try await fileArchiveInput(url.absoluteString, archive.count) == archive)
        for uri in ["https://example.com/project.tar.gz", "file://remote/tmp/archive", "relative/path", directory.absoluteString] {
            do {
                _ = try await fileArchiveInput(uri, 52_428_800)
                Issue.record("Invalid input was accepted")
            } catch {}
        }
        do {
            _ = try await fileArchiveInput(url.absoluteString, archive.count - 1)
            Issue.record("Oversized file was accepted")
        } catch {}
    }

    @Test
    func `empty invalid and oversized host resources fail before HTTP`() async throws {
        for data in [Data(), Data("not gzip".utf8), Data(repeating: 0, count: 52_428_801)] {
            let provider = try provider(archiveInput: { _, _ in data })
            let result = try await provider.callTool("screen_upload_project", arguments: ["archive_uri": .string("resource://selected/archive")])
            #expect(result.isError == true)
        }
    }

    @Test
    func `an archive at the exact byte ceiling is accepted`() async throws {
        var bytes = Data(repeating: 0, count: 52_428_800)
        bytes[0] = 0x1F
        bytes[1] = 0x8B
        let archive = bytes
        let provider = try provider(archiveInput: { _, _ in archive })
        let loader: ScreenResponseRequest = { request, _ in
            #expect(request.httpBody?.count == 52_428_800)
            #expect(request.value(forHTTPHeaderField: "Content-Length") == "52428800")
            return try response(request, status: 200)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_upload_project", arguments: ["archive_uri": .string("resource://selected/archive")])
        }
        #expect(result.isError != true)
    }

    @Test
    func `upload cancellation is propagated`() async throws {
        let provider = try provider(archiveInput: { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await provider.callTool("screen_upload_project", arguments: ["archive_uri": .string("resource://selected/archive")])
        }
    }

    @Test(arguments: [400, 403, 500])
    func `upload failures return errors without retries`(status: Int) async throws {
        let provider = try provider(archiveInput: { _, _ in archive })
        let loader: ScreenResponseRequest = { request, _ in try response(request, status: status) }
        let result = try await ProviderRequestContext.$screenResponse.withValue(loader) {
            try await provider.callTool("screen_upload_project", arguments: ["archive_uri": .string("resource://selected/archive")])
        }
        #expect(result.isError == true)
    }

    private func provider(archiveInput: @escaping CoderPadMCPArchiveInput) throws -> CoderPadProvider {
        let url = try #require(URL(string: "https://app.coderpad.io"))
        let account = try MCPAccount(name: "Upload", apiKey: "interview-key", baseURL: url, screenAPIKey: "screen-key", screenRegion: "us")
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: true),
                                    archiveInput: archiveInput)
    }

    private func response(_ request: URLRequest, status: Int) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        let data = Data((status == 200 ? #"{"id":"0558b3e3-b76c-42ea-9435-8da1adb7e232"}"# : #"{"message":"rejected"}"#).utf8)
        return (data, response)
    }
}
