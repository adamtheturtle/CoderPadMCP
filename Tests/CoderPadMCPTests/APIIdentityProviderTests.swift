@testable import CoderPadMCP
import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor IdentityRequestProbe {
    var paths: [String] = []
    func capture(_ path: String) {
        paths.append(path)
    }

    func captured() -> [String] {
        paths
    }
}

@Suite("API identity introspection")
struct APIIdentityProviderTests {
    @Test(arguments: [false, true])
    func `API identity keeps configured labels separate and preserves nullable names`(nullable: Bool) async throws {
        let probe = IdentityRequestProbe()
        let account = try account(screen: true)
        let provider = try provider(account) { method, path, selected, query, body, limit in
            #expect(method == "GET")
            #expect(selected.id == "configured")
            #expect(selected.apiKey == "interview-key")
            #expect(selected.baseURL.absoluteString == "https://configured.example")
            #expect(query == [])
            #expect(body == nil)
            #expect(limit == 8 * 1024 * 1024)
            await probe.capture(path)
            let payload: [String: Any] = path == "/api/organization"
                ? ["organization_name": "Example Org"]
                : ["name": nullable ? NSNull() : "Actual Owner" as Any,
                   "allow_pad_creation": false, "analytics_id": "analytics-only", "api_key": "hidden"]
            return try APIResponse(status: 200, data: JSONSerialization.data(withJSONObject: payload))
        }
        let screenRequest: ScreenResponseRequest = { request, limit in
            #expect(request.url?.absoluteString == "https://www.codingame.eu/assessment/api/v1.1/me")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "API-Key") == "screen-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(limit == 8 * 1024 * 1024)
            await probe.capture("/me")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"""
            {
              "organization_id": "screen-org",
              "recruiter_id": "recruiter",
              "teams": [
                {
                  "id": "team-a",
                  "name": "First",
                  "is_default": false
                },
                {
                  "id": "team-b",
                  "name": "Second",
                  "is_default": true
                }
              ],
              "api_key": "hidden"
            }
            """#.utf8), response)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(screenRequest) {
            try await provider.callTool("whoami", arguments: ["account": .string("configured")])
        }
        #expect(result.isError != true)
        let expected: [String: Any] = [
            "account": "Configured Label", "account_id": "configured", "organization_name": "Example Org",
            "base_url": "https://configured.example", "screen_configured": true, "writes_enabled": false,
            "interview_user": ["name": nullable ? NSNull() : "Actual Owner" as Any,
                               "allow_pad_creation": false, "analytics_id": "analytics-only"],
            "screen_identity": ["organization_id": "screen-org", "recruiter_id": "recruiter", "teams": [
                ["id": "team-a", "name": "First", "is_default": false],
                ["id": "team-b", "name": "Second", "is_default": true],
            ]],
        ]
        #expect(try object(result) == NSDictionary(dictionary: expected))
        #expect(await probe.captured() == ["/api/organization", "/api/user", "/me"])
    }

    @Test
    func `interview identity is available without Screen credentials`() async throws {
        let provider = try provider(account(screen: false)) { _, path, _, _, _, _ in
            APIResponse(status: 200, body: path == "/api/organization"
                ? #"{"organization_name":"Example Org"}"#
                : #"{"name":"Owner","allow_pad_creation":true,"analytics_id":"user-1"}"#)
        }
        let screenRequest: ScreenResponseRequest = { _, _ in
            Issue.record("Screen was contacted without configured credentials")
            throw URLError(.badURL)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(screenRequest) {
            try await provider.callTool("whoami", arguments: nil)
        }
        #expect(result.isError != true)
        let payload = try object(result)
        #expect(payload["screen_configured"] as? Bool == false)
        #expect(payload["screen_identity"] == nil)
        #expect((payload["interview_user"] as? NSDictionary)?["allow_pad_creation"] as? Bool == true)
    }

    @Test(arguments: [403, 404])
    func `failed Interview user lookup is a tool error`(status: Int) async throws {
        let provider = try provider(account(screen: true)) { _, path, _, _, _, _ in
            APIResponse(status: path == "/api/organization" ? 200 : status,
                        body: path == "/api/organization" ? #"{"organization_name":"Example Org"}"# : #"{"message":"denied"}"#)
        }
        let result = try await provider.callTool("whoami", arguments: nil)
        #expect(result.isError == true)
        #expect(try text(result).contains(String(status)))
    }

    @Test(arguments: [
        #"{"name":null,"allow_pad_creation":"false","analytics_id":"owner"}"#,
        #"{"name":null,"allow_pad_creation":false}"#,
        #"{"name":123,"allow_pad_creation":false,"analytics_id":"owner"}"#,
    ])
    func `malformed user identity cannot become a successful configured label`(body: String) async throws {
        let provider = try provider(account(screen: false)) { _, path, _, _, _, _ in
            APIResponse(status: 200, body: path == "/api/organization" ? #"{"organization_name":"Example Org"}"# : body)
        }
        let result = try await provider.callTool("whoami", arguments: nil)
        #expect(result.isError == true)
        #expect(try text(result) == "CoderPad returned an invalid JSON user identity response.")
    }

    @Test(arguments: [200, 403])
    func `screen identity failure remains visible`(status: Int) async throws {
        let provider = try provider(account(screen: true)) { _, path, _, _, _, _ in
            APIResponse(status: 200, body: path == "/api/organization"
                ? #"{"organization_name":"Example Org"}"#
                : #"{"name":null,"allow_pad_creation":false,"analytics_id":"owner"}"#)
        }
        let screenRequest: ScreenResponseRequest = { request, _ in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(#"""
            {
              "organization_id": "org",
              "recruiter_id": "recruiter",
              "teams": [
                {
                  "id": "team",
                  "name": "Team",
                  "is_default": "false"
                }
              ]
            }
            """#.utf8), response)
        }
        let result = try await ProviderRequestContext.$screenResponse.withValue(screenRequest) {
            try await provider.callTool("whoami", arguments: nil)
        }
        #expect(result.isError == true)
        #expect(try text(result).contains(status == 200 ? "invalid JSON Screen identity" : "403"))
    }

    private func account(screen: Bool) throws -> MCPAccount {
        try MCPAccount(id: "configured", name: "Configured Label", apiKey: "interview-key",
                       baseURL: #require(URL(string: "https://configured.example")),
                       screenAPIKey: screen ? "screen-key" : nil, screenRegion: "eu")
    }

    private func provider(_ account: MCPAccount, request: @escaping InterviewRequest) throws -> CoderPadProvider {
        try CoderPadProvider(accountSet: MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: false),
                             interviewRequest: request)
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return text
    }

    private func object(_ result: CallTool.Result) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? NSDictionary)
    }
}
