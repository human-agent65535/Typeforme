import Testing
@testable import Typeforme

@Suite("Apple Speech language support")
struct AppleSpeechLanguageSupportTests {
    @Test @MainActor func fastRoutePreservesCanonicalAppleLanguagesBeforeCacheResolution() {
        #expect(FastASRRoute.normalizedFastLanguageIDs(["af"], for: .appleSpeech) == ["af"])
        #expect(FastASRRoute.normalizedFastLanguageIDs(["af"], for: .qwen).isEmpty)
        #expect(FastASRRoute.normalizedFastLanguageIDs(["af"], for: .nvidiaNemotron).isEmpty)
    }

    @Test func settingsClampWaitsForAppleSupportResolution() {
        #expect(!ASRLanguageSelection.shouldClampSettingsSelection(
            sources: [.appleSpeech],
            appleSpeechSupportResolved: false
        ))
        #expect(!ASRLanguageSelection.shouldClampSettingsSelection(
            sources: [.qwen, .appleSpeech],
            appleSpeechSupportResolved: false
        ))
        #expect(ASRLanguageSelection.shouldClampSettingsSelection(
            sources: [.appleSpeech],
            appleSpeechSupportResolved: true
        ))
        #expect(ASRLanguageSelection.shouldClampSettingsSelection(
            sources: [.qwen],
            appleSpeechSupportResolved: false
        ))
    }

    @Test func localeCandidatesAreLimitedToRecognizerSupportedLocales() throws {
        let english = try #require(ASRLanguageSelection.option(for: "en-US"))
        let candidates = AppleSpeechLanguageSupport.candidateLocaleIdentifiers(
            for: english,
            supportedLocaleIdentifiers: ["fr-FR", "en-GB", "en-US", "zh-CN"]
        )

        #expect(candidates.first == "en-US")
        #expect(candidates.contains("en-GB"))
        #expect(!candidates.contains("fr-FR"))
        #expect(!candidates.contains("zh-CN"))
    }

    @Test func unavailablePreferredAliasIsNotProbed() throws {
        let english = try #require(ASRLanguageSelection.option(for: "en-US"))
        let candidates = AppleSpeechLanguageSupport.candidateLocaleIdentifiers(
            for: english,
            supportedLocaleIdentifiers: ["en-AU"]
        )

        #expect(candidates == ["en-AU"])
    }

    @Test func appleOnlySessionPreservesSavedCanonicalSelectionBeforeSupportResolution() {
        let savedCanonicalIDs = AppSettings.canonicalASRLanguageIDs(fromRawValue: "ja")
        let selected = ASRLanguageSelection.validatedIDsForTranscription(
            savedCanonicalIDs,
            sources: [.appleSpeech]
        )

        #expect(savedCanonicalIDs == ["ja"])
        #expect(selected == ["ja"])
        #expect(selected != ASRLanguageSelection.defaultIDs)
    }

    @Test func mixedRoutePreservesLanguagesThatRequireAppleResolution() {
        let selected = ASRLanguageSelection.validatedIDsForTranscription(
            ["af"],
            sources: [.qwen, .appleSpeech]
        )

        #expect(selected == ["af"])
    }

    @Test func explicitInvalidSelectionDoesNotFallBackToDefaultLanguages() {
        let selected = ASRLanguageSelection.validatedIDsForTranscription(
            ["not-a-language"],
            sources: [.appleSpeech]
        )

        #expect(selected.isEmpty)
    }
}
