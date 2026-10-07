import Foundation

func validateScreenQuestionSave(_ body: [String: Any], update: Bool) throws(ScreenWriteInputError) {
    guard let kind = body["type"] as? String else { throw ScreenWriteInputError(message: "payload.type is required.") }
    let block = ["MCQ": "mcq_details", "CODE": "code_details", "TEXT": "text_details",
                 "VIDEO": "video_details", "PROJECT": "project_details"][kind]
    for key in ["mcq_details", "code_details", "text_details", "video_details", "project_details"] where body[key] != nil && key != block {
        throw ScreenWriteInputError(message: "\(key) is not supported by the selected question type.")
    }
    if kind == "PROJECT" {
        let project = body["project_details"] as? [String: Any]
        if update, project?["temporary_file_id"] != nil {
            throw ScreenWriteInputError(message: "PROJECT source archives can only be supplied when creating a question.")
        }
        if !update, project?["temporary_file_id"] == nil {
            throw ScreenWriteInputError(message: "PROJECT creation requires project_details.temporary_file_id.")
        }
    }
    let locales = body["locales"] as? [String] ?? Array((body["title"] as? [String: String] ?? [:]).keys)
    guard Set(locales).count == locales.count, locales.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else {
        throw ScreenWriteInputError(message: "locales must contain distinct bounded nonempty strings.")
    }
    if !update || body["locales"] != nil || body["title"] != nil {
        try validateQuestionLocales(body, locales: Set(locales))
    }
    if let evaluation = body["evaluation"] as? [String: Any] {
        let supported: Set<String> = switch kind {
        case "MCQ": ["choice_selection"]
        case "TEXT": ["rubric", "text_answer_matching"]
        case "CODE": ["rubric", "validation_code", "input_output", "sql_query_result_comparison"]
        default: ["rubric"]
        }
        guard Set(evaluation.keys).isSubset(of: supported), evaluation.count <= 1 else {
            throw ScreenWriteInputError(message: "evaluation must select one block supported by the question type.")
        }
    }
    if let code = body["code_details"] as? [String: Any], code["mode"] as? String == "MULTI_LANGUAGE" {
        for key in ["programming_language_id", "starter_code", "candidate_test_code", "validator_code"] where code[key] != nil {
            throw ScreenWriteInputError(message: "MULTI_LANGUAGE questions do not accept language-specific code fields.")
        }
    }
}

private func validateQuestionLocales(_ value: Any, locales: Set<String>) throws(ScreenWriteInputError) {
    if let object = value as? [String: Any] {
        for (key, item) in object {
            if ["title", "statement", "label"].contains(key), let map = item as? [String: Any], Set(map.keys) != locales {
                throw ScreenWriteInputError(message: "Every localized field must cover exactly the question locales.")
            }
            try validateQuestionLocales(item, locales: locales)
        }
    } else if let array = value as? [Any] {
        for item in array {
            try validateQuestionLocales(item, locales: locales)
        }
    }
}
