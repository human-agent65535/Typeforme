import Foundation

struct ASRSessionConfiguration: Sendable, Equatable {
    let sources: [RecognitionSource]
    let unifiedAttemptTimeoutSeconds: TimeInterval
    let appleSpeechAddsPunctuation: Bool
    let qwen: QwenLlamaASRConfiguration?
    let nvidiaNemotron: NvidiaNemotronASRConfiguration?

    @MainActor
    static func capture(sources requestedSources: [RecognitionSource]) -> ASRSessionConfiguration {
        let sources = RecognitionSource.recognizedSources(requestedSources.map(\.rawValue))
        let unifiedAttemptTimeoutSeconds = AppSettings.asrTimeoutSeconds(for: sources)
        let appleSpeechAddsPunctuation = Self.appleSpeechAddsPunctuation(
            for: AppSettings.punctuationPreference
        )
        let canonicalLanguageIDs = AppSettings.asrCanonicalLanguageIDs

        let qwen: QwenLlamaASRConfiguration?
        if sources.contains(.qwen) {
            let modelID = AppSettings.asrQwenLlamaModelID
            let modelPath = AppSettings.asrQwenLlamaModelPath
            let mmprojPath = AppSettings.asrQwenLlamaMMProjPath
            let binaryURL = AppPaths.bundledLlamaServer
            qwen = QwenLlamaASRConfiguration(
                modelID: modelID,
                modelPath: modelPath,
                mmprojPath: mmprojPath,
                modelName: (modelPath as NSString).lastPathComponent,
                requestTimeoutSeconds: unifiedAttemptTimeoutSeconds,
                maxTokens: AppSettings.asrQwenLlamaMaxTokens,
                useFlashAttention: AppSettings.llamaUseFlashAttn,
                binaryURL: binaryURL,
                warmupLanguageIDs: ASRLanguageSelection.validatedIDs(
                    canonicalLanguageIDs,
                    supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
                ),
                modelFilesInstalledAtCapture: FileManager.default.fileExists(atPath: modelPath)
                    && FileManager.default.fileExists(atPath: mmprojPath)
            )
        } else {
            qwen = nil
        }

        let nvidiaNemotron: NvidiaNemotronASRConfiguration?
        if sources.contains(.nvidiaNemotron) {
            nvidiaNemotron = NvidiaNemotronASRConfiguration.capture(
                requestTimeoutSeconds: unifiedAttemptTimeoutSeconds
            )
        } else {
            nvidiaNemotron = nil
        }

        return ASRSessionConfiguration(
            sources: sources,
            unifiedAttemptTimeoutSeconds: unifiedAttemptTimeoutSeconds,
            appleSpeechAddsPunctuation: appleSpeechAddsPunctuation,
            qwen: qwen,
            nvidiaNemotron: nvidiaNemotron
        )
    }

    static func appleSpeechAddsPunctuation(
        for preference: PunctuationOutputPreference
    ) -> Bool {
        switch preference {
        case .normal, .english:
            return true
        case .spaces:
            return false
        }
    }
}

private final class QwenBackendActivationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool) {
        self.isOpen = isOpen
    }

    func wait() async {
        if lock.withLock({ isOpen }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isOpen else { return [] }
            isOpen = true
            let continuations = waiters
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }
}

final class RuntimeActivityLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    init(releaseHandler: @escaping @Sendable () -> Void) {
        self.releaseHandler = releaseHandler
    }

    deinit {
        release()
    }

    func release() {
        let handler = lock.withLock {
            defer { releaseHandler = nil }
            return releaseHandler
        }
        handler?()
    }
}

final class RuntimeMaintenanceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var finishHandler: (@Sendable () -> Void)?

    init(finishHandler: @escaping @Sendable () -> Void) {
        self.finishHandler = finishHandler
    }

    deinit {
        finish()
    }

    func finish() {
        let handler = lock.withLock {
            defer { finishHandler = nil }
            return finishHandler
        }
        handler?()
    }
}

