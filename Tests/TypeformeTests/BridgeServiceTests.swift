import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeService")
struct BridgeServiceTests {
    @Test @MainActor func staleSettingsRevisionRejectsBeforeMutation() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-settings-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let service = BridgeService(dictionary: UserDictionaryStore(url: dictionaryURL))
        let originalAutoCommit = AppSettings.autoCommit
        let request = BridgeSettingsUpdateRequest(
            expectedSettingsRevision: String(repeating: "0", count: 64),
            autoCommit: !originalAutoCommit
        )

        do {
            _ = try await service.updateSettings(request)
            Issue.record("Expected stale revision to be rejected")
        } catch let error as BridgeServiceError {
            guard case .settingsConflict = error else {
                Issue.record("Expected settingsConflict, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(AppSettings.autoCommit == originalAutoCommit)
    }

    @Test @MainActor func invalidLateSettingsFieldRejectsBeforeMutation() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-settings-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let dictionary = UserDictionaryStore(url: dictionaryURL)
        let service = BridgeService(dictionary: dictionary)
        let originalAutoCommit = AppSettings.autoCommit
        let request = BridgeSettingsUpdateRequest(
            expectedSettingsRevision: BridgeSettingsPayload.currentSettingsRevision(
                userDictionary: dictionary.sortedSnapshot()
            ),
            punctuationPreference: "not-a-preference",
            autoCommit: !originalAutoCommit
        )

        await #expect(throws: BridgeServiceError.self) {
            _ = try await service.updateSettings(request)
        }
        #expect(AppSettings.autoCommit == originalAutoCommit)
    }

    @Test @MainActor func resultReadyMessageSurfacesDegradedCorrection() {
        #expect(BridgeService.resultReadyMessage(correctionStatus: "ok", okMessage: "Refine complete") == "Refine complete")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "refine_timeout", okMessage: "Refine complete") == "Without refine: refine timeout")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "refine_error", okMessage: "Refine complete") == "Without refine: refine error")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "skipped_fast_mode", okMessage: "Refine complete") == "Fast transcript ready")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "empty", okMessage: "Refine complete") == "No reliable transcript")
    }

    @Test @MainActor func refineFailureStatusDistinguishesTimeoutFromOtherErrors() {
        #expect(BridgeService.refineFailureStatus(for: CorrectorError.timeout) == "refine_timeout")
        #expect(BridgeService.refineFailureStatus(for: CorrectorError.requestFailed("500")) == "refine_error")
        #expect(BridgeService.refineFailureStatus(for: CorrectorError.empty) == "refine_error")
    }

    @Test @MainActor func correctionCancellationIsRethrownInsteadOfProducingFallbackResult() async throws {
        await #expect(throws: CancellationError.self) {
            let _: String = try await BridgeService.withCorrectionFailureFallback {
                throw CancellationError()
            } fallback: { _ in
                "fallback"
            }
        }

        let fallback = try await BridgeService.withCorrectionFailureFallback {
            throw CorrectorError.requestFailed("expected")
        } fallback: { _ in
            "fallback"
        }
        #expect(fallback == "fallback")

