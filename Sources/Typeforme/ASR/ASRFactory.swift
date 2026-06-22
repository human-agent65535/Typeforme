import Foundation

@MainActor
final class ASRFactory {
    static let shared = ASRFactory()

    private var qwenLlama: QwenLlamaASRService?
    private var qwenLlamaKey: String?
    private var nvidiaNemotron: NvidiaNemotronASRService?

    func get() -> ASRService {
        MultiSourceASRService(sources: AppSettings.enabledRecognitionSources)
    }

    func preloadCachedActiveModel() async {
        let sources = AppSettings.enabledRecognitionSources
        async let qwen: Void = preloadQwenLlamaIfEnabled(sources)
        async let nvidia: Void = preloadNvidiaNemotronIfEnabled(sources)
        _ = await (qwen, nvidia)
    }

    private func preloadQwenLlamaIfEnabled(_ sources: [RecognitionSource]) async {
        guard sources.contains(.qwen) else { return }
        await preloadQwenLlama()
    }

    private func preloadNvidiaNemotronIfEnabled(_ sources: [RecognitionSource]) async {
        guard sources.contains(.nvidiaNemotron) else {
            NvidiaNemotronWarmPool.shared.terminateIdle(reason: "source_disabled")
            return
        }
        await preloadNvidiaNemotron()
    }

    func warmQwenLlama() async throws {
        try await ensureQwenLlamaInstalled()
        guard let service = qwenLlamaServiceAfterInstall() else {
            throw LlamaServerError.launchFailed("Bundled llama-server binary not found")
        }
        try await service.preload()
    }

    func ensureQwenLlamaInstalled() async throws {
        try AppPaths.ensureDirectories()
        try await ModelAutoInstaller.shared.ensureFile(
            atPath: AppSettings.asrQwenLlamaModelPath,
            downloadURLString: AppSettings.asrQwenLlamaModelDownloadURL,
            label: "Qwen3-ASR model"
        )
        try await ModelAutoInstaller.shared.ensureFile(
            atPath: AppSettings.asrQwenLlamaMMProjPath,
            downloadURLString: AppSettings.asrQwenLlamaMMProjDownloadURL,
            label: "Qwen3-ASR mmproj"
        )
    }

    func ensureNvidiaNemotronInstalled() async throws {
        try AppPaths.ensureDirectories()
        let spec = NvidiaNemotronASRModelCatalog.spec(for: AppSettings.asrNvidiaNemotronModelID)
        for file in spec.files {
            try await ModelAutoInstaller.shared.ensureFile(
                atPath: AppSettings.asrNvidiaNemotronPath(for: file),
                downloadURLString: AppSettings.asrNvidiaNemotronDownloadURL(for: file),
                label: "NVIDIA Nemotron \(file.label)",
                expectedBytes: file.expectedBytes
            )
        }
    }