typealias QwenLlamaMaintenanceLease = RuntimeMaintenanceLease
typealias NvidiaNemotronRuntimeLease = RuntimeActivityLease
typealias NvidiaNemotronMaintenanceLease = RuntimeMaintenanceLease

@MainActor
private final class RuntimeMaintenanceGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activityCount = 0
    private var maintenanceDepth = 0
    private var waiters: [Waiter] = []

    var isUnderMaintenance: Bool {
        maintenanceDepth > 0
    }

    func acquire(
        onRelease: @escaping @MainActor () -> Void = {}
    ) -> RuntimeActivityLease? {
        guard maintenanceDepth == 0 else { return nil }
        activityCount += 1
        return RuntimeActivityLease { [weak self] in
            Task { @MainActor [weak self] in
                onRelease()
                self?.releaseActivity()
            }
        }
    }

    func beginMaintenance(
        shutdown: @escaping @MainActor () async -> Void
    ) async throws -> RuntimeMaintenanceLease {
        try Task.checkCancellation()
        maintenanceDepth += 1
        do {
            try await waitUntilIdle()
            try Task.checkCancellation()
            await shutdown()
            try Task.checkCancellation()
            return RuntimeMaintenanceLease { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishMaintenance()
                }
            }
        } catch {
            finishMaintenance()
            throw error
        }
    }

    private func waitUntilIdle() async throws {
        guard activityCount > 0 else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if activityCount == 0 {
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func releaseActivity() {
        guard activityCount > 0 else { return }
        activityCount -= 1
        guard activityCount == 0 else { return }
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.continuation.resume() }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishMaintenance() {
        guard maintenanceDepth > 0 else { return }
        maintenanceDepth -= 1
    }
}

final class QwenLlamaASRServiceLease: ASRService, @unchecked Sendable {
    let service: QwenLlamaASRService
    private let activityLease: RuntimeActivityLease

    init(
        service: QwenLlamaASRService,
        activityLease: RuntimeActivityLease
    ) {
        self.service = service
        self.activityLease = activityLease
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await service.transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
    }
}

enum QwenLlamaLivePreviewLeaseUnavailableReason: LocalizedError, Equatable {
    case maintenance
    case modelMissing
    case runtimeMissing

    var message: String {
        switch self {
        case .maintenance:
            return "Qwen3-ASR is temporarily unavailable during model maintenance"
        case .modelMissing:
            return "Qwen3-ASR model is not installed. Open Setup Guide to download it."
        case .runtimeMissing:
            return "Bundled llama-server binary not found"
        }
    }

    var errorDescription: String? { message }
}

enum QwenLlamaLivePreviewLeaseAcquisition {
    case acquired(QwenLlamaASRServiceLease)
    case unavailable(QwenLlamaLivePreviewLeaseUnavailableReason)
}

final class NvidiaNemotronASRServiceLease: ASRService, @unchecked Sendable {
    let service: NvidiaNemotronASRService
    private let activityLease: RuntimeActivityLease

    init(
        service: NvidiaNemotronASRService,
        activityLease: RuntimeActivityLease
    ) {
        self.service = service
        self.activityLease = activityLease
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await service.transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
    }
}

@MainActor
final class ASRFactory {
    static let shared = ASRFactory()

    private final class QwenBackendEntry {
        let key: String
        let manager: LlamaCppServerManager
        let activationGate: QwenBackendActivationGate
        var leaseCount = 0

        init(
            key: String,
            manager: LlamaCppServerManager,
            activationGate: QwenBackendActivationGate
        ) {
            self.key = key
            self.manager = manager
            self.activationGate = activationGate
        }
    }

    private struct QwenRetirement {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var qwenBackends: [String: QwenBackendEntry] = [:]
    private var qwenBackendOrder: [String] = []
    private var qwenRetirement: QwenRetirement?
    private let qwenMaintenance = RuntimeMaintenanceGate()
    private let nvidiaMaintenance = RuntimeMaintenanceGate()

    func get() -> ASRService {
        get(sources: AppSettings.enabledRecognitionSources)
    }

    // Final recognition accepts only the recorded audio. Live preview output may
    // be incomplete and must never satisfy a batch source attempt.
    func get(sources: [RecognitionSource]) -> ASRService {
        makeSessionService(configuration: .capture(sources: sources), singleSource: false)
    }

    func getInstalled(source: RecognitionSource) -> ASRService {
        makeSessionService(configuration: .capture(sources: [source]), singleSource: true)
    }

    func makeSessionService(
        configuration: ASRSessionConfiguration,
        singleSource: Bool
    ) -> ASRService {
        let bindings = configuration.sources.map {
            sourceBinding(for: $0, configuration: configuration)
        }
        let base: any ASRService
        if singleSource, let binding = bindings.first {
            base = SessionSingleSourceASRService(
                binding: binding,
                timeoutSeconds: configuration.unifiedAttemptTimeoutSeconds
            )
        } else {
            base = MultiSourceASRService(
                bindings: bindings,
                timeoutSeconds: configuration.unifiedAttemptTimeoutSeconds
            )
        }
        return SessionBoundASRService(configuration: configuration, base: base)
    }

    var isQwenLlamaInstalledForCurrentSettings: Bool {
        FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaModelPath)
            && FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaMMProjPath)
            && AppPaths.bundledLlamaServer != nil
    }

    var isNvidiaNemotronInstalledForCurrentSettings: Bool {
        let spec = NvidiaNemotronASRModelCatalog.spec(for: AppSettings.asrNvidiaNemotronModelID)
        return spec.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: AppSettings.asrNvidiaNemotronPath(for: file))
        }
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
        guard let lease = qwenLlamaServiceLeaseAfterInstall() else {
            throw LlamaServerError.launchFailed("Bundled llama-server binary not found")
        }
        try await lease.service.preload()
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
        let maintenance = try await beginNvidiaNemotronMaintenance()
        defer { maintenance.finish() }
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
        await preloadNvidiaNemotron {
            let status = NvidiaNemotronASRService.bundledRuntimeStatus()
            if status.isReady {
                await NvidiaNemotronWarmPool.shared.preloadForCurrentSettings()
                Log.asr.info("NVIDIA Nemotron ASR warm helper requested")
            } else {
                NvidiaNemotronWarmPool.shared.terminateIdle(reason: "runtime_not_ready")
                Log.asr.notice("NVIDIA Nemotron ASR preload skipped: \(status.detail, privacy: .public)")
            }
        }
    }

    func preloadNvidiaNemotron(
        using provider: @escaping @MainActor () async -> Void
    ) async {
        guard let runtimeLease = nvidiaNemotronRuntimeLease() else {
            Log.asr.notice("NVIDIA Nemotron ASR preload skipped during model maintenance")
            return
        }
        defer { runtimeLease.release() }
        guard !Task.isCancelled else { return }
        await provider()
    }

    func stopQwenLlama() async {
        let entries = Array(qwenBackends.values)
        let managers = entries.map(\.manager)
        let precedingRetirement = qwenRetirement?.task
        qwenBackends.removeAll()
        qwenBackendOrder.removeAll()
        qwenRetirement = nil
        await withTaskGroup(of: Void.self) { group in
            for manager in managers {
                group.addTask {
                    await manager.retire()
                }
            }
        }
        if let precedingRetirement {
            await precedingRetirement.value
        }
        entries.forEach { $0.activationGate.open() }
    }

    /// File replacement and deletion wait for session leases instead of
    /// invalidating a recording that already captured this backend. New
    /// sessions remain unavailable until the returned lease is finished.
    func beginQwenLlamaMaintenance() async throws -> QwenLlamaMaintenanceLease {
        try await qwenMaintenance.beginMaintenance { [weak self] in
            await self?.stopQwenLlama()
        }
    }

    func stopNvidiaNemotron() async {
        await NvidiaNemotronWarmPool.shared.shutdown(reason: "stop_requested")
    }

    /// Destructive model operations wait for recordings that captured the
    /// current files. New sessions receive an explicit maintenance error until
    /// the caller releases the returned lease.
    func beginNvidiaNemotronMaintenance() async throws -> NvidiaNemotronMaintenanceLease {
        try await nvidiaMaintenance.beginMaintenance { [weak self] in
            await self?.stopNvidiaNemotron()
        }
    }

    private func nvidiaNemotronServiceLease(
        configuration: NvidiaNemotronASRConfiguration
    ) -> NvidiaNemotronASRServiceLease? {
        guard let activityLease = nvidiaMaintenance.acquire() else { return nil }
        return NvidiaNemotronASRServiceLease(
            service: NvidiaNemotronASRService(configuration: configuration),
            activityLease: activityLease
        )
    }

    /// Every helper start that can read the model files participates in the
    /// same drain as batch sessions, so maintenance cannot race a warm helper.
    func nvidiaNemotronRuntimeLease() -> NvidiaNemotronRuntimeLease? {
        nvidiaMaintenance.acquire()
    }

    func qwenLlamaServiceLeaseAfterInstall() -> QwenLlamaASRServiceLease? {
        guard let configuration = ASRSessionConfiguration.capture(sources: [.qwen]).qwen else {
            return nil
        }
        return qwenLlamaServiceLease(configuration: configuration)
    }

    func qwenLlamaServiceLeaseIfInstalled() -> QwenLlamaASRServiceLease? {
        guard let configuration = ASRSessionConfiguration.capture(sources: [.qwen]).qwen,
              configuration.isInstalledAtCapture
        else { return nil }
        return qwenLlamaServiceLease(configuration: configuration)
    }

    func qwenLlamaLivePreviewServiceLease() -> QwenLlamaLivePreviewLeaseAcquisition {
        guard let configuration = ASRSessionConfiguration.capture(sources: [.qwen]).qwen else {
            return .unavailable(.modelMissing)
        }
        return qwenLlamaLivePreviewServiceLease(configuration: configuration)
    }

    func qwenLlamaLivePreviewServiceLease(
        configuration: QwenLlamaASRConfiguration
    ) -> QwenLlamaLivePreviewLeaseAcquisition {
        guard !qwenMaintenance.isUnderMaintenance else {
            return .unavailable(.maintenance)
        }
        guard configuration.modelFilesInstalledAtCapture else {
            return .unavailable(.modelMissing)
        }
        guard configuration.binaryURL != nil else {
            return .unavailable(.runtimeMissing)
        }
        guard let lease = qwenLlamaServiceLease(configuration: configuration) else {
            return .unavailable(.runtimeMissing)
        }
        return .acquired(lease)
    }

    private func qwenLlamaServiceLease(
        configuration: QwenLlamaASRConfiguration
    ) -> QwenLlamaASRServiceLease? {
        guard !qwenMaintenance.isUnderMaintenance else { return nil }
        guard let binary = configuration.binaryURL else { return nil }
        let key = configuration.serverRuntimeReuseKey
        let entry: QwenBackendEntry
        if let existing = qwenBackends[key] {
            entry = existing
        } else {
            let activatesImmediately = qwenBackendOrder.isEmpty && qwenRetirement == nil
            let activationGate = QwenBackendActivationGate(isOpen: activatesImmediately)
            let activationBarrier: Task<Void, Never>? = activatesImmediately ? nil : Task.detached {
                await activationGate.wait()
            }
            let server = LlamaCppServerManager(
                modelPath: configuration.modelPath,
                contextSize: 4096,
                useFlashAttn: configuration.useFlashAttention,
                binaryURL: binary,
                pidFile: AppPaths.asrLlamaPidFile,
                requiredFiles: [configuration.mmprojPath],
                extraArguments: ["--mmproj", configuration.mmprojPath],
                coldTimeoutSec: 180,
                activationBarrier: activationBarrier
            )
            entry = QwenBackendEntry(
                key: key,
                manager: server,
                activationGate: activationGate
            )
            qwenBackends[key] = entry
            qwenBackendOrder.append(key)
        }
        guard let activityLease = qwenMaintenance.acquire(onRelease: { [weak self] in
            self?.releaseQwenBackend(key: key)
        }) else { return nil }
        entry.leaseCount += 1
        advanceQwenBackendQueueIfNeeded()

        let service = QwenLlamaASRService(
            server: entry.manager,
            configuration: configuration
        )
        return QwenLlamaASRServiceLease(service: service, activityLease: activityLease)
    }

    private func releaseQwenBackend(key: String) {
        guard let entry = qwenBackends[key], entry.leaseCount > 0 else { return }
        entry.leaseCount -= 1
        advanceQwenBackendQueueIfNeeded()
    }

    private func advanceQwenBackendQueueIfNeeded() {
        guard qwenRetirement == nil,
              let firstKey = qwenBackendOrder.first,
              let first = qwenBackends[firstKey]
        else { return }

        guard qwenBackendOrder.count > 1, first.leaseCount == 0 else {
            first.activationGate.open()
            return
        }

        qwenBackendOrder.removeFirst()
        qwenBackends[firstKey] = nil
        let retirementID = UUID()
        let task = Task { [weak self] in
            await first.manager.retire()
            self?.finishQwenBackendRetirement(id: retirementID)
        }
        qwenRetirement = QwenRetirement(id: retirementID, task: task)
    }

    private func finishQwenBackendRetirement(id: UUID) {
        guard qwenRetirement?.id == id else { return }
        qwenRetirement = nil
        advanceQwenBackendQueueIfNeeded()
    }

    private func sourceBinding(
        for source: RecognitionSource,
        configuration: ASRSessionConfiguration
    ) -> ASRSourceBinding {
        switch source {
        case .qwen:
            guard let qwen = configuration.qwen else {
                return ASRSourceBinding(
                    source: source,
                    modelID: "qwen3-asr",
                    service: UnavailableASRService(reason: "Qwen3-ASR configuration is unavailable")
                )
            }
            guard !qwenMaintenance.isUnderMaintenance else {
                return ASRSourceBinding(
                    source: source,
                    modelID: qwen.modelID,
                    service: UnavailableASRService(
                        reason: "Qwen3-ASR is temporarily unavailable during model maintenance"
                    )
                )
            }
            guard qwen.isInstalledAtCapture,
                  let service = qwenLlamaServiceLease(configuration: qwen)
            else {
                return ASRSourceBinding(
                    source: source,
                    modelID: qwen.modelID,
                    service: UnavailableASRService(
                        reason: "Qwen3-ASR model is not installed. Open Setup Guide to download it."
                    )
                )
            }
            return ASRSourceBinding(source: source, modelID: qwen.modelID, service: service)

        case .nvidiaNemotron:
            guard let nvidia = configuration.nvidiaNemotron else {
                return ASRSourceBinding(
                    source: source,
                    modelID: NvidiaNemotronASRModelCatalog.defaultID,
                    service: UnavailableASRService(reason: "NVIDIA Nemotron ASR configuration is unavailable")
                )
            }
            guard nvidia.isInstalledAtCapture else {
                return ASRSourceBinding(
                    source: source,
                    modelID: nvidia.modelID,
                    service: UnavailableASRService(
                        reason: nvidia.unavailableReason
                            ?? "NVIDIA Nemotron ASR model is not installed. Open Setup Guide to download it."
                    )
                )
            }
            guard !nvidiaMaintenance.isUnderMaintenance,
                  let service = nvidiaNemotronServiceLease(configuration: nvidia)
            else {
                return ASRSourceBinding(
                    source: source,
                    modelID: nvidia.modelID,
                    service: UnavailableASRService(
                        reason: "NVIDIA Nemotron ASR is temporarily unavailable during model maintenance"
                    )
                )
            }
            return ASRSourceBinding(
                source: source,
                modelID: nvidia.modelID,
                service: service
            )

        case .appleSpeech:
            return ASRSourceBinding(
                source: source,
                modelID: "on-device",
                service: AppleSpeechASRService(
                    addsPunctuation: configuration.appleSpeechAddsPunctuation
                )
            )
        }
    }
}

