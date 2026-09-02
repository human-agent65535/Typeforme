import Foundation
import Testing
@testable import Typeforme

@Suite("PinyinTextEdit")
struct PinyinTextEditTests {
    @Test func savedPinyinPromptIsReadAgainOnTheNextRequestAndResetRestoresDefault() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-pinyin-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = PromptOverrideStore.pinyinPromptFile(in: folder)
        let request = makeRequest("nihaoma")

        let builtIn = TextEditPromptBuilder.build(for: request, promptOverrideFolder: folder)
        #expect(builtIn.system == BuiltInPrompts.pinyinToChinese)
        try "Custom pinyin instruction".write(to: file, atomically: true, encoding: .utf8)
        let custom = TextEditPromptBuilder.build(for: request, promptOverrideFolder: folder)
        #expect(custom.system == "Custom pinyin instruction")
        #expect(custom.user == builtIn.user)

        try "Updated pinyin instruction".write(to: file, atomically: true, encoding: .utf8)
        #expect(TextEditPromptBuilder.build(for: request, promptOverrideFolder: folder).system == "Updated pinyin instruction")
        try FileManager.default.removeItem(at: file)
        #expect(TextEditPromptBuilder.build(for: request, promptOverrideFolder: folder).system == builtIn.system)
    }

    @Test func pinyinOverrideDoesNotChangeSpokenCommandPrompts() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-pinyin-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = makeRequest("hello", intent: .command)
        let original = TextEditPromptBuilder.build(for: request, promptOverrideFolder: folder)
        try "Pinyin only".write(to: PromptOverrideStore.pinyinPromptFile(in: folder), atomically: true, encoding: .utf8)
        let result = TextEditPromptBuilder.build(for: request, promptOverrideFolder: folder)
        #expect(result.system == original.system)
        #expect(result.user == original.user)
    }

    @Test func emptyPinyinOverrideUsesTheBuiltInPrompt() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-pinyin-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try " \n\t".write(to: PromptOverrideStore.pinyinPromptFile(in: folder), atomically: true, encoding: .utf8)
        #expect(TextEditPromptBuilder.build(for: makeRequest("nihaoma"), promptOverrideFolder: folder).system == BuiltInPrompts.pinyinToChinese)
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

    private func makeRequest(_ pinyin: String, intent: TextEditIntent = .pinyinToChinese) -> TextEditRequest {
        TextEditRequest(
            intent: intent,
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