    func preloadQwenLlama() async {
        guard FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaModelPath),
              FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaMMProjPath)
        else {
            Log.asr.notice("Qwen3-ASR preload skipped; model files not installed")
            return
        }
        do {
            try await warmQwenLlama()
            Log.asr.info("Qwen3-ASR GGUF preloaded")
        } catch {
            Log.asr.error("Qwen3-ASR GGUF preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func preloadNvidiaNemotron() async {
        let status = NvidiaNemotronASRService.bundledRuntimeStatus()
        if status.isReady {
            NvidiaNemotronWarmPool.shared.preloadForCurrentSettings()
            Log.asr.info("NVIDIA Nemotron ASR warm helper requested")
        } else {
            NvidiaNemotronWarmPool.shared.terminateIdle(reason: "runtime_not_ready")
            Log.asr.notice("NVIDIA Nemotron ASR preload skipped: \(status.detail, privacy: .public)")
        }
    }

    func stopQwenLlama() async {
        await qwenLlama?.stop()
        qwenLlama = nil
        qwenLlamaKey = nil
    }

    func stopNvidiaNemotron() {
        NvidiaNemotronWarmPool.shared.terminateIdle(reason: "stop_requested")
    }

    func nvidiaNemotronService() -> NvidiaNemotronASRService {
        if nvidiaNemotron == nil {
            nvidiaNemotron = NvidiaNemotronASRService()
        }
        return nvidiaNemotron!
    }

    func qwenLlamaServiceAfterInstall() -> QwenLlamaASRService? {
        qwenLlamaService()
    }

    private func qwenLlamaService() -> QwenLlamaASRService? {
        guard let binary = AppPaths.bundledLlamaServer else { return nil }
        let modelPath = AppSettings.asrQwenLlamaModelPath
        let mmprojPath = AppSettings.asrQwenLlamaMMProjPath
        let key = [
            modelPath,
            mmprojPath,
            binary.path,
            "timeout=\(AppSettings.asrQwenLlamaTimeoutSeconds)",
            "maxTokens=\(AppSettings.asrQwenLlamaMaxTokens)",
        ].joined(separator: "|")
        if qwenLlama == nil || qwenLlamaKey != key {
            let server = LlamaCppServerManager(
                modelPath: modelPath,
                contextSize: 4096,
                useFlashAttn: AppSettings.llamaUseFlashAttn,
                binaryURL: binary,
                pidFile: AppPaths.asrLlamaPidFile,
                requiredFiles: [mmprojPath],
                extraArguments: ["--mmproj", mmprojPath],
                coldTimeoutSec: min(max(AppSettings.asrQwenLlamaTimeoutSeconds, 30), 180)
            )
            qwenLlama = QwenLlamaASRService(server: server)
            qwenLlamaKey = key
        }
        return qwenLlama
    }
}

private struct UnavailableASRService: ASRService {
    let reason: String

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        throw ASRAudioSupportError.httpStatus(503, reason)
    }
}

private struct AutoInstallingQwenLlamaASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await ASRFactory.shared.ensureQwenLlamaInstalled()
        guard let service = await ASRFactory.shared.qwenLlamaServiceAfterInstall() else {
            throw ASRAudioSupportError.httpStatus(503, "Bundled llama-server binary not found")
        }
        return try await service.transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
    }

    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        let text = try await transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        return ASRTranscription(
            text: text,
            modelOutputs: [
                ASRModelOutputFactory.qwen(role: "source", text: text)
            ]
        )
    }
}

private struct AutoInstallingNvidiaNemotronASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await ASRFactory.shared.ensureNvidiaNemotronInstalled()
        return try await ASRFactory.shared.nvidiaNemotronService().transcribe(
            audioFileURL: audioFileURL,
            languageIDs: languageIDs
        )
    }

    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        let text = try await transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        return ASRTranscription(
            text: text,
            modelOutputs: [
                ASRModelOutputFactory.nemotron(role: "source", text: text)
            ]
        )
    }
}

