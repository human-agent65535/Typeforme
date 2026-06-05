import Foundation

@MainActor
final class ASRFactory {
    static let shared = ASRFactory()

    private var qwenLlama: QwenLlamaASRService?
    private var qwenLlamaKey: String?
    private var nvidiaNemotron: NvidiaNemotronASRService?

    func get() -> ASRService {
        switch AppSettings.asrProvider.lowercased() {
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

        if provider == "nvidia-nemotron-asr" {
            Log.asr.info("NVIDIA Nemotron ASR preload skipped; bundled helper starts on demand")
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
