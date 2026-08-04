@testable import CoderPadMCP
import MCP
import Testing

@Suite("Provider dispatch")
struct ProviderDispatchTests {
    @Test
    func `unknown tools are rejected before account resolution`() async {
        let provider = CoderPadProvider(
            accountSet: MCPAccountSet(accounts: [], defaultName: "", allowWrites: false),
        )

        let result = await provider.callTool("does_not_exist", arguments: nil)

        #expect(result.isError == true)
        guard case let .text(text, _, _)? = result.content.first else {
            Issue.record("Expected a text error result")
            return
        }

        #expect(text == "Unknown tool: does_not_exist")
    }
}
