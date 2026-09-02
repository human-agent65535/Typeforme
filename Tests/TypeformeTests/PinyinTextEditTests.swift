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
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["pinyin"] as? String == "nihaoma")
        #expect(object["input_segments"] as? [String] == ["nihaoma"])
        #expect(object["context_before"] as? String == "他说：")
        #expect(object["context_after"] as? String == "")
        #expect(!prompt.user.contains("This is not a spoken command"))
        #expect(!prompt.system.contains("By default, the replacement must stay in the language/script of target_text"))
    }

    @Test func typedContentDoesNotChangeCacheableSystemInstruction() {
        let first = TextEditPromptBuilder.build(for: makeRequest("nihaoma"))
        let second = TextEditPromptBuilder.build(for: makeRequest("huluozhexioguize"))
        #expect(first.system == second.system)
        #expect(first.user != second.user)
    }

    @Test func pinyinPromptReceivesMatchingUserVocabularyAndKeepsContextReadOnly() throws {
        var request = makeRequest("linjinideshoujinalimaide")
        request.contextBefore = "Typeforme"
        request.userDictionary = [
            DictionaryEntry(type: "person", surface: "林霁"),
            DictionaryEntry(type: "product", surface: "Typeforme"),
        ]
        let prompt = TextEditPromptBuilder.build(for: request)
        let json = try #require(prompt.user.components(separatedBy: "<input_json>\n").last?
            .components(separatedBy: "\n</input_json>").first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let candidates = try #require(object["vocabulary_candidates"] as? [[String: Any]])
        #expect(object["pinyin"] as? String == request.targetText)
        #expect(object["context_before"] as? String == "Typeforme")
        #expect(candidates.compactMap { $0["surface"] as? String } == ["林霁"])
        #expect(candidates.first?["speech_hint"] as? String == "linji")
        #expect(TextEditPromptBuilder.vocabularyCandidates(for: request).map(\.surface) == ["林霁"])
    }

    @Test func punctuationPreferenceIsAppliedAfterPinyinDecoding() {
        var request = makeRequest("nixiangqunali")
        request.punctuationPreference = .spaces
        let spaced = TextEditPromptBuilder.build(for: request)
        request.punctuationPreference = .normal
        let natural = TextEditPromptBuilder.build(for: request)
        #expect(spaced.system == natural.system)
        #expect(spaced.user == natural.user)
        #expect(spaced.user.contains(#"punctuation="normal""#))
        #expect(!spaced.user.contains("Prefer spaces instead of sentence punctuation"))
    }

    @Test func validatesSingleReplacementAndRejectsExpandedParagraph() throws {
        let request = makeRequest("nihaoma")
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"action":"replace_target","converted_segments":["你好吗？"]}"#,
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

    @Test func phoneticPlanMayCorrectTypingErrorsAndIsNeverInserted() throws {
        let request = makeRequest("nihaima")
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"pinyin_syllables":"ni hao ma","action":"replace_target","converted_segments":["你好吗？"]}"#,
            for: request
        )
        #expect(result.text == "你好吗？")
    }

    @Test func phoneticPlanAllowsInputSeparatorsEnglishAndDigits() throws {
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"pinyin_syllables":"wo zai xi an yong Python 3","action":"replace_target","converted_segments":["我在西安","用","Python","3"]}"#,
            for: makeRequest("wozaiXi'an yong Python 3")
        )
        #expect(result.text == "我在西安 用 Python 3")
    }

    @Test func numericPronunciationInPhoneticPlanDoesNotRejectAValidResult() throws {
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"pinyin_syllables":"ming tian san dian bu kai hui","action":"replace_target","converted_segments":["明天三点不开会"]}"#,
            for: makeRequest("mingtian3dianbukaihui")
        )
        #expect(result.text == "明天三点不开会")
    }

    @Test func pinyinConversionCannotRewriteOrExtendProtectedURLs() throws {
        let request = makeRequest("qingdakai https://example.test/linji?x=3.5")
        let valid = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"action":"replace_target","converted_segments":["请打开","https://example.test/linji?x=3.5"]}"#,
            for: request
        )
        #expect(valid.text == "请打开 https://example.test/linji?x=3.5")
        for output in [
            #"{"action":"replace_target","converted_segments":["请打开","https://example.test/林霁?x=3.5"]}"#,
            #"{"action":"replace_target","converted_segments":["请打开","https://example.test/linji?x=3.5&extra=1"]}"#,
        ] {
            #expect(throws: TextEditValidationError.self) {
                try TextEditValidator.parseAndValidate(rawOutput: output, for: request)
            }
        }
    }

    @Test func joinedPinyinAroundDecimalsAndVersionsCanBeConverted() throws {
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"converted_segments":["我买了十二个苹果，每个3.5元","用 Python3.12 记录"]}"#,
            for: makeRequest("womaile12gepingguomeige3.5yuan yongPython3.12jilu")
        )
        #expect(result.text == "我买了十二个苹果每个3.5元 用 Python3.12 记录")
    }

    @Test func mixedDraftPromptIncludesLiteralBoundariesWithoutSwallowingPinyin() throws {
        let prompt = TextEditPromptBuilder.build(for: makeRequest("你好 2026-09-03 15:30 shiyongPython3.12 meige3.5yuan"))
        let json = try #require(prompt.user.components(separatedBy: "<input_json>\n").last?
            .components(separatedBy: "\n</input_json>").first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["pinyin"] as? String == "你好 2026-09-03 15:30 shiyongPython3.12 meige3.5yuan")
        #expect(object["protected_literals"] as? [String] == ["2026-09-03", "15:30", "3.12", "3.5"])
    }

    @Test(arguments: ["2026-09-04 15:30 Python3.12", "2026-09-03 15:31 Python3.12", "2026-09-03 15:30 Python3.13"])
    func conversionRejectsChangedDatesTimesAndVersions(output: String) throws {
        let raw = try JSONSerialization.data(withJSONObject: ["converted_segments": output.components(separatedBy: " ")])
        #expect(throws: TextEditValidationError.self) {
            try TextEditValidator.parseAndValidate(
                rawOutput: String(decoding: raw, as: UTF8.self),
                for: makeRequest("2026-09-03 15:30 shiyongPython3.12")
            )
        }
    }

    @Test(arguments: [PunctuationOutputPreference.normal, .spaces, .english])
    func userBoundariesSurviveModelSpacingAndInventedClauses(_ preference: PunctuationOutputPreference) throws {
        var request = makeRequest("mangya  gongzuoduojiumeigushang\nxiacizhuyi")
        request.punctuationPreference = preference
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"converted_segments":["忙 呀，","工 作 多，\n就 没 顾 上。","下 次 注 意！"]}"#,
            for: request
        )
        #expect(result.text == "忙呀  工作多就没顾上\n下次注意")
    }

    @Test func segmentsKeepCodeSpacesAndProtectedPunctuation() throws {
        let request = makeRequest("qingba `value = 3.5`  fangzai https://example.test/a?x=3.5")
        #expect(PinyinDraftLayout(request.targetText).segments == [
            "qingba", "`value = 3.5`", "fangzai", "https://example.test/a?x=3.5",
        ])
        let result = try TextEditValidator.parseAndValidate(
            rawOutput: #"{"converted_segments":["请 把，","`value = 3.5`","放 在，","https://example.test/a?x=3.5"]}"#,
            for: request
        )
        #expect(result.text == "请把 `value = 3.5`  放在 https://example.test/a?x=3.5")
    }

    @Test(arguments: [
        #"{"converted_segments":["你好你在吗"]}"#,
        #"{"converted_segments":["你好","你在","吗"]}"#,
        #"{"converted_segments":["你好",""]}"#,
    ])
    func changedOrEmptySegmentsAreRejected(output: String) {
        #expect(throws: TextEditValidationError.self) {
            try TextEditValidator.parseAndValidate(rawOutput: output, for: makeRequest("你好 nizaima"))
        }
    }

    @Test func protectedLiteralsCannotMoveAcrossUserBoundaries() {
        #expect(throws: TextEditValidationError.self) {
            try TextEditValidator.parseAndValidate(
                rawOutput: #"{"converted_segments":["请在","3.5元付好账"]}"#,
                for: makeRequest("qingzai3.5yuan fuhaozhang")
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
