import Foundation
import os.lock

enum ModelAutoInstallError: LocalizedError {
    case emptyURL(label: String)
    case invalidURL(String)
    case httpStatus(Int, label: String)
    case maintenanceInProgress(label: String)

    var errorDescription: String? {
        switch self {
        case .emptyURL(let label):
            return "Download URL is empty for \(label)"
        case .invalidURL(let value):
            return "Invalid model download URL: \(value)"
        case .httpStatus(let status, let label):
            return "\(label) download failed with HTTP \(status)"
        case .maintenanceInProgress(let label):
            return "\(label) is being managed manually"
        }
    }
}

final class ModelAutoInstallMaintenanceLease: @unchecked Sendable {
    private struct State {
        var release: (@Sendable () async -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    fileprivate init(installer: ModelAutoInstaller, standardizedPaths: [String]) {
        state = OSAllocatedUnfairLock(initialState: State(release: {
            await installer.endMaintenance(atStandardizedPaths: standardizedPaths)
        }))
    }

    func finish() {
        guard let release = claimRelease() else { return }
        Task { await release() }
    }

    func finishAndWait() async {
        guard let release = claimRelease() else { return }
        await release()
    }

    private func claimRelease() -> (@Sendable () async -> Void)? {
        state.withLock { state in
            defer { state.release = nil }
            return state.release
        }
    }

    deinit {
        finish()
    }
}

enum ModelInstallRegistry {
    private static let activeLabelsByPath = OSAllocatedUnfairLock(initialState: [String: String]())

    static func markInstalling(path: String, label: String) {
        activeLabelsByPath.withLock { labels in
            labels[path] = label
        }
    }

    static func markFinished(path: String) {
        activeLabelsByPath.withLock { labels in
            labels[path] = nil
        }
    }

