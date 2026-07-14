import Foundation
import Testing
@testable import Typeforme

@Suite("Dictation live preview lifecycle")
struct DictationLivePreviewLifecycleTests {
    @Test @MainActor func discardModeDoesNotPreloadAfterResetTimeout() async {
        let session = ControlledResetPreviewSession()
        let actions = PreviewLeaseActionProbe()
        let lease = makePreviewLease(session: session, actions: actions)

        let teardown = Task { @MainActor in
            await DictationLivePreviewLeaseTeardown.run(
                lease: lease,
                mode: .discardOnResetFailure,
                resetTimeout: 30,
                reason: "test_shutdown"
            )
        }
        await session.waitUntilResetStarted()

        session.completeReset(false)
        await teardown.value
        #expect(session.terminationCount == 1)
        #expect(actions.discardCount == 1)
        #expect(actions.preloadCount == 0)
        #expect(actions.returnIdleCount == 0)

        // Copies of a lease share one terminal action gate.
        await lease.preloadReplacement()
        await lease.returnIdle(reason: "late_duplicate")
        #expect(actions.discardCount == 1)
        #expect(actions.preloadCount == 0)
        #expect(actions.returnIdleCount == 0)
    }

    @Test @MainActor func normalResetTimeoutStillRequestsAReplacement() async {
        let session = ImmediateResetPreviewSession(resetResult: false)
        let actions = PreviewLeaseActionProbe()
        let lease = makePreviewLease(session: session, actions: actions)

        await DictationLivePreviewLeaseTeardown.run(
            lease: lease,
            mode: .replenishOnResetFailure,
            resetTimeout: 1,
            reason: "test_normal_stop"
        )

        #expect(session.terminationCount == 1)
        #expect(actions.preloadCount == 1)
        #expect(actions.discardCount == 0)
        #expect(actions.returnIdleCount == 0)
    }

    @Test @MainActor func runtimeTransitionBlocksIdleHotkeysUntilItEnds() async {
        let dictionaryURL = temporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let coordinator = DictationCoordinator(
            dictionary: UserDictionaryStore(url: dictionaryURL)
        )

        coordinator.beginRuntimeTransition()
        #expect(!coordinator.acceptsNewUserOperations)
        await coordinator.toggleDictation()
        #expect(coordinator.state == .idle)

        coordinator.endRuntimeTransition()
        #expect(coordinator.acceptsNewUserOperations)
        coordinator.prepareForApplicationShutdown()
    }

    @Test @MainActor func initialModeApplyLeavesHotkeyGateOpen() {
        let dictionaryURL = temporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let coordinator = DictationCoordinator(
            dictionary: UserDictionaryStore(url: dictionaryURL)
        )
        #expect(coordinator.acceptsNewUserOperations)
        coordinator.prepareForApplicationShutdown()
    }

    @Test @MainActor func shutdownClosesNewOperationGatePermanently() async {
        let dictionaryURL = temporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let coordinator = DictationCoordinator(
            dictionary: UserDictionaryStore(url: dictionaryURL)
        )

        await coordinator.shutdown()
        coordinator.beginRuntimeTransition()
        coordinator.endRuntimeTransition()

        #expect(!coordinator.acceptsNewUserOperations)
        await coordinator.toggleDictation()
        await coordinator.startDictation()
        await coordinator.requestCorrectionModeChange(to: .clean)
        #expect(coordinator.state == .idle)
    }
}

private func temporaryDictionaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("typeforme-dictation-lifecycle-\(UUID().uuidString).json")
}

@MainActor
private final class PreviewLeaseActionProbe {
    var returnIdleCount = 0
    var preloadCount = 0
    var discardCount = 0
}

private final class ControlledResetPreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    let provider = "controlled-reset"

    private let lock = NSLock()
    private var resetContinuation: CheckedContinuation<Bool, Never>?
    private var resetStarted = false
    private var resetStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedTerminationCount = 0

    var terminationCount: Int {
        lock.withLock { recordedTerminationCount }
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {}
    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool { true }

    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiters = lock.withLock {
                resetStarted = true
                resetContinuation = continuation
                let waiters = resetStartedWaiters
                resetStartedWaiters.removeAll()
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilResetStarted() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if resetStarted { return true }
                resetStartedWaiters.append(continuation)
                return false
            }
            if immediate {
                continuation.resume()
            }
        }
    }

    func completeReset(_ result: Bool) {
        let continuation = lock.withLock {
            let continuation = resetContinuation
            resetContinuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func currentTranscript() -> String? { nil }

    func terminate(reason: String) {
        lock.withLock { recordedTerminationCount += 1 }
    }
}

private final class ImmediateResetPreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    let provider = "immediate-reset"
    private let resetResult: Bool
    private let lock = NSLock()
    private var recordedTerminationCount = 0

    init(resetResult: Bool) {
        self.resetResult = resetResult
    }

    var terminationCount: Int {
        lock.withLock { recordedTerminationCount }
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {}
    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool { true }
    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool { resetResult }
    func currentTranscript() -> String? { nil }

    func terminate(reason: String) {
        lock.withLock { recordedTerminationCount += 1 }
    }
}

@MainActor
private func makePreviewLease(
    session: any ASRLivePreviewSession,
    actions: PreviewLeaseActionProbe
) -> ASRLivePreviewLease {
    ASRLivePreviewLease(
        provider: session.provider,
        languageIDs: ["en-US"],
        session: session,
        returnIdleHandler: { _ in actions.returnIdleCount += 1 },
        preloadReplacementHandler: { actions.preloadCount += 1 },
        discardHandler: { reason in
            actions.discardCount += 1
            session.terminate(reason: reason)
        }
    )
}
