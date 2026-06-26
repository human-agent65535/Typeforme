import AVFoundation
import Foundation
import Combine
import CoreGraphics
import Speech

/// Owns the full dictation state machine and orchestrates services.
/// Main flow: `idle → recording → transcribing → correcting →
/// (inserting | preview) → success → idle`; any state can fall to
/// `error → idle`.
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastError: String?
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

    private let recorder = AudioRecorder()
    private var corrector: CorrectorService { CorrectorFactory.shared.make() }
    private let committer = PasteboardTextCommitter()
    private let textEditService: TextEditService
    private let dictionary: UserDictionaryStore

    private var autoStopTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var activeCancelToken: CommitCancellationToken?
    private var activeTextEditTarget: TextEditTargetSnapshot?
    private var activeTextEditIntent: TextEditIntent?
    private var activeDictationContextBefore = ""
    private var activeDictationContextAfter = ""
    private var startInProgress = false
    private var stopAfterStart = false
    /// Published so the HUD action bar can render the elapsed / remaining
    /// recording timer from the same clock the auto-stop uses.
    @Published private(set) var recordingStartedAt: Date?
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveSpeechTask: SFSpeechRecognitionTask?
    private var asrLivePreviewLease: ASRLivePreviewLease?
    private var remoteBridgeLivePreviewStreamer: RemoteBridgeLivePreviewStreamer?

    private static let errorResetDelay: TimeInterval = 8.0
    private static let successResetDelay: TimeInterval = 1.8
    private static let degradedSuccessResetDelay: TimeInterval = 1.8
    private static let minimumToggleStopInterval: TimeInterval = 0.6
    private static let asrLivePreviewFinishTimeout: TimeInterval = 4
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
    }

    // MARK: - Public API used by AppDelegate / hotkey

    func toggleDictation() async {
        if startInProgress {
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

    func startDictation(intent: TextEditIntent? = nil) async {
        guard state == .idle, !startInProgress else { return }
        if !AppPermissions.accessibilityTrusted {
            AppPermissions.requestAccessibility()
        }

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        clearPreviewState()
        voicePreviewHUDExpanded = true
        startInProgress = true
        stopAfterStart = false
        resetTask?.cancel(); resetTask = nil
        captureFrontmost()
        activeTextEditIntent = intent

        let livePreviewPCMHandler = await makeLivePartialPreviewPCMHandlerIfAvailable()
        do {
            let startedURL = try await recorder.start(pcmHandler: livePreviewPCMHandler)
            startInProgress = false
            guard await isActive(sessionID: sessionID, token: cancelToken) else {
                if let stoppedURL = recorder.stop() {
                    try? FileManager.default.removeItem(at: stoppedURL)
                } else {
                    try? FileManager.default.removeItem(at: startedURL)
                }
                teardownLivePartialPreview(clearText: true)
                return
            }
            transition(to: .recording)
            guard captureDictationContextAndTarget(intent: intent) else {
                if let stoppedURL = recorder.stop() {
                    try? FileManager.default.removeItem(at: stoppedURL)
                } else {
                    try? FileManager.default.removeItem(at: startedURL)
                }
                audioLevel = 0
                reportError("Select text or focus a text field first")
                scheduleAutoReset(after: Self.errorResetDelay)
                return
            }
            scheduleAutoStop(after: AppSettings.maxRecordingDuration)
            if stopAfterStart {
                stopAfterStart = false
                await stopDictation()
            }
        } catch {
            teardownLivePartialPreview(clearText: true)
            startInProgress = false
            stopAfterStart = false
            guard activeSessionID == sessionID else { return }
            clearActiveSession()
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func captureDictationContextAndTarget(intent: TextEditIntent?) -> Bool {
        clearDictationContext()
        if let intent {
            activeTextEditIntent = intent
            activeTextEditTarget = TextEditTargetCapture.snapshot(
                in: frontmostSnapshot,
                allowFocusedValue: intent == .command
            )
            return activeTextEditTarget != nil
        }

        clearTextEditRequest()
        let focusedTextContext = TextEditTargetCapture.focusedTextContext(in: frontmostSnapshot)
        activeDictationContextBefore = focusedTextContext.before
        activeDictationContextAfter = focusedTextContext.after
        return true
    }

    func toggleCommandTextEdit() async {
        if startInProgress {
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
        if startInProgress {
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
        if startInProgress {
            stopAfterStart = true
            return
        }
        autoStopTask?.cancel(); autoStopTask = nil
        guard state == .recording else { return }
        guard let sessionID = activeSessionID, let cancelToken = activeCancelToken else {
            reportError("Internal state error: missing dictation session")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        // Keep the recorder open briefly after the stop trigger so the final
        // syllable is not cut off. SFSpeech is ended after the tail so the
        // preview can include the same audio that goes to the Mac ASR.
        transition(to: .transcribing)
        try? await Task.sleep(nanoseconds: BridgeAudioRecordingContract.stopTailBufferNanoseconds)
        guard await isActive(sessionID: sessionID, token: cancelToken) else {
            if let stoppedURL = recorder.stop() {
                try? FileManager.default.removeItem(at: stoppedURL)
            }
            return
        }
        let url = recorder.stop()
        await endLivePartialPreviewAudio()
        audioLevel = 0

        guard let url else {
            reportError("No audio captured")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }

        let snapshot = frontmostSnapshot
        let selectedCorrectionMode = AppSettings.correctionMode
        let selectedTranscriptionLanguageIDs: [String]
        do {
            selectedTranscriptionLanguageIDs = try transcriptionLanguageIDs(for: selectedCorrectionMode)
        } catch {
            try? FileManager.default.removeItem(at: url)
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        let debugLog = DebugLogStore.begin(
            source: AppSettings.processingMode == .client ? "mac-client" : "mac",
            audioURL: url,
            selectedCorrectionMode: selectedCorrectionMode,
            languageIDs: selectedTranscriptionLanguageIDs,
            appName: snapshot?.localizedName,
            bundleID: snapshot?.bundleID,
            appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
        )

        if AppSettings.processingMode == .client {
            await processWithRemoteBridge(
                audioURL: url,
                debugLog: debugLog,
                sessionID: sessionID,
                cancelToken: cancelToken,
                snapshot: snapshot,
                selectedCorrectionMode: selectedCorrectionMode
            )
            return
        }

        var didRecordASR = false
        let asrStarted = Date()
        do {
            let asrResult = try await asrService(for: selectedCorrectionMode).transcribeResult(
                audioFileURL: url,
                languageIDs: selectedTranscriptionLanguageIDs
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

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                transition(to: .correcting)
                do {
                    let spokenInstruction: String
                    if !selectedCorrectionMode.usesRefine {
                        spokenInstruction = trimmed
                        lastWarning = asrWarning
                    } else {
                        let request = buildCorrectionRequest(
                            rawTranscript: trimmed,
                            alternateTranscripts: alternateTranscripts,
                            asrHypotheses: asrHypotheses,
                            sourceHypotheses: asrResult.sourceHypotheses
                        )
                        let correctionStarted = Date()
                        do {
                            let result = try await corrector.correct(request, timeoutMs: AppSettings.correctionTimeoutMs)
                            try await ensureActive(sessionID: sessionID, token: cancelToken)
                            let normalizedResult = normalizeResult(result, correctionMode: request.correctionMode)
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
                                correctionMode: request.correctionMode
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
                                timeoutMs: AppSettings.correctionTimeoutMs
                            )
                        }
                    }
                    guard !spokenInstruction.isEmpty else {
                        reportError("Dictation produced an empty edit command")
                        scheduleAutoReset(after: Self.errorResetDelay)
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
                        appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
                    )
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    DebugLogStore.recordCorrection(
                        debugLog,
                        mode: selectedCorrectionMode,
                        text: result.text,
                        status: "text_edit_\(editIntent.rawValue)",
                        latencyMs: elapsedMs(since: editStarted),
                        timeoutMs: AppSettings.correctionTimeoutMs
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
                    reportError("Text edit failed: \(error.localizedDescription)")
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
                    timeoutMs: AppSettings.correctionTimeoutMs
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
            let request = buildCorrectionRequest(
                rawTranscript: trimmed,
                alternateTranscripts: alternateTranscripts,
                asrHypotheses: asrHypotheses,
                sourceHypotheses: asrResult.sourceHypotheses
            )
            let correctionStarted = Date()
            do {
                let result = try await corrector.correct(request, timeoutMs: AppSettings.correctionTimeoutMs)
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                let normalizedResult = normalizeResult(result, correctionMode: request.correctionMode)
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: normalizedResult.text,
                    status: "ok",
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
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
                    correctionMode: request.correctionMode
                )
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: fallbackResult.text,
                    status: statusLabel,
                    error: error.localizedDescription,
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
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
            transition(to: .idle)
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
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func handleAudioConfigurationChanged() async {
        if startInProgress {
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
    }

    private func clearTextEditRequest() {
        activeTextEditTarget = nil
        activeTextEditIntent = nil
    }

    private func clearDictationContext() {
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
    }

    private func clearPreviewState() {
        previewCorrectionMode = nil
        voicePreviewHUDExpanded = false
        lastWarning = nil
    }

    func reportError(_ message: String) {
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        clearActiveSession()
        clearTextEditRequest()
        clearDictationContext()
        clearPreviewState()
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        teardownLivePartialPreview(clearText: true)
        lastError = message
        lastWarning = nil
        Log.coordinator.error("\(message, privacy: .public)")
        DictationErrorLog.shared.record(message)
        DictationSoundPlayer.playError()
        state = .error
    }

    func reset(keepVoicePreviewExpanded: Bool = false) {
        autoStopTask?.cancel()
        autoStopTask = nil
        resetTask?.cancel()
        resetTask = nil
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        clearActiveSession()
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        lastError = nil
        lastWarning = nil
        lastTranscript = ""
        lastCorrected = ""
        clearPreviewState()
        voicePreviewHUDExpanded = keepVoicePreviewExpanded
        frontmostSnapshot = nil
        clearTextEditRequest()
        clearDictationContext()
        audioLevel = 0
        teardownLivePartialPreview(clearText: true)
        state = .idle
    }

    /// Cancels any active phase, tears down recording if needed, cancels
    /// pending timers, and returns to idle without inserting text.
    func cancelDictation() async {
        if state == .recording {
            DictationSoundPlayer.playStop()
        }
        autoStopTask?.cancel(); autoStopTask = nil
        resetTask?.cancel();     resetTask = nil
        await activeCancelToken?.cancel()
        clearActiveSession()
        clearTextEditRequest()
        clearDictationContext()
        clearPreviewState()
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        audioLevel = 0
        reset()
    }

    func captureFrontmost() {
        frontmostSnapshot = FrontmostAppCapture.snapshot()
    }

    func setAudioLevel(_ level: Float) {
        audioLevel = max(0, min(1, level))
    }

    func shutdown() {
        autoStopTask?.cancel()
        resetTask?.cancel()
        Task { await activeCancelToken?.cancel() }
        clearActiveSession()
        clearTextEditRequest()
        clearDictationContext()
        clearPreviewState()
        recordingStartedAt = nil
        _ = recorder.stop()
        teardownLivePartialPreview(clearText: true)
    }

    // MARK: - Mode switching

    /// Style chips in the HUD action bar refine the focused input's current
    /// text in place. Only valid while idle with the bar expanded — during an
    /// active dictation the chips are disabled.
    func requestCorrectionModeChange(to newMode: CorrectionMode) async {
        guard canRefineFocusedInputFromHUD else { return }
        await refineFocusedInput(to: newMode)
    }

    // MARK: - Request building

    private func buildCorrectionRequest(
        rawTranscript: String,
        correctionModeOverride: CorrectionMode? = nil,
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = [],
        sourceHypotheses: [ASRSourceHypothesis] = []
    ) -> CorrectionRequest {
        let snapshot = frontmostSnapshot
        let category = AppCategory.from(bundleID: snapshot?.bundleID)
        let correctionMode = correctionModeOverride ?? AppSettings.correctionMode
        let alternateForRequest = Self.combinedAlternateTranscripts(
            primaryTranscript: rawTranscript,
            candidates: alternateTranscripts.map(Optional.some)
        )
        return CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName:  snapshot?.localizedName,
            frontmostBundleID: snapshot?.bundleID,
            appCategory: category,
            languageIDs: AppSettings.activeLanguageIDs,
            rawTranscript: rawTranscript,
            contextBefore: activeDictationContextBefore,
            contextAfter: activeDictationContextAfter,
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot(),
            alternateTranscripts: alternateForRequest,
            asrHypotheses: asrHypotheses,
            sourceHypotheses: sourceHypotheses
        )
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
        let lines = trimmed.components(separatedBy: .newlines).map { line -> String in
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return lines.joined(separator: "\n")
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

    private func asrService(for correctionMode: CorrectionMode) throws -> ASRService {
        ASRFactory.shared.get(sources: try recognitionSources(for: correctionMode))
    }

    private func validateCorrectionModeAvailable(_ correctionMode: CorrectionMode) throws {
        guard AppSettings.isCorrectionModeAvailable(correctionMode) else {
            throw BridgeServiceError.invalidRequest("Fast mode requires Qwen ASR enabled on Mac")
        }
    }

    private func recognitionSources(for correctionMode: CorrectionMode) throws -> [RecognitionSource] {
        try validateCorrectionModeAvailable(correctionMode)
        guard AppSettings.processingMode != .client else {
            return correctionMode == .fast ? [.qwen] : AppSettings.enabledRecognitionSources
        }
        return correctionMode == .fast ? [.qwen] : AppSettings.enabledRecognitionSources
    }

    private func transcriptionLanguageIDs(for correctionMode: CorrectionMode) throws -> [String] {
        guard AppSettings.processingMode != .client else { return AppSettings.clientLanguageIDs }
        return ASRLanguageSelection.validatedIDs(
            AppSettings.asrLanguageIDs,
            sources: try recognitionSources(for: correctionMode)
        )
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

    private func makeLivePartialPreviewPCMHandlerIfAvailable() async -> ((AVAudioPCMBuffer) -> Void)? {
        teardownLivePartialPreview(clearText: true)
        if AppSettings.processingMode == .client {
            switch AppSettings.voiceLivePreviewSource {
            case .off:
                return nil
            case .appleSpeech:
                return makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(requiresEnabledRecognitionSource: false)
            case .qwen, .nvidiaNemotron:
                return await makeRemoteBridgeLivePartialPreviewPCMHandlerIfAvailable()
            }
        }
        switch AppSettings.voiceLivePreviewSource {
        case .off:
            return nil
        case .qwen:
            return makeASRLivePartialPreviewPCMHandlerIfAvailable(source: .qwen)
        case .appleSpeech:
            return makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable()
        case .nvidiaNemotron:
            return makeASRLivePartialPreviewPCMHandlerIfAvailable(source: .nvidiaNemotron)
        }
    }

    private func makeRemoteBridgeLivePartialPreviewPCMHandlerIfAvailable() async -> ((AVAudioPCMBuffer) -> Void)? {
        let source = AppSettings.voiceLivePreviewSource
        guard source == .qwen || source == .nvidiaNemotron else {
            if source != .off {
                Log.bridge.notice("Mac client live preview skipped: source \(source.rawValue, privacy: .public) is not bridge-streamable")
            }
            return nil
        }
        let displaysLivePartial = activeTextEditIntent != .command
        do {
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: false)
            let snapshot = frontmostSnapshot
            let streamer = RemoteBridgeLivePreviewStreamer(
                client: resolved.client,
                languageIDs: AppSettings.clientLanguageIDs,
                correctionMode: AppSettings.correctionMode,
                livePreviewSource: source,
                appSnapshot: snapshot,
                appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                onTranscript: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.applyLivePartialPreview(text, displaysLivePartial: displaysLivePartial)
                    }
                },
                onFailure: { message in
                    Log.bridge.notice("Mac client live preview failed: \(message, privacy: .public)")
                }
            )
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
        source: VoiceLivePreviewSource
    ) -> ((AVAudioPCMBuffer) -> Void)? {
        let displaysLivePartial = activeTextEditIntent != .command
        do {
            let lease = try ASRLivePreviewLeaseFactory.take(
                source: source,
                requestedLanguageIDs: AppSettings.asrLanguageIDs,
                diagnosticID: UUID().uuidString
            ) { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.applyLivePartialPreview(text, displaysLivePartial: displaysLivePartial)
                }
            }
            guard let handler = makeASRLivePreviewPCMHandler(session: lease.session) else {
                lease.returnIdle(reason: "mac_preview_unsupported_session")
                return nil
            }
            asrLivePreviewLease = lease
            return handler
        } catch {
            Log.asr.notice("ASR live preview unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable() -> ((AVAudioPCMBuffer) -> Void)? {
        makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(requiresEnabledRecognitionSource: true)
    }

    private func makeAppleSpeechLivePartialPreviewPCMHandlerIfAvailable(
        requiresEnabledRecognitionSource: Bool
    ) -> ((AVAudioPCMBuffer) -> Void)? {
        guard !requiresEnabledRecognitionSource || AppSettings.enabledRecognitionSources.contains(.appleSpeech) else {
            return nil
        }
        guard let localeID = AppSettings.activeLanguageIDs.lazy.compactMap({
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
        if AppSettings.punctuationPreference != .spaces {
            request.addsPunctuation = true
        }

        let displaysLivePartial = activeTextEditIntent != .command
        liveSpeechRecognizer = recognizer
        liveSpeechRequest = request
        liveSpeechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Callback fires off the main actor — hop back before @Published
            // mutation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.applyLivePartialPreview(text, displaysLivePartial: displaysLivePartial)
                }
                if error != nil {
                    self.teardownLivePartialPreview(clearText: false)
                }
            }
        }

        return makeAppleSpeechLivePreviewPCMHandler(request: request)
    }

    private func applyLivePartialPreview(_ rawText: String, displaysLivePartial: Bool) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if displaysLivePartial {
            livePartialTranscript = text
        }
    }

    /// Called when stopDictation() pulls the audio file. Closes the audio side
    /// of the request so the recognizer finalises its last partial. We keep
    /// `livePartialTranscript` on screen until the Mac final replaces it.
    func endLivePartialPreviewAudio() async {
        remoteBridgeLivePreviewStreamer?.finish()
        remoteBridgeLivePreviewStreamer = nil
        liveSpeechRequest?.endAudio()
        if let lease = asrLivePreviewLease {
            asrLivePreviewLease = nil
            let completed = await lease.session.finishInputAndWaitForFinal(
                timeout: Self.asrLivePreviewFinishTimeout
            )
            if completed {
                lease.returnIdle(reason: "mac_preview_finished")
            } else {
                lease.session.terminate(reason: "mac_preview_finish_timeout")
                lease.preloadReplacement()
            }
        }
    }

    /// Called after the Mac final result is applied (or on reset / error).
    func teardownLivePartialPreview(clearText: Bool) {
        remoteBridgeLivePreviewStreamer?.cancel()
        remoteBridgeLivePreviewStreamer = nil
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        liveSpeechRequest = nil
        liveSpeechRecognizer = nil
        if let lease = asrLivePreviewLease {
            asrLivePreviewLease = nil
            if lease.session is QwenLlamaLivePreviewSession {
                lease.returnIdle(reason: "mac_preview_cancelled")
                if clearText {
                    livePartialTranscript = ""
                }
                return
            }
            Task { @MainActor in
                let reset = await lease.session.cancelInputAndWaitForReset(
                    timeout: Self.asrLivePreviewResetTimeout
                )
                if reset {
                    lease.returnIdle(reason: "mac_preview_cancelled")
                } else {
                    lease.session.terminate(reason: "mac_preview_cancel_timeout")
                    lease.preloadReplacement()
                }
            }
        }
        if clearText {
            livePartialTranscript = ""
        }
    }

    private func normalizeResult(_ result: CorrectionResult, correctionMode: CorrectionMode) -> CorrectionResult {
        var normalized = result
        normalized.text = LocaleTextNormalizer.normalize(result.text, languageIDs: AppSettings.activeLanguageIDs)
        normalized.text = TranscriptPostProcessor.clean(
            normalized.text,
            languageIDs: AppSettings.activeLanguageIDs,
            preserveLineBreaks: correctionMode == .structurePlus,
            numberPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference
        )
        return normalized
    }

    private func processWithRemoteBridge(
        audioURL: URL,
        debugLog: DebugLogHandle?,
        sessionID: UUID,
        cancelToken: CommitCancellationToken,
        snapshot: FrontmostAppSnapshot?,
        selectedCorrectionMode: CorrectionMode
    ) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let started = Date()
        do {
            let appCategory = AppCategory.from(bundleID: snapshot?.bundleID)
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: false)
            let client = resolved.client
            let response = try await client.dictate(
                audioURL: audioURL,
                languageIDs: AppSettings.clientLanguageIDs,
                correctionMode: selectedCorrectionMode,
                appSnapshot: snapshot,
                appCategory: appCategory,
                contextBefore: activeDictationContextBefore,
                contextAfter: activeDictationContextAfter,
                includeRawTranscript: true
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

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                let spoken = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else {
                    reportError("Remote transcript was empty")
                    scheduleAutoReset(after: Self.errorResetDelay)
                    return
                }
                transition(to: .correcting)
                let editResponse = try await client.editText(
                    intent: editIntent,
                    contextBefore: editTarget.contextBefore,
                    targetText: editTarget.targetText,
                    contextAfter: editTarget.contextAfter,
                    spokenInstruction: spoken,
                    languageIDs: AppSettings.clientLanguageIDs,
                    appSnapshot: snapshot,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: selectedCorrectionMode,
                    text: editResponse.text,
                    status: "remote_text_edit_\(editIntent.rawValue)",
                    error: editResponse.editError,
                    latencyMs: editResponse.editLatencyMs ?? editResponse.latencyMs,
                    timeoutMs: AppSettings.correctionTimeoutMs
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

            transition(to: .correcting)
            let result = normalizeResult(
                CorrectionResult(action: .commit, text: response.text, risk: .low),
                correctionMode: selectedCorrectionMode
            )
            DebugLogStore.recordCorrection(
                debugLog,
                mode: selectedCorrectionMode,
                text: result.text,
                status: response.correctionStatus ?? "remote_unknown",
                error: response.correctionError,
                latencyMs: response.correctionLatencyMs ?? response.latencyMs,
                timeoutMs: AppSettings.correctionTimeoutMs
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
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
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
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func refineFocusedInput(to newMode: CorrectionMode) async {
        guard !startInProgress else { return }
        if !AppPermissions.accessibilityTrusted {
            AppPermissions.requestAccessibility()
        }

        let snapshot = FrontmostAppCapture.snapshot()
        guard let target = TextEditTargetCapture.snapshot(in: snapshot, allowFocusedValue: true) else {
            reportError("Select text or focus a text field first")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }

        let sourceText = target.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

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
            if !newMode.usesRefine {
                try validateCorrectionModeAvailable(newMode)
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                lastWarning = nil
                text = sourceText
            } else if AppSettings.processingMode == .client {
                let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: false)
                let response = try await resolved.client.refine(
                    sessionID: nil,
                    rawTranscript: sourceText,
                    languageIDs: AppSettings.clientLanguageIDs,
                    correctionMode: newMode,
                    appSnapshot: snapshot,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                    contextBefore: target.contextBefore,
                    contextAfter: target.contextAfter
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                lastWarning = Self.isCorrectionDegradedStatus(response.correctionStatus)
                    ? Self.previewWithoutRefineMessage(for: response.correctionStatus)
                    : nil
                text = normalizeResult(
                    CorrectionResult(action: .commit, text: response.text, risk: .low),
                    correctionMode: newMode
                ).text
            } else {
                let request = CorrectionRequest(
                    correctionMode: newMode,
                    frontmostAppName: snapshot?.localizedName,
                    frontmostBundleID: snapshot?.bundleID,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                    languageIDs: AppSettings.activeLanguageIDs,
                    rawTranscript: sourceText,
                    contextBefore: target.contextBefore,
                    contextAfter: target.contextAfter,
                    numberOutputPreference: AppSettings.numberOutputPreference,
                    punctuationPreference: AppSettings.punctuationPreference,
                    userDictionary: dictionary.sortedSnapshot()
                )
                do {
                    let result = try await corrector.correct(request, timeoutMs: AppSettings.correctionTimeoutMs)
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    lastWarning = nil
                    text = normalizeResult(result, correctionMode: request.correctionMode).text
                } catch {
                    if error is CancellationError {
                        throw error
                    }
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    let status = Self.refineFailureStatus(for: error)
                    lastWarning = Self.previewWithoutRefineMessage(for: status)
                    text = normalizeResult(
                        CorrectionResult(action: .commit, text: sourceText, risk: .medium),
                        correctionMode: request.correctionMode
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
            try await ensureActive(sessionID: sessionID, token: cancelToken)
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
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            reportError("Refine failed: \(error.localizedDescription)")
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    // MARK: - Commit

    private func finish(
        with result: CorrectionResult,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reportError("Refine returned empty text")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        transition(to: .inserting)
        do {
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            try await committer.commit(result.text, to: frontmostSnapshot, cancelToken: cancelToken)
            try await ensureActive(sessionID: sessionID, token: cancelToken)
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
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            reportError(error.localizedDescription)
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
            try await ensureActive(sessionID: sessionID, token: cancelToken)
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
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            reportError(error.localizedDescription)
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