private struct MultiSourceASRService: ASRService {
    let sources: [RecognitionSource]

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs).text
    }

    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        let enabledSources = sources.isEmpty ? RecognitionSource.defaultEnabled : sources
        let selectedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            sources: enabledSources
        )
        var attempts: [ASRSourceAttemptResult] = []
        await withTaskGroup(of: ASRSourceAttemptResult.self) { group in
            for (index, source) in enabledSources.enumerated() {
                group.addTask {
                    await Self.attempt(
                        source: source,
                        index: index,
                        audioFileURL: audioFileURL,
                        selectedLanguageIDs: selectedLanguageIDs
                    )
                }
            }
            for await attempt in group {
                attempts.append(attempt)
            }
        }

        let ordered = attempts.sorted { $0.index < $1.index }
        let successfulTexts = ordered
            .compactMap { $0.successText }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let transcript = successfulTexts.first else {
            let detail = ordered
                .map { "\($0.source.displayName): \($0.error ?? $0.status)" }
                .joined(separator: "; ")
            throw ASRAudioSupportError.httpStatus(
                503,
                detail.isEmpty ? "No recognition source produced a transcript" : detail
            )
        }
        var seen = Set([transcript])
        let alternates = successfulTexts.dropFirst().filter { seen.insert($0).inserted }
        let warnings = ordered.compactMap { attempt -> String? in
            guard attempt.status != "ok" else { return nil }
            return "\(attempt.source.displayName): \(attempt.error ?? attempt.status)"
        }
        return ASRTranscription(
            text: transcript,
            alternateTranscripts: alternates,
            modelOutputs: ordered.map(\.modelOutput),
            warnings: warnings
        )
    }

    private static func attempt(
        source: RecognitionSource,
        index: Int,
        audioFileURL: URL,
        selectedLanguageIDs: [String]
    ) async -> ASRSourceAttemptResult {
        let effectiveLanguageIDs = ASRLanguageSelection.effectiveIDs(selectedLanguageIDs, for: source)
        guard !effectiveLanguageIDs.isEmpty else {
            return ASRSourceAttemptResult(
                source: source,
                index: index,
                status: "skipped_unsupported_language",
                text: nil,
                error: "No selected language is supported by this source"
            )
        }
        do {
            let text: String
            switch source {
            case .qwen:
                text = try await AutoInstallingQwenLlamaASRService()
                    .transcribe(audioFileURL: audioFileURL, languageIDs: effectiveLanguageIDs)
            case .nvidiaNemotron:
                text = try await AutoInstallingNvidiaNemotronASRService()
                    .transcribe(audioFileURL: audioFileURL, languageIDs: effectiveLanguageIDs)
            case .appleSpeech:
                text = try await AppleSpeechASRService()
                    .transcribe(audioFileURL: audioFileURL, languageIDs: effectiveLanguageIDs)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ASRSourceAttemptResult(
                source: source,
                index: index,
                status: trimmed.isEmpty ? "error" : "ok",
                text: trimmed,
                error: trimmed.isEmpty ? ASRAudioSupportError.emptyTranscript.localizedDescription : nil
            )
        } catch {
            return ASRSourceAttemptResult(
                source: source,
                index: index,
                status: "error",
                text: nil,
                error: error.localizedDescription
            )
        }
    }
}

private struct ASRSourceAttemptResult {
    let source: RecognitionSource
    let index: Int
    let status: String
    let text: String?
    let error: String?

    var successText: String? {
        guard status == "ok" else { return nil }
        return text
    }

    var modelOutput: ASRTranscriptModelOutput {
        switch source {
        case .qwen:
            return ASRModelOutputFactory.qwen(role: "source", text: text ?? "", status: status, error: error)
        case .nvidiaNemotron:
            return ASRModelOutputFactory.nemotron(role: "source", text: text ?? "", status: status, error: error)
        case .appleSpeech:
            return ASRModelOutputFactory.appleSpeech(role: "source", text: text ?? "", status: status, error: error)
        }
    }
}

private enum ASRModelOutputFactory {
    static func qwen(
        role: String,
        text: String,
        status: String? = nil,
        error: String? = nil
    ) -> ASRTranscriptModelOutput {
        ASRTranscriptModelOutput(
            role: role,
            provider: "qwen3-asr-llama",
            model: AppSettings.asrQwenLlamaModelID,
            status: status ?? (error == nil ? "ok" : "error"),
            text: text,
            error: error
        )
    }

    static func nemotron(
        role: String,
        text: String,
        status: String? = nil,
        error: String? = nil
    ) -> ASRTranscriptModelOutput {
        ASRTranscriptModelOutput(
            role: role,
            provider: "nvidia-nemotron-asr",
            model: AppSettings.asrNvidiaNemotronModelID,
            status: status ?? (error == nil ? "ok" : "error"),
            text: text,
            error: error
        )
    }

    static func appleSpeech(
        role: String,
        text: String,
        status: String? = nil,
        error: String? = nil
    ) -> ASRTranscriptModelOutput {
        ASRTranscriptModelOutput(
            role: role,
            provider: "apple-speech",
            model: "on-device",
            status: status ?? (error == nil ? "ok" : "error"),
            text: text,
            error: error
        )
    }
}
