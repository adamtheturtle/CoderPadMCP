import CoderPadMCP
import Foundation
import MCP
import MCPKit

private let environment = ProcessInfo.processInfo.environment

let accountSet: MCPAccountSet
do {
    let config = try loadConfigObject(environment: environment)
    accountSet = try makeAccountSet(config: config, environment: environment)
} catch {
    FileHandle.standardError.write(Data(configurationFailureMessage(error).utf8))
    exit(1)
}

let provider = CoderPadProvider(accountSet: accountSet)
let server = MCPServer(name: "CoderPad MCP", version: coderPadMCPVersion, provider: provider)
try await server.run(transport: StdioTransport())
