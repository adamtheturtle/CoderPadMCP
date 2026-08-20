# ``CoderPadMCP``

Embed CoderPad tools, prompts, and resources in a Model Context Protocol server.

## Overview

Create one or more ``MCPAccount`` values, collect them in an ``MCPAccountSet``, and
initialize ``CoderPadProvider``. The provider implements `MCPToolProvider` from MCPKit,
leaving the host in control of credential storage, server identity, and transport.

Read tools are always available. Write tools are advertised and accepted only when the
account set enables writes. CoderPad Screen tools appear only when at least one account
has Screen credentials.

```swift
let accounts = try MCPAccountSet(
    accounts: [
        try MCPAccount(
            name: "Acme",
            apiKey: apiKey,
            baseURL: URL(string: "https://app.coderpad.io")!,
            screenAPIKey: nil,
            screenRegion: "us"
        )
    ],
    defaultName: "Acme",
    allowWrites: false
)

let provider = CoderPadProvider(accountSet: accounts)
```

## Topics

### Provider

- ``CoderPadProvider``
- ``coderPadMCPVersion``

### Accounts and configuration

- ``MCPAccount``
- ``MCPAccountSet``
- ``MCPConfigError``
- ``MCPConfigLoadError``
- ``configurationFailureMessage(_:)``
- ``makeAccountSet(config:environment:)``
- ``loadConfigObject(environment:homeDirectory:)``

### Prompts and resources

- ``interviewPrompts``
- ``renderPrompt(name:arguments:)``
- ``staticResources(for:)``
- ``resourceTemplates(for:)``
- ``parseResourceURI(_:)``
