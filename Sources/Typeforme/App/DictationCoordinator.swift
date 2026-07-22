import AVFoundation
import Foundation
import Combine
import CoreGraphics
import Speech

enum DictationLivePreviewLeaseTeardownMode: Sendable {
    case replenishOnResetFailure
    case discardOnResetFailure
}

@MainActor
enum DictationLivePreviewLeaseTeardown {
    static func run(
        lease: ASRLivePreviewLease,
        mode: DictationLivePreviewLeaseTeardownMode,
        resetTimeout: TimeInterval,
        reason: String
    ) async {
        // Qwen previews are request based rather than a reusable streaming
        // subprocess. Returning the lease terminates its in-flight request.
        if lease.session is QwenLlamaLivePreviewSession {
            await lease.returnIdle(reason: reason)
            return
        }

        let reset = await lease.session.cancelInputAndWaitForReset(timeout: resetTimeout)
        if reset {
            await lease.returnIdle(reason: reason)
            return
        }

        switch mode {
        case .replenishOnResetFailure:
            lease.session.terminate(reason: "\(reason)_timeout")
            await lease.preloadReplacement()
        case .discardOnResetFailure:
            await lease.discard(reason: "\(reason)_timeout")
        }
    }
}

/// Owns the full dictation state machine and orchestrates services.
/// Main flow: `idle → recording → transcribing → correcting →
/// (inserting | preview) → success → idle`; any state can fall to
/// `error → idle`.
@MainActor
final class DictationCoordinator: ObservableObject {
    private struct StartOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Input ownership captured on the second modifier press. The 90 ms hold
    /// confirmation is intentionally separate: another app may handle the
    /// same double-modifier gesture immediately and replace its focused view
    /// before Typeforme knows the user meant to hold.
    private struct PreparedHoldStart {
        let frontmostSnapshot: FrontmostAppSnapshot?
        let insertionTarget: TextInsertionTargetSnapshot?
        let accessibilityWasTrusted: Bool
    }

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var presentationError: DictationPresentationError?
    @Published private(set) var lastWarning: String?
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastCorrected: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var frontmostSnapshot: FrontmostAppSnapshot?
    @Published private(set) var previewCorrectionMode: CorrectionMode?
    @Published private(set) var voicePreviewHUDExpanded = false
    /// Live-preview transcript fed in parallel with recording. Held in place
    /// from the first partial until the Mac ASR + correction final replaces
    /// it, then cleared. Empty string = no preview.
    @Published private(set) var livePartialTranscript: String = ""
    @Published private(set) var transcriptionProgress: ASRTranscriptionProgress?

    var lastError: String? { presentationError?.message }

    private let recorder = AudioRecorder()
    private var activeCorrectionConfiguration: CorrectionSessionConfiguration?
    private let committer = PasteboardTextCommitter()
    private let textEditService: TextEditService
    private let dictionary: UserDictionaryStore

    private var autoStopTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var activeStartOperation: StartOperation?
    private var activeProcessingTask: Task<Void, Never>?
    private var activeProcessingTaskID: UUID?
    private var activeSessionID: UUID?
    private var activeCancelToken: CommitCancellationToken?
    private var activeBridgeDictateJobID: String?
    private var activeTextEditTarget: TextEditTargetSnapshot?
    private var activeInsertionTarget: TextInsertionTargetSnapshot?
    private var preparedHoldStart: PreparedHoldStart?
    private var activeTextEditIntent: TextEditIntent?
    private var activeDictationContextBefore = ""
    private var activeDictationContextAfter = ""
    private var stopAfterStart = false
    /// Published so the HUD action bar can render the elapsed / remaining
    /// recording timer from the same clock the auto-stop uses.
    @Published private(set) var recordingStartedAt: Date?
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveSpeechTask: SFSpeechRecognitionTask?
    private var asrLivePreviewLease: ASRLivePreviewLease?
    private var remoteBridgeLivePreviewStreamer: RemoteBridgeLivePreviewStreamer?
    private var livePreviewOwnerSessionID: UUID?
    private let livePreviewCleanup = SerialMainActorTaskQueue()
    private var userCancellationDepth = 0
    private var runtimeTransitionIsActive = false
    private var applicationIsTerminating = false
    private var activeFastASRRoute: FastASRRoute?
    private var activeASRSession: DictationASRSession?

    private static let errorResetDelay: TimeInterval = 8.0
    private static let successResetDelay: TimeInterval = 1.8
    private static let degradedSuccessResetDelay: TimeInterval = 1.8
    private static let minimumToggleStopInterval: TimeInterval = 0.6
    private static let asrLivePreviewResetTimeout: TimeInterval = 2
    private static let previewWithoutRefineBaseMessage = "Preview without refine"
    private static let insertedWithoutRefineBaseMessage = "Inserted without refine"

