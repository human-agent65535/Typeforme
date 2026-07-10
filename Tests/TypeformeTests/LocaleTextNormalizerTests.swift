import Testing
@testable import Typeforme

@Suite("LocaleTextNormalizer")
struct LocaleTextNormalizerTests {
    @Test func simplifiedChineseNormalizesTraditionalCharacters() {
        let text = LocaleTextNormalizer.normalize("這是一個測試，語音輸入", locale: "zh-CN")
        #expect(text == "这是一个测试，语音输入")
    }

    @Test func traditionalChineseNormalizesSimplifiedCharacters() {
        let text = LocaleTextNormalizer.normalize("这是一个测试，语音输入", locale: "zh-TW")
        #expect(text == "這是一個測試，語音輸入")
    }

    @Test func autoPreservesMixedLanguageText() {
        let text = "今天 ship 这个 feature"
        #expect(LocaleTextNormalizer.normalize(text, languageIDs: ["en-US", "ja"]) == text)
    }

    @Test func mixedSimplifiedChineseNormalizesChineseOnly() {
        let text = LocaleTextNormalizer.normalize("今天 ship 這個 feature", languageIDs: ["zh-CN", "en-US"])
        #expect(text == "今天 ship 这个 feature")
    }

    @Test func simplifiedChineseDoesNotCorruptJapaneseKanji() {
        let text = LocaleTextNormalizer.normalize("この機能は便利だけど UI が少し重い", languageIDs: ["zh-CN", "ja"])
        #expect(text == "この機能は便利だけど UI が少し重い")
    }

    @Test func mixedChineseAndJapaneseNormalizesOnlyChineseRuns() {
        let text = LocaleTextNormalizer.normalize("這個功能很好 この機能を見て", languageIDs: ["zh-CN", "ja"])
        #expect(text == "这个功能很好 この機能を見て")
    }

    @Test func promptInstructionPreservesSelectedLanguageSegments() {
        let prompt = LocaleTextNormalizer.promptInstruction(for: ["vi", "zh-CN"])
        #expect(prompt.contains("do not translate"))
        #expect(prompt.contains("Preserve code-switching"))
        #expect(prompt.contains("Chinese script: Simplified"))
    }

    @Test func scriptConversionDoesNotAlterProtectedTechnicalSpans() {
        let url = "https://例子.test/資料?q=繁體,保留"
        let path = "\"/使用者/資料\""
        let code = "`let 名稱 = \"繁體\"`"
        let input = "這是正文 \(url) \(path) \(code)"
        let output = LocaleTextNormalizer.normalize(input, languageIDs: ["zh-CN"])

        #expect(output.hasPrefix("这是正文 "))
        #expect(output.contains(url))
        #expect(output.contains(path))
        #expect(output.contains(code))
    }

    @Test func unquotedPathDoesNotSwallowAdjacentChineseProse() {
        let input = "請檢查 /使用者/資料這個路徑，然後繼續"
        let output = LocaleTextNormalizer.normalize(input, languageIDs: ["zh-CN"])

        #expect(output == "请检查 /使用者/资料这个路径，然后继续")
    }
}
