@testable import CoderPadMCP
import CoderPadToolCore
import Foundation
import MCP
import Testing

private actor PadControlProbe {
    var calls = 0
    var invalidations: [String] = []
    func request() {
        calls += 1
    }

    func invalidate(_ kind: CoderPadMCPRecordKind, _ account: String) {
        invalidations.append("\(kind.rawValue):\(account)")
    }

    func count() -> Int {
        calls
    }

    func cleared() -> [String] {
        invalidations
    }
}

@Suite("Pad control writes")
struct PadControlProviderTests {
    @Test(arguments: ["create_pad", "update_pad"])
    func `control requests preserve false and selected account credentials`(tool: String) async throws {
        let probe = PadControlProbe()
        let provider = try provider(probe: probe) { method, path, account, query, body, limit in
            await probe.request()
            #expect(method == (tool == "create_pad" ? "POST" : "PUT"))
            #expect(path == "/api/pads/" + (tool == "update_pad" ? "ABC123" : ""))
            #expect(account.id == "chosen")
            #expect(account.apiKey == "chosen-key")
            #expect(account.baseURL.absoluteString == "https://chosen.example")
            #expect(query == [])
            #expect(limit == 1024 * 1024)
            let data = try #require(body)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            #expect(object == NSDictionary(dictionary: ["private": false, "execution_enabled": "false",
                                                        "restrict_interviewer_access": true, "disable_coaching_tips": false,
                                                        "allowed_interviewer_emails": ["ada@example.com"]]))
            return APIResponse(status: 200, body: #"{"id":"ABC123"}"#)
        }
        var arguments: [String: Value] = ["account": .string("chosen"), "private": .bool(false),
                                          "execution_enabled": .bool(false), "restrict_interviewer_access": .bool(true),
                                          "disable_coaching_tips": .bool(false), "allowed_interviewer_emails": .array([.string("ada@example.com")])]
        if tool == "update_pad" {
            arguments["pad"] = .string("ABC123")
        }
        let result = try await provider.callTool(tool, arguments: arguments)
        #expect(result.isError != true)
        #expect(await probe.count() == 1)
        #expect(await probe.cleared() == ["pads:chosen"])
    }

    @Test
    func `dry run preserves creation settings zero minutes and clearing list`() async throws {
        let probe = PadControlProbe()
        let provider = try provider(probe: probe) { _, _, _, _, _, _ in
            Issue.record("Dry runs must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let arguments: [String: Value] = [
            "account": .string("chosen"), "take_home": .bool(true), "ai_assist_enabled": .bool(false),
            "take_home_time_limit": .int(0), "execution_enabled": .bool(true),
            "allowed_interviewer_emails": .array([]), "dry_run": .bool(true),
        ]
        let result = try await provider.callTool("create_pad", arguments: arguments)
        #expect(result.isError != true)
        let expectedBody: [String: Any] = [
            "take_home": true, "ai_assist_enabled": false, "take_home_time_limit": 0,
            "execution_enabled": "true", "allowed_interviewer_emails": [String](),
        ]
        let expectedPreview: [String: Any] = [
            "dry_run": true, "changed": false, "method": "POST", "path": "/api/pads/", "body": expectedBody,
        ]
        #expect(try object(result) == NSDictionary(dictionary: expectedPreview))
        let clearingArguments: [String: Value] = [
            "account": .string("chosen"), "pad": .string("ABC123"),
            "allowed_interviewer_emails": .array([]), "dry_run": .bool(true),
        ]
        let clearing = try await provider.callTool("update_pad", arguments: clearingArguments)
        #expect(clearing.isError != true)
        let preview = try object(clearing)
        #expect(preview["body"] as? NSDictionary == NSDictionary(dictionary: ["allowed_interviewer_emails": [String]()]))
        #expect(preview["method"] as? String == "PUT")
        #expect(await probe.count() == 0)
        #expect(await probe.cleared() == [])
    }

    @Test(arguments: ["create_pad", "update_pad"])
    func `invalid settings fail before network access`(tool: String) async throws {
        let probe = PadControlProbe()
        let provider = try provider(probe: probe) { _, _, _, _, _, _ in
            Issue.record("Invalid settings must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        var invalid: [[String: Value]] = padControlBooleanFields.map { [$0: .string("false")] }
        invalid += [["allowed_interviewer_emails": .string("ada@example.com")],
                    ["allowed_interviewer_emails": .array([.bool(false)])], ["allowed_interviewer_emails": .array([.string("")])],
                    ["allowed_interviewer_emails": .array([.string("bad")])],
                    ["allowed_interviewer_emails": .array(Array(repeating: .string("ada@example.com"), count: 101))]]
        if tool == "create_pad" {
            invalid += [["take_home": .int(0)], ["ai_assist_enabled": .null], ["take_home_time_limit": .string("30")],
                        ["take_home_time_limit": .bool(false)], ["take_home_time_limit": .double(1.5)],
                        ["take_home_time_limit": .int(-1)], ["take_home_time_limit": .int(Int(Int32.max) + 1)]]
        } else {
            invalid += [["take_home": .bool(false)], ["ai_assist_enabled": .bool(false)], ["take_home_time_limit": .int(30)]]
        }
        for var arguments in invalid {
            arguments["account"] = .string("chosen")
            if tool == "update_pad" {
                arguments["pad"] = .string("ABC123")
            }
            let result = try await provider.callTool(tool, arguments: arguments)
            #expect(result.isError == true)
        }
        #expect(await probe.count() == 0)
        #expect(await probe.cleared() == [])
    }

    @Test(arguments: [400, 403, 404, 409, 500])
    func `failed updates run once without clearing caches`(status: Int) async throws {
        let probe = PadControlProbe()
        let provider = try provider(probe: probe) { _, _, _, _, _, _ in
            await probe.request()
            return APIResponse(status: status, body: #"{"message":"failed"}"#)
        }
        let result = try await provider.callTool("update_pad", arguments: ["account": .string("chosen"),
                                                                           "pad": .string("ABC123"), "private": .bool(false)])
        #expect(result.isError == true)
        #expect(await probe.count() == 1)
        #expect(await probe.cleared() == [])
    }

    @Test
    func `write opt-in and creation-only schemas remain enforced`() async throws {
        let probe = PadControlProbe()
        let provider = try provider(writes: false, probe: probe) { _, _, _, _, _, _ in
            Issue.record("Disabled writes must not make requests")
            return APIResponse(status: 500, body: "unexpected")
        }
        let tools = await provider.tools()
        #expect(tools.first { $0.name == "create_pad" } == nil)
        let result = try await provider.callTool("create_pad", arguments: ["account": .string("chosen"), "private": .bool(true)])
        #expect(result.isError == true)
        #expect(padCreationControlProperties["take_home_time_limit"]?["minimum"] as? Int == 0)
        #expect(padControlProperties["take_home"] == nil)
        #expect(padControlProperties["allowed_interviewer_emails"]?["maxItems"] as? Int == 100)
    }

    private func provider(writes: Bool = true, probe: PadControlProbe,
                          request: @escaping InterviewRequest) throws -> CoderPadProvider
    {
        let defaultURL = try #require(URL(string: "https://default.example"))
        let selectedURL = try #require(URL(string: "https://chosen.example"))
        let other = try MCPAccount(id: "other", name: "Other", apiKey: "other-key", baseURL: defaultURL,
                                   screenAPIKey: nil, screenRegion: "us", allowWrites: false)
        let selected = try MCPAccount(id: "chosen", name: "Selected", apiKey: "chosen-key", baseURL: selectedURL,
                                      screenAPIKey: nil, screenRegion: "us", allowWrites: true)
        let cache = CoderPadMCPCache(load: { _, _, _ in nil }, invalidate: { await probe.invalidate($0, $1) })
        return try CoderPadProvider(accountSet: MCPAccountSet(accounts: [other, selected], defaultName: other.id, allowWrites: writes),
                                    cache: cache, interviewRequest: request)
    }

    private func object(_ result: CallTool.Result) throws -> NSDictionary {
        guard case let .text(text, _, _)? = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }
}