    init(dictionary: UserDictionaryStore) {
        self.dictionary = dictionary
        self.textEditService = TextEditService(dictionary: dictionary)
        recorder.onLevel = { [weak self] level in self?.audioLevel = level }
        recorder.onConfigurationChanged = { [weak self] in
            Task { @MainActor in
                await self?.handleAudioConfigurationChanged()
            }
        }
        recorder.onCaptureFailure = { [weak self] error in
            guard let self, self.state == .recording || self.isStartingDictation else { return }
            self.reportError(
                error.localizedDescription,
                recovery: error == .permissionDenied ? .openSettings : .dismiss
            )
            self.scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    // MARK: - Public API used by AppDelegate / hotkey

    var acceptsNewUserOperations: Bool {
        !applicationIsTerminating
            && !runtimeTransitionIsActive
            && userCancellationDepth == 0
    }

    private var isStartingDictation: Bool {
        activeStartOperation != nil && state == .idle
    }

    var requiresRuntimeDiscard: Bool {
        applicationIsTerminating || runtimeTransitionIsActive
    }

    func beginRuntimeTransition() {
        runtimeTransitionIsActive = true
    }

    func endRuntimeTransition() {
        runtimeTransitionIsActive = false
    }

    /// Closes the user-operation gate synchronously, before application
    /// termination schedules any asynchronous cleanup.
    func prepareForApplicationShutdown() {
        applicationIsTerminating = true
    }

    func toggleDictation() async {
        guard acceptsNewUserOperations else {
            Log.coordinator.debug("toggle ignored while runtime is quiescing")
            return
        }
        if activeStartOperation != nil {
            Log.coordinator.debug("toggle ignored while dictation start is in progress")
            return
        }

        switch state {
        case .idle:
            await startDictation()
        case .recording:
            guard !shouldIgnoreEarlyToggleStop() else { return }
            await stopDictation()
        case .success, .error:
            // Terminal visible states stay on screen briefly for feedback. A
            // toggle press during that window should start the next dictation,
            // not merely clear the HUD and force a second press.
            reset()
            await startDictation()
        default:
            await cancelDictation()
        }
    }

    func prepareHoldDictationStart() {
        guard acceptsNewUserOperations, activeStartOperation == nil else {
            preparedHoldStart = nil
            return
        }
        switch state {
        case .idle, .success, .error:
            break
        default:
            preparedHoldStart = nil
            return
        }

        let snapshot = FrontmostAppCapture.snapshot()
        let accessibilityWasTrusted = AppPermissions.accessibilityTrusted
        preparedHoldStart = PreparedHoldStart(
            frontmostSnapshot: snapshot,
            insertionTarget: TextEditTargetCapture.insertionTarget(in: snapshot),
            accessibilityWasTrusted: accessibilityWasTrusted
        )
    }

    func cancelPreparedHoldDictationStart() {
        preparedHoldStart = nil
    }

    func startPreparedHoldDictation() async {
        guard acceptsNewUserOperations else { return }
        let prepared = preparedHoldStart
        preparedHoldStart = nil

        switch state {
        case .idle:
            break
        case .success, .error:
            reset()
        default:
            return
        }

        await startDictation(intent: nil, preparedHoldStart: prepared)
    }

    func startDictation(intent: TextEditIntent? = nil) async {
        await startDictation(intent: intent, preparedHoldStart: nil)
    }

    private func startDictation(
        intent: TextEditIntent?,
        preparedHoldStart: PreparedHoldStart?
    ) async {
        guard acceptsNewUserOperations,
              state == .idle,
              activeStartOperation == nil
        else { return }

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartDictation(
                intent: intent,
                preparedHoldStart: preparedHoldStart
            )
        }
        activeStartOperation = StartOperation(id: operationID, task: task)
        await task.value
        if activeStartOperation?.id == operationID {
            activeStartOperation = nil
        }
    }

    private func performStartDictation(
        intent: TextEditIntent?,
        preparedHoldStart: PreparedHoldStart?
    ) async {
        guard acceptsNewUserOperations, state == .idle else { return }
        if !AppPermissions.accessibilityTrusted {
            AppPermissions.requestAccessibility()
        }

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeProcessingTaskID = nil
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        activeBridgeDictateJobID = Self.bridgeJobID(prefix: "mac_dictate", sessionID: sessionID)
        stopAfterStart = false
        resetTask?.cancel(); resetTask = nil
        activeTextEditIntent = intent
        activeFastASRRoute = nil
        activeCorrectionConfiguration = nil
        let targetCaptured: Bool
        if let preparedHoldStart, intent == nil {
            targetCaptured = applyPreparedHoldStart(preparedHoldStart)
        } else {
            captureFrontmost()
            targetCaptured = captureDictationContextAndTarget(intent: intent)
        }
        guard targetCaptured else {
            let message = intent == .command
                ? "Wand needs selected or existing text."
                : "Focus a text field first"
            reportError(message)
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        clearPreviewState()
        voicePreviewHUDExpanded = true

        do {
            let sessionSettings = try DictationSessionSettings.capture()
            activeASRSession = try DictationASRSession(settings: sessionSettings) { settings in
                try self.asrService(for: settings)
            }
            if let fastASRSource = sessionSettings.fastASRSource {
                activeFastASRRoute = FastASRRoute(
                    source: fastASRSource,
                    languageIDs: sessionSettings.transcriptionLanguageIDs
                )
            }
            if sessionSettings.processingMode == .server,
               sessionSettings.correctionMode.usesRefine || intent != nil {
                let correctorConfiguration = CorrectorConfigurationSnapshot.capture()
                activeCorrectionConfiguration = CorrectionSessionConfiguration(
                    corrector: CorrectorFactory.shared.make(configuration: correctorConfiguration),
                    numberOutputPreference: sessionSettings.numberOutputPreference,
                    punctuationPreference: sessionSettings.punctuationPreference,
                    timeoutMs: sessionSettings.correctionTimeoutMs,
                    userDictionary: dictionary.sortedSnapshot()
                )
            }
            let livePreviewPCMHandler = await makeLivePartialPreviewPCMHandlerIfAvailable(
                sessionID: sessionID,
                settings: sessionSettings
            )
            guard activeSessionID == sessionID else {
                let previewTeardown = beginCancellingLivePartialPreview(
                    clearText: true,
                    reason: "mac_preview_stale_start"
                )
                await previewTeardown.value
                return
            }
            _ = try await recorder.start(pcmHandler: livePreviewPCMHandler)
            guard activeSessionID == sessionID else {
                await recorder.discard()
                teardownLivePartialPreview(clearText: true, ifOwnedBy: sessionID)
                return
            }
            guard await isActive(sessionID: sessionID, token: cancelToken) else {
                await recorder.discard()
                teardownLivePartialPreview(clearText: true, ifOwnedBy: sessionID)
                return
            }
            transition(to: .recording)
            scheduleAutoStop(after: sessionSettings.maxRecordingDuration)
            if stopAfterStart {
                stopAfterStart = false
                await stopDictation()
            }
        } catch {
            guard activeSessionID == sessionID else { return }
            teardownLivePartialPreview(clearText: true, ifOwnedBy: sessionID)
            stopAfterStart = false
            clearActiveSession()
            reportError(error.localizedDescription, recovery: .openSettings)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func captureDictationContextAndTarget(intent: TextEditIntent?) -> Bool {
        clearDictationContext()
        if let intent {
            activeTextEditIntent = intent
            Log.textCommit.notice(
                "edit target capture requested pid=\(self.frontmostSnapshot?.pid ?? -1) bundle=\(self.frontmostSnapshot?.bundleID ?? "unknown", privacy: .public)"
            )
            activeTextEditTarget = TextEditTargetCapture.snapshot(
                in: frontmostSnapshot,
                allowFocusedValue: intent == .command
            )
            return activeTextEditTarget != nil
        }

        clearTextEditRequest()
        activeInsertionTarget = TextEditTargetCapture.insertionTarget(in: frontmostSnapshot)
        activeDictationContextBefore = activeInsertionTarget?.contextBefore ?? ""
        activeDictationContextAfter = activeInsertionTarget?.contextAfter ?? ""
        // Without AX permission we still allow recording so the existing
        // Clipboard fallback remains available. Once AX is trusted, require a
        // concrete non-secure focused control so a later insertion can prove it
        // still owns the original target.
        return activeInsertionTarget != nil || !AppPermissions.accessibilityTrusted
    }

    private func applyPreparedHoldStart(_ prepared: PreparedHoldStart) -> Bool {
        clearTextEditRequest()
        clearDictationContext()
        frontmostSnapshot = prepared.frontmostSnapshot
        activeInsertionTarget = prepared.insertionTarget
        activeDictationContextBefore = prepared.insertionTarget?.contextBefore ?? ""
        activeDictationContextAfter = prepared.insertionTarget?.contextAfter ?? ""
        return prepared.insertionTarget != nil || !prepared.accessibilityWasTrusted
    }

    func toggleCommandTextEdit() async {
        guard acceptsNewUserOperations else {
            Log.coordinator.debug("command edit toggle ignored while runtime is quiescing")
            return
        }
        if activeStartOperation != nil {
            Log.coordinator.debug("command edit toggle ignored while dictation start is in progress")
            return
        }

        switch state {
        case .idle:
            await startDictation(intent: .command)
        case .recording:
            guard !shouldIgnoreEarlyToggleStop() else { return }
            await stopDictation()
        case .success, .error:
            reset()
            await startDictation(intent: .command)
        default:
            await cancelDictation()
        }
    }

    func togglePreviewCommand() async {
        guard acceptsNewUserOperations else {
            Log.coordinator.debug("preview command toggle ignored while runtime is quiescing")
            return
        }
        if activeStartOperation != nil {
            Log.coordinator.debug("preview command toggle ignored while dictation start is in progress")
            return
        }

        switch state {
        case .idle:
            await startDictation(intent: .command)
        case .success, .error:
            reset()
            await startDictation(intent: .command)
        case .recording:
            guard !shouldIgnoreEarlyToggleStop() else { return }
            await stopDictation()
        case .transcribing, .correcting, .inserting:
            await cancelDictation()
        }
    }

    func expandVoicePreviewHUD() {
        guard state == .idle else { return }
        voicePreviewHUDExpanded = true
    }

    func collapseVoicePreviewHUD() {
        voicePreviewHUDExpanded = false
    }

    func dismissVoicePreviewHUDFromKeyboard() {
        switch state {
        case .idle:
            guard voicePreviewHUDExpanded else { return }
            collapseVoicePreviewHUD()
        case .success:
            resetTask?.cancel()
            resetTask = nil
            reset(keepVoicePreviewExpanded: false)
        default:
            return
        }
    }

    var canCollapseVoicePreviewHUD: Bool {
        state == .idle && voicePreviewHUDExpanded
    }

    var isRecordingCommandTextEdit: Bool {
        state == .recording && activeTextEditIntent == .command
    }

    var isProcessingCommandTextEdit: Bool {
        activeTextEditIntent == .command && (state == .transcribing || state == .correcting)
    }

    private var canRefineFocusedInputFromHUD: Bool {
        state == .idle && voicePreviewHUDExpanded
    }

    private func collapseVoicePreviewHUDAfterAction() {
        voicePreviewHUDExpanded = false
    }

    func stopDictation() async {
        if isStartingDictation {
            stopAfterStart = true
            return
        }
        guard state == .recording else { return }
        guard let sessionID = activeSessionID, let cancelToken = activeCancelToken else {
            await recorder.discard()
            reportError("Internal state error: missing dictation session")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processStoppedDictation(sessionID: sessionID, cancelToken: cancelToken)
        }
        activeProcessingTask?.cancel()
        activeProcessingTask = task
        activeProcessingTaskID = taskID
        await task.value
        if activeProcessingTaskID == taskID {
            activeProcessingTask = nil
            activeProcessingTaskID = nil
        }
    }

    private func processStoppedDictation(
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        autoStopTask?.cancel(); autoStopTask = nil
        guard activeSessionID == sessionID, state == .recording else { return }
        // Keep the recorder open briefly after the stop trigger so the final
        // syllable is not cut off. SFSpeech is ended after the tail so the
        // preview can include the same audio that goes to the Mac ASR.
        transition(to: .transcribing)
        try? await Task.sleep(nanoseconds: BridgeAudioRecordingContract.stopTailBufferNanoseconds)
        guard await isActive(sessionID: sessionID, token: cancelToken) else {
            await recorder.discard()
            return
        }
        let url: URL?
        do {
            url = try await recorder.stop()
        } catch {
            endLivePartialPreviewAudio(sessionID: sessionID)
            audioLevel = 0
            guard activeSessionID == sessionID else { return }
            reportError(error.localizedDescription, recovery: .openSettings)
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        endLivePartialPreviewAudio(sessionID: sessionID)
        audioLevel = 0

        guard await isActive(sessionID: sessionID, token: cancelToken) else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        guard let url else {
            reportError("No audio captured")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }

        let snapshot = frontmostSnapshot
        guard let asrSession = activeASRSession else {
            try? FileManager.default.removeItem(at: url)
            reportError("Internal state error: missing dictation ASR session")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        let sessionSettings = asrSession.settings
        let selectedCorrectionMode = sessionSettings.correctionMode
        let selectedTranscriptionLanguageIDs = sessionSettings.transcriptionLanguageIDs
        let debugLog = DebugLogStore.begin(
            source: sessionSettings.processingMode == .client ? "mac-client" : "mac",
            audioURL: url,
            selectedCorrectionMode: selectedCorrectionMode,
            languageIDs: selectedTranscriptionLanguageIDs,
            appName: snapshot?.localizedName,
            bundleID: snapshot?.bundleID,
            appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
        )
        let audioDurationMs = ASRAudioSupport.audioDurationMilliseconds(for: url)

        if sessionSettings.usesRemoteBridge {
            await processWithRemoteBridge(
                audioURL: url,
                debugLog: debugLog,
                sessionID: sessionID,
                cancelToken: cancelToken,
                snapshot: snapshot,
                selectedCorrectionMode: selectedCorrectionMode,
                sessionSettings: sessionSettings
            )
            return
        }

        guard let asrService = asrSession.localASRService else {
            try? FileManager.default.removeItem(at: url)
            reportError("Internal state error: missing local ASR service")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }

        var didRecordASR = false
        let asrStarted = Date()
        do {
            let shouldAdvanceToCorrectionWhenASRCompletes = selectedCorrectionMode.usesRefine
                || activeTextEditTarget != nil
            let asrProgressHandler: ASRTranscriptionProgressHandler = { [weak self] progress in
                await self?.applyASRTranscriptionProgress(
                    progress,
                    sessionID: sessionID,
                    token: cancelToken,
                    shouldAdvanceToCorrectionWhenComplete: shouldAdvanceToCorrectionWhenASRCompletes
                )
            }
            let asrResult = try await asrService.transcribeResult(
                audioFileURL: url,
                languageIDs: selectedTranscriptionLanguageIDs,
                progress: asrProgressHandler
            )
            let raw = asrResult.text
            let asrHypotheses = Self.combinedASRHypotheses(
                candidates: asrResult.hypotheses.map(Optional.some)
            )
            let alternateTranscripts = Self.combinedAlternateTranscripts(
                primaryTranscript: raw,
                candidates: asrHypotheses.map(Optional.some)
            )
            let asrWarning = asrResult.warningText
            DebugLogStore.recordASR(
                debugLog,
                text: raw,
                status: "ok",
                latencyMs: elapsedMs(since: asrStarted),
                asrHypotheses: asrHypotheses,
                alternateTranscripts: alternateTranscripts,
                modelOutputs: asrResult.modelOutputs
            )
            didRecordASR = true
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            lastTranscript = raw
            try? FileManager.default.removeItem(at: url)

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.asr.notice("empty transcript — returning to idle without commit")
                clearActiveSession()
                clearDictationContext()
                clearTextEditRequest()
                collapseVoicePreviewHUDAfterAction()
                transition(to: .idle)
                return
            }

            applyASRFinalPreview(trimmed, displaysLivePartial: activeTextEditIntent != .command)

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                transition(to: .correcting)
                do {
                    let spokenInstruction: String
                    let correctionConfiguration = try sessionCorrectionConfiguration()
                    let request = buildCorrectionRequest(
                        rawTranscript: trimmed,
                        sessionSettings: sessionSettings,
                        correctionConfiguration: correctionConfiguration,
                        correctionModeOverride: .clean,
                        audioDurationMs: audioDurationMs,
                        alternateTranscripts: alternateTranscripts,
                        asrHypotheses: asrHypotheses,
                        sourceHypotheses: asrResult.sourceHypotheses
                    )
                    let correctionStarted = Date()
                    do {
                        let output = try await correctionConfiguration.corrector.correct(
                            request,
                            timeoutMs: correctionConfiguration.timeoutMs
                        )
                        try await ensureActive(sessionID: sessionID, token: cancelToken)
                        let normalizedResult = normalizeResult(
                            output.result,
                            correctionMode: request.correctionMode,
                            languageIDs: sessionSettings.transcriptionLanguageIDs,
                            punctuationPreference: sessionSettings.punctuationPreference
                        )
                        spokenInstruction = normalizedResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        lastWarning = asrWarning
                    } catch {
                        if error is CancellationError {
                            throw error
                        }
                        try await ensureActive(sessionID: sessionID, token: cancelToken)
                        let statusLabel = Self.refineFailureStatus(for: error)
                        let fallbackResult = normalizeResult(
                            CorrectionResult(action: .commit, text: trimmed, risk: .medium),
                            correctionMode: request.correctionMode,
                            languageIDs: sessionSettings.transcriptionLanguageIDs,
                            punctuationPreference: sessionSettings.punctuationPreference
                        )
                        spokenInstruction = fallbackResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        lastWarning = Self.combinedWarning([
                            Self.previewWithoutRefineMessage(for: statusLabel),
                            asrWarning,
                        ])
                        DebugLogStore.recordCorrection(
                            debugLog,
                            mode: request.correctionMode,
                            text: fallbackResult.text,
                            status: statusLabel,
                            error: error.localizedDescription,
                            latencyMs: elapsedMs(since: correctionStarted),
                            request: request,
                            debugTrace: (error as? CorrectorError)?.correctionDebugTrace,
                            timeoutMs: sessionSettings.correctionTimeoutMs
                        )
                    }
                    guard !spokenInstruction.isEmpty else {
                        Log.coordinator.notice("refine returned empty edit command — returning to idle without commit")
                        clearActiveSession()
                        clearDictationContext()
                        clearTextEditRequest()
                        collapseVoicePreviewHUDAfterAction()
                        transition(to: .idle)
                        return
                    }
                    let editStarted = Date()
                    let result = try await textEditService.edit(
                        intent: editIntent,
                        contextBefore: editTarget.contextBefore,
                        targetText: editTarget.targetText,
                        contextAfter: editTarget.contextAfter,
                        spokenInstruction: spokenInstruction,
                        languageIDs: selectedTranscriptionLanguageIDs,
                        appName: snapshot?.localizedName,
                        bundleID: snapshot?.bundleID,
                        appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                        configuration: correctionConfiguration
                    )
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    DebugLogStore.recordCorrection(
                        debugLog,
                        mode: selectedCorrectionMode,
                        text: result.text,
                        status: "text_edit_\(editIntent.rawValue)",
                        latencyMs: elapsedMs(since: editStarted),
                        timeoutMs: sessionSettings.correctionTimeoutMs
                    )
                    previewCorrectionMode = selectedCorrectionMode
                    lastCorrected = result.text
                    await finishTextEdit(
                        result,
                        target: editTarget,
                        appSnapshot: snapshot,
                        intent: editIntent,
                        sessionID: sessionID,
                        cancelToken: cancelToken
                    )
                } catch {
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    reportError(
                        "Text edit failed: \(error.localizedDescription)",
                        recovery: .openSettings
                    )
                    scheduleAutoReset(after: Self.errorResetDelay)
                }
                return
            }

            if !selectedCorrectionMode.usesRefine {
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: selectedCorrectionMode,
                    text: trimmed,
                    status: "skipped_fast_mode",
                    latencyMs: 0,
                    timeoutMs: sessionSettings.correctionTimeoutMs
                )
                previewCorrectionMode = selectedCorrectionMode
                lastWarning = asrWarning
                lastCorrected = trimmed
                await finish(
                    with: CorrectionResult(action: .commit, text: trimmed, risk: .low),
                    sessionID: sessionID,
                    cancelToken: cancelToken
                )
                return
            }

            transition(to: .correcting)
            let correctionConfiguration = try sessionCorrectionConfiguration()
            let request = buildCorrectionRequest(
                rawTranscript: trimmed,
                sessionSettings: sessionSettings,
                correctionConfiguration: correctionConfiguration,
                audioDurationMs: audioDurationMs,
                alternateTranscripts: alternateTranscripts,
                asrHypotheses: asrHypotheses,
                sourceHypotheses: asrResult.sourceHypotheses
            )
            let correctionStarted = Date()
            do {
                let output = try await correctionConfiguration.corrector.correct(
                    request,
                    timeoutMs: correctionConfiguration.timeoutMs
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                let normalizedResult = normalizeResult(
                    output.result,
                    correctionMode: request.correctionMode,
                    languageIDs: sessionSettings.transcriptionLanguageIDs,
                    punctuationPreference: sessionSettings.punctuationPreference
                )
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: normalizedResult.text,
                    status: normalizedResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "ok",
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    debugTrace: output.debugTrace,
                    timeoutMs: sessionSettings.correctionTimeoutMs
                )
                previewCorrectionMode = request.correctionMode
                lastWarning = asrWarning
                lastCorrected = normalizedResult.text
                await finish(with: normalizedResult, sessionID: sessionID, cancelToken: cancelToken)
            } catch {
                if error is CancellationError {
                    throw error
                }
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                let statusLabel = Self.refineFailureStatus(for: error)
                let fallbackResult = normalizeResult(
                    CorrectionResult(action: .commit, text: trimmed, risk: .medium),
                    correctionMode: request.correctionMode,
                    languageIDs: sessionSettings.transcriptionLanguageIDs,
                    punctuationPreference: sessionSettings.punctuationPreference
                )
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: fallbackResult.text,
                    status: statusLabel,
                    error: error.localizedDescription,
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    debugTrace: (error as? CorrectorError)?.correctionDebugTrace,
                    timeoutMs: sessionSettings.correctionTimeoutMs
                )
                previewCorrectionMode = request.correctionMode
                lastWarning = Self.combinedWarning([
                    Self.previewWithoutRefineMessage(for: statusLabel),
                    asrWarning,
                ])
                lastCorrected = fallbackResult.text
                await finish(with: fallbackResult, sessionID: sessionID, cancelToken: cancelToken)
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            return
        } catch TextCommitterError.cancelled {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch {
            if !didRecordASR {
                DebugLogStore.recordASR(
                    debugLog,
                    text: nil,
                    status: "error",
                    error: error.localizedDescription,
                    latencyMs: elapsedMs(since: asrStarted),
                    asrHypotheses: [],
                    alternateTranscripts: []
                )
            }
            try? FileManager.default.removeItem(at: url)
            guard await isActive(sessionID: sessionID, token: cancelToken) else { return }
            if ASRAudioSupport.isBenignEmptyTranscript(error) {
                Log.asr.notice("empty transcript — returning to idle without commit")
                clearActiveSession()
                clearDictationContext()
                clearTextEditRequest()
                collapseVoicePreviewHUDAfterAction()
                transition(to: .idle)
                return
            }
            reportError(error.localizedDescription, recovery: .openSettings)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func handleAudioConfigurationChanged() async {
        if isStartingDictation {
            stopAfterStart = true
            return
        }
        guard state == .recording else { return }
        Log.audio.notice("audio device changed mid-recording; processing captured audio")
        await stopDictation()
    }

    // MARK: - State helpers

    func transition(to next: DictationState) {
        guard state != next else { return }
        Log.coordinator.debug("state: \(self.state.rawValue) → \(next.rawValue)")
        if next == .recording {
            DictationSoundPlayer.playStart()
        } else if state == .recording, next == .transcribing {
            DictationSoundPlayer.playStop()
        }
        recordingStartedAt = next == .recording ? Date() : nil
        if next != .transcribing {
            transcriptionProgress = nil
        }
        // Live preview lives only across the active in-flight states
        // (recording/transcribing/correcting/inserting). Any transition out of
        // those — to preview/success/idle/error — replaces it with the final
        // text or clears it entirely.
        let activeStates: Set<DictationState> = [.recording, .transcribing, .correcting, .inserting]
        if !activeStates.contains(next) {
            teardownLivePartialPreview(clearText: true)
        }
        state = next
    }

    private func shouldIgnoreEarlyToggleStop() -> Bool {
        guard let recordingStartedAt else { return false }
        let elapsed = Date().timeIntervalSince(recordingStartedAt)
        guard elapsed < Self.minimumToggleStopInterval else { return false }
        Log.coordinator.debug("toggle stop ignored during recording warmup")
        return true
    }

    private static func refineFailureStatus(for error: Error) -> String {
        isCorrectionTimeout(error) ? "refine_timeout" : "refine_error"
    }

    private static func isCorrectionTimeout(_ error: Error) -> Bool {
        if let correctorError = error as? CorrectorError, correctorError == .timeout {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    private static func isCorrectionDegradedStatus(_ status: String?) -> Bool {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "refine_error", "refine_timeout":
            return true
        default:
            return false
        }
    }

    private func clearActiveSession() {
        activeSessionID = nil
        activeCancelToken = nil
        activeBridgeDictateJobID = nil
        activeFastASRRoute = nil
        activeASRSession = nil
        activeCorrectionConfiguration = nil
    }

    private func clearTextEditRequest() {
        activeTextEditTarget = nil
        activeTextEditIntent = nil
    }

    private func clearDictationContext() {
        activeInsertionTarget = nil
        preparedHoldStart = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
    }

    private func clearPreviewState() {
        previewCorrectionMode = nil
        voicePreviewHUDExpanded = false
        lastWarning = nil
    }

    func reportError(
        _ message: String,
        recovery: DictationErrorRecovery = .dismiss
    ) {
        activeStartOperation?.task.cancel()
        activeStartOperation = nil
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeProcessingTaskID = nil
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        clearActiveSession()
        clearTextEditRequest()
        clearDictationContext()
        clearPreviewState()
        stopAfterStart = false
        recordingStartedAt = nil
        teardownLivePartialPreview(clearText: true)
        presentationError = DictationPresentationError(
            message: message,
            recovery: recovery
        )
        lastWarning = nil
        Log.coordinator.error("\(message, privacy: .public)")
        DictationErrorLog.shared.record(message)
        DictationSoundPlayer.playError()
        state = .error
    }

    func reset(keepVoicePreviewExpanded: Bool = false) {
        activeStartOperation?.task.cancel()
        activeStartOperation = nil
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeProcessingTaskID = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        resetTask?.cancel()
        resetTask = nil
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        clearActiveSession()
        stopAfterStart = false
        recordingStartedAt = nil
        presentationError = nil
        lastWarning = nil
        lastTranscript = ""
        lastCorrected = ""
        transcriptionProgress = nil
        clearPreviewState()
        voicePreviewHUDExpanded = keepVoicePreviewExpanded
        frontmostSnapshot = nil
        clearTextEditRequest()
        clearDictationContext()
        audioLevel = 0
        teardownLivePartialPreview(clearText: true)
        state = .idle
    }

    /// Cancels any reversible phase, tears down recording if needed, and joins
    /// the processing task. Once insertion begins, the committed result wins.
    func cancelDictation() async {
        userCancellationDepth += 1
        defer { userCancellationDepth -= 1 }
        let mustJoinCommittedWork = requiresRuntimeDiscard
        if state == .recording {
            DictationSoundPlayer.playStop()
        }
        let cancelToken = activeCancelToken
        if let cancelToken, !(await cancelToken.cancel()) {
            // The text committer has crossed its irreversible boundary. Do not
            // report cancellation after text has already reached the target.
            collapseVoicePreviewHUDAfterAction()
            guard mustJoinCommittedWork else { return }
            // A mode transition still has to wait for the successful commit
            // pipeline and any preview cleanup before stopping its runtimes.
            await activeProcessingTask?.value
            let previewTeardown = beginCancellingLivePartialPreview(
                clearText: true,
                reason: "mac_preview_mode_change_after_commit"
            )
            await previewTeardown.value
            return
        }
        autoStopTask?.cancel(); autoStopTask = nil
        resetTask?.cancel();     resetTask = nil
        let startTask = activeStartOperation?.task
        let processingTask = activeProcessingTask
        startTask?.cancel()
        activeStartOperation = nil
        clearActiveSession()
        processingTask?.cancel()
        activeProcessingTask = nil
        activeProcessingTaskID = nil
        clearTextEditRequest()
        clearDictationContext()
        clearPreviewState()
        stopAfterStart = false
        recordingStartedAt = nil
        let previewTeardown = beginCancellingLivePartialPreview(
            clearText: true,
            reason: "mac_preview_dictation_cancelled"
        )
        await recorder.discard()
        // Runtime owners may shut down ASR/correction helpers as soon as this
        // method returns. Wait until the cancelled pipeline has observed its
        // commit token and fully released those helpers first; reset must not
        // retain or cancel the task that is currently being joined.
        await processingTask?.value
        await startTask?.value
        await previewTeardown.value
        audioLevel = 0
        reset()
    }

    func captureFrontmost() {
        frontmostSnapshot = FrontmostAppCapture.snapshot()
    }

    func setAudioLevel(_ level: Float) {
        audioLevel = max(0, min(1, level))
    }

    func shutdown() async {
        prepareForApplicationShutdown()
        let startTask = activeStartOperation?.task
        let processingTask = activeProcessingTask
        startTask?.cancel()
        activeStartOperation = nil
        processingTask?.cancel()
        activeProcessingTask = nil
        activeProcessingTaskID = nil
        autoStopTask?.cancel()
        resetTask?.cancel()
        let cancelToken = activeCancelToken
        clearActiveSession()
        clearTextEditRequest()
        clearDictationContext()
        clearPreviewState()
        recordingStartedAt = nil
        let previewTeardown = beginCancellingLivePartialPreview(
            clearText: true,
            reason: "mac_preview_app_shutdown"
        )
        await recorder.discard()
        await cancelToken?.cancel()
        await processingTask?.value
        await startTask?.value
        await previewTeardown.value
    }

    // MARK: - Mode switching

    /// A style chip changes the next-dictation default. Refine modes also
    /// rewrite the current focused text when there is a usable target; Fast
    /// deliberately leaves the current text unchanged.
    func requestCorrectionModeChange(to newMode: CorrectionMode) async {
        guard acceptsNewUserOperations,
              canRefineFocusedInputFromHUD,
              AppSettings.isCorrectionModeAvailable(newMode),
              newMode != (previewCorrectionMode ?? AppSettings.correctionMode)
        else { return }

        UserDefaults.standard.set(newMode.rawValue, forKey: AppSettings.Keys.correctionMode)
        previewCorrectionMode = newMode
        if !newMode.usesRefine {
            lastWarning = NSLocalizedString(
                "Fast applies to next dictation",
                comment: "HUD feedback after selecting Fast mode"
            )
            return
        }

        lastWarning = nil
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refineFocusedInput(to: newMode)
        }
        activeProcessingTask?.cancel()
        activeProcessingTask = task
        activeProcessingTaskID = taskID
        await task.value
        if activeProcessingTaskID == taskID {
            activeProcessingTask = nil
            activeProcessingTaskID = nil
        }
    }

    // MARK: - Request building

    private func buildCorrectionRequest(
        rawTranscript: String,
        sessionSettings: DictationSessionSettings,
        correctionConfiguration: CorrectionSessionConfiguration,
        correctionModeOverride: CorrectionMode? = nil,
        audioDurationMs: Int? = nil,
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = [],
        sourceHypotheses: [ASRSourceHypothesis] = []
    ) -> CorrectionRequest {
        let snapshot = frontmostSnapshot
        let category = AppCategory.from(bundleID: snapshot?.bundleID)
        let correctionMode = correctionModeOverride ?? sessionSettings.correctionMode
        let alternateForRequest = Self.combinedAlternateTranscripts(
            primaryTranscript: rawTranscript,
            candidates: alternateTranscripts.map(Optional.some)
        )
        return CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName:  snapshot?.localizedName,
            frontmostBundleID: snapshot?.bundleID,
            appCategory: category,
            languageIDs: sessionSettings.transcriptionLanguageIDs,
            rawTranscript: rawTranscript,
            contextBefore: activeDictationContextBefore,
            contextAfter: activeDictationContextAfter,
            numberOutputPreference: correctionConfiguration.numberOutputPreference,
            punctuationPreference: correctionConfiguration.punctuationPreference,
            userDictionary: correctionConfiguration.userDictionary,
            audioDurationMs: audioDurationMs,
            alternateTranscripts: alternateForRequest,
            asrHypotheses: asrHypotheses,
            sourceHypotheses: sourceHypotheses
        )
    }

    private func sessionCorrectionConfiguration() throws -> CorrectionSessionConfiguration {
        guard let activeCorrectionConfiguration else {
            throw CorrectorError.unavailable("Dictation correction backend is no longer available")
        }
        return activeCorrectionConfiguration
    }

    private static func combinedASRHypotheses(candidates: [String?]) -> [String] {
        CorrectionRequest.normalizedASRHypotheses(candidates: candidates)
    }

    private static func combinedAlternateTranscripts(
        primaryTranscript: String,
        candidates: [String?]
    ) -> [String] {
        CorrectionRequest.normalizedAlternateTranscripts(
            primaryTranscript: primaryTranscript,
            candidates: candidates
        )
    }

    private static func combinedWarning(_ warnings: [String?]) -> String? {
        let cleaned = warnings
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }

    private static func successWarning(from warning: String?) -> String? {
        let trimmed = warning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        let lines = trimmed.components(separatedBy: .newlines).compactMap { line -> String? in
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ASRAudioSupport.isBenignEmptyTranscriptMessage(cleaned) else {
                return nil
            }
            if cleaned == previewWithoutRefineBaseMessage {
                return insertedWithoutRefineBaseMessage
            }
            if cleaned == previewWithoutRefineMessage(for: "refine_timeout") {
                return insertedWithoutRefineMessage(for: "refine_timeout")
            }
            if cleaned == previewWithoutRefineMessage(for: "refine_error") {
                return insertedWithoutRefineMessage(for: "refine_error")
            }
            return line
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func previewWithoutRefineMessage(for status: String?) -> String {
        withoutRefineMessage(prefix: previewWithoutRefineBaseMessage, status: status)
    }

    private static func insertedWithoutRefineMessage(for status: String?) -> String {
        withoutRefineMessage(prefix: insertedWithoutRefineBaseMessage, status: status)
    }

    private static func withoutRefineMessage(prefix: String, status: String?) -> String {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "refine_timeout":
            return "\(prefix): refine timeout"
        case "refine_error":
            return "\(prefix): refine error"
        default:
            return prefix
        }
    }

    private func asrService(for settings: DictationSessionSettings) throws -> ASRService {
        if settings.correctionMode == .fast {
            guard let source = settings.canonicalRecognitionSources.first else {
                throw ASRAudioSupportError.httpStatus(503, "Fast ASR source is unavailable")
            }
            return ASRFactory.shared.getInstalled(source: source)
        }
        return ASRFactory.shared.get(sources: settings.canonicalRecognitionSources)
    }

    private func fastRouteForCurrentSession() throws -> FastASRRoute {
        if let activeFastASRRoute {
            return activeFastASRRoute
        }
        let route = try FastASRRoute.resolve(languageIDs: AppSettings.asrCanonicalLanguageIDs)
        activeFastASRRoute = route
        return route
    }

    // MARK: - Live partial preview
    //
    // The selected preview source subscribes to the AudioRecorder PCM tap and
    // renders partial hypotheses into `livePartialTranscript` for the HUD
    // except command/wand edits, which suppress visible preview. The Mac
    // recognition sources + correction pipeline are unchanged — preview never
    // replaces or augments the canonical result.
    //
    // Any preview failure silently degrades to "no preview" — recording still
    // works and final ASR still runs.

    private func makeLivePartialPreviewPCMHandlerIfAvailable(
        sessionID: UUID,
        settings: DictationSessionSettings
    ) async -> ((AVAudioPCMBuffer) -> Void)? {
        teardownLivePartialPreview(clearText: true)
        // A new preview starts only after the previous session has returned or
        // terminated, so model ownership stays strictly serial.
        await livePreviewCleanup.waitForAll()
        guard activeSessionID == sessionID, !Task.isCancelled else { return nil }
        if settings.correctionMode == .fast, settings.voiceLivePreviewEnabled {
            let source = settings.fastASRSource ?? settings.configuredFastASRSource
            switch source {
            case .qwen:
                guard settings.processingMode == .server || settings.clientBridgeRecognitionSources.contains(.qwen) else {
                    return nil
                }
                if settings.processingMode == .client {
                    return await makeRemoteBridgeLivePartialPreviewPCMHandlerIfAvailable(
                        source: .qwen,
                        sessionID: sessionID,
                        settings: settings
                    )
                }
                return await makeASRLivePartialPreviewPCMHandlerIfAvailable(
                    source: .qwen,
                    sessionID: sessionID,
                    settings: settings
                )
            case .appleSpeech:
                guard settings.processingMode == .server || settings.clientBridgeRecognitionSources.contains(.appleSpeech) else {
                    return nil
                }
                return makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(
                    requiresEnabledRecognitionSource: settings.processingMode == .server,
                    sessionID: sessionID,
                    settings: settings
                )
            case .nvidiaNemotron:
                guard settings.processingMode == .server || settings.clientBridgeRecognitionSources.contains(.nvidiaNemotron) else {
                    return nil
                }
                if settings.processingMode == .client {
                    return await makeRemoteBridgeLivePartialPreviewPCMHandlerIfAvailable(
                        source: .nvidiaNemotron,
                        sessionID: sessionID,
                        settings: settings
                    )
                }
                return await makeASRLivePartialPreviewPCMHandlerIfAvailable(
                    source: .nvidiaNemotron,
                    sessionID: sessionID,
                    settings: settings
                )
            }
        }
        if settings.processingMode == .client {
            switch settings.voiceLivePreviewSource {
            case .off:
                return nil
            case .appleSpeech:
                return makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(
                    requiresEnabledRecognitionSource: false,
                    sessionID: sessionID,
                    settings: settings
                )
            case .qwen, .nvidiaNemotron:
                return await makeRemoteBridgeLivePartialPreviewPCMHandlerIfAvailable(
                    source: settings.voiceLivePreviewSource,
                    sessionID: sessionID,
                    settings: settings
                )
            }
        }
        switch settings.voiceLivePreviewSource {
        case .off:
            return nil
        case .qwen:
            return await makeASRLivePartialPreviewPCMHandlerIfAvailable(
                source: .qwen,
                sessionID: sessionID,
                settings: settings
            )
        case .appleSpeech:
            return makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(
                requiresEnabledRecognitionSource: true,
                sessionID: sessionID,
                settings: settings
            )
        case .nvidiaNemotron:
            return await makeASRLivePartialPreviewPCMHandlerIfAvailable(
                source: .nvidiaNemotron,
                sessionID: sessionID,
                settings: settings
            )
        }
    }

    private func makeRemoteBridgeLivePartialPreviewPCMHandlerIfAvailable(
        source: VoiceLivePreviewSource,
        sessionID: UUID,
        settings: DictationSessionSettings
    ) async -> ((AVAudioPCMBuffer) -> Void)? {
        guard source == .qwen || source == .nvidiaNemotron else {
            if source != .off {
                Log.bridge.notice("Mac client live preview skipped: source \(source.rawValue, privacy: .public) is not bridge-streamable")
            }
            return nil
        }
        let displaysLivePartial = activeTextEditIntent != .command
        do {
            let resolved = try await resolveRemoteBridgeClient(
                configuration: settings.clientBridgeConfiguration
            )
            guard activeSessionID == sessionID else { return nil }
            let snapshot = frontmostSnapshot
            let streamer = RemoteBridgeLivePreviewStreamer(
                client: resolved,
                languageIDs: settings.transcriptionLanguageIDs,
                correctionMode: settings.correctionMode,
                livePreviewSource: source,
                appSnapshot: snapshot,
                appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                clientJobID: activeBridgeDictateJobID,
                onTranscript: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.applyLivePartialPreview(
                            text,
                            sessionID: sessionID,
                            displaysLivePartial: displaysLivePartial,
                            source: source.rawValue
                        )
                    }
                },
                onFailure: { message in
                    Log.bridge.notice("Mac client live preview failed: \(message, privacy: .public)")
                }
            )
            livePreviewOwnerSessionID = sessionID
            remoteBridgeLivePreviewStreamer = streamer
            streamer.start()
            return { [streamer] buffer in
                streamer.append(buffer)
            }
        } catch {
            Log.bridge.notice("Mac client live preview skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makeASRLivePartialPreviewPCMHandlerIfAvailable(
        source: VoiceLivePreviewSource,
        sessionID: UUID,
        settings: DictationSessionSettings
    ) async -> ((AVAudioPCMBuffer) -> Void)? {
        let displaysLivePartial = activeTextEditIntent != .command
        do {
            let lease = try await ASRLivePreviewLeaseFactory.take(
                source: source,
                requestedLanguageIDs: settings.transcriptionLanguageIDs,
                diagnosticID: UUID().uuidString
            ) { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.applyLivePartialPreview(
                        text,
                        sessionID: sessionID,
                        displaysLivePartial: displaysLivePartial,
                        source: source.rawValue
                    )
                }
            }
            guard activeSessionID == sessionID, !Task.isCancelled else {
                await releaseUnusedLivePreviewLease(
                    lease,
                    reason: "mac_preview_start_cancelled"
                )
                return nil
            }
            guard let handler = makeASRLivePreviewPCMHandler(session: lease.session) else {
                await lease.returnIdle(reason: "mac_preview_unsupported_session")
                return nil
            }
            livePreviewOwnerSessionID = sessionID
            asrLivePreviewLease = lease
            return handler
        } catch is CancellationError {
            return nil
        } catch {
            Log.asr.notice("ASR live preview unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func releaseUnusedLivePreviewLease(
        _ lease: ASRLivePreviewLease,
        reason: String
    ) async {
        if requiresRuntimeDiscard {
            await lease.discard(reason: reason)
        } else {
            await lease.returnIdle(reason: reason)
        }
    }

    private func makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(
        requiresEnabledRecognitionSource: Bool,
        sessionID: UUID,
        settings: DictationSessionSettings
    ) -> ((AVAudioPCMBuffer) -> Void)? {
        guard !requiresEnabledRecognitionSource || settings.recognitionSources.contains(.appleSpeech) else {
            return nil
        }
        guard let localeID = settings.transcriptionLanguageIDs.lazy.compactMap({
            AppleSpeechLanguageSupport.cachedBestLocaleIdentifier(for: $0)
        }).first else {
            AppleSpeechLanguageSupport.refreshInBackgroundIfNeeded()
            return nil
        }
        let locale = Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else { return nil }

        switch AppPermissions.speechRecognitionStatus {
        case .granted:
            break
        case .notDetermined:
            // First-time use: kick the system prompt asynchronously so the
            // NEXT recording can use it. Don't block the current one.
            Task { _ = await AppPermissions.requestSpeechRecognition() }
            return nil
        case .denied, .restricted, .unknown:
            return nil
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true
        if settings.punctuationPreference != .spaces {
            request.addsPunctuation = true
        }

        let displaysLivePartial = activeTextEditIntent != .command
        livePreviewOwnerSessionID = sessionID
        liveSpeechRecognizer = recognizer
        liveSpeechRequest = request
        liveSpeechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Callback fires off the main actor — hop back before @Published
            // mutation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.applyLivePartialPreview(
                        text,
                        sessionID: sessionID,
                        displaysLivePartial: displaysLivePartial,
                        source: VoiceLivePreviewSource.appleSpeech.rawValue
                    )
                }
                if let error {
                    _ = AppleSpeechAvailability.recordRecognitionError(error)
                    self.teardownLivePartialPreview(clearText: false, ifOwnedBy: sessionID)
                }
            }
        }

        return makeAppleSpeechLivePreviewPCMHandler(request: request)
    }

    private func applyLivePartialPreview(
        _ rawText: String,
        sessionID: UUID,
        displaysLivePartial: Bool,
        source: String
    ) {
        guard activeSessionID == sessionID,
              livePreviewOwnerSessionID == sessionID
        else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard displaysLivePartial else { return }
        let current = livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLikelyLivePartialSuffixRegression(candidate: text, current: current) {
            Log.coordinator.debug(
                "live preview partial ignored source=\(source, privacy: .public) reason=suffix_regression current_chars=\(current.count, privacy: .public) candidate_chars=\(text.count, privacy: .public)"
            )
            return
        }
        guard text != current else { return }
        livePartialTranscript = text
    }

    private static func isLikelyLivePartialSuffixRegression(candidate: String, current: String) -> Bool {
        guard candidate.count < current.count else { return false }
        let normalizedCandidate = livePartialComparisonText(candidate)
        let normalizedCurrent = livePartialComparisonText(current)
        guard normalizedCandidate.count >= 4,
              normalizedCurrent.count > normalizedCandidate.count
        else { return false }
        if normalizedCurrent.hasSuffix(normalizedCandidate) {
            return true
        }
        let lengthRatio = Double(normalizedCandidate.count) / Double(normalizedCurrent.count)
        guard lengthRatio <= 0.75 else { return false }
        return livePartialTailSimilarity(current: normalizedCurrent, candidate: normalizedCandidate) >= 0.75
    }

    private static func livePartialComparisonText(_ text: String) -> String {
        var result = ""
        let keptScalars = CharacterSet.alphanumerics
        let ignoredScalars = CharacterSet.whitespacesAndNewlines
        for scalar in text.unicodeScalars {
            if ignoredScalars.contains(scalar) {
                continue
            }
            if keptScalars.contains(scalar) {
                result.append(String(scalar))
            }
        }
        return result.lowercased()
    }

    private static func livePartialTailSimilarity(current: String, candidate: String) -> Double {
        let currentCharacters = Array(current)
        let candidateCharacters = Array(candidate)
        guard !candidateCharacters.isEmpty,
              currentCharacters.count >= candidateCharacters.count
        else { return 0 }
        let suffix = currentCharacters.suffix(candidateCharacters.count)
        let matches = zip(suffix, candidateCharacters).reduce(0) { count, pair in
            count + (pair.0 == pair.1 ? 1 : 0)
        }
        return Double(matches) / Double(candidateCharacters.count)
    }

    private func applyASRFinalPreview(_ rawText: String, displaysLivePartial: Bool) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        teardownLivePartialPreview(clearText: false)
        if displaysLivePartial {
            livePartialTranscript = text
        }
    }

    /// Detaches and cancels the display-only preview when recording stops. The
    /// canonical ASR starts immediately from the recorded file; it never waits
    /// for a preview request to finish or repeats full-audio preview inference.
    /// Existing partial text stays visible until canonical output replaces it.
    func endLivePartialPreviewAudio(sessionID: UUID) {
        guard activeSessionID == sessionID,
              livePreviewOwnerSessionID == sessionID
        else { return }
        detachLivePartialPreview(
            clearText: false,
            teardownMode: currentLivePreviewTeardownMode,
            reason: "mac_preview_stopped_for_final_asr"
        )
    }

    /// Called after a final ASR/correction result owns the display (or on reset / error).
    func teardownLivePartialPreview(clearText: Bool) {
        detachLivePartialPreview(
            clearText: clearText,
            teardownMode: currentLivePreviewTeardownMode,
            reason: "mac_preview_cancelled"
        )
    }

    private var currentLivePreviewTeardownMode: DictationLivePreviewLeaseTeardownMode {
        requiresRuntimeDiscard
            ? .discardOnResetFailure
            : .replenishOnResetFailure
    }

    private func beginCancellingLivePartialPreview(
        clearText: Bool,
        reason: String
    ) -> Task<Void, Never> {
        let discardsForRuntimeTransition = requiresRuntimeDiscard
        detachLivePartialPreview(
            clearText: clearText,
            teardownMode: discardsForRuntimeTransition
                ? .discardOnResetFailure
                : .replenishOnResetFailure,
            reason: reason
        )
        return Task { @MainActor [livePreviewCleanup] in
            await livePreviewCleanup.waitForAll()
        }
    }

    private func detachLivePartialPreview(
        clearText: Bool,
        teardownMode: DictationLivePreviewLeaseTeardownMode,
        reason: String
    ) {
        livePreviewOwnerSessionID = nil
        if let remoteStreamer = remoteBridgeLivePreviewStreamer {
            livePreviewCleanup.enqueue {
                remoteStreamer.cancel()
                // Queueing a waiter after cancel creates a FIFO barrier on the
                // streamer's audio queue, so cancellation has been applied
                // before coordinator shutdown is allowed to continue.
                _ = await remoteStreamer.finishAndWait(
                    timeout: Self.asrLivePreviewResetTimeout
                )
            }
        }
        remoteBridgeLivePreviewStreamer = nil
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        liveSpeechRequest = nil
        liveSpeechRecognizer = nil
        if let lease = asrLivePreviewLease {
            asrLivePreviewLease = nil
            livePreviewCleanup.enqueue {
                await DictationLivePreviewLeaseTeardown.run(
                    lease: lease,
                    mode: teardownMode,
                    resetTimeout: Self.asrLivePreviewResetTimeout,
                    reason: reason
                )
            }
        }
        if clearText {
            livePartialTranscript = ""
        }
    }

    private func teardownLivePartialPreview(clearText: Bool, ifOwnedBy sessionID: UUID) {
        guard livePreviewOwnerSessionID == sessionID else { return }
        teardownLivePartialPreview(clearText: clearText)
    }

    private func normalizeResult(
        _ result: CorrectionResult,
        correctionMode: CorrectionMode,
        languageIDs: [String],
        punctuationPreference: PunctuationOutputPreference
    ) -> CorrectionResult {
        var normalized = result
        normalized.text = LocaleTextNormalizer.normalize(result.text, languageIDs: languageIDs)
        normalized.text = TranscriptPostProcessor.clean(
            normalized.text,
            languageIDs: languageIDs,
            preserveLineBreaks: correctionMode == .structurePlus,
            punctuationPreference: punctuationPreference
        )
        return normalized
    }

    private func processWithRemoteBridge(
        audioURL: URL,
        debugLog: DebugLogHandle?,
        sessionID: UUID,
        cancelToken: CommitCancellationToken,
        snapshot: FrontmostAppSnapshot?,
        selectedCorrectionMode: CorrectionMode,
        sessionSettings: DictationSessionSettings
    ) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let started = Date()
        do {
            let appCategory = AppCategory.from(bundleID: snapshot?.bundleID)
            let client = try await resolveRemoteBridgeClient(
                configuration: sessionSettings.clientBridgeConfiguration
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            let hasTextEditRequest = activeTextEditTarget != nil && activeTextEditIntent != nil
            let remoteDictateCorrectionMode: CorrectionMode = hasTextEditRequest ? .clean : selectedCorrectionMode
            let dictateJobID = activeBridgeDictateJobID ?? Self.bridgeJobID(prefix: "mac_dictate", sessionID: sessionID)
            let remoteJobEventHandler: @Sendable (BridgeJobStatusEvent) async -> Void = { [weak self] event in
                await self?.applyRemoteBridgeJobStatus(
                    event,
                    sessionID: sessionID,
                    token: cancelToken,
                    shouldAdvanceToCorrectionWhenTranscriptionCompletes: remoteDictateCorrectionMode.usesRefine
                )
            }
            let response = try await client.dictate(
                audioURL: audioURL,
                languageIDs: sessionSettings.transcriptionLanguageIDs,
                correctionMode: remoteDictateCorrectionMode,
                appSnapshot: snapshot,
                appCategory: appCategory,
                contextBefore: activeDictationContextBefore,
                contextAfter: activeDictationContextAfter,
                includeRawTranscript: true,
                clientJobID: dictateJobID,
                onJobEvent: remoteJobEventHandler
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)

            let raw = response.rawTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DebugLogStore.recordASR(
                debugLog,
                text: raw.isEmpty ? nil : raw,
                status: raw.isEmpty ? "remote_no_raw" : "remote_ok",
                latencyMs: response.transcriptionLatencyMs ?? elapsedMs(since: started),
                asrHypotheses: Self.combinedASRHypotheses(candidates: [raw]),
                alternateTranscripts: []
            )
            lastTranscript = raw.isEmpty ? response.text : raw
            if !raw.isEmpty {
                applyASRFinalPreview(raw, displaysLivePartial: activeTextEditIntent != .command)
            }

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                let spoken = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else {
                    Log.coordinator.notice("remote refine returned empty edit command — returning to idle without commit")
                    clearActiveSession()
                    clearDictationContext()
                    clearTextEditRequest()
                    collapseVoicePreviewHUDAfterAction()
                    transition(to: .idle)
                    return
                }
                transition(to: .correcting)
                let editResponse = try await client.editText(
                    intent: editIntent,
                    contextBefore: editTarget.contextBefore,
                    targetText: editTarget.targetText,
                    contextAfter: editTarget.contextAfter,
                    spokenInstruction: spoken,
                    languageIDs: sessionSettings.transcriptionLanguageIDs,
                    appSnapshot: snapshot,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                    clientJobID: Self.bridgeJobID(prefix: "mac_edit", sessionID: sessionID),
                    onJobEvent: remoteJobEventHandler
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: selectedCorrectionMode,
                    text: editResponse.text,
                    status: "remote_text_edit_\(editIntent.rawValue)",
                    error: editResponse.editError,
                    latencyMs: editResponse.editLatencyMs ?? editResponse.latencyMs,
                    timeoutMs: sessionSettings.correctionTimeoutMs
                )
                previewCorrectionMode = selectedCorrectionMode
                lastWarning = response.asrWarning
                lastCorrected = editResponse.text
                await finishTextEdit(
                    TextEditResult(action: .replaceTarget, text: editResponse.text),
                    target: editTarget,
                    appSnapshot: snapshot,
                    intent: editIntent,
                    sessionID: sessionID,
                    cancelToken: cancelToken
                )
                return
            }

            if selectedCorrectionMode.usesRefine {
                transition(to: .correcting)
            }
            let result = normalizeResult(
                CorrectionResult(action: .commit, text: response.text, risk: .low),
                correctionMode: selectedCorrectionMode,
                languageIDs: sessionSettings.transcriptionLanguageIDs,
                punctuationPreference: sessionSettings.punctuationPreference
            )
            DebugLogStore.recordCorrection(
                debugLog,
                mode: selectedCorrectionMode,
                text: result.text,
                status: response.correctionStatus ?? "remote_unknown",
                error: response.correctionError,
                latencyMs: response.correctionLatencyMs ?? response.latencyMs,
                timeoutMs: sessionSettings.correctionTimeoutMs
            )
            previewCorrectionMode = selectedCorrectionMode
            lastWarning = Self.combinedWarning([
                Self.isCorrectionDegradedStatus(response.correctionStatus)
                    ? Self.previewWithoutRefineMessage(for: response.correctionStatus)
                    : nil,
                response.asrWarning,
            ])
            lastCorrected = result.text
            await finish(with: result, sessionID: sessionID, cancelToken: cancelToken)
        } catch is CancellationError {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch TextCommitterError.cancelled {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch {
            DebugLogStore.recordASR(
                debugLog,
                text: nil,
                status: "remote_error",
                error: error.localizedDescription,
                latencyMs: elapsedMs(since: started),
                asrHypotheses: [],
                alternateTranscripts: []
            )
            guard await isActive(sessionID: sessionID, token: cancelToken) else { return }
            reportError(error.localizedDescription, recovery: .openSettings)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func resolveRemoteBridgeClient(
        configuration: ClientBridgeConfiguration
    ) async throws -> RemoteBridgeClient {
        guard configuration.hasAnyBridgeURL else { throw RemoteBridgeClientError.missingURL }
        guard !configuration.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteBridgeClientError.missingToken
        }
        let status = await ClientBridgeRouteResolver().resolve(
            config: configuration,
            probeAllEndpoints: false
        )
        guard let activeURL = status.activeURL else {
            throw RemoteBridgeClientError.unavailable
        }
        return try RemoteBridgeClient(
            baseURLString: activeURL.absoluteString,
            token: configuration.token
        )
    }

    private func refineFocusedInput(to newMode: CorrectionMode) async {
        guard acceptsNewUserOperations, activeStartOperation == nil else { return }
        if !AppPermissions.accessibilityTrusted {
            AppPermissions.requestAccessibility()
        }

        let snapshot = FrontmostAppCapture.snapshot()
        guard let target = TextEditTargetCapture.snapshot(in: snapshot, allowFocusedValue: true) else {
            return
        }

        let sourceText = target.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        let processingMode = AppSettings.processingMode
        let languageIDs = processingMode == .client
            ? AppSettings.clientLanguageIDs
            : AppSettings.asrCanonicalLanguageIDs
        let punctuationPreference = AppSettings.punctuationPreference
        let clientBridgeConfiguration = ClientBridgeConfiguration.current
        let localCorrectionConfiguration = processingMode == .server && newMode.usesRefine
            ? CorrectionSessionConfiguration.capture(userDictionary: dictionary.sortedSnapshot())
            : nil

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        previewCorrectionMode = newMode
        frontmostSnapshot = snapshot
        resetTask?.cancel(); resetTask = nil
        transition(to: .correcting)

        do {
            let text: String
            if processingMode == .client {
                let client = try await resolveRemoteBridgeClient(
                    configuration: clientBridgeConfiguration
                )
                let refineJobID = Self.bridgeJobID(prefix: "mac_refine", sessionID: sessionID)
                let response = try await client.refine(
                    sessionID: nil,
                    rawTranscript: sourceText,
                    languageIDs: languageIDs,
                    correctionMode: newMode,
                    appSnapshot: snapshot,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                    contextBefore: target.contextBefore,
                    contextAfter: target.contextAfter,
                    clientJobID: refineJobID,
                    onJobEvent: { [weak self] event in
                        await self?.applyRemoteBridgeJobStatus(
                            event,
                            sessionID: sessionID,
                            token: cancelToken,
                            shouldAdvanceToCorrectionWhenTranscriptionCompletes: true
                        )
                    }
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                lastWarning = Self.isCorrectionDegradedStatus(response.correctionStatus)
                    ? Self.previewWithoutRefineMessage(for: response.correctionStatus)
                    : nil
                text = normalizeResult(
                    CorrectionResult(action: .commit, text: response.text, risk: .low),
                    correctionMode: newMode,
                    languageIDs: languageIDs,
                    punctuationPreference: punctuationPreference
                ).text
            } else {
                guard let localCorrectionConfiguration else {
                    throw CorrectorError.unavailable("Dictation correction backend is no longer available")
                }
                let request = CorrectionRequest(
                    correctionMode: newMode,
                    frontmostAppName: snapshot?.localizedName,
                    frontmostBundleID: snapshot?.bundleID,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                    languageIDs: languageIDs,
                    rawTranscript: sourceText,
                    contextBefore: target.contextBefore,
                    contextAfter: target.contextAfter,
                    numberOutputPreference: localCorrectionConfiguration.numberOutputPreference,
                    punctuationPreference: localCorrectionConfiguration.punctuationPreference,
                    userDictionary: localCorrectionConfiguration.userDictionary
                )
                do {
                    let output = try await localCorrectionConfiguration.corrector.correct(
                        request,
                        timeoutMs: localCorrectionConfiguration.timeoutMs
                    )
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    lastWarning = nil
                    text = normalizeResult(
                        output.result,
                        correctionMode: request.correctionMode,
                        languageIDs: languageIDs,
                        punctuationPreference: localCorrectionConfiguration.punctuationPreference
                    ).text
                } catch {
                    if error is CancellationError {
                        throw error
                    }
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    let status = Self.refineFailureStatus(for: error)
                    lastWarning = Self.previewWithoutRefineMessage(for: status)
                    text = normalizeResult(
                        CorrectionResult(action: .commit, text: sourceText, risk: .medium),
                        correctionMode: request.correctionMode,
                        languageIDs: languageIDs,
                        punctuationPreference: localCorrectionConfiguration.punctuationPreference
                    ).text
                }
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                clearActiveSession()
                collapseVoicePreviewHUDAfterAction()
                transition(to: .idle)
                return
            }

            lastCorrected = trimmed
            transition(to: .inserting)
            try await committer.commitTextEdit(
                trimmed,
                target: target,
                appSnapshot: snapshot,
                cancelToken: cancelToken
            )
            clearActiveSession()
            collapseVoicePreviewHUDAfterAction()
            let warning = Self.successWarning(from: lastWarning)
            lastWarning = warning
            transition(to: .success)
            scheduleAutoReset(
                after: warning == nil ? Self.successResetDelay : Self.degradedSuccessResetDelay,
                keepVoicePreviewExpanded: true
            )
        } catch is CancellationError {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch TextCommitterError.cancelled {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch {
            guard activeSessionID == sessionID else { return }
            reportError(
                "Refine failed: \(error.localizedDescription)",
                recovery: .openSettings
            )
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private static func bridgeJobID(prefix: String, sessionID: UUID) -> String {
        "\(prefix)_\(sessionID.uuidString.lowercased())"
    }

    private func applyRemoteBridgeJobStatus(
        _ event: BridgeJobStatusEvent,
        sessionID: UUID,
        token: CommitCancellationToken,
        shouldAdvanceToCorrectionWhenTranscriptionCompletes: Bool
    ) async {
        guard await isActive(sessionID: sessionID, token: token) else { return }
        if event.stage == .transcriptReady,
           let raw = event.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            lastTranscript = raw
            applyASRFinalPreview(raw, displaysLivePartial: activeTextEditIntent != .command)
        }
        applyBridgeTranscriptionProgress(event)
        if shouldAdvanceToCorrectionWhenTranscriptionCompletes,
           event.transcriptionReadyForRefine,
           state == .transcribing {
            transition(to: .correcting)
        }
        switch event.stage {
        case .refining:
            if state == .transcribing {
                transition(to: .correcting)
            }
        case .failed:
            if state == .transcribing || state == .correcting {
                lastWarning = event.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .audioReceived, .transcribing, .transcriptReady, .resultReady:
            break
        }
    }

    private func applyBridgeTranscriptionProgress(_ event: BridgeJobStatusEvent) {
        guard event.stage == .transcribing || event.stage == .transcriptReady else { return }
        guard let completed = event.transcriptionCompletedSources,
              let total = event.transcriptionTotalSources,
              total > 1
        else { return }
        transcriptionProgress = ASRTranscriptionProgress(
            completedSources: min(max(0, completed), total),
            totalSources: total,
            source: nil
        )
    }

    private func applyASRTranscriptionProgress(
        _ progress: ASRTranscriptionProgress,
        sessionID: UUID,
        token: CommitCancellationToken,
        shouldAdvanceToCorrectionWhenComplete: Bool
    ) async {
        guard await isActive(sessionID: sessionID, token: token) else { return }
        guard progress.isMultiSource else { return }
        transcriptionProgress = progress
        if shouldAdvanceToCorrectionWhenComplete,
           progress.completedSources >= progress.totalSources,
           state == .transcribing {
            transition(to: .correcting)
        }
    }

    func statusTextWithTranscriptionProgress(_ base: String) -> String {
        guard state == .transcribing,
              let progress = transcriptionProgress,
              progress.totalSources > 1
        else { return base }
        let total = progress.totalSources
        let completed = min(max(0, progress.completedSources), total)
        return "\(base) (\(completed)/\(total))"
    }

    // MARK: - Commit

    private func finish(
        with result: CorrectionResult,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        guard activeSessionID == sessionID else { return }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.coordinator.notice("refine returned empty text — returning to idle without commit")
            clearActiveSession()
            clearDictationContext()
            clearTextEditRequest()
            collapseVoicePreviewHUDAfterAction()
            transition(to: .idle)
            return
        }
        transition(to: .inserting)
        do {
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            try await committer.commit(
                result.text,
                to: frontmostSnapshot,
                target: activeInsertionTarget,
                cancelToken: cancelToken
            )
            clearActiveSession()
            collapseVoicePreviewHUDAfterAction()
            let warning = Self.successWarning(from: lastWarning)
            lastWarning = warning
            transition(to: .success)
            scheduleAutoReset(
                after: warning == nil ? Self.successResetDelay : Self.degradedSuccessResetDelay,
                keepVoicePreviewExpanded: true
            )
        } catch is CancellationError {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch TextCommitterError.cancelled {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch {
            guard activeSessionID == sessionID else { return }
            reportError(error.localizedDescription, recovery: .openSettings)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func finishTextEdit(
        _ result: TextEditResult,
        target: TextEditTargetSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        intent: TextEditIntent,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        guard activeSessionID == sessionID else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clearActiveSession()
            transition(to: .idle)
            return
        }

        transition(to: .inserting)
        do {
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            try await committer.commitTextEdit(
                text,
                target: target,
                appSnapshot: appSnapshot,
                cancelToken: cancelToken
            )
            clearTextEditRequest()
            clearActiveSession()
            collapseVoicePreviewHUDAfterAction()
            let warning = Self.successWarning(from: lastWarning)
            lastWarning = warning
            transition(to: .success)
            scheduleAutoReset(
                after: warning == nil ? Self.successResetDelay : Self.degradedSuccessResetDelay,
                keepVoicePreviewExpanded: true
            )
        } catch is CancellationError {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch TextCommitterError.cancelled {
            returnToIdleIfOwned(sessionID: sessionID)
        } catch {
            guard activeSessionID == sessionID else { return }
            reportError(error.localizedDescription, recovery: .openSettings)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    // MARK: - Private

    private func scheduleAutoStop(after seconds: TimeInterval) {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopDictation()
        }
    }

    private func scheduleAutoReset(after seconds: TimeInterval, keepVoicePreviewExpanded: Bool = false) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reset(keepVoicePreviewExpanded: keepVoicePreviewExpanded)
        }
    }

    private func ensureActive(sessionID: UUID, token: CommitCancellationToken) async throws {
        guard await isActive(sessionID: sessionID, token: token) else {
            throw CancellationError()
        }
    }

    private func isActive(sessionID: UUID, token: CommitCancellationToken) async -> Bool {
        let cancelled = await token.isCancelled()
        return activeSessionID == sessionID && !cancelled
    }

    private func returnToIdleIfOwned(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        clearActiveSession()
        clearTextEditRequest()
        clearDictationContext()
        collapseVoicePreviewHUDAfterAction()
        transition(to: .idle)
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

private func makeASRLivePreviewPCMHandler(
    session: any ASRLivePreviewSession
) -> ((AVAudioPCMBuffer) -> Void)? {
    if let session = session as? NvidiaNemotronLivePreviewSession {
        return { [weak session] buffer in
            session?.append(buffer)
        }
    }
    if let session = session as? QwenLlamaLivePreviewSession {
        return { [weak session] buffer in
            session?.append(buffer)
        }
    }
    return nil
}

private func makeAppleSpeechLivePreviewPCMHandler(
    request: SFSpeechAudioBufferRecognitionRequest
) -> (AVAudioPCMBuffer) -> Void {
    { [weak request] buffer in
        request?.append(buffer)
    }
}
