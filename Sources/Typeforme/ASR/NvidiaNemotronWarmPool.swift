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

    private init() {}

    func preloadForCurrentSettings() {
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            terminateIdle(reason: "source_disabled")
            return
        }
        preload(languageIDs: AppSettings.asrLanguageIDs)
    }

    func preload(languageIDs requestedLanguageIDs: [String]) {
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            terminateIdle(reason: "source_disabled")
            return
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            terminateIdle(reason: "unsupported_language")
            return
        }

        let key = Self.key(for: languageIDs)
        if let idle {
            if idle.key == key, idle.session.isRunning {
                return
            }
            terminateIdleSession(reason: "key_changed")
        }
        if let warmingSession {
            if warmingKey == key, warmingSession.isRunning {
                return
            }
            terminateWarming(reason: "key_changed")
        }

        do {
            let diagnosticID = Self.warmDiagnosticID()
            let session = try NvidiaNemotronLivePreviewSession.start(
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
                await self?.finishPreload(
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
        languageIDs requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) throws -> NvidiaNemotronLivePreviewSession {
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            throw ASRAudioSupportError.httpStatus(
                422,
                "NVIDIA Nemotron ASR does not support the selected languages"
            )
        }
        let key = Self.key(for: languageIDs)
        if let idle {
            self.idle = nil
            if idle.key == key, idle.session.isRunning {
                idle.session.prepareForUse(diagnosticID: diagnosticID, onTranscript: onTranscript)
                return idle.session
            }
            idle.session.terminate(reason: "key_changed_on_take")
        }
        if let warmingSession {
            let reason = warmingKey == key ? "take_during_warmup" : "key_changed_on_take"
            self.warmingSession = nil
            warmingKey = nil
            warmingSession.terminate(reason: reason)
        }

        let session = try NvidiaNemotronLivePreviewSession.start(
            languageIDs: languageIDs,
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
        return session
    }

    func returnIdle(
        _ session: NvidiaNemotronLivePreviewSession,
        languageIDs requestedLanguageIDs: [String],
        reason: String
    ) {
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            session.terminate(reason: "return_while_disabled")
            return
        }
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            session.terminate(reason: "return_unsupported_language")
            return
        }
        let key = Self.key(for: languageIDs)
        guard session.isRunning else {
            preload(languageIDs: languageIDs)
            return
        }

        terminateIdle(reason: "replace_idle")
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
        var sessions: [NvidiaNemotronLivePreviewSession] = []
        if let warmingSession {
            sessions.append(warmingSession)
        }
        if let idleSession = idle?.session,
           !sessions.contains(where: { $0 === idleSession }) {
            sessions.append(idleSession)
        }
        warmingSession = nil
        warmingKey = nil
        idle = nil

        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask {
                    await session.terminateAndWait(reason: reason)
                }
            }
        }
    }

    private func terminateIdleSession(reason: String) {
        guard let idle else { return }
        self.idle = nil
        idle.session.terminate(reason: reason)
    }

    private func terminateWarming(reason: String) {
        guard let warmingSession else { return }
        self.warmingSession = nil
        warmingKey = nil
        warmingSession.terminate(reason: reason)
    }

    private func finishPreload(
        _ session: NvidiaNemotronLivePreviewSession,
        key: String,
        languageIDs: [String],
        warmed: Bool
    ) {
        guard warmingSession === session, warmingKey == key else {
            session.terminate(reason: "warmup_superseded")
            return
        }
        warmingSession = nil
        warmingKey = nil

        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            session.terminate(reason: "source_disabled_after_warmup")
            return
        }
        guard session.isRunning, warmed else {
            session.terminate(reason: warmed ? "warmup_process_stopped" : "warmup_failed")
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

    private static func key(for languageIDs: [String]) -> String {
        [
            AppSettings.asrNvidiaNemotronModelID,
            "target=\(NvidiaNemotronASRService.targetLanguage(for: languageIDs))",
            "languages=\(languageIDs.joined(separator: ","))",
        ].joined(separator: "|")
    }

    private static func warmDiagnosticID() -> String {
        "warm-\(UUID().uuidString)"
    }
}
