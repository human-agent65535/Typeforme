import Foundation
import Testing
@testable import Typeforme

@Suite("PinyinTextEdit")
struct PinyinTextEditTests {
    @Test @MainActor func disabledServerRejectsPinyinBeforeCallingModel() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = original
        overrides[AppSettings.Keys.aiWritingEnabled] = false
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-pinyin-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let service = BridgeService(dictionary: UserDictionaryStore(url: dictionaryURL))
        let request = BridgeTextEditRequest(
            intent: TextEditIntent.pinyinToChinese.rawValue,
            targetText: "nihaoma",
            spokenInstruction: ""
        )
        do {
            _ = try await service.editText(request)
            Issue.record("A disabled server must not perform pinyin conversion")
        } catch let error as BridgeServiceError {
            guard case .invalidRequest(let message) = error else {
                Issue.record("Unexpected rejection: \(error)")
                return
            }
            #expect(message.contains("disabled"))
        }
    }

    @Test func rawPinyinAndReadOnlyContextStayInSeparateJSONFields() throws {
        let prompt = TextEditPromptBuilder.build(for: makeRequest("nihaoma"))
        let json = try #require(prompt.user.components(separatedBy: "<input_json>\n").last?
            .components(separatedBy: "\n</input_json>").first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object == ["pinyin": "nihaoma", "context_before": "他说：", "context_after": ""])
        #expect(!prompt.user.contains("This is not a spoken command"))
        #expect(!prompt.system.contains("By default, the replacement must stay in the language/script of target_text"))
    }

    @Test func typedContentDoesNotChangeCacheableSystemInstruction() {
        let first = TextEditPromptBuilder.build(for: makeRequest("nihaoma"))
        let second = TextEditPromptBuilder.build(for: makeRequest("huluozhexioguize"))
        #expect(first.system == second.system)
        #expect(first.user != second.user)
    }

    @Test func validatesSingleReplacementAndRejectsExpandedParagraph() throws {
        let request = makeRequest("nihaoma")
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"action":"replace_target","text":"你好吗？"}"#,
            for: request
        )
        #expect(result.text == "你好吗？")
        #expect(throws: TextEditValidationError.self) {
            try TextEditValidator.validate(
                TextEditResult(action: .replaceTarget, text: String(repeating: "你好", count: 50)),
                for: request
            )
        }
    }

    private func makeRequest(_ pinyin: String) -> TextEditRequest {
        TextEditRequest(
            intent: .pinyinToChinese,
            contextBefore: "他说：",
            targetText: pinyin,
            contextAfter: "",
            spokenInstruction: "This is not a spoken command",
            languageIDs: ["zh-CN"],
            frontmostAppName: nil,
            frontmostBundleID: nil,
            appCategory: .unknown,
            userDictionary: []
        )
    }
}
