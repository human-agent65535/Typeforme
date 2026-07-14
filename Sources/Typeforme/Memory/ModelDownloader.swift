import Combine
import Foundation

@MainActor
final class ModelDownloadOperationOwnership: @unchecked Sendable {
    private var owner: (any Sendable)?

    init(owner: (any Sendable)?) {
        self.owner = owner
    }

    var isRetainingOwner: Bool { owner != nil }

    func finish() {
        owner = nil
    }
}

/// Owns the two resources a manual model change must exclude: automatic
/// installation for the target paths and inference using the affected runtime.
/// Multiple downloaders may retain the same lease; both exclusions end when the
/// last downloader releases it.
final class ModelManualMaintenanceLease: @unchecked Sendable {
    private let autoInstallLease: ModelAutoInstallMaintenanceLease
    private let runtimeLease: RuntimeMaintenanceLease

    fileprivate init(
        autoInstallLease: ModelAutoInstallMaintenanceLease,
        runtimeLease: RuntimeMaintenanceLease
    ) {
        self.autoInstallLease = autoInstallLease
        self.runtimeLease = runtimeLease
    }

    func finishAndWait() async {
        runtimeLease.finish()
        await autoInstallLease.finishAndWait()
    }
}

@MainActor
enum ModelManualMaintenance {
    static func begin(
        atPaths paths: [String],
        beginRuntimeMaintenance: () async throws -> RuntimeMaintenanceLease
    ) async throws -> ModelManualMaintenanceLease {
        let autoInstallLease = try await ModelAutoInstaller.shared.beginMaintenance(atPaths: paths)
        do {
            try Task.checkCancellation()
            let runtimeLease = try await beginRuntimeMaintenance()
            do {
                try Task.checkCancellation()
                return ModelManualMaintenanceLease(
                    autoInstallLease: autoInstallLease,
                    runtimeLease: runtimeLease
                )
            } catch {
                runtimeLease.finish()
                throw error
            }
        } catch {
            await autoInstallLease.finishAndWait()
            throw error
        }
    }
}

/// Owns the cancellable preparation phase before a manual model download or
/// deletion reaches `ModelDownloader`. SwiftUI rows use one controller so a
/// second click cannot enqueue a hidden operation behind a path lease.
@MainActor
final class ModelManualOperationController: ObservableObject {
    @Published private(set) var isPending = false

    private var task: Task<Void, Never>?

    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        isPending = true
        task = Task { @MainActor [weak self] in
            await operation()
            guard let self else { return }
            self.task = nil
            self.isPending = false
        }
    }

    func cancel() {
        task?.cancel()
    }

    deinit {
        task?.cancel()
    }
}

/// Streams a single GGUF (or any large file) from a URL to disk with live
/// progress, suitable for binding from SwiftUI via `@ObservedObject`.
/// Used by the Settings UI download buttons.
@MainActor
final class ModelDownloader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case completed(at: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var task: URLSessionDownloadTask?
    private var runner: ResumableModelDownloadRunner?
    private var destination: URL?
    private var resumeData: Data?
    private var resumeDestination: URL?
    private var runID: UUID?
    /// Retains operation-scoped resources (for example a model maintenance
    /// lease) until the transfer has actually completed or cancelled. SwiftUI
    /// view lifetime is shorter than a registry-owned download.
    private var operationOwnership: ModelDownloadOperationOwnership?

    func start(
        from url: URL,
        to destination: URL,
        checksumPolicy: ModelDownloadChecksumPolicy,
        expectedBytes: Int64? = nil,
        operationOwner: (any Sendable)? = nil
    ) {
        if task != nil {
            cancel()
        }

        self.destination = destination
        let operationOwnership = ModelDownloadOperationOwnership(owner: operationOwner)
        self.operationOwnership = operationOwnership
        let runID = UUID()
        self.runID = runID
        state = .downloading(received: 0, total: 0)

        let runner = ResumableModelDownloadRunner(
            destination: destination,
            label: destination.lastPathComponent,
            checksumPolicy: checksumPolicy,
            expectedBytes: expectedBytes,
            onProgress: { [weak self] received, total in
                Task { @MainActor in
                    guard self?.runID == runID else { return }
                    self?.state = .downloading(received: received, total: total)
                }
            },
            onCompletion: { [weak self, operationOwnership] completion in
                Task { @MainActor in
                    guard self?.runID == runID else {
                        operationOwnership.finish()
                        return
                    }
                    self?.handleCompletion(completion)
                }
            }
        )
        let matchingResumeData = resumeDestination == destination ? resumeData : nil
        resumeData = nil

        resumeDestination = destination
        self.runner = runner
        let nextTask = runner.start(from: url, resumeData: matchingResumeData)
        task = nextTask
    }

    func cancel() {
        guard let task else {
            if case .downloading = state { state = .idle }
            operationOwnership?.finish()
            operationOwnership = nil
            return
        }

        let cancelledDestination = destination
        let operationOwnership = self.operationOwnership
        runner?.cancel { [weak self, operationOwnership] data in
            Task { @MainActor in
                guard let self else {
                    operationOwnership?.finish()
                    return
                }
                if let data, !data.isEmpty {
                    self.storeResumeData(data, for: cancelledDestination)
                }
                if self.task === task {
                    self.finishActiveTask()
                    if case .downloading = self.state {
                        self.state = .idle
                    }
                } else {
                    operationOwnership?.finish()
                }
            }
        }
        if case .downloading = state { state = .idle }
    }

    func reset() {
        cancel()
        runID = nil
        resumeData = nil
        resumeDestination = nil
        ModelDownloadResumeStore.remove(for: destination)
        state = .idle
    }

    func fail(_ message: String) {
        cancel()
        state = .failed(message)
    }

    var progress: Double {
        if case .downloading(let received, let total) = state, total > 0 {
            return Double(received) / Double(total)
        }
        return 0
    }

    private func handleCompletion(_ completion: ModelDownloadCompletion) {
        switch completion {
        case .success(let url):
            finishActiveTask()
            resumeData = nil
            resumeDestination = nil
            state = .completed(at: url)
            Log.store.info("model downloaded: \(url.lastPathComponent, privacy: .public)")
        case .failure(let message, let producedResumeData, let wasCancelled):
            if let producedResumeData, !producedResumeData.isEmpty {
                storeResumeData(producedResumeData, for: destination)
            } else if !wasCancelled {
                ModelDownloadResumeStore.remove(for: destination)
            }
            finishActiveTask()
            state = wasCancelled ? .idle : .failed(message)
        }
    }

    private func finishActiveTask() {
        task = nil
        runner = nil
        runID = nil
        operationOwnership?.finish()
        operationOwnership = nil
    }

    private func storeResumeData(_ data: Data, for destination: URL?) {
        resumeData = data
        resumeDestination = destination
        guard let destination else { return }
        ModelDownloadResumeStore.store(data, for: destination)
    }
}

@MainActor
final class ModelDownloadRegistry: ObservableObject {
    private var downloaders: [String: ModelDownloader] = [:]
    private var cancellables: [String: AnyCancellable] = [:]

    func downloader(for key: String) -> ModelDownloader {
        if let downloader = downloaders[key] {
            return downloader
        }

        let downloader = ModelDownloader()
        downloaders[key] = downloader
        cancellables[key] = downloader.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
        return downloader
    }
}