        let cancelledTask = Task { @MainActor in
            try await BridgeService.withCorrectionFailureFallback {
                throw CorrectorError.requestFailed("wrapped cancellation")
            } fallback: { _ in
                "fallback"
            }
        }
        cancelledTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }
    }

    @Test @MainActor func settingsLanguageIDsRequireExactSupportedCanonicalIDs() throws {
        let supported = ASRLanguageSelection.qwenASRSupportedLanguages

        #expect(try BridgeService.resolveSettingsLanguageIDs(["en-US", "zh-CN", "en-US"], supportedOptions: supported) == ["zh-CN", "en-US"])
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs([], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs([""], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs([" en-US "], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs(["en"], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs(["en-us"], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs(["af"], supportedOptions: supported)
        }
    }

    @Test @MainActor func settingsRejectDisablingEveryRecognitionSource() {
        #expect(throws: BridgeServiceError.self) {
            try BridgeService.validateEnabledRecognitionSources([], languageIDs: ["en-US"])
        }
        #expect(throws: Never.self) {
            try BridgeService.validateEnabledRecognitionSources([.qwen], languageIDs: ["en-US"])
        }
    }

    @Test @MainActor func externalCorrectionSettingsSaveDoesNotRequireReachableListedModel() throws {
        try BridgeService.validateExternalCorrectionSettingsIfNeeded(
            .externalOpenAICompatible,
            externalLLMBaseURL: "http://127.0.0.1:1234",
            externalLLMModel: "model-that-is-not-currently-listed"
        )
    }

    @Test @MainActor func externalCorrectionSettingsStillRequireModelAndHTTPURL() {
        #expect(throws: BridgeServiceError.self) {
            try BridgeService.validateExternalCorrectionSettingsIfNeeded(
                .externalOpenAICompatible,
                externalLLMBaseURL: "http://127.0.0.1:1234",
                externalLLMModel: " "
            )
        }
        #expect(throws: BridgeServiceError.self) {
            try BridgeService.validateExternalCorrectionSettingsIfNeeded(
                .externalAnthropicCompatible,
                externalLLMBaseURL: "file:///tmp/model",
                externalLLMModel: "claude-sonnet-4-5"
            )
        }
    }

    @Test @MainActor func localCorrectionSettingsSaveDoesNotRequireInstalledModel() throws {
        try BridgeService.validateExternalCorrectionSettingsIfNeeded(
            .qwen35_9B,
            externalLLMBaseURL: "",
            externalLLMModel: ""
        )
    }

    @Test @MainActor func livePreviewCancelIsIdempotentForMissingSession() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-cancel-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let service = BridgeService(dictionary: UserDictionaryStore(url: dictionaryURL))

        let first = await service.cancelLivePreview(sessionID: "missing-preview")
        let second = await service.cancelLivePreview(sessionID: "missing-preview")

        #expect(first.sessionID == "missing-preview")
        #expect(second.sessionID == "missing-preview")
    }

    @Test @MainActor func livePreviewCancelJoinsFinishBeforeResetAndReturnsLeaseOnce() async {
        let process = BlockingFinishLivePreviewSession()
        let lease = ASRLivePreviewLease(
            provider: process.provider,
            languageIDs: ["en-US"],
            session: process,
            returnIdleHandler: { _ in process.recordLeaseReturn() },
            preloadReplacementHandler: { process.recordPreload() }
        )
        let session = BridgeLivePreviewSession(
            id: "preview",
            lease: lease,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let finishTask = session.beginFinish(timeout: 30)
        await process.waitUntilFinishStarted()

        let firstTeardown = session.cancelAndTeardown()
        let secondTeardown = session.cancelAndTeardown()
        await firstTeardown.value
        await secondTeardown.value
        let result = await finishTask.value

        #expect(result.wasCancelled)
        #expect(process.events == [
            "finish-started",
            "finish-cancelled",
            "finish-returned",
            "reset-started",
            "lease-returned",
        ])
    }

    @Test func livePreviewInputGateRejectsEveryAppendAfterDeactivation() async {
        let process = BlockingAppendLivePreviewSession()
        let gate = BridgeLivePreviewInputGate(
            process: process,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let appendTask = Task.detached {
            gate.append(Data([1, 2, 3]), at: Date(timeIntervalSince1970: 2))
        }
        await process.waitUntilAppendStarted()

        let deactivateTask = Task.detached {
            gate.deactivate()
        }
        await Task.yield()
        process.allowAppendToReturn()

        #expect(await appendTask.value)
        await deactivateTask.value
        #expect(!gate.append(Data([4]), at: Date(timeIntervalSince1970: 3)))
        #expect(process.appendCount == 1)
        #expect(gate.lastActivityAt == Date(timeIntervalSince1970: 2))
    }

    @Test @MainActor func livePreviewStartReservesCapacityBeforeLeaseAwait() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-preview-capacity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let provider = ControlledBridgeLivePreviewLeaseProvider()
        let service = BridgeService(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            livePreviewLeaseProvider: provider,
            livePreviewRecognitionSourcesProvider: { [.qwen] }
        )
        let request = BridgeLivePreviewStartRequest(
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue
        )
        let starts = (0..<10).map { _ in
            Task { @MainActor in
                try? await service.startLivePreview(request).sessionID
            }
        }

        await provider.waitUntilPendingCount(8)
        #expect(provider.requestCount == 8)
        #expect(provider.maximumPendingCount == 8)
        provider.releaseAll()

        var sessionIDs: [String] = []
        for start in starts {
            if let sessionID = await start.value {
                sessionIDs.append(sessionID)
            }
        }
        #expect(sessionIDs.count == 8)
        for sessionID in sessionIDs {
            _ = await service.cancelLivePreview(sessionID: sessionID)
        }
        #expect(provider.returnCount == 8)
    }

    @Test @MainActor func cancelledLivePreviewStartReturnsAcquiredLeaseAndReservation() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-preview-cancel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let provider = ControlledBridgeLivePreviewLeaseProvider()
        let service = BridgeService(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            livePreviewLeaseProvider: provider,
            livePreviewRecognitionSourcesProvider: { [.qwen] }
        )
        let request = BridgeLivePreviewStartRequest(
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue
        )
        let start = Task { @MainActor in
            do {
                _ = try await service.startLivePreview(request)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await provider.waitUntilPendingCount(1)
        start.cancel()
        provider.releaseAll()

        #expect(await start.value)
        #expect(provider.returnCount == 1)

        let replacement = Task { @MainActor in
            try? await service.startLivePreview(request).sessionID
        }
        await provider.waitUntilPendingCount(1)
        provider.releaseAll()
        let replacementSessionID = await replacement.value
        #expect(replacementSessionID != nil)
        if let replacementSessionID {
            _ = await service.cancelLivePreview(sessionID: replacementSessionID)
        }
    }

    @Test @MainActor func bridgeStopInvalidatesPendingLivePreviewBeforeLeaseCanRegister() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-preview-stop-pending-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let provider = ControlledBridgeLivePreviewLeaseProvider()
        let service = BridgeService(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            livePreviewLeaseProvider: provider,
            livePreviewRecognitionSourcesProvider: { [.qwen] }
        )
        let request = BridgeLivePreviewStartRequest(
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue
        )
        let start = Task { @MainActor in
            do {
                _ = try await service.startLivePreview(request)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await provider.waitUntilPendingCount(1)
        let shutdown = service.beginCancelAllLivePreviews()
        provider.releaseAll()

        await shutdown.value
        #expect(await start.value)
        #expect(provider.returnCount == 1)

        let replacementRunID = UUID()
        service.beginAcceptingLivePreviews(listenerRunID: replacementRunID)
        let replacement = Task { @MainActor in
            try? await service.startLivePreview(
                request,
                listenerRunID: replacementRunID
            ).sessionID
        }
        await provider.waitUntilPendingCount(1)
        provider.releaseAll()
        let replacementID = await replacement.value
        #expect(replacementID != nil)
        if let replacementID {
            _ = await service.cancelLivePreview(sessionID: replacementID)
        }
        #expect(provider.returnCount == 2)
    }

    @Test @MainActor func listenerExitCleanupRejectsOldTokenAfterReplacementReopens() async throws {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-preview-listener-token-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let provider = ControlledBridgeLivePreviewLeaseProvider()
        let service = BridgeService(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            livePreviewLeaseProvider: provider,
            livePreviewRecognitionSourcesProvider: { [.qwen] }
        )
        let request = BridgeLivePreviewStartRequest(
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue
        )
        let oldRunID = UUID()
        let replacementRunID = UUID()

        service.beginAcceptingLivePreviews(listenerRunID: oldRunID)
        let activeStart = Task { @MainActor in
            try await service.startLivePreview(
                request,
                listenerRunID: oldRunID
            ).sessionID
        }
        await provider.waitUntilPendingCount(1)
        provider.releaseAll()
        let activeID = try await activeStart.value

        let exitCleanup = service.beginCancelAllLivePreviewsIfOwned(
            listenerRunID: oldRunID
        )
        #expect(exitCleanup != nil)
        await exitCleanup?.value
        #expect(provider.returnCount == 1)
        #expect(throws: BridgeServiceError.self) {
            _ = try service.livePreviewInputGate(sessionID: activeID)
        }
        service.beginAcceptingLivePreviews(listenerRunID: replacementRunID)

        await #expect(throws: BridgeServiceError.self) {
            _ = try await service.startLivePreview(request, listenerRunID: oldRunID)
        }
        #expect(provider.requestCount == 1)

        let replacement = Task { @MainActor in
            try await service.startLivePreview(
                request,
                listenerRunID: replacementRunID
            ).sessionID
        }
        await provider.waitUntilPendingCount(1)
        provider.releaseAll()
        let replacementID = try await replacement.value
        _ = await service.cancelLivePreview(sessionID: replacementID)
        #expect(provider.returnCount == 2)
    }

    @Test @MainActor func bridgeStopClearsActiveAndCompletedLivePreviewsBeforeReopen() async throws {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-preview-stop-active-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let provider = ControlledBridgeLivePreviewLeaseProvider()
        let service = BridgeService(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            livePreviewLeaseProvider: provider,
            livePreviewRecognitionSourcesProvider: { [.qwen] }
        )
        let request = BridgeLivePreviewStartRequest(
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue
        )

        let completedStart = Task { @MainActor in
            try await service.startLivePreview(request).sessionID
        }
        await provider.waitUntilPendingCount(1)
        provider.releaseAll()
        let completedID = try await completedStart.value
        _ = try await service.finishLivePreview(sessionID: completedID)
        _ = try await service.finishLivePreview(sessionID: completedID)

        let activeStart = Task { @MainActor in
            try await service.startLivePreview(request).sessionID
        }
        await provider.waitUntilPendingCount(1)
        provider.releaseAll()
        let activeID = try await activeStart.value

        let shutdown = service.beginCancelAllLivePreviews()
        #expect(throws: BridgeServiceError.self) {
            _ = try service.livePreviewInputGate(sessionID: activeID)
        }
        await shutdown.value
        #expect(provider.returnCount == 2)
        await #expect(throws: BridgeServiceError.self) {
            _ = try await service.finishLivePreview(sessionID: activeID)
        }
        await #expect(throws: BridgeServiceError.self) {
            _ = try await service.finishLivePreview(sessionID: completedID)
        }
    }

    @Test @MainActor func bridgeStopJoinsTeardownAfterSessionLeavesActiveMap() async throws {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-preview-stop-teardown-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let process = BlockingResetLivePreviewSession()
        let provider = FixedBridgeLivePreviewLeaseProvider(process: process)
        let service = BridgeService(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            livePreviewLeaseProvider: provider,
            livePreviewRecognitionSourcesProvider: { [.qwen] }
        )
        let request = BridgeLivePreviewStartRequest(
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue
        )
        let sessionID = try await service.startLivePreview(request).sessionID
        let cancel = Task { @MainActor in
            await service.cancelLivePreview(sessionID: sessionID)
        }
        await process.waitUntilResetStarted()

        // cancelLivePreview has already removed the externally visible
        // session, but its lease-return teardown remains Bridge-owned.
        #expect(throws: BridgeServiceError.self) {
            _ = try service.livePreviewInputGate(sessionID: sessionID)
        }
        let stopBarrier = service.beginCancelAllLivePreviews()
        let probe = BridgeStopBarrierProbe()
        let stopWaiter = Task { @MainActor in
            probe.started = true
            await stopBarrier.value
            probe.finished = true
        }
        while !probe.started {
            await Task.yield()
        }
        #expect(!probe.finished)

        process.allowResetToFinish()
        await stopWaiter.value
        _ = await cancel.value
        #expect(probe.finished)
        #expect(provider.returnCount == 1)
    }

    @Test func bridgeSettingsPreserveCanonicalAppleLanguagesUntilSupportResolves() {
        #expect(BridgeSettingsPayload.resolvedSettingsLanguageIDs(
            ["ja"],
            sources: [.appleSpeech],
            appleSpeechSupportResolved: false
        ) == ["ja"])
        #expect(BridgeSettingsPayload.resolvedSettingsLanguageIDs(
            ["af"],
            sources: [.qwen, .appleSpeech],
            appleSpeechSupportResolved: false
        ) == ["af"])
    }

    @Test func remoteClientAcceptsDegradedRefineResponsesWithText() throws {
        try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "refine_timeout", error: "Correction timed out")
        try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "refine_error", error: "Backend error")
        try RemoteBridgeClient.validateTextResponse(text: "", status: "empty", error: nil)
        #expect(throws: RemoteBridgeClientError.self) {
            try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "error", error: "Backend error")
        }
        #expect(throws: RemoteBridgeClientError.self) {
            try RemoteBridgeClient.validateTextResponse(text: "", status: "refine_error", error: "Backend error")
        }
    }
}