private struct UnavailableASRService: ASRService {
    let reason: String

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        throw ASRAudioSupportError.httpStatus(503, reason)
    }
}

struct SessionBoundASRService: ASRService {
    let configuration: ASRSessionConfiguration
    private let base: any ASRService

    init(configuration: ASRSessionConfiguration, base: any ASRService) {
        self.configuration = configuration
        self.base = base
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await base.transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
    }

    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        try await base.transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs)
    }

    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription {
        try await base.transcribeResult(
            audioFileURL: audioFileURL,
            languageIDs: languageIDs,
            progress: progress
        )
    }
}

enum ASRStringOperationTimeout {
    static func run(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await operation()
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

struct ASRSourceBinding: Sendable {
    let source: RecognitionSource
    let modelID: String
    let service: any ASRService
}

private struct SessionSingleSourceASRService: ASRService {
    let binding: ASRSourceBinding
    let timeoutSeconds: TimeInterval

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
            await progress(ASRTranscriptionProgress(
                completedSources: 0,
                totalSources: 1,
                source: binding.source
            ))
        }
        let started = Date()
        let text: String
        do {
            text = try await ASRStringOperationTimeout.run(timeoutSeconds: timeoutSeconds) {
                try await binding.service.transcribe(
                    audioFileURL: audioFileURL,
                    languageIDs: languageIDs
                )
            }
        } catch {
            if let progress {
                await progress(ASRTranscriptionProgress(
                    completedSources: 1,
                    totalSources: 1,
                    source: binding.source
                ))
            }
            throw error
        }
        if let progress {
            await progress(ASRTranscriptionProgress(
                completedSources: 1,
                totalSources: 1,
                source: binding.source
            ))
        }
        return ASRTranscription(
            text: text,
            hypotheses: [text],
            modelOutputs: [
                ASRModelOutputFactory.output(
                    for: binding.source,
                    modelID: binding.modelID,
                    text: text,
                    latencyMs: elapsedASRMS(since: started)
                )
            ]
        )
    }

}

