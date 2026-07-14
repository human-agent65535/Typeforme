import Foundation
import Testing
@testable import Typeforme

@Suite("ModelDownloadIntegrity")
struct ModelDownloadIntegrityTests {
    @MainActor
    @Test func registryReusesDownloadersByStableKey() {
        let registry = ModelDownloadRegistry()
        let first = registry.downloader(for: "model-a")
        let second = registry.downloader(for: "model-a")
        let other = registry.downloader(for: "model-b")

        #expect(first === second)
        #expect(first !== other)
    }

    @Test func canonicalHuggingFaceURLIgnoresDownloadQuery() throws {
        let url = try #require(URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true"))
        #expect(ModelDownloadIntegrity.expectedSHA256(for: url) == "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223")
    }

    @Test func checksumPolicyRequiresKnownSHAForDownloads() throws {
        let url = try #require(URL(string: "https://example.com/custom-model.gguf"))
        #expect(throws: ModelDownloadIntegrityError.self) {
            try ModelDownloadIntegrity.checksumPolicy(for: url, label: "custom")
        }
    }

    @Test func nemotronDownloadURLsHaveTrustedSHA256() throws {
        let spec = NvidiaNemotronASRModelCatalog.spec(for: NvidiaNemotronASRModelCatalog.defaultID)
        for file in spec.files {
            let url = try #require(URL(string: file.defaultURL))
            #expect(ModelDownloadIntegrity.expectedSHA256(for: url) != nil, "\(file.label) is missing SHA256")
        }
    }

    @Test func validatesSHA256WithoutLoadingWholeFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-integrity-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try ModelDownloadIntegrity.validateFile(
            at: url,
            checksumPolicy: .verifySHA256("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            label: "fixture"
        )
        #expect(throws: ModelDownloadIntegrityError.self) {
            try ModelDownloadIntegrity.validateFile(
                at: url,
                checksumPolicy: .verifySHA256(String(repeating: "0", count: 64)),
                label: "fixture"
            )
        }
    }

    @Test func validatesExpectedByteCount() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-integrity-size-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try ModelDownloadIntegrity.validateFile(
            at: url,
            expectedBytes: 3,
            label: "fixture"
        )
        #expect(throws: ModelDownloadIntegrityError.self) {
            try ModelDownloadIntegrity.validateFile(
                at: url,
                expectedBytes: 4,
                label: "fixture"
            )
        }
    }

    @Test func failedInstallPreservesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-model-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloaded = root.appendingPathComponent("downloaded.tmp")
        let destination = root.appendingPathComponent("model.gguf")
        try Data("replacement".utf8).write(to: downloaded)
        try Data("known-good".utf8).write(to: destination)

        #expect(throws: ModelDownloadIntegrityError.self) {
            try ModelDownloadFileInstaller.install(
                downloadedFile: downloaded,
                at: destination,
                checksumPolicy: .verifySHA256(String(repeating: "0", count: 64)),
                expectedBytes: nil,
                label: "fixture",
                cancellationCheck: {},
                beginCommit: {}
            )
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "known-good")
    }

    @Test func verifiedInstallAtomicallyReplacesDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-model-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloaded = root.appendingPathComponent("downloaded.tmp")
        let destination = root.appendingPathComponent("model.gguf")
        try Data("replacement".utf8).write(to: downloaded)
        try Data("known-good".utf8).write(to: destination)
        let checksum = try ModelDownloadIntegrity.sha256Hex(of: downloaded)

        try ModelDownloadFileInstaller.install(
            downloadedFile: downloaded,
            at: destination,
            checksumPolicy: .verifySHA256(checksum),
            expectedBytes: Int64(Data("replacement".utf8).count),
            label: "fixture",
            cancellationCheck: {},
            beginCommit: {}
        )

        #expect(try String(contentsOf: destination, encoding: .utf8) == "replacement")
        #expect(!FileManager.default.fileExists(atPath: downloaded.path))
    }

    @Test func cancellationDuringValidationPreservesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-model-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloaded = root.appendingPathComponent("downloaded.tmp")
        let destination = root.appendingPathComponent("model.gguf")
        try Data(repeating: 0x5A, count: 3 * 1024 * 1024).write(to: downloaded)
        try Data("known-good".utf8).write(to: destination)
        var checks = 0

        do {
            try ModelDownloadFileInstaller.install(
                downloadedFile: downloaded,
                at: destination,
                checksumPolicy: .verifySHA256(String(repeating: "0", count: 64)),
                expectedBytes: nil,
                label: "fixture",
                cancellationCheck: {
                    checks += 1
                    if checks >= 4 { throw CancellationError() }
                },
                beginCommit: {}
            )
            Issue.record("Expected installation cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(checks >= 4)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "known-good")
    }

    @Test func cancellationAtCommitGatePreservesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-model-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloaded = root.appendingPathComponent("downloaded.tmp")
        let destination = root.appendingPathComponent("model.gguf")
        let replacement = Data("replacement".utf8)
        try replacement.write(to: downloaded)
        try Data("known-good".utf8).write(to: destination)
        let checksum = try ModelDownloadIntegrity.sha256Hex(of: downloaded)

        #expect(throws: CancellationError.self) {
            try ModelDownloadFileInstaller.install(
                downloadedFile: downloaded,
                at: destination,
                checksumPolicy: .verifySHA256(checksum),
                expectedBytes: Int64(replacement.count),
                label: "fixture",
                cancellationCheck: {},
                beginCommit: { throw CancellationError() }
            )
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "known-good")
    }

    @Test func cancellationAfterCommitGateDoesNotOverrideSuccessfulInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-model-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloaded = root.appendingPathComponent("downloaded.tmp")
        let destination = root.appendingPathComponent("model.gguf")
        let replacement = Data("replacement".utf8)
        try replacement.write(to: downloaded)
        try Data("known-good".utf8).write(to: destination)
        let checksum = try ModelDownloadIntegrity.sha256Hex(of: downloaded)
        var cancellationRequested = false

        try ModelDownloadFileInstaller.install(
            downloadedFile: downloaded,
            at: destination,
            checksumPolicy: .verifySHA256(checksum),
            expectedBytes: Int64(replacement.count),
            label: "fixture",
            cancellationCheck: {
                if cancellationRequested { throw CancellationError() }
            },
            beginCommit: {
                cancellationRequested = true
            }
        )

        #expect(cancellationRequested)
        #expect(try Data(contentsOf: destination) == replacement)
    }

    @Test func lifecycleCompletionHasSingleWinner() {
        var lifecycle = ModelDownloadRunnerLifecycle()
        let firstClaim = lifecycle.claimCompletion()
        let secondClaim = lifecycle.claimCompletion()
        let cancellationAccepted = lifecycle.requestCancellation()

        #expect(firstClaim)
        #expect(!secondClaim)
        #expect(!cancellationAccepted)
    }

    @Test func lifecycleRejectsCancellationAfterCommitStarts() {
        var lifecycle = ModelDownloadRunnerLifecycle()
        let beganInstalling = lifecycle.beginInstalling()
        let beganCommit = lifecycle.beginCommit()
        let cancellationAccepted = lifecycle.requestCancellation()
        let completionClaimed = lifecycle.claimCompletion()

        #expect(beganInstalling)
        #expect(beganCommit)
        #expect(!cancellationAccepted)
        #expect(!lifecycle.cancellationRequested)
        #expect(completionClaimed)
    }

    @Test func lifecycleCancellationBeforeCommitPreventsCommit() {
        var lifecycle = ModelDownloadRunnerLifecycle()
        let beganInstalling = lifecycle.beginInstalling()
        let cancellationAccepted = lifecycle.requestCancellation()
        let beganCommit = lifecycle.beginCommit()
        let wasCancellationRequested = lifecycle.cancellationRequested
        let completionClaimed = lifecycle.claimCompletion()

        #expect(beganInstalling)
        #expect(cancellationAccepted)
        #expect(!beganCommit)
        #expect(wasCancellationRequested)
        #expect(completionClaimed)
    }

    @Test func transferCallbackCannotCompleteWhileInstallerOwnsResult() {
        var lifecycle = ModelDownloadRunnerLifecycle()
        let beganInstalling = lifecycle.beginInstalling()
        let transferClaimedCompletion = lifecycle.claimCompletion(unlessInstalling: true)
        let wasCompletedByTransfer = lifecycle.didComplete
        let installerClaimedCompletion = lifecycle.claimCompletion()

        #expect(beganInstalling)
        #expect(!transferClaimedCompletion)
        #expect(!wasCompletedByTransfer)
        #expect(installerClaimedCompletion)
    }

    @Test func safeRemoveDeletesDestinationAndResumeData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-model-remove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("model.gguf")
        try Data("installed".utf8).write(to: destination)
        ModelDownloadResumeStore.store(Data("resume".utf8), for: destination)

        try ModelDownloadFileInstaller.remove(at: destination)

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(ModelDownloadResumeStore.load(for: destination) == nil)
    }

    @Test func cancelAndWaitReportsWhenNoAutoInstallIsActive() async {
        let installer = ModelAutoInstaller()
        let didCancel = await installer.cancelAndWaitForInstall(
            atPath: "/tmp/typeforme-no-active-install"
        )

        #expect(!didCancel)
    }

    @Test func maintenanceLeaseRejectsAutoInstallUntilExplicitlyReleased() async throws {
        let installer = ModelAutoInstaller()
        let path = "/tmp/typeforme-auto-install-maintenance-\(UUID().uuidString)/model.gguf"
        let lease = try await installer.beginMaintenance(atPaths: [path])

        do {
            try await installer.ensureFile(
                atPath: path,
                downloadURLString: "",
                label: "fixture"
            )
            Issue.record("Expected maintenance to reject auto-install")
        } catch ModelAutoInstallError.maintenanceInProgress(_) {
            // Expected.
        } catch {
            Issue.record("Unexpected maintenance error: \(error)")
        }

        await lease.finishAndWait()
        do {
            try await installer.ensureFile(
                atPath: path,
                downloadURLString: "",
                label: "fixture"
            )
            Issue.record("Expected the empty URL to be rejected")
        } catch ModelAutoInstallError.emptyURL(_) {
            // Maintenance is over, so normal request validation owns the error.
        } catch {
            Issue.record("Unexpected error after maintenance: \(error)")
        }
    }

    @Test func concurrentMaintenanceForTheSamePathIsSerialized() async throws {
        let installer = ModelAutoInstaller()
        let path = "/tmp/typeforme-auto-install-serialized-\(UUID().uuidString)/model.gguf"
        let first = try await installer.beginMaintenance(atPaths: [path])
        let secondTask = Task {
            try await installer.beginMaintenance(atPaths: [path])
        }

        var waiterCount = 0
        for _ in 0..<100 {
            waiterCount = await installer.maintenanceWaiterCount(atPath: path)
            if waiterCount == 1 { break }
            await Task.yield()
        }
        #expect(waiterCount == 1)

        await first.finishAndWait()
        let second = try await secondTask.value
        #expect(await installer.maintenanceWaiterCount(atPath: path) == 0)
        do {
            try await installer.ensureFile(
                atPath: path,
                downloadURLString: "",
                label: "fixture"
            )
            Issue.record("Expected the second manual operation to own maintenance")
        } catch ModelAutoInstallError.maintenanceInProgress(_) {
            // Expected.
        } catch {
            Issue.record("Unexpected error while second maintenance was active: \(error)")
        }

        await second.finishAndWait()
        do {
            try await installer.ensureFile(
                atPath: path,
                downloadURLString: "",
                label: "fixture"
            )
            Issue.record("Expected the empty URL to be rejected")
        } catch ModelAutoInstallError.emptyURL(_) {
            // Maintenance is over, so normal request validation owns the error.
        } catch {
            Issue.record("Unexpected error after maintenance: \(error)")
        }
    }

    @Test func cancellingAQueuedMaintenanceRequestRemovesItWithoutLateAcquisition() async throws {
        let installer = ModelAutoInstaller()
        let path = "/tmp/typeforme-auto-install-cancelled-waiter-\(UUID().uuidString)/model.gguf"
        let first = try await installer.beginMaintenance(atPaths: [path])
        let queued = Task {
            try await installer.beginMaintenance(atPaths: [path])
        }

        for _ in 0..<100 {
            if await installer.maintenanceWaiterCount(atPath: path) == 1 { break }
            await Task.yield()
        }
        #expect(await installer.maintenanceWaiterCount(atPath: path) == 1)

        queued.cancel()
        await #expect(throws: CancellationError.self) {
            try await queued.value
        }
        #expect(await installer.maintenanceWaiterCount(atPath: path) == 0)

        await first.finishAndWait()
        let next = try await installer.beginMaintenance(atPaths: [path])
        await next.finishAndWait()
    }

    @Test @MainActor func manualOperationControllerRejectsHiddenQueuedWork() async {
        let controller = ModelManualOperationController()
        var starts = 0
        controller.start {
            starts += 1
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        controller.start {
            starts += 100
        }

        for _ in 0..<20 {
            if starts != 0 { break }
            await Task.yield()
        }
        #expect(starts == 1)
        #expect(controller.isPending)

        controller.cancel()
        for _ in 0..<100 {
            if !controller.isPending { break }
            await Task.yield()
        }
        #expect(!controller.isPending)

        controller.start {
            starts += 1
        }
        for _ in 0..<20 {
            if starts != 1 { break }
            await Task.yield()
        }
        #expect(starts == 2)
    }

    @Test @MainActor func operationOwnerIsRetainedUntilRunnerCompletion() {
        var owner: ModelDownloadOwner? = ModelDownloadOwner()
        weak let weakOwner = owner
        let ownership = ModelDownloadOperationOwnership(owner: owner)
        owner = nil

        #expect(ownership.isRetainingOwner)
        #expect(weakOwner != nil)

        ownership.finish()
        #expect(!ownership.isRetainingOwner)
        #expect(weakOwner == nil)
    }
}

private final class ModelDownloadOwner: @unchecked Sendable {}
