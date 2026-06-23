import Foundation

@MainActor
final class NvidiaNemotronWarmPool {
    static let shared = NvidiaNemotronWarmPool()

    private struct IdleSession {
        let key: String
        let languageIDs: [String]
        let session: NvidiaNemotronLivePreviewSession
        let createdAt: Date
    }

    private var idle: IdleSession?

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
            terminateIdle(reason: "key_changed")
        }

        do {
            let diagnosticID = Self.warmDiagnosticID()
            let session = try NvidiaNemotronLivePreviewSession.start(
                languageIDs: languageIDs,
                diagnosticID: diagnosticID,
                onTranscript: { _ in }
            )
            session.prepareForIdle(diagnosticID: diagnosticID)
            idle = IdleSession(
                key: key,
                languageIDs: languageIDs,
                session: session,
                createdAt: Date()
            )
            Log.asr.info(
                "NVIDIA Nemotron warm helper started languages=\(languageIDs.joined(separator: ","), privacy: .public)"
            )
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
        guard let idle else { return }
        self.idle = nil
        idle.session.terminate(reason: reason)
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
