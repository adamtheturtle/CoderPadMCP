# CoderPadMCP

An unofficial, embeddable Model Context Protocol provider and standalone server for
the CoderPad REST APIs.

[Documentation](https://swiftpackageindex.com/adamtheturtle/CoderPadMCP/documentation/coderpadmcp) |
[Swift Package Index](https://swiftpackageindex.com/adamtheturtle/CoderPadMCP)

CoderPadMCP gives assistants controlled access to pads, questions, organization data,
quota information, and CoderPad Screen assessments. Reads are enabled by default.
Create and update tools require an explicit opt-in, and deletion is never exposed.

## Installation

```swift
.package(
    url: "https://github.com/adamtheturtle/CoderPadMCP.git",
    from: "0.1.0"
)
```

Add the `CoderPadMCP` product to an application target, or install and run the bundled
`coderpad-mcp` executable.

## Products

- `CoderPadMCP`: Account configuration, MCP tools, prompts, resources, and the reusable
  ``CoderPadProvider``.
- `CoderPadToolCore`: Foundation-only validation and data transforms used by the MCP
  provider.
- `coderpad-mcp`: A stdio server for editors, agents, and other MCP clients.

## Embedding

```swift
import CoderPadMCP
import MCPKit

let account = MCPAccount(
    name: "Acme",
    apiKey: apiKey,
    baseURL: URL(string: "https://app.coderpad.io")!,
    screenAPIKey: nil,
    screenRegion: "us"
)
let accounts = MCPAccountSet(
    accounts: [account],
    defaultName: account.name,
    allowWrites: false
)
let provider = CoderPadProvider(accountSet: accounts)
let server = MCPServer(
    name: "My CoderPad integration",
    version: "1.0.0",
    provider: provider
)
```

The provider implements MCP tools, prompts, resources, resource templates, and resource
reads. The host chooses the MCP transport and controls where credentials come from.

## Standalone server

Download a signed macOS or Linux executable from
[GitHub Releases](https://github.com/adamtheturtle/CoderPadMCP/releases), or build
the server from source:

```sh
swift build -c release
CODERPAD_API_KEY=your-key swift run coderpad-mcp
```

Configure an MCP client with the built executable:

```json
{
  "mcpServers": {
    "coderpad": {
      "command": "/absolute/path/to/coderpad-mcp",
      "env": {
        "CODERPAD_API_KEY": "your-key"
      }
    }
  }
}
```

For multiple accounts, set `CODERPAD_MCP_CONFIG` to a user-owned JSON file readable
only by that user (mode `0600`, no group/other bits, and no ACL grants to other
users). A blank or whitespace-only `CODERPAD_MCP_CONFIG` is an error; it does not
fall back to the default path or environment credentials.

```json
{
  "accounts": [
    {
      "name": "Acme",
      "api_key": "secret",
      "base_url": "https://app.coderpad.io",
      "default": true
    }
  ],
  "allow_writes": false
}
```

The default path is `~/.config/coderpad-mcp/config.json`.

## Capabilities

The provider includes:

- account discovery and identity;
- paginated, compact, counted, and aggregated pad and question queries;
- full pad and question retrieval;
- compact single-file and multi-file pad code;
- organization and quota resources;
- optional CoderPad Screen campaign and test tools;
- review, summary, comparison, and question-drafting prompts;
- opt-in pad and question creation and updates, including dry runs.

API responses are returned as JSON so clients retain fields added by CoderPad without
waiting for a library release.

## Security

- API keys are never included in MCP results.
- Writes are disabled unless `allowWrites` or `CODERPAD_MCP_ALLOW_WRITES` is enabled.
- No delete tools are provided.
- Configuration files reject symbolic links, incorrect ownership, and group/world access.
- Network response sizes and internal pagination are bounded.
- Errors redact response bodies while retaining a diagnostic fingerprint.

## Requirements

- Swift 6.2+
- macOS 15+ or Linux

## License

MIT. See [LICENSE](LICENSE).
