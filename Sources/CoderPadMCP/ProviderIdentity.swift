import Foundation
import MCP

private struct InterviewKeyIdentity: Decodable {
    let name: String?
    let allowPadCreation: Bool
    let analyticsID: String

    enum CodingKeys: String, CodingKey {
        case name
        case allowPadCreation = "allow_pad_creation"
        case analyticsID = "analytics_id"
    }

    var object: [String: Any] {
        ["name": name as Any? ?? NSNull(), "allow_pad_creation": allowPadCreation, "analytics_id": analyticsID]
    }
}

private struct ScreenIdentityTeam: Decodable {
    let id: String
    let name: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "is_default"
    }

    var object: [String: Any] {
        ["id": id, "name": name, "is_default": isDefault]
    }
}

private struct ScreenKeyIdentity: Decodable {
    let organizationID: String
    let recruiterID: String
    let teams: [ScreenIdentityTeam]

    enum CodingKeys: String, CodingKey {
        case organizationID = "organization_id"
        case recruiterID = "recruiter_id"
        case teams
    }

    var object: [String: Any] {
        ["organization_id": organizationID, "recruiter_id": recruiterID, "teams": teams.map(\.object)]
    }
}

/// Keeps configured labels separate from API-derived identity and propagates lookup failures.
func whoami(account: MCPAccount, writesEnabled: Bool) async throws -> CallTool.Result {
    let org = try await apiGet("/api/organization", account: account)
    guard org.ok else { return toolResult(org) }
    guard let object = jsonObject(org.data) else {
        return errorResult("CoderPad returned an invalid JSON organization response.")
    }
    guard let organizationName = object["organization_name"] as? String,
          !organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return errorResult("Organization response did not include organization_name.")
    }
    let userResponse = try await apiGet("/api/user", account: account)
    guard userResponse.ok else { return toolResult(userResponse) }
    if let message = apiErrorEnvelopeMessage(in: userResponse.data) {
        return errorResult(message)
    }
    guard let user = try? JSONDecoder().decode(InterviewKeyIdentity.self, from: userResponse.data) else {
        return errorResult("CoderPad returned an invalid JSON user identity response.")
    }
    var result: [String: Any] = [
        "account": account.name,
        "account_id": account.id,
        "organization_name": organizationName,
        "base_url": account.baseURL.absoluteString,
        "screen_configured": account.screenEnabled,
        "writes_enabled": writesEnabled,
        "interview_user": user.object,
    ]
    if account.screenEnabled {
        let response = try await screenGet("/me", account: account)
        guard response.ok else { return toolResult(response) }
        if let message = apiErrorEnvelopeMessage(in: response.data) {
            return errorResult(message)
        }
        guard let identity = try? JSONDecoder().decode(ScreenKeyIdentity.self, from: response.data) else {
            return errorResult("CoderPad returned an invalid JSON Screen identity response.")
        }
        result["screen_identity"] = identity.object
    }
    return jsonResult(result)
}