struct MultiSourceASRService: ASRService {
    let bindings: [ASRSourceBinding]
    let timeoutSeconds: TimeInterval

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
        let enabledSources = bindings.map(\.source)
        guard !enabledSources.isEmpty else {
            throw ASRAudioSupportError.httpStatus(503, "No ASR source enabled")
        }
        let selectedLanguageIDs = ASRLanguageSelection.validatedIDsForTranscription(
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
        if let progress, enabledSources.count > 1 {
            await progress(ASRTranscriptionProgress(
                completedSources: 0,
                totalSources: enabledSources.count,
                source: nil
            ))
        }
        try await withThrowingTaskGroup(of: ASRSourceAttemptResult.self) { group in
            var completedSourceCount = 0
            for (index, binding) in bindings.enumerated() {
                group.addTask {
                    try await Self.attempt(
                        binding: binding,
                        index: index,
                        audioFileURL: canonicalAudioURL,
                        selectedLanguageIDs: selectedLanguageIDs,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            }
            while let attempt = try await group.next() {
                try Task.checkCancellation()
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

        try Task.checkCancellation()
        return try Self.transcription(from: attempts)
    }

    private static func transcription(from attempts: [ASRSourceAttemptResult]) throws -> ASRTranscription {
        let ordered = attempts.sorted { $0.index < $1.index }
        let successfulTexts = ordered
            .compactMap { $0.successText }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hypotheses = CorrectionRequest.normalizedASRHypotheses(
            candidates: successfulTexts.map(Optional.some)
        )
        guard let transcript = hypotheses.first else {
            if MultiSourceASRResultPolicy.shouldReturnEmptyTranscript(
                statuses: ordered.map(\.status)
            ) {
                throw ASRAudioSupportError.emptyTranscript
            }
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
            guard attempt.status != "ok", attempt.status != "empty" else { return nil }
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
        binding: ASRSourceBinding,
        index: Int,
        audioFileURL: URL,
        selectedLanguageIDs: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> ASRSourceAttemptResult {
        try Task.checkCancellation()
        let started = Date()
        let source = binding.source
        let effectiveLanguageIDs: [String]
        switch source {
        case .appleSpeech:
            if let resolved = await AppleSpeechLanguageSupport.bestSupportedLocaleIdentifier(
                for: selectedLanguageIDs
            ) {
                effectiveLanguageIDs = [resolved.languageID]
            } else {
                effectiveLanguageIDs = []
            }
        case .qwen, .nvidiaNemotron:
            effectiveLanguageIDs = ASRLanguageSelection.effectiveIDs(selectedLanguageIDs, for: source)
        }
        try Task.checkCancellation()
        guard !effectiveLanguageIDs.isEmpty else {
            return ASRSourceAttemptResult(
                source: source,
                modelID: binding.modelID,
                index: index,
                status: "skipped_unsupported_language",
                text: nil,
                error: "No selected language is supported by this source",
                latencyMs: elapsedASRMS(since: started)
            )
        }
        do {
            let text = try await transcribe(
                service: binding.service,
                audioFileURL: audioFileURL,
                languageIDs: effectiveLanguageIDs,
                timeoutSeconds: timeoutSeconds
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ASRSourceAttemptResult(
                source: source,
                modelID: binding.modelID,
                index: index,
                status: trimmed.isEmpty ? "empty" : "ok",
                text: trimmed.isEmpty ? nil : trimmed,
                error: nil,
                latencyMs: elapsedASRMS(since: started)
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if ASRAudioSupport.isBenignEmptyTranscript(error) {
                return ASRSourceAttemptResult(
                    source: source,
                    modelID: binding.modelID,
                    index: index,
                    status: "empty",
                    text: nil,
                    error: nil,
                    latencyMs: elapsedASRMS(since: started)
                )
            }
            return ASRSourceAttemptResult(
                source: source,
                modelID: binding.modelID,
                index: index,
                status: "error",
                text: nil,
                error: error.localizedDescription,
                latencyMs: elapsedASRMS(since: started)
            )
        }
    }

    private static func transcribe(
        service: any ASRService,
        audioFileURL: URL,
        languageIDs: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await ASRStringOperationTimeout.run(timeoutSeconds: timeoutSeconds) {
            try await service.transcribe(
                audioFileURL: audioFileURL,
                languageIDs: languageIDs
            )
        }
    }
}

enum MultiSourceASRResultPolicy {
    static func shouldReturnEmptyTranscript(statuses: [String]) -> Bool {
        let hasActualEmptyAttempt = statuses.contains("empty")
        guard hasActualEmptyAttempt else { return false }
        return statuses.allSatisfy {
            $0 == "empty" || $0 == "skipped_unsupported_language"
        }
    }
}

private struct ASRSourceAttemptResult: Sendable {
    let source: RecognitionSource
    let modelID: String
    let index: Int
    let status: String
    let text: String?
    let error: String?
    let latencyMs: Int?

    var successText: String? {
        guard status == "ok" else { return nil }
        return text
    }

    var modelOutput: ASRTranscriptModelOutput {
        ASRModelOutputFactory.output(
            for: source,
            modelID: modelID,
            text: text ?? "",
            status: status,
            error: error,
            latencyMs: latencyMs
        )
    }
}

private enum ASRModelOutputFactory {
    static func output(
        for source: RecognitionSource,
        modelID: String,
        text: String,
        status: String? = nil,
        error: String? = nil,
        latencyMs: Int? = nil
    ) -> ASRTranscriptModelOutput {
        let provider: String
        switch source {
        case .qwen: provider = "qwen3-asr-llama"
        case .nvidiaNemotron: provider = "nvidia-nemotron-asr"
        case .appleSpeech: provider = "apple-speech"
        }
        return ASRTranscriptModelOutput(
            role: "source",
            provider: provider,
            model: modelID,
            status: status ?? (error == nil ? "ok" : "error"),
            text: text,
            error: error,
            latencyMs: latencyMs
        )
    }
}

private func elapsedASRMS(since date: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(date) * 1_000))
}
