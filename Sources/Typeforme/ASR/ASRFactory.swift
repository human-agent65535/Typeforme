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

    func get(sources: [RecognitionSource]) -> ASRService {
        MultiSourceASRService(sources: sources)
    }

    func getInstalled(source: RecognitionSource) -> ASRService {
        InstalledSingleSourceASRService(source: source)
    }

    var isQwenLlamaInstalledForCurrentSettings: Bool {
        FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaModelPath)
            && FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaMMProjPath)
            && AppPaths.bundledLlamaServer != nil
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
        } catch let error as QwenLlamaWarmupError {
            switch error {
            case .skipped(let reason):
                Log.asr.notice("Qwen3-ASR GGUF preload skipped: \(reason, privacy: .public)")
            case .failed(let message):
                Log.asr.error("Qwen3-ASR GGUF preload failed: \(message, privacy: .public)")
            }
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

    func qwenLlamaServiceIfInstalled() -> QwenLlamaASRService? {
        guard isQwenLlamaInstalledForCurrentSettings else { return nil }
        return qwenLlamaService()
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

private struct InstalledSingleSourceASRService: ASRService {
    let source: RecognitionSource

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs).text
    }

    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs, progress: nil)
    }

    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription {
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 0, totalSources: 1, source: source))
        }
        let text: String
        let output: ASRTranscriptModelOutput
        do {
            switch source {
            case .qwen:
                guard let service = await ASRFactory.shared.qwenLlamaServiceIfInstalled() else {
                    throw ASRAudioSupportError.httpStatus(503, "Qwen3-ASR model is not installed")
                }
                text = try await service.transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
                output = ASRModelOutputFactory.qwen(role: "source", text: text)
            case .nvidiaNemotron:
                text = try await AutoInstallingNvidiaNemotronASRService()
                    .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
                output = ASRModelOutputFactory.nemotron(role: "source", text: text)
            case .appleSpeech:
                text = try await AppleSpeechASRService()
                    .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
                output = ASRModelOutputFactory.appleSpeech(role: "source", text: text)
            }
        } catch {
            if let progress {
                await progress(ASRTranscriptionProgress(completedSources: 1, totalSources: 1, source: source))
            }
            throw error
        }
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 1, totalSources: 1, source: source))
        }
        return ASRTranscription(text: text, hypotheses: [text], modelOutputs: [output])
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
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs, progress: nil)
    }

    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription {
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 0, totalSources: 1, source: .qwen))
        }
        let text = try await transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 1, totalSources: 1, source: .qwen))
        }
        return ASRTranscription(
            text: text,
            hypotheses: [text],
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
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs, progress: nil)
    }

    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription {
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 0, totalSources: 1, source: .nvidiaNemotron))
        }
        let text = try await transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 1, totalSources: 1, source: .nvidiaNemotron))
        }
        return ASRTranscription(
            text: text,
            hypotheses: [text],
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
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs, progress: nil)
    }

    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription {
        let enabledSources = sources.isEmpty ? RecognitionSource.defaultEnabled : sources
        let selectedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            sources: enabledSources
        )
        let canonicalAudioURL = try await ASRAudioSupport.wavUploadableAudioURL(for: audioFileURL)
        defer {
            if canonicalAudioURL != audioFileURL {
                try? FileManager.default.removeItem(at: canonicalAudioURL)
            }
        }

        var attempts: [ASRSourceAttemptResult] = []
        let timeoutSeconds = Self.unifiedAttemptTimeoutSeconds(for: enabledSources)
        if let progress, enabledSources.count > 1 {
            await progress(ASRTranscriptionProgress(
                completedSources: 0,
                totalSources: enabledSources.count,
                source: nil
            ))
        }
        await withTaskGroup(of: ASRSourceAttemptResult.self) { group in
            var completedSourceCount = 0
            for (index, source) in enabledSources.enumerated() {
                group.addTask {
                    await Self.attempt(
                        source: source,
                        index: index,
                        audioFileURL: canonicalAudioURL,
                        selectedLanguageIDs: selectedLanguageIDs,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            }
            while let attempt = await group.next() {
                completedSourceCount += 1
                attempts.append(attempt)
                if let progress, enabledSources.count > 1 {
                    await progress(ASRTranscriptionProgress(
                        completedSources: completedSourceCount,
                        totalSources: enabledSources.count,
                        source: attempt.source
                    ))
                }
            }
        }

        let ordered = attempts.sorted { $0.index < $1.index }
        let successfulTexts = ordered
            .compactMap { $0.successText }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hypotheses = CorrectionRequest.normalizedASRHypotheses(
            candidates: successfulTexts.map(Optional.some)
        )
        guard let transcript = hypotheses.first else {
            let detail = ordered
                .map { "\($0.source.displayName): \($0.error ?? $0.status)" }
                .joined(separator: "; ")
            throw ASRAudioSupportError.httpStatus(
                503,
                detail.isEmpty ? "No recognition source produced a transcript" : detail
            )
        }
        let alternates = Array(hypotheses.dropFirst())
        let warnings = ordered.compactMap { attempt -> String? in
            guard attempt.status != "ok" else { return nil }
            return "\(attempt.source.displayName): \(attempt.error ?? attempt.status)"
        }
        return ASRTranscription(
            text: transcript,
            hypotheses: hypotheses,
            alternateTranscripts: alternates,
            modelOutputs: ordered.map(\.modelOutput),
            warnings: warnings
        )
    }

    private static func attempt(
        source: RecognitionSource,
        index: Int,
        audioFileURL: URL,
        selectedLanguageIDs: [String],
        timeoutSeconds: TimeInterval
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
            let text = try await transcribe(
                source: source,
                audioFileURL: audioFileURL,
                languageIDs: effectiveLanguageIDs,
                timeoutSeconds: timeoutSeconds
            )
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

    private static func unifiedAttemptTimeoutSeconds(for sources: [RecognitionSource]) -> TimeInterval {
        let configured = sources.compactMap { source -> TimeInterval? in
            switch source {
            case .qwen:
                return AppSettings.asrQwenLlamaTimeoutSeconds
            case .nvidiaNemotron:
                return AppSettings.asrNvidiaNemotronTimeoutSeconds
            case .appleSpeech:
                return nil
            }
        }
        return max(10, configured.max() ?? AppSettings.asrQwenLlamaTimeoutSeconds)
    }

    private static func transcribe(
        source: RecognitionSource,
        audioFileURL: URL,
        languageIDs: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                switch source {
                case .qwen:
                    return try await AutoInstallingQwenLlamaASRService()
                        .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
                case .nvidiaNemotron:
                    return try await AutoInstallingNvidiaNemotronASRService()
                        .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
                case .appleSpeech:
                    return try await AppleSpeechASRService()
                        .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ASRAudioSupportError.timeout(seconds: timeoutSeconds)
            }
            guard let result = try await group.next() else {
                throw ASRAudioSupportError.emptyTranscript
            }
            group.cancelAll()
            return result
        }
    }
}

private struct ASRSourceAttemptResult: Sendable {
    let source: RecognitionSource
    let index: Int
    let status: String
    let text: String?
    let error: String?

    var successText: String? {
        guard status == "ok" else { return nil }
        return text
    }

    var hasUsableText: Bool {
        guard let successText else { return false }
        return !successText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
