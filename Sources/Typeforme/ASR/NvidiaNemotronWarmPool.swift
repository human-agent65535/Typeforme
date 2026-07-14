import Foundation

@MainActor
final class NvidiaNemotronWarmPool {
    static let shared = NvidiaNemotronWarmPool()
    private static let warmupTimeout: TimeInterval = 8

    private struct IdleSession {
        let key: String
        let languageIDs: [String]
        let session: NvidiaNemotronLivePreviewSession
        let createdAt: Date
    }

    private var idle: IdleSession?
    private var warmingKey: String?
    private var warmingSession: NvidiaNemotronLivePreviewSession?
    private var isStopping = false
    // A new helper never starts until the previous process has exited.
    private let terminationQueue = SerialMainActorTaskQueue()

    private init() {}

    func preloadForCurrentSettings() async {
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            terminateIdle(reason: "source_disabled")
            return
        }
        let configuration = NvidiaNemotronASRConfiguration.capture(
            requestTimeoutSeconds: AppSettings.asrTimeoutSeconds(for: [.nvidiaNemotron])
        )
        await preload(
            configuration: configuration,
            languageIDs: AppSettings.asrCanonicalLanguageIDs
        )
    }

    func preload(languageIDs requestedLanguageIDs: [String]) async {
        let configuration = NvidiaNemotronASRConfiguration.capture(
            requestTimeoutSeconds: AppSettings.asrTimeoutSeconds(for: [.nvidiaNemotron])
        )
        await preload(configuration: configuration, languageIDs: requestedLanguageIDs)
    }

    private func preload(
        configuration: NvidiaNemotronASRConfiguration,
        languageIDs requestedLanguageIDs: [String]
    ) async {
        await waitForPendingTerminations()
        guard canStartHelpers else {
            terminateIdle(reason: "source_disabled")
            return
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            terminateIdle(reason: "unsupported_language")
            return
        }

        let key = configuration.reuseKey(languageIDs: languageIDs)
        if let idle {
            if idle.key == key, idle.session.isRunning {
                return
            }
            terminateIdleSession(reason: "key_changed")
            await waitForPendingTerminations()
            guard canStartHelpers else { return }
        }
        if let warmingSession {
            if warmingKey == key, warmingSession.isRunning {
                return
            }
            terminateWarming(reason: "key_changed")
            await waitForPendingTerminations()
            guard canStartHelpers else { return }
        }

        do {
            let diagnosticID = Self.warmDiagnosticID()
            let session = try NvidiaNemotronLivePreviewSession.start(
                configuration: configuration,
                languageIDs: languageIDs,
                diagnosticID: diagnosticID,
                onTranscript: { _ in }
            )
            warmingKey = key
            warmingSession = session
            Log.asr.info(
                "NVIDIA Nemotron warm helper started languages=\(languageIDs.joined(separator: ","), privacy: .public)"
            )
            Task { [weak self, session, key, languageIDs] in
                let warmed = await session.warmUpWithDecodedSilence(timeout: Self.warmupTimeout)
                self?.finishPreload(
                    session,
                    key: key,
                    languageIDs: languageIDs,
                    warmed: warmed
                )
            }
        } catch {
            Log.asr.error("NVIDIA Nemotron warm helper failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func takeOrStart(
        configuration: NvidiaNemotronASRConfiguration,
        languageIDs requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> NvidiaNemotronLivePreviewSession {
        await waitForPendingTerminations()
        guard canStartHelpers else {
            throw ASRAudioSupportError.httpStatus(503, "NVIDIA Nemotron ASR is shutting down")
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            throw ASRAudioSupportError.httpStatus(
                422,
                "NVIDIA Nemotron ASR does not support the selected languages"
            )
        }
        let key = configuration.reuseKey(languageIDs: languageIDs)
        if let idle {
            self.idle = nil
            if idle.key == key, idle.session.isRunning {
                idle.session.prepareForUse(diagnosticID: diagnosticID, onTranscript: onTranscript)
                return idle.session
            }
            trackTermination(of: idle.session, reason: "key_changed_on_take")
            await waitForPendingTerminations()
            guard canStartHelpers else {
                throw ASRAudioSupportError.httpStatus(503, "NVIDIA Nemotron ASR pool was invalidated")
            }
        }
        if let warmingSession {
            let reason = warmingKey == key ? "take_during_warmup" : "key_changed_on_take"
            self.warmingSession = nil
            warmingKey = nil
            trackTermination(of: warmingSession, reason: reason)
            await waitForPendingTerminations()
            guard canStartHelpers else {
                throw ASRAudioSupportError.httpStatus(503, "NVIDIA Nemotron ASR pool was invalidated")
            }
        }

        let session = try NvidiaNemotronLivePreviewSession.start(
            configuration: configuration,
            languageIDs: languageIDs,
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
        return session
    }

    func returnIdle(
        _ session: NvidiaNemotronLivePreviewSession,
        configuration: NvidiaNemotronASRConfiguration,
        languageIDs requestedLanguageIDs: [String],
        reason: String
    ) async {
        guard canStartHelpers else {
            await discard(session, reason: "return_while_stopping_\(reason)")
            return
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            await discard(session, reason: "return_unsupported_language")
            return
        }
        let key = configuration.reuseKey(languageIDs: languageIDs)
        guard Self.currentKey(for: languageIDs) == key else {
            await discard(session, reason: "return_after_current_settings_changed")
            return
        }
        guard session.isRunning else {
            await discard(session, reason: "return_after_process_stopped")
            return
        }

        if idle != nil || warmingSession != nil {
            terminateIdle(reason: "replace_idle")
            await waitForPendingTerminations()
        }
        guard canStartHelpers, Self.currentKey(for: languageIDs) == key else {
            await discard(session, reason: "return_after_current_settings_changed")
            return
        }
        let diagnosticID = Self.warmDiagnosticID()
        session.prepareForIdle(diagnosticID: diagnosticID)
        idle = IdleSession(
            key: key,
            languageIDs: languageIDs,
            session: session,
            createdAt: Date()
        )
    }

    func terminateIdle(reason: String) {
        terminateWarming(reason: reason)
        terminateIdleSession(reason: reason)
    }

    /// Process-exit cleanup must wait for warm helpers to terminate; merely
    /// sending SIGTERM is insufficient because child processes survive a
    /// command-line invocation that calls `exit` immediately afterwards.
    func shutdown(reason: String) async {
        if isStopping {
            await waitForPendingTerminations()
            return
        }
        isStopping = true
        terminateIdle(reason: reason)
        await waitForPendingTerminations()
        isStopping = false
    }

    private func terminateIdleSession(reason: String) {
        guard let idle else { return }
        self.idle = nil
        trackTermination(of: idle.session, reason: reason)
    }

    private func terminateWarming(reason: String) {
        guard let warmingSession else { return }
        self.warmingSession = nil
        warmingKey = nil
        trackTermination(of: warmingSession, reason: reason)
    }

    private func finishPreload(
        _ session: NvidiaNemotronLivePreviewSession,
        key: String,
        languageIDs: [String],
        warmed: Bool
    ) {
        // Whoever replaced this warmup already owns its termination.
        guard warmingSession === session, warmingKey == key else { return }
        warmingSession = nil
        warmingKey = nil

        guard !isStopping, key == Self.currentKey(for: languageIDs) else {
            trackTermination(of: session, reason: "warmup_runtime_changed")
            return
        }
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            trackTermination(of: session, reason: "source_disabled_after_warmup")
            return
        }
        guard session.isRunning, warmed else {
            trackTermination(
                of: session,
                reason: warmed ? "warmup_process_stopped" : "warmup_failed"
            )
            Log.asr.error(
                "NVIDIA Nemotron warm helper failed during decoded warmup languages=\(languageIDs.joined(separator: ","), privacy: .public)"
            )
            return
        }

        session.prepareForIdle(diagnosticID: Self.warmDiagnosticID())
        idle = IdleSession(
            key: key,
            languageIDs: languageIDs,
            session: session,
            createdAt: Date()
        )
        Log.asr.info(
            "NVIDIA Nemotron warm helper ready languages=\(languageIDs.joined(separator: ","), privacy: .public)"
        )
    }

    func discardAndPreload(
        _ session: NvidiaNemotronLivePreviewSession,
        languageIDs: [String],
        reason: String
    ) async {
        await discard(session, reason: reason)
        guard canStartHelpers else { return }
        await preload(languageIDs: languageIDs)
    }

    func discard(_ session: NvidiaNemotronLivePreviewSession, reason: String) async {
        trackTermination(of: session, reason: reason)
        await waitForPendingTerminations()
    }

    private func trackTermination(of session: NvidiaNemotronLivePreviewSession, reason: String) {
        session.terminate(reason: reason)
        terminationQueue.enqueue {
            await session.terminateAndWait(reason: reason)
        }
    }

    private func waitForPendingTerminations() async {
        await terminationQueue.waitForAll()
    }

    private var canStartHelpers: Bool {
        !isStopping
            && AppSettings.processingMode == .server
            && AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron)
    }

    private static func currentKey(for languageIDs: [String]) -> String {
        NvidiaNemotronASRConfiguration.capture(
            requestTimeoutSeconds: AppSettings.asrTimeoutSeconds(for: [.nvidiaNemotron])
        ).reuseKey(languageIDs: languageIDs)
    }

    private static func warmDiagnosticID() -> String {
        "warm-\(UUID().uuidString)"
    }
}
