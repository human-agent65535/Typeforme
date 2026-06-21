import Foundation

enum ModelJSONOutputValidator {
    static func decodePayload<Payload: Decodable>(
        rawOutput: String,
        parseError: (String) -> Error
    ) throws -> Payload {
        let cleaned = ModelOutputCleaner.clean(rawOutput)
        guard let jsonString = ModelOutputCleaner.extractFirstJSONObject(cleaned) else {
            throw parseError("no JSON object found")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw parseError("not utf-8")
        }
        do {
            return try BridgeJSON.decode(Payload.self, from: data)
        } catch {
            throw parseError(error.localizedDescription)
        }
    }

    static func validateText(
        _ text: String,
        cap: Int,
        emptyError: Error,
        tooLongError: (Int, Int) -> Error,
        containsMarkupOrJSONError: Error
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw emptyError
        }
        if text.count > cap {
            throw tooLongError(text.count, cap)
        }
        if containsMarkupOrJSON(text) {
            throw containsMarkupOrJSONError
        }
    }

    static func containsMarkupOrJSON(_ text: String) -> Bool {
        if text.contains("```") { return true }
        if text.contains("<think>") || text.contains("</think>") { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return true }
        return false
    }
}
