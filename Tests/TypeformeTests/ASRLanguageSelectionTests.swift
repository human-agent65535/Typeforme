import Testing
@testable import Typeforme

@Suite("ASRLanguageSelection")
struct ASRLanguageSelectionTests {
    @Test func exposesLanguageCatalog() {
        #expect(ASRLanguageSelection.all.count >= 95)
        #expect(Set(ASRLanguageSelection.all.map(\.id)).count == ASRLanguageSelection.all.count)
        #expect(ASRLanguageSelection.option(for: "yue")?.displayName == "Cantonese")
    }

    @Test func singleLanguageProducesLanguageHint() {
        #expect(ASRLanguageSelection.languageHint(for: ["zh-CN"]) == "zh")
        #expect(ASRLanguageSelection.languageHint(for: ["en-US"]) == "en")
        #expect(ASRLanguageSelection.languageHint(for: ["ja"]) == "ja")
    }

    @Test func multipleLanguagesUseDetection() {
        #expect(ASRLanguageSelection.languageHint(for: ["zh-CN", "en-US"]) == nil)
        #expect(ASRLanguageSelection.languageCodes(for: ["zh-CN", "en-US"]) == ["zh", "en"])
    }

    @Test func compatibilityLanguageValuesAreCanonicalized() {
        #expect(ASRLanguageSelection.parse("zh-Hant") == ["zh-TW"])
        #expect(ASRLanguageSelection.parse("en") == ["en-US"])
        #expect(ASRLanguageSelection.parse("fil") == ["tl"])
        #expect(ASRLanguageSelection.parse("auto") == ASRLanguageSelection.defaultIDs)
    }

    @Test func qwenASRLanguageCatalogMatchesSupportedModelList() {
        let ids = Set(ASRLanguageSelection.qwenASRSupportedLanguages.map(\.id))
        #expect(ids.contains("vi"))
        #expect(ids.contains("tl"))
        #expect(ids.contains("ro"))
        #expect(!ids.contains("af"))
        #expect(ASRLanguageSelection.validatedIDs(["af", "vi"], sources: [.qwen]) == ["vi"])
    }

    @Test func nvidiaNemotronLanguageCatalogUsesOutOfBoxLocales() {
        let ids = Set(ASRLanguageSelection.nvidiaNemotronASRSupportedLanguages.map(\.id))
        #expect(ids.contains("zh-CN"))
        #expect(ids.contains("en-US"))
        #expect(ids.contains("ja"))
        #expect(ids.contains("vi"))
        #expect(ids.contains("pl"))
        #expect(!ids.contains("zh-TW"))
        #expect(!ids.contains("af"))
        #expect(ASRLanguageSelection.validatedIDs(["zh-TW", "ja"], sources: [.nvidiaNemotron]) == ["ja"])
    }

    @Test func multiSourceLanguageCatalogUsesSourceUnion() {
        let ids = Set(ASRLanguageSelection.supportedOptions(for: [.qwen, .nvidiaNemotron]).map(\.id))
        #expect(ids.contains("zh-CN"))
        #expect(ids.contains("zh-TW"))
        #expect(ids.contains("en-US"))
        #expect(ids.contains("ja"))
        #expect(ids.contains("vi"))
        #expect(!ids.contains("af"))
        #expect(
            ASRLanguageSelection.validatedIDs(
                ["zh-TW", "zh-CN"],
                sources: [.qwen, .nvidiaNemotron]
            ) == ["zh-CN", "zh-TW"]
        )
    }
}
