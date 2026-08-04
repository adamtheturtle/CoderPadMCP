//
//  ConfigLoaderTests.swift
//  CoderPadMCPTests
//

@testable import CoderPadMCP
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("Config file loading")
struct ConfigLoaderTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeConfig(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @Test
    func `missing default config falls back to environment`() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try loadConfigObject(environment: [:], homeDirectory: home) == nil)
    }

    @Test
    func `missing explicit config does not fall back to environment`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "missing.json").path
        #expect(throws: MCPConfigLoadError.missingConfig(path: path)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": path])
        }
    }

    @Test
    func `explicit config directory is reported separately from a read failure`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: MCPConfigLoadError.notRegularFile(path: directory.path)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": directory.path])
        }
    }

    @Test
    func `explicit config FIFO is rejected without waiting for a writer`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "config.json")
        try #require(mkfifo(fifo.path, 0o600) == 0)

        #expect(throws: MCPConfigLoadError.notRegularFile(path: fifo.path)) {
            _ = try securelyReadConfig(path: fifo.path, explicit: true, limit: 1_048_576)
        }
    }

    @Test
    func `filesystem errors retain safe remediation categories`() {
        let path = "/private/config.json"
        #expect(classifiedConfigReadError(path: path, error: CocoaError(.fileReadNoSuchFile))
            == .missingConfig(path: path))
        #expect(classifiedConfigReadError(path: path, error: CocoaError(.fileReadNoPermission))
            == .permissionDenied(path: path))
        #expect(classifiedConfigReadError(path: path, error: CocoaError(.fileReadUnknown))
            == .readFailed(path: path))
    }

    @Test
    func `malformed explicit config does not fall back to environment`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        try writeConfig(Data("{".utf8), to: url)
        #expect(throws: MCPConfigLoadError.malformedConfig(path: url.path)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": url.path])
        }
    }

    @Test
    func `explicit config must be a JSON object`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        try writeConfig(Data("[]".utf8), to: url)
        #expect(throws: MCPConfigLoadError.nonObjectConfig(path: url.path)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": url.path])
        }
    }

    @Test
    func `explicit config parses an object`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        try writeConfig(Data(#"{"accounts":[{"name":"Acme","api_key":"key"}]}"#.utf8), to: url)
        let config = try #require(try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": url.path]))
        let accounts = try #require(config["accounts"] as? [[String: Any]])
        #expect(accounts.count == 1)
        #expect(accounts[0]["name"] as? String == "Acme")
    }

    @Test
    func `a config at the byte limit is parsed`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let limit = 1_048_576
        let prefix = #"{"accounts":[]}"#
        try writeConfig(Data((prefix + String(repeating: " ", count: limit - prefix.utf8.count)).utf8), to: url)

        let config = try #require(try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": url.path]))
        #expect((config["accounts"] as? [Any])?.isEmpty == true)
    }

    @Test
    func `an oversized config is rejected before JSON parsing`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let limit = 1_048_576
        try writeConfig(Data(repeating: 0x20, count: limit + 1), to: url)

        #expect(throws: MCPConfigLoadError.configTooLarge(path: url.path, limit: limit)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": url.path])
        }
    }

    @Test
    func `group-readable and symbolic-link configs are rejected`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.json")
        try writeConfig(Data(#"{"accounts":[]}"#.utf8), to: target)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        #expect(throws: MCPConfigLoadError.insecurePermissions(path: target.path)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": target.path])
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = directory.appending(path: "config-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: MCPConfigLoadError.symbolicLink(path: link.path)) {
            _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": link.path])
        }
    }

    #if os(macOS)
        @Test
        func `a config with an extended ACL is rejected`() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "config.json")
            try writeConfig(Data(#"{"accounts":[]}"#.utf8), to: url)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", "everyone allow read", url.path]
            try chmod.run()
            chmod.waitUntilExit()
            try #require(chmod.terminationStatus == 0)

            #expect(throws: MCPConfigLoadError.insecurePermissions(path: url.path)) {
                _ = try loadConfigObject(environment: ["CODERPAD_MCP_CONFIG": url.path])
            }
        }
    #endif

    @Test
    func `config bytes come from the validated descriptor after a path swap`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let replacement = directory.appending(path: "replacement.json")
        let original = Data(#"{"source":"validated"}"#.utf8)
        try writeConfig(original, to: url)
        try writeConfig(Data(#"{"source":"replacement"}"#.utf8), to: replacement)

        let loaded = try securelyReadConfig(path: url.path, explicit: true, limit: 1_048_576) {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
        }

        #expect(loaded == original)
    }
}
