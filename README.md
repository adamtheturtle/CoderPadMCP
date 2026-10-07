# CoderPadMCP

An unofficial, embeddable Model Context Protocol provider and standalone server for the CoderPad REST APIs.

[Documentation](https://swiftpackageindex.com/adamtheturtle/CoderPadMCP/documentation/coderpadmcp) | [Swift Package Index](https://swiftpackageindex.com/adamtheturtle/CoderPadMCP)

CoderPadMCP gives assistants controlled access to pads, questions, organization data, quota information, and CoderPad Screen assessments.
Reads are enabled by default.
Create and update tools require an explicit opt-in, and deletion is never exposed.

## Installation

```swift
.package(
    url: "https://github.com/adamtheturtle/CoderPadMCP.git",
    from: "0.1.0"
)
```

Add the `CoderPadMCP` product to an application target, or install and run the bundled `coderpad-mcp` executable.

## Products

- `CoderPadMCP`: Account configuration, MCP tools, prompts, resources, and the reusable ``CoderPadProvider``.
- `CoderPadToolCore`: Foundation-only validation and data transforms used by the MCP provider.
- `coderpad-mcp`: A stdio server for editors, agents, and other MCP clients.

## Embedding

```swift
import CoderPadMCP
import MCPKit

let account = try MCPAccount(
    name: "Acme",
    apiKey: apiKey,
    baseURL: URL(string: "https://app.coderpad.io")!,
    screenAPIKey: nil,
    screenRegion: "us"
)
let accounts = try MCPAccountSet(
    accounts: [account],
    defaultName: account.id,
    allowWrites: false
)
let provider = CoderPadProvider(accountSet: accounts)
let server = MCPServer(
    name: "My CoderPad integration",
    version: "1.0.0",
    provider: provider
)
```

The provider implements MCP tools, prompts, resources, resource templates, and resource reads.
The host chooses the MCP transport and controls where credentials come from.

## Standalone server

Download a signed macOS or Linux executable from [GitHub Releases](https://github.com/adamtheturtle/CoderPadMCP/releases), or build the server from source:

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

For multiple accounts, set `CODERPAD_MCP_CONFIG` to a user-owned JSON file readable only by that user (mode `0600` without group, other, or ACL access).
A blank or whitespace-only `CODERPAD_MCP_CONFIG` is an error.
It does not fall back to the default path or environment credentials.

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

API responses are returned as JSON so clients retain fields added by CoderPad without waiting for a library release.

## Security

- API keys are never included in MCP results.
- Writes are disabled unless `allowWrites` or `CODERPAD_MCP_ALLOW_WRITES` is enabled.
- No delete tools are provided.
- Configuration files reject symbolic links, incorrect ownership, and group/world access.
- Network response sizes and internal pagination are bounded.
- Errors redact response bodies while retaining a diagnostic fingerprint.

## Requirements

- Swift 6.4+
- macOS 15+ or Linux

## License

MIT.
See [LICENSE](LICENSE).

Internal pad scans follow both page and opaque cursor continuations.
Requests keep the selected account’s configured API origin and credentials.
Continuation URLs supply only a page or cursor value.
Cycles and incomplete scans are reported as errors rather than complete counts or aggregates.

`screen_get_test` returns the JSON test details and their existing report and UUID question results.
Set `withCommunityStats` to include community statistics.
This tool makes one JSON request.
It does not fetch the PDF export or candidate media.

Question list tools accept server-side `text` search and a `pad_types` array of `any`, `live`, or `take_home`.
Categories use repeated query keys, and empty text is preserved.
Question lists also sort by `title` or `used`, with optional `asc` or `desc` directions.
Count and aggregate tools retain search filters across every page or cursor and bypass unfiltered host caches.

Question variants are addressed by parent question and variant IDs.
Use `list_question_variants` and `get_question_variant` to read full starter code and project files.
Opt-in `create_question_variant` and `update_question_variant` writes support `dry_run` previews and invalidate the selected account’s question cache after success.
Omitted `contents` preserves code, an empty string writes blank code, and JSON null restores language defaults.
Omitted `file_contents` preserves files, while an empty array resets template files.
Structured entries retain `hidden` and `deleted` flags.
Code and file arrays are mutually exclusive.
Each string is limited to 512 KiB and the complete write body to 1 MiB.
Mutations are attempted once.
Variant deletion remains a human action.

`screen_ai_assist_conversations` reads candidate AI Assist conversations for an integer test ID and a UUID project-question ID.
Conversation and message order, subjects, creation times, roles, and structured `output_items` remain intact.
Empty conversation arrays remain valid.
Missing questions and unfinished tests return HTTP errors.
Responses exceeding the JSON response limit fail with `response_too_large`, without returning a partial transcript as a complete result.
The tool is available only with Screen credentials and never fetches project archives or media.

`screen_create_campaign` creates a campaign from ordered question UUIDs or random sets and optional team settings.
The selected account must have both a Screen key and write permission.
Omitted settings keep team defaults, and explicit false values and empty lists are preserved.
Dry runs preview the validated request without creating a campaign or returning an invented ID.
Creation uses one bounded POST and is never automatically retried.

`screen_project_archive` returns a credential-free resource link for a candidate project tar.gz archive.
Read the linked resource to download binary content as an MCP blob.
Resources use the selected account's Screen key, an 8 MiB ceiling, and a 120-second request timeout, with normal cancellation and API errors.
The server does not extract or execute archive files.
Archive reads require Screen access and are available without enabling writes.

Screen question discovery uses `screen_list_questions`, `screen_get_question`, and `screen_question_insights`.
Question identities are UUIDs.
Lists expose offset pagination with a maximum page size of 50 and filters for type, duration, difficulty, domain, skill, programming language, origin, product, and sort order.
Insights accept an optional programming language.
Responses retain full question and evaluation data, optional metrics, explicit zero and false values, and pagination metadata.
These tools require Screen credentials on the selected account and return bounded JSON.

Screen question authoring tools require both a Screen key and writes opt-in on the selected account.
`screen_create_question` and `screen_update_question` accept writable fields in `payload` for MCQ, CODE, TEXT, FILE_UPLOAD, VIDEO, and PROJECT questions.
Creation returns the question details and optional Location header without following that URL.
Use `screen_upload_project` with an explicit `archive_uri` to upload original gzip bytes, up to 52,428,800 bytes.
The default loader accepts absolute file URIs.
Embedding hosts can supply `CoderPadMCPArchiveInput` to resolve binary resource URIs.
Upload dry runs read and validate the selected archive and preview its headers.
Reference the returned temporary file UUID promptly when creating a PROJECT question.
Existing project source archives are replaced in the question editor.


`whoami` distinguishes the configured account label from the API-derived `interview_user` display name, pad-creation capability, and analytics identifier.
When Screen credentials are configured, `screen_identity` includes organization, recruiter, and team identities with default-team flags.
Identity lookup failures are returned as tool errors.
Display names and analytics identifiers do not establish user email addresses or organization roles.
