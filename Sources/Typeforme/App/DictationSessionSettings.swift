import Foundation

/// Immutable settings used by one recording from start through commit. A
/// settings-window role or ASR change applies to the next recording and cannot
/// splice a different pipeline into audio that is already in flight.
struct DictationSessionSettings: Sendable, Equatable {
    let processingMode: ProcessingMode
    let correctionMode: CorrectionMode
    let recognitionSources: [RecognitionSource]
    let transcriptionLanguageIDs: [String]
    let fastASRSource: RecognitionSource?
    let configuredFastASRSource: RecognitionSource
    let numberOutputPreference: NumberOutputPreference
    let punctuationPreference: PunctuationOutputPreference
    let correctionTimeoutMs: Int
    let voiceLivePreviewEnabled: Bool
    let voiceLivePreviewSource: VoiceLivePreviewSource
    let clientBridgeRecognitionSources: [RecognitionSource]
    let clientBridgeConfiguration: ClientBridgeConfiguration
    let maxRecordingDuration: TimeInterval

    var usesRemoteBridge: Bool {
        processingMode == .client
    }

    var canonicalRecognitionSources: [RecognitionSource] {
        guard !usesRemoteBridge else { return [] }
        if correctionMode == .fast {
            return fastASRSource.map { [$0] } ?? []
        }
        return recognitionSources
    }

    @MainActor
    static func capture() throws -> DictationSessionSettings {
        let processingMode = AppSettings.processingMode
        let correctionMode = AppSettings.correctionMode
        let recognitionSources = AppSettings.enabledRecognitionSources
        let serverLanguageIDs = AppSettings.asrCanonicalLanguageIDs
        let clientLanguageIDs = AppSettings.clientLanguageIDs

        let transcriptionLanguageIDs: [String]
        let fastASRSource: RecognitionSource?
        switch processingMode {
        case .client:
            transcriptionLanguageIDs = clientLanguageIDs
            fastASRSource = nil
        case .server where correctionMode == .fast:
            let route = try FastASRRoute.resolve(
                languageIDs: serverLanguageIDs,
                source: AppSettings.fastASRSource,
                enabledSources: recognitionSources
            )
            transcriptionLanguageIDs = route.languageIDs
            fastASRSource = route.source
        case .server:
            guard !recognitionSources.isEmpty else {
                throw ASRAudioSupportError.httpStatus(503, "No ASR source enabled")
            }
            transcriptionLanguageIDs = ASRLanguageSelection.validatedIDsForTranscription(
                serverLanguageIDs,
                sources: recognitionSources
            )
            fastASRSource = nil
        }

        return DictationSessionSettings(
            processingMode: processingMode,
            correctionMode: correctionMode,
            recognitionSources: recognitionSources,
            transcriptionLanguageIDs: transcriptionLanguageIDs,
            fastASRSource: fastASRSource,
            configuredFastASRSource: AppSettings.fastASRSource,
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            voiceLivePreviewEnabled: AppSettings.voiceLivePreview,
            voiceLivePreviewSource: AppSettings.voiceLivePreviewSource,
            clientBridgeRecognitionSources: AppSettings.clientBridgeEnabledRecognitionSources,
            clientBridgeConfiguration: .current,
            maxRecordingDuration: AppSettings.maxRecordingDuration
        )
    }
}

/// Settings and the local ASR instance owned by one recording. Capturing the
/// service before audio starts keeps model switches from replacing or retiring
/// the backend underneath an in-flight recording. Client sessions intentionally
/// own no local ASR service.
struct DictationASRSession: Sendable {
    let settings: DictationSessionSettings
    let localASRService: (any ASRService)?

    @MainActor
    init(
        settings: DictationSessionSettings,
        makeLocalASRService: (DictationSessionSettings) throws -> any ASRService
    ) throws {
        self.settings = settings
        self.localASRService = settings.usesRemoteBridge
            ? nil
            : try makeLocalASRService(settings)
    }
}
