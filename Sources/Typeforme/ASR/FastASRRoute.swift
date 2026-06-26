import Foundation

@MainActor
struct FastASRRoute: Sendable {
    let source: RecognitionSource
    let languageIDs: [String]

    static func resolve(languageIDs requestedLanguageIDs: [String]) -> FastASRRoute {
        if qwenIsEnabledAndReady(for: requestedLanguageIDs) {
            return FastASRRoute(
                source: .qwen,
                languageIDs: ASRLanguageSelection.validatedIDs(
                    requestedLanguageIDs,
                    supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
                )
            )
        }

        return FastASRRoute(
            source: .appleSpeech,
            languageIDs: ASRLanguageSelection.validatedIDs(
                requestedLanguageIDs,
                supportedOptions: ASRLanguageSelection.supportedOptions(for: .appleSpeech)
            )
        )
    }

    private static func qwenIsEnabledAndReady(for requestedLanguageIDs: [String]) -> Bool {
        guard AppSettings.configuredRecognitionSources.contains(.qwen),
              ASRFactory.shared.isQwenLlamaInstalledForCurrentSettings
        else { return false }

        let qwenLanguageIDs = ASRLanguageSelection.filteredIDs(
            requestedLanguageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        return !qwenLanguageIDs.isEmpty
    }
}
