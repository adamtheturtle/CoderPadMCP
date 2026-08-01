import CoderPadMCP
import Foundation
import MCP
import MCPKit

private let environment = ProcessInfo.processInfo.environment

private func configurationFailure(_ error: Error) -> String {
    switch error {
    case MCPConfigError.noAccounts:
        "coderpad-mcp: no accounts configured. Set CODERPAD_API_KEY, or point "
            + "CODERPAD_MCP_CONFIG at a config file with an \"accounts\" array.\n"
    case let MCPConfigError.tooManyAccounts(limit):
        "coderpad-mcp: the account configuration exceeds the \(limit)-account limit.\n"
    case let MCPConfigError.missingAPIKey(account):
        "coderpad-mcp: account \"\(account)\" is missing its \"api_key\".\n"
    case let MCPConfigError.duplicateName(name):
        "coderpad-mcp: two accounts share the name \"\(name)\"; names must be unique.\n"
    case let MCPConfigError.multipleDefaultAccounts(names):
        "coderpad-mcp: multiple accounts are marked as default ("
            + names.joined(separator: ", ") + "); mark only one as the default.\n"
    case MCPConfigError.noDefaultAccount:
        "coderpad-mcp: a config with multiple accounts must mark one as the default.\n"
    case let MCPConfigError.invalidDefaultFlag(account):
        "coderpad-mcp: account \"\(account)\" has a non-Boolean \"default\" value.\n"
    case let MCPConfigError.invalidScreenRegion(account, region):
        "coderpad-mcp: account \"\(account)\" has unsupported screen_region \"\(region)\".\n"
    case let MCPConfigError.invalidBaseURL(account, baseURL):
        "coderpad-mcp: account \"\(account)\" has unsupported base_url \"\(baseURL)\".\n"
    default:
        "coderpad-mcp: could not load the account configuration: \(error.localizedDescription)\n"
    }
}

let accountSet: MCPAccountSet
do {
    let config = try loadConfigObject(environment: environment)
    accountSet = try makeAccountSet(config: config, environment: environment)
} catch {
    FileHandle.standardError.write(Data(configurationFailure(error).utf8))
    exit(1)
}

let provider = CoderPadProvider(accountSet: accountSet)
let server = MCPServer(name: "CoderPad MCP", version: coderPadMCPVersion, provider: provider)
try await server.run(transport: StdioTransport())
