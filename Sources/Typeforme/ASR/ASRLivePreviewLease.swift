import Foundation

enum ASRLivePreviewLeaseError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

@MainActor
struct ASRLivePreviewLease {
    let provider: String
    let languageIDs: [String]
    let session: any ASRLivePreviewSession

    private let returnIdleHandler: @MainActor (String) -> Void
    private let preloadReplacementHandler: @MainActor () -> Void

    init(
        provider: String,
        languageIDs: [String],
        session: any ASRLivePreviewSession,
        returnIdleHandler: @escaping @MainActor (String) -> Void,
        preloadReplacementHandler: @escaping @MainActor () -> Void
    ) {
        self.provider = provider
        self.languageIDs = languageIDs
        self.session = session
        self.returnIdleHandler = returnIdleHandler
        self.preloadReplacementHandler = preloadReplacementHandler
    }

    func returnIdle(reason: String) {
        returnIdleHandler(reason)
    }

    func preloadReplacement() {
        preloadReplacementHandler()
    }
}

@MainActor
enum ASRLivePreviewLeaseFactory {
    static func take(
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) throws -> ASRLivePreviewLease {
        switch source {
        case .nvidiaNemotron:
            return try takeNvidiaNemotron(
                requestedLanguageIDs: requestedLanguageIDs,
                diagnosticID: diagnosticID,
                onTranscript: onTranscript
            )
        case .off:
            throw ASRLivePreviewLeaseError.unavailable("Live preview is off")
        case .appleSpeech:
            throw ASRLivePreviewLeaseError.unavailable("Apple Speech live preview is local-only")
        }
    }

    private static func takeNvidiaNemotron(
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) throws -> ASRLivePreviewLease {
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            throw ASRLivePreviewLeaseError.unavailable("NVIDIA Nemotron ASR is not enabled")
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            throw ASRLivePreviewLeaseError.unavailable(
                "NVIDIA Nemotron ASR does not support the selected live preview languages"
            )
        }
        let session = try NvidiaNemotronWarmPool.shared.takeOrStart(
            languageIDs: languageIDs,
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
        return ASRLivePreviewLease(
            provider: session.provider,
            languageIDs: languageIDs,
            session: session,
            returnIdleHandler: { reason in
                NvidiaNemotronWarmPool.shared.returnIdle(
                    session,
                    languageIDs: languageIDs,
                    reason: reason
                )
            },
            preloadReplacementHandler: {
                NvidiaNemotronWarmPool.shared.preload(languageIDs: languageIDs)
            }
        )
    }
}
