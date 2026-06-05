import Foundation

@MainActor
final class ASRFactory {
    static let shared = ASRFactory()

    private var qwenLlama: QwenLlamaASRService?
    private var qwenLlamaKey: String?
    private var nvidiaNemotron: NvidiaNemotronASRService?

    func get() -> ASRService {
        switch AppSettings.asrProvider.lowercased() {
        case "qwen3-asr-llama+nvidia-nemotron-asr":
            return AutoInstallingDualASRService()
        case "nvidia-nemotron-asr":
            return AutoInstallingNvidiaNemotronASRService()
        case "qwen3-asr-llama":
            fallthrough
        default:
            return AutoInstallingQwenLlamaASRService()
        }
    }

    func preloadCachedActiveModel() async {
        let provider = AppSettings.asrProvider.lowercased()
        if provider == "qwen3-asr-llama" {
            await preloadQwenLlama()
            return
        }

        if provider == "qwen3-asr-llama+nvidia-nemotron-asr" {
            async let qwen: Void = preloadQwenLlama()
            async let nvidia: Void = preloadNvidiaNemotron()
            _ = await (qwen, nvidia)
            return
        }

        if provider == "nvidia-nemotron-asr" {
            await preloadNvidiaNemotron()
            return
        }
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
            Log.asr.info("NVIDIA Nemotron ASR ready; bundled helper starts on demand")
        } else {
            Log.asr.notice("NVIDIA Nemotron ASR preload skipped: \(status.detail, privacy: .public)")
        }
    }

    func stopQwenLlama() async {
        await qwenLlama?.stop()
        qwenLlama = nil
        qwenLlamaKey = nil
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
}

private struct AutoInstallingNvidiaNemotronASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await ASRFactory.shared.ensureNvidiaNemotronInstalled()
        return try await ASRFactory.shared.nvidiaNemotronService().transcribe(
            audioFileURL: audioFileURL,
            languageIDs: languageIDs
        )
    }
}

private struct AutoInstallingDualASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs).text
    }

    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        async let qwen = Self.attempt {
            try await AutoInstallingQwenLlamaASRService()
                .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        }
        async let nemotron = Self.attempt {
            try await AutoInstallingNvidiaNemotronASRService()
                .transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        }

        let (qwenResult, nemotronResult) = await (qwen, nemotron)
        let primaryIsNemotron = Self.prefersNemotronPrimary(languageIDs: languageIDs)
        let primaryResult = primaryIsNemotron ? nemotronResult : qwenResult
        let auxiliaryResult = primaryIsNemotron ? qwenResult : nemotronResult

        guard primaryResult.error == nil else {
            throw ASRAudioSupportError.httpStatus(
                503,
                primaryResult.error ?? "Primary ASR failed"
            )
        }

        let primary = primaryResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty else {
            throw ASRAudioSupportError.emptyTranscript
        }
        let auxiliary = auxiliaryResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscription(
            text: primary,
            alternateTranscripts: auxiliary.isEmpty || auxiliary == primary ? [] : [auxiliary],
            warnings: auxiliaryResult.error == nil ? [] : ["Cross-check transcript unavailable"]
        )
    }

    private static func attempt(_ operation: () async throws -> String) async -> ASRAttemptResult {
        do {
            return ASRAttemptResult(text: try await operation(), error: nil)
        } catch {
            return ASRAttemptResult(text: "", error: error.localizedDescription)
        }
    }

    private static func prefersNemotronPrimary(languageIDs: [String]) -> Bool {
        let ids = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.dualASRSupportedLanguages
        )
        return ids.count == 1 && ids[0] == "en-US"
    }
}

private struct ASRAttemptResult {
    let text: String
    let error: String?
}
