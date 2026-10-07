import Foundation
import MCP

private struct CreatedScreenCampaign: Decodable {
    let id: Int
}

func screenCreateCampaign(_ arguments: [String: Value]?, account: MCPAccount) async throws -> CallTool.Result {
    guard account.screenEnabled else { return errorResult("CoderPad Screen is not configured for this account.") }
    if let error = unknownArgumentError(arguments, allowed: [mcpAccountArgument, "name", "questions", "settings", "team_id", "dry_run"]) {
        return errorResult(error)
    }
    var fields = arguments ?? [:]
    fields.removeValue(forKey: mcpAccountArgument)
    fields.removeValue(forKey: "dry_run")
    let body: [String: Any]
    do {
        var budget = 256
        guard let validated = try screenWriteValue(.object(fields), schema: screenCampaignCreateSchema,
                                                   path: "campaign", budget: &budget) as? [String: Any]
        else {
            return errorResult("Campaign encoding failed.")
        }
        body = validated
        try validateCampaignEntries(body)
        try validateCampaignSettings(body)
    } catch {
        return errorResult(error.message)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= maxMCPWriteBodyBytes else {
        return errorResult("The Screen write body exceeds its byte limit.")
    }
    if strictDryRunArgument(arguments) == .value(true) {
        return dryRunResult(method: "POST", path: "/assessment/api/v1.1/campaigns", body: body)
    }
    let response = try await screenSend("POST", path: "/campaigns", account: account, data: data, contentType: "application/json")
    if response.ok {
        guard let created = try? JSONDecoder().decode(CreatedScreenCampaign.self, from: response.data),
              created.id > 0, created.id <= Int(Int32.max)
        else {
            return errorResult("Screen campaign creation returned no usable integer id.")
        }
    }
    return toolResult(response)
}

private func validateCampaignEntries(_ body: [String: Any]) throws(ScreenWriteInputError) {
    for question in body["questions"] as? [[String: Any]] ?? [] {
        switch question["type"] as? String {
        case "QUESTION":
            guard question["question_id"] != nil, question["configuration"] == nil else {
                throw ScreenWriteInputError(message: "A QUESTION entry requires question_id and cannot include configuration.")
            }
        case "RANDOM_QUESTION_SET":
            guard let configuration = question["configuration"] as? [String: Any], question["question_id"] == nil,
                  configuration["included_question_ids"] == nil || configuration["excluded_question_ids"] == nil,
                  let kind = configuration["question_type"] as? String,
                  let duration = configuration["target_duration_minutes"] as? Int
            else {
                throw ScreenWriteInputError(message: "A random set requires configuration and cannot mix included and excluded question IDs.")
            }
            let durations = kind == "QUIZ" ? [5, 10, 15, 20, 25, 30] : [5, 10, 20, 30, 45, 60]
            guard durations.contains(duration) else { throw ScreenWriteInputError(message: "Unsupported random-set target duration.") }
        default:
            throw ScreenWriteInputError(message: "Unsupported campaign question type.")
        }
    }
}

private func validateCampaignSettings(_ body: [String: Any]) throws(ScreenWriteInputError) {
    guard let settings = body["settings"] as? [String: Any] else { return }
    let timer = settings["timer"] as? [String: Any]
    let mode = timer?["mode"] as? String
    if let timer {
        guard let mode else { throw ScreenWriteInputError(message: "An explicit timer requires mode.") }
        if mode == "GLOBAL" {
            guard let duration = timer["duration_minutes"] as? Int, duration > 0 else {
                throw ScreenWriteInputError(message: "A GLOBAL timer requires positive duration_minutes.")
            }
        } else if timer["duration_minutes"] != nil {
            throw ScreenWriteInputError(message: "Only a GLOBAL timer accepts duration_minutes.")
        }
    }
    if let access = settings["access_period"] as? [String: Any] {
        if access["max_end_time"] != nil, mode == "PER_QUESTION" {
            throw ScreenWriteInputError(message: "PER_QUESTION timers do not accept max_end_time.")
        }
        if let start = access["min_start_time"] as? String, let end = access["max_end_time"] as? String,
           let startDate = campaignInstant(start), let endDate = campaignInstant(end), endDate <= startDate
        {
            throw ScreenWriteInputError(message: "max_end_time must be after min_start_time.")
        }
    }
    if let followUp = settings["follow_up_questions"] as? [String: Any], followUp["enabled"] as? Bool == true,
       let mode, mode != "PER_QUESTION"
    {
        throw ScreenWriteInputError(message: "Enabled follow-up questions require a PER_QUESTION timer.")
    }
}
