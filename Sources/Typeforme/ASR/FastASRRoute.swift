import Foundation

@MainActor
struct FastASRRoute: Sendable {
    let source: RecognitionSource
    let languageIDs: [String]

    static func resolve(
        languageIDs requestedLanguageIDs: [String],
        source requestedSource: RecognitionSource = AppSettings.fastASRSource,
        enabledSources: [RecognitionSource] = AppSettings.configuredRecognitionSources
    ) throws -> FastASRRoute {
        let readiness = readinessReport(
            for: requestedSource,
            languageIDs: requestedLanguageIDs,
            enabledSources: enabledSources
        )
        guard readiness.ready else {
            throw ASRAudioSupportError.httpStatus(
                503,
                "Fast ASR source is not ready: \(readiness.reason)"
            )
        }
        let supportedOptions = requestedSource.supportedLanguages()
        let languageIDs = normalizedFastLanguageIDs(
            requestedLanguageIDs,
            supportedOptions: supportedOptions
        )
        guard !languageIDs.isEmpty else {
            throw ASRAudioSupportError.httpStatus(
                422,
                "\(requestedSource.displayName) does not support the selected languages"
            )
        }
        return FastASRRoute(
            source: requestedSource,
            languageIDs: languageIDs
        )
    }

    static func readinessReport(
        for source: RecognitionSource = AppSettings.fastASRSource,
        languageIDs requestedLanguageIDs: [String] = AppSettings.asrLanguageIDs,
        enabledSources: [RecognitionSource] = AppSettings.configuredRecognitionSources
    ) -> BridgeSourceAvailability {
        guard enabledSources.contains(source) else {
            return BridgeSourceAvailability(
                canEnable: false,
                ready: false,
                status: "source_disabled",
                reason: "\(source.displayName) is not enabled."
            )
        }
        let supportedOptions = source.supportedLanguages()
        guard !normalizedFastLanguageIDs(requestedLanguageIDs, supportedOptions: supportedOptions).isEmpty else {
            return BridgeSourceAvailability(
                canEnable: false,
                ready: false,
                status: "unsupported_language",
                reason: "\(source.displayName) does not support the selected languages."
            )
        }
        switch source {
        case .qwen:
            let ready = ASRFactory.shared.isQwenLlamaInstalledForCurrentSettings
            return BridgeSourceAvailability(
                canEnable: true,
                ready: ready,
                status: ready ? "ready" : "model_missing",
                reason: ready ? "Qwen3-ASR is ready." : "Qwen3-ASR model is not installed."
            )
        case .nvidiaNemotron:
            let status = NvidiaNemotronASRService.bundledRuntimeStatus()
            return BridgeSourceAvailability(
                canEnable: true,
                ready: status.isReady,
                status: status.isReady ? "ready" : "model_missing",
                reason: status.isReady ? "NVIDIA Nemotron ASR is ready." : status.detail
            )
        case .appleSpeech:
            return AppleSpeechAvailability.sourceAvailability(languageIDs: requestedLanguageIDs)
        }
    }

    private static func normalizedFastLanguageIDs(
        _ requestedLanguageIDs: [String],
        supportedOptions: [ASRLanguageOption]
    ) -> [String] {
        guard !supportedOptions.isEmpty else { return [] }
        let filtered = ASRLanguageSelection.filteredIDs(
            requestedLanguageIDs,
            supportedOptions: supportedOptions
        )
        if !filtered.isEmpty { return filtered }
        guard requestedLanguageIDs.isEmpty else { return [] }
        return ASRLanguageSelection.validatedIDs([], supportedOptions: supportedOptions)
    }
}
