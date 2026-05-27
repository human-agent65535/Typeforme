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
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastCorrected: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var frontmostSnapshot: FrontmostAppSnapshot?
    @Published private(set) var previewCorrectionMode: CorrectionMode?
    @Published private(set) var previewKind: VoicePreviewKind = .dictation
    @Published private(set) var previewAnchorRect: CGRect?
    /// Live-preview transcript fed by Apple Speech in parallel with recording.
    /// Held in place from the first partial until the Mac ASR + correction
    /// final replaces it, then cleared. Empty string = no preview (unsupported
    /// language, denied permission, toggle off, or not recording).
    @Published private(set) var livePartialTranscript: String = ""

    private let recorder = AudioRecorder()
    /// Resolved per-request so provider/model setting changes take effect immediately.
    private var asr: ASRService { ASRFactory.shared.get() }
    private var corrector: CorrectorService { CorrectorFactory.shared.make() }
    private let committer = PasteboardTextCommitter()
    private let textEditService: TextEditService
    private let dictionary: UserDictionaryStore

    private var autoStopTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var activeCancelToken: CommitCancellationToken?
    private var remoteBridgeSessionID: String?
    private var activeTextEditTarget: TextEditTargetSnapshot?
    private var activeTextEditIntent: TextEditIntent?
    private var previewTextEditTarget: TextEditTargetSnapshot?
    private var previewTextEditAppSnapshot: FrontmostAppSnapshot?
    private var activeVoiceDraftTarget: VoiceDraftInsertionTarget?
    private var previewVoiceDraft: VoiceDraftTextSnapshot?
    private var previewVoiceDraftAppSnapshot: FrontmostAppSnapshot?
    private var previewRestyleSourceText: String?
    private var activeDraftCommandTargetText: String?
    private var activeDictationContextBefore = ""
    private var activeDictationContextAfter = ""
    private var startInProgress = false
    private var stopAfterStart = false
    private var recordingStartedAt: Date?
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveSpeechTask: SFSpeechRecognitionTask?
    /// Last partial text we surfaced. Snapshot at correction time so the Mac
    /// LLM gets the same string the user just saw.
    private var liveSnapshotAtCorrection: String = ""

    private static let errorResetDelay: TimeInterval = 4.0
    private static let previewResetDelay: TimeInterval = 12.0
    private static let minimumToggleStopInterval: TimeInterval = 0.6

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
        case .preview, .success, .error:
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
        if AppSettings.autoCommit && !AccessibilityPermissions.isTrusted {
            AccessibilityPermissions.requestTrustPrompt()
        }

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        previewCorrectionMode = nil
        previewKind = .dictation
        previewAnchorRect = nil
        previewTextEditTarget = nil
        previewTextEditAppSnapshot = nil
        activeVoiceDraftTarget = nil
        previewVoiceDraft = nil
        previewVoiceDraftAppSnapshot = nil
        previewRestyleSourceText = nil
        activeDraftCommandTargetText = nil
        startInProgress = true
        stopAfterStart = false
        resetTask?.cancel(); resetTask = nil
        captureFrontmost()
        let focusedTextContext = TextEditTargetCapture.focusedTextContext(in: frontmostSnapshot)
        activeDictationContextBefore = focusedTextContext.before
        activeDictationContextAfter = focusedTextContext.after
        activeTextEditIntent = intent
        if let intent {
            activeTextEditTarget = TextEditTargetCapture.snapshot(
                in: frontmostSnapshot,
                allowFocusedValue: intent == .command
            )
            guard activeTextEditTarget != nil else {
                startInProgress = false
                activeSessionID = nil
                activeCancelToken = nil
                activeTextEditIntent = nil
                reportError("Select text or focus a text field first")
                scheduleAutoReset(after: Self.errorResetDelay)
                return
            }
        } else if AppSettings.voiceUXMode == .classic {
            activeTextEditTarget = TextEditTargetCapture.snapshot(
                in: frontmostSnapshot,
                allowFocusedValue: false
            )
            activeTextEditIntent = activeTextEditTarget == nil ? nil : .repairSelection
        } else {
            activeTextEditTarget = nil
            activeTextEditIntent = nil
            activeVoiceDraftTarget = TextEditTargetCapture.draftInsertionTarget(in: frontmostSnapshot)
            guard activeVoiceDraftTarget != nil else {
                startInProgress = false
                activeSessionID = nil
                activeCancelToken = nil
                reportError("Focus an editable text field first")
                scheduleAutoReset(after: Self.errorResetDelay)
                return
            }
        }

        let livePreviewPCMHandler = makeLivePartialPreviewPCMHandlerIfAvailable()
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
            activeSessionID = nil
            activeCancelToken = nil
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
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
        case .preview, .success, .error:
            reset()
            await startDictation(intent: .command)
        default:
            await cancelDictation()
        }
    }

    func toggleDraftCommand() async {
        if startInProgress {
            Log.coordinator.debug("draft command toggle ignored while dictation start is in progress")
            return
        }

        switch state {
        case .preview:
            await startDraftCommand()
        case .recording where activeDraftCommandTargetText != nil:
            guard !shouldIgnoreEarlyToggleStop() else { return }
            await stopDictation()
        default:
            break
        }
    }

    private func startDraftCommand() async {
        guard state == .preview, !startInProgress else { return }
        let targetText = lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetText.isEmpty else { return }
        if !AccessibilityPermissions.isTrusted {
            AccessibilityPermissions.requestTrustPrompt()
        }

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        activeDraftCommandTargetText = targetText
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        startInProgress = true
        stopAfterStart = false
        resetTask?.cancel(); resetTask = nil

        let livePreviewPCMHandler = makeLivePartialPreviewPCMHandlerIfAvailable()
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
            scheduleAutoStop(after: AppSettings.maxRecordingDuration)
            if stopAfterStart {
                stopAfterStart = false
                await stopDictation()
            }
        } catch {
            teardownLivePartialPreview(clearText: true)
            startInProgress = false
            stopAfterStart = false
            activeDraftCommandTargetText = nil
            guard activeSessionID == sessionID else { return }
            activeSessionID = nil
            activeCancelToken = nil
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
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
        let url = recorder.stop()
        // Close the SFSpeech audio side so it finalises its last partial; we
        // intentionally KEEP `livePartialTranscript` on screen until the Mac
        // final replaces it. liveSnapshotAtCorrection is captured here so the
        // value flowing into the corrector matches what the user just saw.
        endLivePartialPreviewAudio()
        audioLevel = 0
        transition(to: .transcribing)

        guard let url else {
            reportError("No audio captured")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }

        let snapshot = frontmostSnapshot
        let selectedCorrectionMode = AppSettings.correctionMode
        let debugLog = DebugLogStore.begin(
            source: AppSettings.processingMode == .client ? "mac-client" : "mac",
            audioURL: url,
            selectedCorrectionMode: selectedCorrectionMode,
            languageIDs: AppSettings.activeLanguageIDs,
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

        remoteBridgeSessionID = nil
        var didRecordASR = false
        let asrStarted = Date()
        do {
            let raw = try await asr.transcribe(audioFileURL: url, languageIDs: AppSettings.asrLanguageIDs)
            DebugLogStore.recordASR(
                debugLog,
                text: raw,
                status: "ok",
                latencyMs: elapsedMs(since: asrStarted),
                alternateText: liveSnapshotAtCorrection
            )
            didRecordASR = true
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            lastTranscript = raw
            try? FileManager.default.removeItem(at: url)

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.asr.notice("empty transcript — returning to idle without commit")
                activeSessionID = nil
                activeCancelToken = nil
                activeDraftCommandTargetText = nil
                activeDictationContextBefore = ""
                activeDictationContextAfter = ""
                activeTextEditTarget = nil
                activeTextEditIntent = nil
                transition(to: .idle)
                return
            }

            if let draftTarget = activeDraftCommandTargetText {
                activeDraftCommandTargetText = nil
                transition(to: .correcting)
                do {
                    let editStarted = Date()
                    let result = try await textEditService.edit(
                        intent: .command,
                        contextBefore: "",
                        targetText: draftTarget,
                        contextAfter: "",
                        spokenInstruction: trimmed,
                        languageIDs: AppSettings.asrLanguageIDs,
                        appName: snapshot?.localizedName,
                        bundleID: snapshot?.bundleID,
                        appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
                    )
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    DebugLogStore.recordCorrection(
                        debugLog,
                        mode: selectedCorrectionMode,
                        text: result.text,
                        status: "draft_command",
                        latencyMs: elapsedMs(since: editStarted),
                        timeoutMs: AppSettings.correctionTimeoutMs
                    )
                    previewCorrectionMode = selectedCorrectionMode
                    previewKind = .dictation
                    lastCorrected = result.text
                    try await replaceVoiceDraftIfNeeded(result.text, sessionID: sessionID, cancelToken: cancelToken)
                    previewRestyleSourceText = stableRestyleText(result.text)
                    activeSessionID = nil
                    activeCancelToken = nil
                    PasteboardTextCommitter.copyForManualPaste(result.text)
                    transition(to: .preview)
                    schedulePreviewResetIfNeeded()
                } catch {
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    reportError("Draft command failed: \(error.localizedDescription)")
                    scheduleAutoReset(after: Self.errorResetDelay)
                }
                return
            }

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                transition(to: .correcting)
                do {
                    let editStarted = Date()
                    let result = try await textEditService.edit(
                        intent: editIntent,
                        contextBefore: editTarget.contextBefore,
                        targetText: editTarget.targetText,
                        contextAfter: editTarget.contextAfter,
                        spokenInstruction: trimmed,
                        languageIDs: AppSettings.asrLanguageIDs,
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

            transition(to: .correcting)
            let request = buildCorrectionRequest(rawTranscript: trimmed)
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
                lastCorrected = normalizedResult.text
                await finish(with: normalizedResult, sessionID: sessionID, cancelToken: cancelToken)
            } catch CorrectorError.empty {
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: nil,
                    status: "empty",
                    error: CorrectorError.empty.localizedDescription,
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                Log.coordinator.notice("corrector returned empty — back to idle")
                activeSessionID = nil
                activeCancelToken = nil
                activeTextEditTarget = nil
                activeTextEditIntent = nil
                activeDictationContextBefore = ""
                activeDictationContextAfter = ""
                transition(to: .idle)
            } catch let correctorError as CorrectorError where
                correctorError == .timeout
                || Self.isCorrectorRecoverableError(correctorError)
            {
                // Timeout / network / validation / backend-unavailable: keep
                // the dictation usable by committing the raw transcript so
                // the user doesn't lose the audio just because the styler is
                // down. `.empty` is intentionally NOT in this set (handled
                // above) — there's no raw text to fall back to.
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                let fallbackResult = normalizeResult(
                    CorrectionResult(action: .commit, text: trimmed, risk: .medium),
                    correctionMode: request.correctionMode
                )
                let statusLabel: String = correctorError == .timeout ? "timeout" : "fallback"
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: fallbackResult.text,
                    status: statusLabel,
                    error: correctorError.localizedDescription,
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                previewCorrectionMode = request.correctionMode
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
                    alternateText: liveSnapshotAtCorrection
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

    /// `.unavailable` / `.requestFailed` / `.validationFailed` mean ASR
    /// succeeded but the styling backend let us down — we can still commit
    /// the raw transcript so the user doesn't lose dictation. `.empty` and
    /// `.timeout` are handled by their own catches.
    private static func isCorrectorRecoverableError(_ error: CorrectorError) -> Bool {
        switch error {
        case .unavailable, .requestFailed, .validationFailed:
            return true
        case .timeout, .empty:
            return false
        }
    }

    func reportError(_ message: String) {
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        activeSessionID = nil
        activeCancelToken = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        previewCorrectionMode = nil
        previewKind = .dictation
        previewAnchorRect = nil
        previewTextEditTarget = nil
        previewTextEditAppSnapshot = nil
        activeVoiceDraftTarget = nil
        previewVoiceDraft = nil
        previewVoiceDraftAppSnapshot = nil
        previewRestyleSourceText = nil
        activeDraftCommandTargetText = nil
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        teardownLivePartialPreview(clearText: true)
        lastError = message
        Log.coordinator.error("\(message, privacy: .public)")
        state = .error
    }

    func reset() {
        autoStopTask?.cancel()
        autoStopTask = nil
        resetTask?.cancel()
        resetTask = nil
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        activeSessionID = nil
        activeCancelToken = nil
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        lastError = nil
        lastTranscript = ""
        lastCorrected = ""
        previewCorrectionMode = nil
        previewKind = .dictation
        previewAnchorRect = nil
        frontmostSnapshot = nil
        remoteBridgeSessionID = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        previewTextEditTarget = nil
        previewTextEditAppSnapshot = nil
        activeVoiceDraftTarget = nil
        previewVoiceDraft = nil
        previewVoiceDraftAppSnapshot = nil
        previewRestyleSourceText = nil
        activeDraftCommandTargetText = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        audioLevel = 0
        teardownLivePartialPreview(clearText: true)
        state = .idle
    }

    /// Cancels any active phase, tears down recording if needed, cancels
    /// pending timers, and returns to idle without inserting text.
    func cancelDictation() async {
        autoStopTask?.cancel(); autoStopTask = nil
        resetTask?.cancel();     resetTask = nil
        await activeCancelToken?.cancel()
        activeSessionID = nil
        activeCancelToken = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        previewCorrectionMode = nil
        previewKind = .dictation
        previewAnchorRect = nil
        previewTextEditTarget = nil
        previewTextEditAppSnapshot = nil
        let draftToRemove = previewVoiceDraft
        let draftAppSnapshot = previewVoiceDraftAppSnapshot
        activeVoiceDraftTarget = nil
        previewVoiceDraft = nil
        previewVoiceDraftAppSnapshot = nil
        previewRestyleSourceText = nil
        activeDraftCommandTargetText = nil
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        if state == .recording {
            if let url = recorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            _ = recorder.stop()
        }
        if let draftToRemove {
            try? await committer.removeVoiceDraft(
                draftToRemove,
                appSnapshot: draftAppSnapshot,
                cancelToken: nil
            )
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
        activeSessionID = nil
        activeCancelToken = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        previewCorrectionMode = nil
        previewKind = .dictation
        previewAnchorRect = nil
        previewTextEditTarget = nil
        previewTextEditAppSnapshot = nil
        activeVoiceDraftTarget = nil
        previewVoiceDraft = nil
        previewVoiceDraftAppSnapshot = nil
        previewRestyleSourceText = nil
        activeDraftCommandTargetText = nil
        recordingStartedAt = nil
        _ = recorder.stop()
    }

    // MARK: - Mode switching

    func requestCorrectionModeChange(to newMode: CorrectionMode) async {
        guard state == .preview else { return }
        let source = restyleSource()
        let raw = source.text
        guard !raw.isEmpty else { return }

        let previousPreviewMode = previewCorrectionMode
        previewCorrectionMode = newMode

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        resetTask?.cancel(); resetTask = nil
        transition(to: .correcting)

        if AppSettings.processingMode == .client {
            let didRestyle = await requestRemoteCorrectionModeChange(
                rawTranscript: raw,
                newMode: newMode,
                useExistingSession: source.useExistingSession,
                sessionID: sessionID,
                cancelToken: cancelToken
            )
            if !didRestyle {
                previewCorrectionMode = previousPreviewMode
            }
            return
        }

        let request = buildCorrectionRequest(rawTranscript: raw, correctionModeOverride: newMode)
        do {
            let result = try await corrector.correct(request, timeoutMs: AppSettings.correctionTimeoutMs)
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            let normalizedResult = normalizeResult(result, correctionMode: request.correctionMode)
            lastCorrected = normalizedResult.text
            try await replaceVoiceDraftIfNeeded(
                normalizedResult.text,
                sessionID: sessionID,
                cancelToken: cancelToken
            )
            copyPreviewToPasteboard(normalizedResult)
            transition(to: .preview)
            schedulePreviewResetIfNeeded()
        } catch is CancellationError {
            previewCorrectionMode = previousPreviewMode
            transition(to: .idle)
        } catch CorrectorError.empty {
            previewCorrectionMode = previousPreviewMode
            transition(to: .idle)
        } catch {
            previewCorrectionMode = previousPreviewMode
            reportError("Re-correction failed: \(error.localizedDescription)")
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    /// Insert the previewed text. Ordinary dictation inserts at the current
    /// cursor; a Voice Draft text-edit preview applies the replacement to the
    /// originally captured target.
    func commitPreview() async {
        guard state == .preview else { return }
        let text = lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let snapshot = FrontmostAppCapture.snapshot()
        let textEditTarget = previewTextEditTarget
        let textEditAppSnapshot = previewTextEditAppSnapshot
        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        resetTask?.cancel(); resetTask = nil
        transition(to: .inserting)

        do {
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            if let draft = previewVoiceDraft {
                try await committer.acceptVoiceDraft(
                    draft,
                    appSnapshot: previewVoiceDraftAppSnapshot ?? snapshot,
                    cancelToken: cancelToken
                )
            } else if let textEditTarget {
                try await committer.commitTextEdit(
                    text,
                    target: textEditTarget,
                    appSnapshot: textEditAppSnapshot ?? snapshot,
                    cancelToken: cancelToken
                )
            } else {
                try await committer.commit(text, to: snapshot, cancelToken: cancelToken)
            }
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            previewKind = .dictation
            previewAnchorRect = nil
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
            previewVoiceDraft = nil
            previewVoiceDraftAppSnapshot = nil
            previewRestyleSourceText = nil
            transition(to: .success)
            scheduleAutoReset(after: 0.8)
        } catch is CancellationError {
            previewKind = .dictation
            previewAnchorRect = nil
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
            previewVoiceDraft = nil
            previewVoiceDraftAppSnapshot = nil
            previewRestyleSourceText = nil
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            previewKind = .dictation
            previewAnchorRect = nil
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
            previewVoiceDraft = nil
            previewVoiceDraftAppSnapshot = nil
            previewRestyleSourceText = nil
            transition(to: .idle)
        } catch {
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    // MARK: - Request building

    private func buildCorrectionRequest(
        rawTranscript: String,
        correctionModeOverride: CorrectionMode? = nil
    ) -> CorrectionRequest {
        let snapshot = frontmostSnapshot
        let category = AppCategory.from(bundleID: snapshot?.bundleID)
        let correctionMode = correctionModeOverride ?? AppSettings.correctionMode
        // Snapshot the live partial so the corrector sees the same text the
        // user just saw on screen. Neutral framing (see baseSystem prompt) —
        // never attributed by source name in the prompt itself.
        let alternate = liveSnapshotAtCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternateForRequest: String? = alternate.isEmpty ? nil : alternate
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
            alternateTranscript: alternateForRequest
        )
    }

    // MARK: - Live partial preview (Apple Speech, on-device only)
    //
    // Pattern mirrors iOS: SFSpeechRecognizer subscribes to the AudioRecorder
    // PCM tap and renders partial hypotheses into `livePartialTranscript` for
    // the HUD except command/wand edits, which keep the hypothesis internal.
    // The Mac ASR + correction pipeline is unchanged — Apple Speech never
    // replaces the canonical result. The last partial is captured into
    // `liveSnapshotAtCorrection` at stopDictation() time and threaded into
    // CorrectionRequest.alternateTranscript so the corrector LLM can use it
    // as a supplementary hypothesis (neutral framing — see baseSystem prompt).
    //
    // Gating: AppSettings.voiceLivePreview must be on, the primary language
    // must support on-device recognition, and authorization must be granted.
    // Any failure silently degrades to "no preview" — recording still works.

    private func makeLivePartialPreviewPCMHandlerIfAvailable() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        teardownLivePartialPreview(clearText: true)
        guard AppSettings.voiceLivePreview else { return nil }

        let primaryID = AppSettings.activeLanguageIDs.first ?? "en-US"
        let locale = Locale(identifier: primaryID)
        guard Self.supportedSpeechLocalesContain(locale) else {
            return nil
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else { return nil }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // First-time use: kick the system prompt asynchronously so the
            // NEXT recording can use it. Don't block the current one.
            SFSpeechRecognizer.requestAuthorization { _ in }
            return nil
        case .denied, .restricted:
            return nil
        @unknown default:
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
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if displaysLivePartial {
                            self.livePartialTranscript = text
                        } else {
                            self.liveSnapshotAtCorrection = text
                        }
                    }
                }
                if error != nil {
                    self.teardownLivePartialPreview(clearText: false)
                }
            }
        }

        return { [weak request] buffer in
            request?.append(buffer)
        }
    }

    private static func supportedSpeechLocalesContain(_ locale: Locale) -> Bool {
        let target = normalizedSpeechLocaleIdentifier(locale.identifier)
        return SFSpeechRecognizer.supportedLocales().contains { candidate in
            let normalized = normalizedSpeechLocaleIdentifier(candidate.identifier)
            return normalized == target || normalized.hasPrefix("\(target)-")
        }
    }

    private static func normalizedSpeechLocaleIdentifier(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    /// Called when stopDictation() pulls the audio file. Closes the audio side
    /// of the request so the recognizer finalises its last partial. We keep
    /// `livePartialTranscript` on screen until the Mac final replaces it.
    func endLivePartialPreviewAudio() {
        liveSpeechRequest?.endAudio()
        if !livePartialTranscript.isEmpty {
            liveSnapshotAtCorrection = livePartialTranscript
        }
    }

    /// Called after the Mac final result is applied (or on reset / error).
    func teardownLivePartialPreview(clearText: Bool) {
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        liveSpeechRequest = nil
        liveSpeechRecognizer = nil
        if clearText {
            livePartialTranscript = ""
            liveSnapshotAtCorrection = ""
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
            let alternateForRemote = liveSnapshotAtCorrection
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await client.dictate(
                audioURL: audioURL,
                languageIDs: AppSettings.clientLanguageIDs,
                correctionMode: selectedCorrectionMode,
                appSnapshot: snapshot,
                appCategory: appCategory,
                contextBefore: activeDictationContextBefore,
                contextAfter: activeDictationContextAfter,
                includeRawTranscript: true,
                alternateTranscript: alternateForRemote.isEmpty ? nil : alternateForRemote
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)

            let raw = response.rawTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DebugLogStore.recordASR(
                debugLog,
                text: raw.isEmpty ? nil : raw,
                status: raw.isEmpty ? "remote_no_raw" : "remote_ok",
                latencyMs: response.transcriptionLatencyMs ?? elapsedMs(since: started),
                alternateText: liveSnapshotAtCorrection
            )
            lastTranscript = raw.isEmpty ? response.text : raw
            remoteBridgeSessionID = response.sessionID

            if let draftTarget = activeDraftCommandTargetText {
                activeDraftCommandTargetText = nil
                let spoken = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else {
                    reportError("Remote transcript was empty")
                    scheduleAutoReset(after: Self.errorResetDelay)
                    return
                }
                transition(to: .correcting)
                let editResponse = try await client.editText(
                    intent: .command,
                    contextBefore: "",
                    targetText: draftTarget,
                    contextAfter: "",
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
                    status: "remote_draft_command",
                    error: editResponse.editError,
                    latencyMs: editResponse.editLatencyMs ?? editResponse.latencyMs,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                previewCorrectionMode = selectedCorrectionMode
                previewKind = .dictation
                lastCorrected = editResponse.text
                try await replaceVoiceDraftIfNeeded(
                    editResponse.text,
                    sessionID: sessionID,
                    cancelToken: cancelToken
                )
                previewRestyleSourceText = stableRestyleText(editResponse.text)
                activeSessionID = nil
                activeCancelToken = nil
                PasteboardTextCommitter.copyForManualPaste(editResponse.text)
                transition(to: .preview)
                schedulePreviewResetIfNeeded()
                return
            }

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                let spoken = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
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
                status: response.correctionStatus,
                error: response.correctionError,
                latencyMs: response.correctionLatencyMs ?? response.latencyMs,
                timeoutMs: AppSettings.correctionTimeoutMs
            )
            previewCorrectionMode = selectedCorrectionMode
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
                alternateText: liveSnapshotAtCorrection
            )
            guard await isActive(sessionID: sessionID, token: cancelToken) else { return }
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func requestRemoteCorrectionModeChange(
        rawTranscript: String,
        newMode: CorrectionMode,
        useExistingSession: Bool,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async -> Bool {
        do {
            let snapshot = frontmostSnapshot
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: false)
            let response = try await resolved.client.restyle(
                sessionID: useExistingSession ? remoteBridgeSessionID : nil,
                rawTranscript: rawTranscript,
                languageIDs: AppSettings.clientLanguageIDs,
                correctionMode: newMode,
                appSnapshot: snapshot,
                appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                contextBefore: activeDictationContextBefore,
                contextAfter: activeDictationContextAfter
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            let result = normalizeResult(
                CorrectionResult(action: .commit, text: response.text, risk: .low),
                correctionMode: newMode
            )
            remoteBridgeSessionID = response.sessionID
            previewCorrectionMode = newMode
            lastCorrected = result.text
            try await replaceVoiceDraftIfNeeded(result.text, sessionID: sessionID, cancelToken: cancelToken)
            copyPreviewToPasteboard(result)
            transition(to: .preview)
            schedulePreviewResetIfNeeded()
            return true
        } catch is CancellationError {
            transition(to: .idle)
            return false
        } catch {
            reportError("Remote re-correction failed: \(error.localizedDescription)")
            scheduleAutoReset(after: Self.errorResetDelay)
            return false
        }
    }

    // MARK: - Commit

    private func finish(
        with result: CorrectionResult,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        if AppSettings.voiceUXMode == .voiceDraft {
            await finishVoiceDraft(
                result.text,
                target: activeVoiceDraftTarget,
                appSnapshot: frontmostSnapshot,
                sessionID: sessionID,
                cancelToken: cancelToken,
                restyleSource: lastTranscript
            )
            return
        }

        let shouldAutoCommit = AppSettings.autoCommit && AppSettings.voiceUXMode == .classic
        if shouldAutoCommit {
            previewKind = .dictation
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
            transition(to: .inserting)
            do {
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                try await committer.commit(result.text, to: frontmostSnapshot, cancelToken: cancelToken)
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                transition(to: .success)
                scheduleAutoReset(after: 0.8)
            } catch is CancellationError {
                transition(to: .idle)
            } catch TextCommitterError.cancelled {
                transition(to: .idle)
            } catch {
                reportError(error.localizedDescription)
                scheduleAutoReset(after: Self.errorResetDelay)
            }
        } else {
            activeSessionID = nil
            activeCancelToken = nil
            previewKind = .dictation
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
            previewRestyleSourceText = nil
            copyPreviewToPasteboard(result)
            transition(to: .preview)
            scheduleAutoReset(after: Self.previewResetDelay)
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
            activeSessionID = nil
            activeCancelToken = nil
            transition(to: .idle)
            return
        }

        let shouldAutoCommit = intent == .command
            || (AppSettings.autoCommit && AppSettings.voiceUXMode == .classic)
        if shouldAutoCommit {
            previewKind = .dictation
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
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
                activeTextEditTarget = nil
                activeTextEditIntent = nil
                transition(to: .success)
                scheduleAutoReset(after: 0.8)
            } catch is CancellationError {
                transition(to: .idle)
            } catch TextCommitterError.cancelled {
                transition(to: .idle)
            } catch {
                reportError(error.localizedDescription)
                scheduleAutoReset(after: Self.errorResetDelay)
            }
        } else {
            if AppSettings.voiceUXMode == .voiceDraft,
               let draftTarget = TextEditTargetCapture.draftInsertionTarget(from: target) {
                await finishVoiceDraft(
                    text,
                    target: draftTarget,
                    appSnapshot: appSnapshot,
                    sessionID: sessionID,
                    cancelToken: cancelToken,
                    kind: .textEdit,
                    restyleSource: text
                )
                return
            }

            activeSessionID = nil
            activeCancelToken = nil
            activeTextEditTarget = nil
            activeTextEditIntent = nil
            previewKind = .textEdit
            previewTextEditTarget = target
            previewTextEditAppSnapshot = appSnapshot
            previewRestyleSourceText = stableRestyleText(text)
            PasteboardTextCommitter.copyForManualPaste(text)
            transition(to: .preview)
            scheduleAutoReset(after: Self.previewResetDelay)
        }
    }

    private func finishVoiceDraft(
        _ text: String,
        target: VoiceDraftInsertionTarget?,
        appSnapshot: FrontmostAppSnapshot?,
        sessionID: UUID,
        cancelToken: CommitCancellationToken,
        kind: VoicePreviewKind = .dictation,
        restyleSource: String? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target else {
            activeSessionID = nil
            activeCancelToken = nil
            transition(to: .idle)
            return
        }

        do {
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            let draft = try await committer.insertVoiceDraft(
                trimmed,
                target: target,
                appSnapshot: appSnapshot,
                cancelToken: cancelToken
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            activeSessionID = nil
            activeCancelToken = nil
            activeTextEditTarget = nil
            activeTextEditIntent = nil
            activeVoiceDraftTarget = nil
            previewKind = kind
            previewTextEditTarget = nil
            previewTextEditAppSnapshot = nil
            previewVoiceDraft = draft
            previewVoiceDraftAppSnapshot = appSnapshot
            previewRestyleSourceText = stableRestyleText(restyleSource, fallback: trimmed)
            previewAnchorRect = draft.anchorRect
            lastCorrected = trimmed
            PasteboardTextCommitter.copyForManualPaste(trimmed)
            transition(to: .preview)
        } catch is CancellationError {
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            PasteboardTextCommitter.copyForManualPaste(trimmed)
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func replaceVoiceDraftIfNeeded(
        _ text: String,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async throws {
        guard let draft = previewVoiceDraft else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = try await committer.replaceVoiceDraft(
            trimmed,
            draft: draft,
            appSnapshot: previewVoiceDraftAppSnapshot ?? frontmostSnapshot,
            cancelToken: cancelToken
        )
        try await ensureActive(sessionID: sessionID, token: cancelToken)
        previewVoiceDraft = updated
        previewAnchorRect = updated.anchorRect
        lastCorrected = trimmed
    }

    private func schedulePreviewResetIfNeeded() {
        guard previewVoiceDraft == nil else { return }
        scheduleAutoReset(after: Self.previewResetDelay)
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

    private func scheduleAutoReset(after seconds: TimeInterval) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reset()
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

    private func copyPreviewToPasteboard(_ result: CorrectionResult) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        PasteboardTextCommitter.copyForManualPaste(text)
    }

    private func restyleSource() -> (text: String, useExistingSession: Bool) {
        if AppSettings.voiceUXMode == .voiceDraft || previewTextEditTarget != nil {
            if let text = stableRestyleText(previewRestyleSourceText) {
                return (text, false)
            }
            if let text = stableRestyleText(lastTranscript) {
                return (text, false)
            }
            if let text = stableRestyleText(lastCorrected) {
                return (text, false)
            }
        }
        return (lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private func stableRestyleText(_ text: String?, fallback: String? = nil) -> String? {
        if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

enum VoicePreviewKind: String, Sendable {
    case dictation
    case textEdit
}
