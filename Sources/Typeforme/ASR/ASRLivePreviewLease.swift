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

    private let returnIdleHandler: @MainActor (String) async -> Void
    private let preloadReplacementHandler: @MainActor () async -> Void
    private let discardHandler: @MainActor (String) async -> Void
    private let terminalAction = ASRLivePreviewLeaseTerminalAction()

    init(
        provider: String,
        languageIDs: [String],
        session: any ASRLivePreviewSession,
        returnIdleHandler: @escaping @MainActor (String) async -> Void,
        preloadReplacementHandler: @escaping @MainActor () async -> Void,
        discardHandler: (@MainActor (String) async -> Void)? = nil
    ) {
        self.provider = provider
        self.languageIDs = languageIDs
        self.session = session
        self.returnIdleHandler = returnIdleHandler
        self.preloadReplacementHandler = preloadReplacementHandler
        self.discardHandler = discardHandler ?? { reason in
            session.terminate(reason: reason)
        }
    }

    func returnIdle(reason: String) async {
        guard terminalAction.claim() else { return }
        await returnIdleHandler(reason)
    }

    func preloadReplacement() async {
        guard terminalAction.claim() else { return }
        await preloadReplacementHandler()
    }

    /// Permanently releases this checked-out session without starting a warm
    /// replacement. Mode changes and application shutdown use this path so a
    /// late preview cleanup cannot resurrect a helper after runtime teardown.
    func discard(reason: String) async {
        guard terminalAction.claim() else { return }
        await discardHandler(reason)
    }
}

@MainActor
private final class ASRLivePreviewLeaseTerminalAction {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

@MainActor
enum ASRLivePreviewLeaseFactory {
    static func take(
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> ASRLivePreviewLease {
        switch source {
        case .qwen:
            return try takeQwen(
                requestedLanguageIDs: requestedLanguageIDs,
                diagnosticID: diagnosticID,
                onTranscript: onTranscript
            )
        case .nvidiaNemotron:
            return try await takeNvidiaNemotron(
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

    private static func takeQwen(
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) throws -> ASRLivePreviewLease {
        guard AppSettings.enabledRecognitionSources.contains(.qwen) else {
            throw ASRLivePreviewLeaseError.unavailable("Qwen3-ASR is not enabled")
        }
        let languageIDs = ASRLanguageSelection.validatedIDs(
            requestedLanguageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        guard !languageIDs.isEmpty else {
            throw ASRLivePreviewLeaseError.unavailable(
                "Qwen3-ASR does not support the selected live preview languages"
            )
        }
        let backendLease: QwenLlamaASRServiceLease
        switch ASRFactory.shared.qwenLlamaLivePreviewServiceLease() {
        case .acquired(let lease):
            backendLease = lease
        case .unavailable(let reason):
            throw ASRLivePreviewLeaseError.unavailable(reason.message)
        }
        let session = try QwenLlamaLivePreviewSession.start(
            service: backendLease.service,
            languageIDs: languageIDs,
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
        return ASRLivePreviewLease(
            provider: session.provider,
            languageIDs: languageIDs,
            session: session,
            returnIdleHandler: { reason in
                _ = backendLease
                session.terminate(reason: reason)
            },
            preloadReplacementHandler: {
                _ = backendLease
                Task {
                    await ASRFactory.shared.preloadQwenLlama()
                }
            },
            discardHandler: { reason in
                _ = backendLease
                session.terminate(reason: reason)
            }
        )
    }

    private static func takeNvidiaNemotron(
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> ASRLivePreviewLease {
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            throw ASRLivePreviewLeaseError.unavailable("NVIDIA Nemotron ASR is not enabled")
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            throw ASRLivePreviewLeaseError.unavailable(
                "NVIDIA Nemotron ASR does not support the selected live preview languages"
            )
        }
        guard let runtimeLease = ASRFactory.shared.nvidiaNemotronRuntimeLease() else {
            throw ASRLivePreviewLeaseError.unavailable(
                "NVIDIA Nemotron ASR is temporarily unavailable during model maintenance"
            )
        }
        let configuration = NvidiaNemotronASRConfiguration.capture(
            requestTimeoutSeconds: AppSettings.asrTimeoutSeconds(for: [.nvidiaNemotron])
        )
        var acquiredSession: NvidiaNemotronLivePreviewSession?
        let session: NvidiaNemotronLivePreviewSession
        do {
            try Task.checkCancellation()
            let candidate = try await NvidiaNemotronWarmPool.shared.takeOrStart(
                configuration: configuration,
                languageIDs: languageIDs,
                diagnosticID: diagnosticID,
                onTranscript: onTranscript
            )
            acquiredSession = candidate
            try Task.checkCancellation()
            session = candidate
        } catch {
            if let acquiredSession {
                await NvidiaNemotronWarmPool.shared.discard(
                    acquiredSession,
                    reason: "live_preview_acquisition_cancelled"
                )
            }
            runtimeLease.release()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        return ASRLivePreviewLease(
            provider: session.provider,
            languageIDs: languageIDs,
            session: session,
            returnIdleHandler: { reason in
                await NvidiaNemotronWarmPool.shared.returnIdle(
                    session,
                    configuration: configuration,
                    languageIDs: languageIDs,
                    reason: reason
                )
                runtimeLease.release()
            },
            preloadReplacementHandler: {
                await NvidiaNemotronWarmPool.shared.discardAndPreload(
                    session,
                    languageIDs: languageIDs,
                    reason: "live_preview_replacement"
                )
                runtimeLease.release()
            },
            discardHandler: { reason in
                await NvidiaNemotronWarmPool.shared.discard(
                    session,
                    reason: reason
                )
                runtimeLease.release()
            }
        )
    }
}
