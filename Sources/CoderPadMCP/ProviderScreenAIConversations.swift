import Foundation
import MCP

func screenAIConversations(arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument, "test", "question"]) {
        return errorResult(error)
    }
    let numericTest = switch arguments?["test"] {
    case .int?, .double?: true
    default: false
    }
    guard numericTest, let test = positiveScreenID(strictIntArgument(arguments, "test")) else {
        return errorResult("test must be a positive int32.")
    }
    guard case let .string(raw)? = arguments?["question"], raw.count == 36, let question = UUID(uuidString: raw) else {
        return errorResult("question must be a UUID string.")
    }
    let path = "/tests/\(test)/questions/\(question.uuidString.lowercased())/ai-assist-conversations"
    return try await toolResult(screenGet(path, account: account))
}
