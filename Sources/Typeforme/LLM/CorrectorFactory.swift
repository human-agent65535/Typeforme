import Foundation

typealias CorrectorLlamaServerBuilder = (
    _ configuration: CorrectorLlamaRuntimeConfiguration,
    _ activationBarrier: Task<Void, Never>?
) -> LlamaCppServerManager

/// A session keeps this token alive for as long as its embedded corrector may
/// still be used. Release is thread-safe because the last service reference
/// can disappear off the main actor.
final class CorrectorLlamaRuntimeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var didRelease = false
    private let releaseHandler: @Sendable () -> Void

    init(releaseHandler: @escaping @Sendable () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        if shouldRelease {
            releaseHandler()
        }
    }

    deinit {
        release()
    }
}

@MainActor
private final class CorrectorLlamaRuntimeSlot {
    let id = UUID()
    let configuration: CorrectorLlamaRuntimeConfiguration
    let server: LlamaCppServerManager
    let activationBarrier: Task<Void, Never>?
    var retirementTask: Task<Void, Never>?

    private(set) var acceptsLeases = true
    private var leaseCount = 0
    private var forceDrained = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        configuration: CorrectorLlamaRuntimeConfiguration,
        server: LlamaCppServerManager,
        activationBarrier: Task<Void, Never>?
    ) {
        self.configuration = configuration
        self.server = server
        self.activationBarrier = activationBarrier
    }

    func acquireLease() -> CorrectorLlamaRuntimeLease? {
        guard acceptsLeases else { return nil }
        leaseCount += 1
        return CorrectorLlamaRuntimeLease { [weak self] in
            Task { @MainActor in
                self?.releaseLease()
            }
        }
    }

    func close(force: Bool = false) {
        acceptsLeases = false
        if force {
            forceDrained = true
        }
        resumeDrainWaitersIfReady()
    }

    func waitUntilDrained() async {
        guard !forceDrained, leaseCount > 0 else { return }
        await withCheckedContinuation { continuation in
            if forceDrained || leaseCount == 0 {
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
            }
        }
    }

    private func releaseLease() {
        guard leaseCount > 0 else { return }
        leaseCount -= 1
        resumeDrainWaitersIfReady()
    }

    private func resumeDrainWaitersIfReady() {
        guard forceDrained || (!acceptsLeases && leaseCount == 0) else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Resolves the active correction backend and caches the embedded helper
/// process. Each returned service keeps the configuration captured for its
/// recording or request.
@MainActor
final class CorrectorFactory {
    static let shared = CorrectorFactory()

    private let bundledLlamaServerProvider: () -> URL?
    private let llamaServerBuilder: CorrectorLlamaServerBuilder
    private var activeLlamaRuntime: CorrectorLlamaRuntimeSlot?
    private var llamaRuntimeSlots: [CorrectorLlamaRuntimeSlot] = []
    private var pendingLlamaRetirementTask: Task<Void, Never>?
    private var runtimeTeardownDepth = 0
    private var modelPathsUnderMaintenance: Set<String> = []

    init(
        bundledLlamaServerProvider: @escaping () -> URL? = { AppPaths.bundledLlamaServer },
        llamaServerBuilder: @escaping CorrectorLlamaServerBuilder = { configuration, activationBarrier in
            LlamaCppServerManager(
                modelPath: configuration.modelPath,
                contextSize: configuration.contextSize,
                useFlashAttn: configuration.useFlashAttention,
                binaryURL: URL(fileURLWithPath: configuration.binaryPath),
                pidFile: URL(fileURLWithPath: configuration.pidFilePath),
                coldTimeoutSec: TimeInterval(configuration.coldTimeoutMilliseconds) / 1_000,
                activationBarrier: activationBarrier
            )
        }
    ) {
        self.bundledLlamaServerProvider = bundledLlamaServerProvider
        self.llamaServerBuilder = llamaServerBuilder
    }

    /// Explicit backend selection. Do not automatically fall back to another
    /// engine: failures should surface as failures so quality issues are visible.
    func make() -> CorrectorService {
        make(configuration: .capture())
    }

    func make(configuration: CorrectorConfigurationSnapshot) -> CorrectorService {
        switch configuration {
        case .embedded(let configuration):
            return makeLlama(configuration: configuration)
        case .external(let configuration):
            closeActiveLlamaRuntime()
            return ExternalCompatibleCorrectorService(configuration: configuration)
        }
    }

    @discardableResult
    func preloadActiveModels() async -> CorrectorPreloadResult {
        let configuration = CorrectorConfigurationSnapshot.capture()
        switch configuration {
        case .external(let externalConfiguration):
            closeActiveLlamaRuntime()
            return .ready(
                kind: externalConfiguration.kind,
                message: "\(externalConfiguration.kind.displayName) server is configured."
            )
        case .embedded(let embeddedConfiguration):
            return await preloadLlama(configuration: embeddedConfiguration)
        }
    }

    private func makeLlama(configuration: EmbeddedCorrectorConfiguration) -> CorrectorService {
        let modelPath = Self.standardizedPath(configuration.modelPath)
        guard runtimeTeardownDepth == 0,
              !modelPathsUnderMaintenance.contains(modelPath)
        else {
            return UnavailableCorrectorService(
                kind: configuration.kind,
                reason: "Correction model maintenance is in progress"
            )
        }
        guard FileManager.default.fileExists(atPath: configuration.modelPath) else {
            closeActiveLlamaRuntime()
            return UnavailableCorrectorService(
                kind: configuration.kind,
                reason: "\(configuration.kind.displayName) model is not installed. Open Setup Guide to download it."
            )
        }
        return installedLlamaService(configuration: configuration)
    }

    func installedLlamaService(modelPath: String, kind: CorrectionBackendKind) -> CorrectorService {
        installedLlamaService(configuration: EmbeddedCorrectorConfiguration(
            kind: kind,
            modelPath: modelPath,
            contextSize: AppSettings.correctionContextSize,
            maxTokens: AppSettings.correctionMaxTokens,
            useFlashAttention: AppSettings.llamaUseFlashAttn,
            coldTimeoutMilliseconds: AppSettings.correctionColdTimeoutMs
        ))
    }

    private func installedLlamaService(
        configuration: EmbeddedCorrectorConfiguration
    ) -> CorrectorService {
        guard let (runtime, lease) = leasedLlamaRuntime(configuration: configuration) else {
            Log.llm.notice("bundled llama-server binary not found; \(configuration.kind.rawValue, privacy: .public) unavailable")
            return UnavailableCorrectorService(
                kind: configuration.kind,
                reason: "Bundled llama-server binary not found"
            )
        }
        return EmbeddedLlamaCorrectorService(
            kind: configuration.kind,
            server: runtime.server,
            contextSize: configuration.contextSize,
            maxTokens: configuration.maxTokens,
            runtimeLease: lease,
            activationBarrier: runtime.activationBarrier,
            coldTimeoutMilliseconds: configuration.coldTimeoutMilliseconds
        )
    }

    private func preloadLlama(
        configuration: EmbeddedCorrectorConfiguration
    ) async -> CorrectorPreloadResult {
        guard runtimeTeardownDepth == 0,
              !modelPathsUnderMaintenance.contains(Self.standardizedPath(configuration.modelPath))
        else {
            return .failed(kind: configuration.kind, message: "Correction model maintenance is in progress")
        }
        guard FileManager.default.fileExists(atPath: configuration.modelPath) else {
            closeActiveLlamaRuntime()
            let modelFile = URL(fileURLWithPath: configuration.modelPath).lastPathComponent
            Log.llm.notice("LLM preload skipped; model missing: \(modelFile, privacy: .public)")
            return .missing(kind: configuration.kind, message: "Model file is missing: \(modelFile)")
        }
        guard let (runtime, lease) = leasedLlamaRuntime(configuration: configuration) else {
            Log.llm.notice("LLM preload skipped; bundled llama-server missing")
            return .failed(kind: configuration.kind, message: "Bundled llama-server binary not found")
        }
        defer { lease.release() }
        do {
            try await CorrectorLlamaActivationDeadline.wait(
                for: runtime.activationBarrier,
                timeoutMilliseconds: configuration.coldTimeoutMilliseconds
            )
            _ = try await runtime.server.ensureRunning()
            Log.llm.info("LLM preloaded: \(configuration.kind.rawValue, privacy: .public)")
            return .ready(kind: configuration.kind, message: "\(configuration.kind.displayName) is loaded.")
        } catch {
            Log.llm.error("LLM preload failed: \(error.localizedDescription, privacy: .public)")
            return .failed(kind: configuration.kind, message: error.localizedDescription)
        }
    }

    private func leasedLlamaRuntime(
        configuration serviceConfiguration: EmbeddedCorrectorConfiguration
    ) -> (runtime: CorrectorLlamaRuntimeSlot, lease: CorrectorLlamaRuntimeLease)? {
        guard let binary = bundledLlamaServerProvider() else {
            closeActiveLlamaRuntime()
            return nil
        }
        let configuration = CorrectorLlamaRuntimeConfiguration(
            kind: serviceConfiguration.kind,
            modelPath: URL(fileURLWithPath: serviceConfiguration.modelPath).standardizedFileURL.path,
            binaryPath: binary.standardizedFileURL.path,
            pidFilePath: AppPaths.llamaPidFile.standardizedFileURL.path,
            contextSize: serviceConfiguration.contextSize,
            useFlashAttention: serviceConfiguration.useFlashAttention,
            coldTimeoutMilliseconds: serviceConfiguration.coldTimeoutMilliseconds
        )
        if let activeLlamaRuntime,
           activeLlamaRuntime.configuration == configuration,
           let lease = activeLlamaRuntime.acquireLease() {
            return (activeLlamaRuntime, lease)
        }

        let activationBarrier = closeActiveLlamaRuntime() ?? pendingLlamaRetirementTask
        pendingLlamaRetirementTask = nil
        let server = llamaServerBuilder(configuration, activationBarrier)
        let runtime = CorrectorLlamaRuntimeSlot(
            configuration: configuration,
            server: server,
            activationBarrier: activationBarrier
        )
        llamaRuntimeSlots.append(runtime)
        activeLlamaRuntime = runtime
        guard let lease = runtime.acquireLease() else { return nil }
        return (runtime, lease)
    }

    @discardableResult
    private func closeActiveLlamaRuntime(force: Bool = false) -> Task<Void, Never>? {
        guard let runtime = activeLlamaRuntime else { return pendingLlamaRetirementTask }
        activeLlamaRuntime = nil
        runtime.close(force: force)
        let retirement = retirementTask(for: runtime)
        pendingLlamaRetirementTask = retirement
        return retirement
    }

    private func retirementTask(
        for runtime: CorrectorLlamaRuntimeSlot
    ) -> Task<Void, Never> {
        if let retirementTask = runtime.retirementTask {
            return retirementTask
        }
        let retirement = Task { @MainActor [weak self, runtime] in
            if let activationBarrier = runtime.activationBarrier {
                await activationBarrier.value
            }
            await runtime.waitUntilDrained()
            await runtime.server.retire()
            self?.llamaRuntimeSlots.removeAll { $0 === runtime }
        }
        runtime.retirementTask = retirement
        return retirement
    }

    /// Graceful process teardown for settings transitions and downloads. New
    /// embedded sessions are rejected while existing session leases drain.
    func drainAndShutdownAll() async {
        await withRuntimeTeardownScope {
            await drainRuntimeSlots(force: false)
        }
    }

    /// Runs a destructive correction-model file mutation only after every
    /// session using that exact path has released its runtime lease.
    func withDrainedModelRuntime<T>(
        atPath path: String,
        operation: @MainActor () throws -> T
    ) async rethrows -> T {
        let standardizedPath = Self.standardizedPath(path)
        modelPathsUnderMaintenance.insert(standardizedPath)
        defer { modelPathsUnderMaintenance.remove(standardizedPath) }

        if activeLlamaRuntime?.configuration.modelPath == standardizedPath {
            closeActiveLlamaRuntime()
        }
        let matchingRuntimes = llamaRuntimeSlots.filter {
            $0.configuration.modelPath == standardizedPath
        }
        for runtime in matchingRuntimes {
            runtime.close()
            await retirementTask(for: runtime).value
        }
        return try operation()
    }

    /// Explicit application/CLI shutdown invalidates outstanding leases so
    /// helper processes cannot outlive the app termination deadline.
    func shutdownAll() async {
        await withRuntimeTeardownScope {
            await drainRuntimeSlots(force: true)
        }
    }

    /// Teardown requests can overlap when multiple model rows or application
    /// shutdown paths fire together. Every scope owns one increment so an
    /// earlier completion cannot reopen runtime creation for a later scope.
    func withRuntimeTeardownScope<T>(
        operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        runtimeTeardownDepth += 1
        defer {
            precondition(runtimeTeardownDepth > 0, "Unbalanced runtime teardown")
            runtimeTeardownDepth -= 1
        }
        return try await operation()
    }

    private func drainRuntimeSlots(force: Bool) async {
        while true {
            if let activeLlamaRuntime {
                activeLlamaRuntime.close(force: force)
                closeActiveLlamaRuntime(force: force)
            }
            let runtimes = llamaRuntimeSlots
            guard !runtimes.isEmpty else {
                if let pendingLlamaRetirementTask {
                    await pendingLlamaRetirementTask.value
                    self.pendingLlamaRetirementTask = nil
                }
                return
            }
            for runtime in runtimes {
                runtime.close(force: force)
            }
            for runtime in runtimes {
                await retirementTask(for: runtime).value
            }
            if activeLlamaRuntime == nil, llamaRuntimeSlots.isEmpty {
                pendingLlamaRetirementTask = nil
                return
            }
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
    let runtimeFileIdentity: String

    init(
        kind: CorrectionBackendKind,
        modelPath: String,
        binaryPath: String,
        pidFilePath: String,
        contextSize: Int,
        useFlashAttention: Bool,
        coldTimeoutMilliseconds: Int,
        fileManager: FileManager = .default
    ) {
        self.kind = kind
        self.modelPath = modelPath
        self.binaryPath = binaryPath
        self.pidFilePath = pidFilePath
        self.contextSize = contextSize
        self.useFlashAttention = useFlashAttention
        self.coldTimeoutMilliseconds = coldTimeoutMilliseconds
        self.runtimeFileIdentity = [
            "model=\(RuntimeFileIdentity.capture(URL(fileURLWithPath: modelPath), fileManager: fileManager))",
            "binary=\(RuntimeFileIdentity.capture(URL(fileURLWithPath: binaryPath), fileManager: fileManager))",
        ].joined(separator: "|")
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
