import Foundation

/// Resolves the active correction backend and caches backend-specific services.
@MainActor
final class CorrectorFactory {
    static let shared = CorrectorFactory()

    private var servers: [String: LlamaCppServerManager] = [:]
    private var activeServerKeyByModelPath: [String: String] = [:]
    private var correctorServices: [String: CorrectorService] = [:]

    /// Explicit backend selection. Do not automatically fall back to another
    /// engine: failures should surface as failures so quality issues are visible.
    func make() -> CorrectorService {
        switch AppSettings.correctionBackend {
        case .qwen35_2B:
            return makeLlama(modelPath: AppSettings.llama2BPath, kind: .qwen35_2B)
        case .qwen35_4B:
            return makeLlama(modelPath: AppSettings.llama4BPath, kind: .qwen35_4B)
        case .qwen35_9B:
            return makeLlama(modelPath: AppSettings.llama9BPath, kind: .qwen35_9B)
        case .externalOpenAICompatible, .externalAnthropicCompatible:
            let key = AppSettings.correctionBackend.rawValue
            if let service = correctorServices[key] {
                return service
            }
            let service = ExternalCompatibleCorrectorService(kind: AppSettings.correctionBackend)
            correctorServices[key] = service
            return service
        }
    }

    @discardableResult
    func preloadActiveModels() async -> CorrectorPreloadResult {
        switch AppSettings.correctionBackend {
        case .externalOpenAICompatible, .externalAnthropicCompatible:
            return .ready(kind: AppSettings.correctionBackend, message: "\(AppSettings.correctionBackend.displayName) server is configured.")
        case .qwen35_2B:
            return await preloadLlama(modelPath: AppSettings.llama2BPath, kind: .qwen35_2B)
        case .qwen35_4B:
            return await preloadLlama(modelPath: AppSettings.llama4BPath, kind: .qwen35_4B)
        case .qwen35_9B:
            return await preloadLlama(modelPath: AppSettings.llama9BPath, kind: .qwen35_9B)
        }
    }

    private func makeLlama(modelPath: String, kind: CorrectionBackendKind) -> CorrectorService {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return UnavailableCorrectorService(
                kind: kind,
                reason: "\(kind.displayName) model is not installed. Open Setup Guide to download it."
            )
        }
        let key = [
            kind.rawValue,
            modelPath
        ].joined(separator: "|")
        if let service = correctorServices[key] {
            return service
        }
        let service = installedLlamaService(modelPath: modelPath, kind: kind)
        correctorServices[key] = service
        return service
    }

    func installedLlamaService(modelPath: String, kind: CorrectionBackendKind) -> CorrectorService {
        guard let server = llamaServer(modelPath: modelPath, kind: kind) else {
            Log.llm.notice("bundled llama-server binary not found; \(kind.rawValue, privacy: .public) unavailable")
            return UnavailableCorrectorService(kind: kind, reason: "Bundled llama-server binary not found")
        }
        return EmbeddedLlamaCorrectorService(kind: kind, server: server)
    }

    private func preloadLlama(modelPath: String, kind: CorrectionBackendKind) async -> CorrectorPreloadResult {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            let modelFile = URL(fileURLWithPath: modelPath).lastPathComponent
            Log.llm.notice("LLM preload skipped; model missing: \(modelFile, privacy: .public)")
            return .missing(kind: kind, message: "Model file is missing: \(modelFile)")
        }
        guard let server = llamaServer(modelPath: modelPath, kind: kind) else {
            Log.llm.notice("LLM preload skipped; bundled llama-server missing")
            return .failed(kind: kind, message: "Bundled llama-server binary not found")
        }
        do {
            _ = try await server.ensureRunning()
            Log.llm.info("LLM preloaded: \(kind.rawValue, privacy: .public)")
            return .ready(kind: kind, message: "\(kind.displayName) is loaded.")
        } catch {
            Log.llm.error("LLM preload failed: \(error.localizedDescription, privacy: .public)")
            return .failed(kind: kind, message: error.localizedDescription)
        }
    }

    private func llamaServer(modelPath: String, kind: CorrectionBackendKind) -> LlamaCppServerManager? {
        guard let binary = AppPaths.bundledLlamaServer else { return nil }
        let coldTimeoutSec = TimeInterval(AppSettings.correctionColdTimeoutMs) / 1000.0
        let serverKey = [
            modelPath,
            binary.path,
            "ctx=\(AppSettings.correctionContextSize)",
            "flash=\(AppSettings.llamaUseFlashAttn)",
            "cold=\(coldTimeoutSec)",
        ].joined(separator: "|")

        if let previousKey = activeServerKeyByModelPath[modelPath],
           previousKey != serverKey,
           let previousServer = servers.removeValue(forKey: previousKey) {
            Task { await previousServer.stop() }
        }

        let server = servers[serverKey] ?? LlamaCppServerManager(
            modelPath: modelPath,
            contextSize: AppSettings.correctionContextSize,
            useFlashAttn: AppSettings.llamaUseFlashAttn,
            binaryURL: binary,
            coldTimeoutSec: coldTimeoutSec
        )
        servers[serverKey] = server
        activeServerKeyByModelPath[modelPath] = serverKey
        return server
    }

    func shutdownAll() async {
        for server in servers.values {
            await server.stop()
        }
        servers.removeAll()
        activeServerKeyByModelPath.removeAll()
        correctorServices.removeAll()
    }
}

enum CorrectorPreloadResult: Equatable {
    case ready(kind: CorrectionBackendKind, message: String)
    case missing(kind: CorrectionBackendKind, message: String)
    case failed(kind: CorrectionBackendKind, message: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .ready(_, let message),
             .missing(_, let message),
             .failed(_, let message):
            return message
        }
    }
}

private struct UnavailableCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind
    let reason: String

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput {
        throw CorrectorError.unavailable(reason)
    }

    func complete(system: String, messages: [CorrectorChatMessage], timeoutMs: Int) async throws -> String {
        throw CorrectorError.unavailable(reason)
    }
}