    static func isInstalling(path: String) -> Bool {
        activeLabelsByPath.withLock { labels in
            labels[path] != nil
        }
    }
}

actor ModelAutoInstaller {
    static let shared = ModelAutoInstaller()

    private struct ActiveInstall {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct MaintenanceWaiter {
        let id: UUID
        let paths: Set<String>
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var tasks: [String: ActiveInstall] = [:]
    private var activeMaintenancePaths: Set<String> = []
    private var maintenanceWaiters: [MaintenanceWaiter] = []

    func beginMaintenance(atPaths paths: [String]) async throws -> ModelAutoInstallMaintenanceLease {
        try Task.checkCancellation()
        let standardizedPaths = Array(Set(paths.map(Self.standardizedPath))).sorted()
        let pathSet = Set(standardizedPaths)
        try await reserveMaintenance(paths: pathSet)
        do {
            try Task.checkCancellation()
            for path in standardizedPaths {
                while let activeInstall = tasks[path] {
                    activeInstall.task.cancel()
                    _ = await activeInstall.task.result
                    try Task.checkCancellation()
                    if tasks[path]?.id == activeInstall.id {
                        tasks[path] = nil
                    }
                }
            }
            try Task.checkCancellation()

            return ModelAutoInstallMaintenanceLease(
                installer: self,
                standardizedPaths: standardizedPaths
            )
        } catch {
            endMaintenance(atStandardizedPaths: standardizedPaths)
            throw error
        }
    }

    private func reserveMaintenance(paths: Set<String>) async throws {
        guard !paths.isDisjoint(with: activeMaintenancePaths) else {
            activeMaintenancePaths.formUnion(paths)
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                maintenanceWaiters.append(MaintenanceWaiter(
                    id: waiterID,
                    paths: paths,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelMaintenanceWaiter(waiterID) }
        }
    }

    @discardableResult
    func cancelAndWaitForInstall(atPath path: String) async -> Bool {
        let key = Self.standardizedPath(path)
        var cancelledAnInstall = false
        while let activeInstall = tasks[key] {
            cancelledAnInstall = true
            activeInstall.task.cancel()
            _ = await activeInstall.task.result
            if tasks[key]?.id == activeInstall.id {
                tasks[key] = nil
            }
        }
        return cancelledAnInstall
    }

    func ensureFile(
        atPath path: String,
        downloadURLString: String,
        label: String,
        expectedBytes: Int64? = nil
    ) async throws {
        try Task.checkCancellation()
        let key = Self.standardizedPath(path)
        try rejectMaintenance(for: key, label: label)
        let trimmedURL = downloadURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ModelAutoInstallError.emptyURL(label: label)
        }
        guard let url = URL(string: trimmedURL) else {
            throw ModelAutoInstallError.invalidURL(trimmedURL)
        }
        let checksumPolicy = try ModelDownloadIntegrity.checksumPolicy(for: url, label: label)

        if FileManager.default.fileExists(atPath: path) {
            do {
                try ModelDownloadIntegrity.validateFile(
                    at: URL(fileURLWithPath: path),
                    checksumPolicy: checksumPolicy,
                    expectedBytes: expectedBytes,
                    label: label
                )
                return
            } catch {
                // Preserve the existing file until a verified replacement is
                // atomically committed. It may be incomplete, but deleting it
                // first turns a transient download failure into data loss.
            }
        }

        if let existing = tasks[key] {
            // A cancelled waiter must not cancel path-scoped shared work, but
            // it also must not continue into validation or start a replacement.
            let result = await existing.task.result
            try Task.checkCancellation()
            try rejectMaintenance(for: key, label: label)
            try result.get()
            // A caller may request another trusted artifact at the same path.
            // Reuse the serialized writer only when its result satisfies this
            // caller's checksum and size contract.
            if (try? ModelDownloadIntegrity.validateFile(
                at: URL(fileURLWithPath: path),
                checksumPolicy: checksumPolicy,
                expectedBytes: expectedBytes,
                label: label
            )) != nil {
                return
            }
        }

        try rejectMaintenance(for: key, label: label)

        let destination = URL(fileURLWithPath: path)
        let installID = UUID()
        let task = Task {
            try await Self.download(
                from: url,
                to: destination,
                label: label,
                checksumPolicy: checksumPolicy,
                expectedBytes: expectedBytes
            )
        }
        tasks[key] = ActiveInstall(id: installID, task: task)
        defer {
            if tasks[key]?.id == installID {
                tasks[key] = nil
            }
        }
        let result = await task.result
        try Task.checkCancellation()
        try result.get()
    }

    fileprivate func endMaintenance(atStandardizedPaths paths: [String]) {
        for path in paths {
            activeMaintenancePaths.remove(path)
        }

        var remaining: [MaintenanceWaiter] = []
        var ready: [CheckedContinuation<Void, any Error>] = []
        for waiter in maintenanceWaiters {
            if waiter.paths.isDisjoint(with: activeMaintenancePaths) {
                activeMaintenancePaths.formUnion(waiter.paths)
                ready.append(waiter.continuation)
            } else {
                remaining.append(waiter)
            }
        }
        maintenanceWaiters = remaining
        ready.forEach { $0.resume() }
    }

    func maintenanceWaiterCount(atPath path: String) -> Int {
        let key = Self.standardizedPath(path)
        return maintenanceWaiters.count { $0.paths.contains(key) }
    }

    private func cancelMaintenanceWaiter(_ waiterID: UUID) {
        guard let index = maintenanceWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = maintenanceWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func rejectMaintenance(for path: String, label: String) throws {
        guard !activeMaintenancePaths.contains(path) else {
            throw ModelAutoInstallError.maintenanceInProgress(label: label)
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func download(
        from url: URL,
        to destination: URL,
        label: String,
        checksumPolicy: ModelDownloadChecksumPolicy,
        expectedBytes: Int64?
    ) async throws {
        Log.store.notice("auto-installing model: \(label, privacy: .public)")
        ModelInstallRegistry.markInstalling(path: destination.path, label: label)
        defer { ModelInstallRegistry.markFinished(path: destination.path) }

        let runner = ResumableModelDownloadRunner(
            destination: destination,
            label: label,
            checksumPolicy: checksumPolicy,
            expectedBytes: expectedBytes
        )
        try await runner.download(from: url)
        Log.store.info("model auto-installed: \(destination.lastPathComponent, privacy: .public)")
    }
}