private final class BlockingAppendLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    let provider = "blocking-append"

    private let lock = NSLock()
    private var didStartAppend = false
    private var appendMayReturn = false
    private var appendStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedAppendCount = 0

    var appendCount: Int {
        lock.withLock { recordedAppendCount }
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {
        let waiters = lock.withLock {
            didStartAppend = true
            let waiters = appendStartedWaiters
            appendStartedWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
        while !lock.withLock({ appendMayReturn }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        lock.withLock { recordedAppendCount += 1 }
    }

    func waitUntilAppendStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if didStartAppend { return true }
                appendStartedWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func allowAppendToReturn() {
        lock.withLock { appendMayReturn = true }
    }

    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool { true }
    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool { true }
    func currentTranscript() -> String? { nil }
    func terminate(reason: String) {}
}

@MainActor
private final class ControlledBridgeLivePreviewLeaseProvider: BridgeLivePreviewLeaseProviding {
    private struct Pending {
        let diagnosticID: String
        let continuation: CheckedContinuation<ASRLivePreviewLease, any Error>
    }

    private var pending: [Pending] = []
    private(set) var requestCount = 0
    private(set) var maximumPendingCount = 0
    private(set) var returnCount = 0

    func take(
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> ASRLivePreviewLease {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(diagnosticID: diagnosticID, continuation: continuation))
            maximumPendingCount = max(maximumPendingCount, pending.count)
        }
    }

    func releaseAll() {
        let pending = self.pending
        self.pending.removeAll()
        for item in pending {
            let process = ImmediateBridgeLivePreviewSession(provider: "test-\(item.diagnosticID)")
            item.continuation.resume(returning: ASRLivePreviewLease(
                provider: process.provider,
                languageIDs: ["en-US"],
                session: process,
                returnIdleHandler: { [weak self] _ in
                    self?.returnCount += 1
                },
                preloadReplacementHandler: {}
            ))
        }
    }

    func waitUntilPendingCount(_ expected: Int) async {
        while pending.count < expected {
            await Task.yield()
        }
    }
}

private final class ImmediateBridgeLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    let provider: String

    init(provider: String) {
        self.provider = provider
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {}
    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool { true }
    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool { true }
    func currentTranscript() -> String? { nil }
    func terminate(reason: String) {}
}

@MainActor
private final class FixedBridgeLivePreviewLeaseProvider: BridgeLivePreviewLeaseProviding {
    private let process: any ASRLivePreviewSession
    private(set) var returnCount = 0

    init(process: any ASRLivePreviewSession) {
        self.process = process
    }

    func take(
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> ASRLivePreviewLease {
        ASRLivePreviewLease(
            provider: process.provider,
            languageIDs: ["en-US"],
            session: process,
            returnIdleHandler: { [weak self] _ in
                self?.returnCount += 1
            },
            preloadReplacementHandler: {}
        )
    }
}

@MainActor
private final class BridgeStopBarrierProbe {
    var started = false
    var finished = false
}

private final class BlockingResetLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    let provider = "blocking-reset"

    private let lock = NSLock()
    private var resetContinuation: CheckedContinuation<Bool, Never>?
    private var resetStarted = false
    private var resetStartedWaiters: [CheckedContinuation<Void, Never>] = []

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

    func currentTranscript() -> String? { nil }
    func terminate(reason: String) {}

    func waitUntilResetStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if resetStarted { return true }
                resetStartedWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func allowResetToFinish() {
        let continuation = lock.withLock {
            let continuation = resetContinuation
            resetContinuation = nil
            return continuation
        }
        continuation?.resume(returning: true)
    }
}

private final class BlockingFinishLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    let provider = "test"

    private let lock = NSLock()
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var finishWasCancelled = false
    private var recordedEvents: [String] = []
    private var finishStartedWaiters: [CheckedContinuation<Void, Never>] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {}

    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool {
        recordFinishStarted()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if finishWasCancelled {
                        return true
                    }
                    finishContinuation = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume(returning: false)
                }
            }
        } onCancel: {
            self.cancelFinish()
        }
        record("finish-returned")
        return result
    }

    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool {
        record("reset-started")
        return true
    }

    func currentTranscript() -> String? { nil }

    func terminate(reason: String) {
        record("terminated")
    }

    func recordLeaseReturn() {
        record("lease-returned")
    }

    func recordPreload() {
        record("preloaded")
    }

    func waitUntilFinishStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if recordedEvents.contains("finish-started") {
                    return true
                }
                finishStartedWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func recordFinishStarted() {
        let waiters = lock.withLock {
            recordedEvents.append("finish-started")
            let waiters = finishStartedWaiters
            finishStartedWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelFinish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard !finishWasCancelled else { return nil }
            finishWasCancelled = true
            recordedEvents.append("finish-cancelled")
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume(returning: false)
    }

    private func record(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
