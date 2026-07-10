import Foundation

/// Resolves the active correction backend and caches backend-specific services.
@MainActor
final class CorrectorFactory {
    static let shared = CorrectorFactory()

    private struct ActiveLlamaRuntime {
        let configuration: CorrectorLlamaRuntimeConfiguration
        let server: LlamaCppServerManager
        let service: EmbeddedLlamaCorrectorService
    }

    private var activeLlamaRuntime: ActiveLlamaRuntime?
    /// Each replacement waits for the preceding retirement. The next manager
    /// also receives this task as its activation barrier, so two correction
    /// models cannot become resident at the same time.
    private var llamaRetirementTask: Task<Void, Never>?
    private var llamaRetirementGeneration = 0
    private var externalServices: [CorrectionBackendKind: CorrectorService] = [:]

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
            retireActiveLlamaRuntime()
            let kind = AppSettings.correctionBackend
            if let service = externalServices[kind] {
                return service
            }
            let service = ExternalCompatibleCorrectorService(kind: kind)
            externalServices[kind] = service
            return service
        }
    }

    @discardableResult
    func preloadActiveModels() async -> CorrectorPreloadResult {
        switch AppSettings.correctionBackend {
        case .externalOpenAICompatible, .externalAnthropicCompatible:
            retireActiveLlamaRuntime()
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
            retireActiveLlamaRuntime()
            return UnavailableCorrectorService(
                kind: kind,
                reason: "\(kind.displayName) model is not installed. Open Setup Guide to download it."
            )
        }
        return installedLlamaService(modelPath: modelPath, kind: kind)
    }

    func installedLlamaService(modelPath: String, kind: CorrectionBackendKind) -> CorrectorService {
        guard let runtime = llamaRuntime(modelPath: modelPath, kind: kind) else {
            Log.llm.notice("bundled llama-server binary not found; \(kind.rawValue, privacy: .public) unavailable")
            return UnavailableCorrectorService(kind: kind, reason: "Bundled llama-server binary not found")
        }
        return runtime.service
    }

    private func preloadLlama(modelPath: String, kind: CorrectionBackendKind) async -> CorrectorPreloadResult {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            retireActiveLlamaRuntime()
            let modelFile = URL(fileURLWithPath: modelPath).lastPathComponent
            Log.llm.notice("LLM preload skipped; model missing: \(modelFile, privacy: .public)")
            return .missing(kind: kind, message: "Model file is missing: \(modelFile)")
        }
        guard let runtime = llamaRuntime(modelPath: modelPath, kind: kind) else {
            Log.llm.notice("LLM preload skipped; bundled llama-server missing")
            return .failed(kind: kind, message: "Bundled llama-server binary not found")
        }
        do {
            _ = try await runtime.server.ensureRunning()
            Log.llm.info("LLM preloaded: \(kind.rawValue, privacy: .public)")
            return .ready(kind: kind, message: "\(kind.displayName) is loaded.")
        } catch {
            Log.llm.error("LLM preload failed: \(error.localizedDescription, privacy: .public)")
            return .failed(kind: kind, message: error.localizedDescription)
        }
    }

    private func llamaRuntime(
        modelPath: String,
        kind: CorrectionBackendKind
    ) -> ActiveLlamaRuntime? {
        guard let binary = AppPaths.bundledLlamaServer else {
            retireActiveLlamaRuntime()
            return nil
        }
        let configuration = CorrectorLlamaRuntimeConfiguration(
            kind: kind,
            modelPath: URL(fileURLWithPath: modelPath).standardizedFileURL.path,
            binaryPath: binary.standardizedFileURL.path,
            pidFilePath: AppPaths.llamaPidFile.standardizedFileURL.path,
            contextSize: AppSettings.correctionContextSize,
            useFlashAttention: AppSettings.llamaUseFlashAttn,
            coldTimeoutMilliseconds: AppSettings.correctionColdTimeoutMs
        )
        if let activeLlamaRuntime,
           activeLlamaRuntime.configuration == configuration {
            return activeLlamaRuntime
        }

        let activationBarrier = retireActiveLlamaRuntime()
        let server = LlamaCppServerManager(
            modelPath: configuration.modelPath,
            contextSize: configuration.contextSize,
            useFlashAttn: configuration.useFlashAttention,
            binaryURL: URL(fileURLWithPath: configuration.binaryPath),
            pidFile: URL(fileURLWithPath: configuration.pidFilePath),
            coldTimeoutSec: TimeInterval(configuration.coldTimeoutMilliseconds) / 1_000,
            activationBarrier: activationBarrier
        )
        let runtime = ActiveLlamaRuntime(
            configuration: configuration,
            server: server,
            service: EmbeddedLlamaCorrectorService(kind: kind, server: server)
        )
        activeLlamaRuntime = runtime
        return runtime
    }

    @discardableResult
    private func retireActiveLlamaRuntime() -> Task<Void, Never>? {
        guard let runtime = activeLlamaRuntime else { return llamaRetirementTask }
        activeLlamaRuntime = nil
        let precedingRetirement = llamaRetirementTask
        let server = runtime.server
        llamaRetirementGeneration += 1
        let retirement = Task {
            if let precedingRetirement {
                await precedingRetirement.value
            }
            await server.retire()
        }
        llamaRetirementTask = retirement
        return retirement
    }

    func shutdownAll() async {
        while true {
            if activeLlamaRuntime != nil {
                retireActiveLlamaRuntime()
            }
            guard let retirement = llamaRetirementTask else { break }
            let generation = llamaRetirementGeneration
            await retirement.value
            guard generation == llamaRetirementGeneration,
                  activeLlamaRuntime == nil
            else { continue }
            llamaRetirementTask = nil
            break
        }
        externalServices.removeAll()
    }
}

/// Every setting that changes the correction helper process belongs in this
/// value. Synthesized equality is the cache-reuse decision and is covered by
/// tests so new launch-affecting settings cannot silently reuse an old server.
struct CorrectorLlamaRuntimeConfiguration: Hashable, Sendable {
    let kind: CorrectionBackendKind
    let modelPath: String
    let binaryPath: String
    let pidFilePath: String
    let contextSize: Int
    let useFlashAttention: Bool
    let coldTimeoutMilliseconds: Int
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
