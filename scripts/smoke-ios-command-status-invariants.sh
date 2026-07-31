#!/usr/bin/env bash
# Static smoke for the intentionally small iOS keyboard command ownership flow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
app = (root / "iOS/TypeformeIOS/AppState.swift").read_text()
keyboard = (root / "iOS/TypeformeKeyboard/KeyboardViewController.swift").read_text()
rime_controller = (root / "iOS/TypeformeKeyboard/RimeInputController.swift").read_text()
shared = (root / "iOS/Shared/KeyboardBridgeModels.swift").read_text()
pip = (root / "iOS/TypeformeIOS/PiP/PiPDictationCoordinator.swift").read_text()
audio = (root / "iOS/TypeformeIOS/Recording/AudioRecorder.swift").read_text()
local_server = (root / "iOS/TypeformeIOS/Bridge/KeyboardLocalServer.swift").read_text()
handshake = (root / "Sources/Typeforme/Models/KeyboardStartHandshakePolicy.swift").read_text()
marked_policy = (root / "Sources/Typeforme/Models/KeyboardMarkedTextOwnershipPolicy.swift").read_text()
rime_activation_policy = (root / "Sources/Typeforme/Models/KeyboardRimeActivationPolicy.swift").read_text()
rime_schema = (root / "iOS/TypeformeKeyboard/RimeSharedSupport/typeforme_pinyin.schema.yaml").read_text()
rime_stage = (root / "scripts/stage-rime-ios-runtime.sh").read_text()
rime_outputs = (root / "iOS/TypeformeKeyboard/RimeRuntimeOutputs.xcfilelist").read_text()


def block(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"missing marker: {marker}")
    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"missing body: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"unterminated body: {marker}")


for forbidden in (
    "KeyboardSharedMailbox",
    "cancelledStartStopToken",
    "captureGeneration",
    "CaptureOwner",
):
    if forbidden in app or forbidden in keyboard or forbidden in shared or forbidden in pip:
        raise AssertionError(f"removed lifecycle branch returned: {forbidden}")

prepare = block(app, "private func prepareKeyboardStart(")
for required in (
    "keyboardCoordinator.acceptCommand(",
    "case .accepted(let supersededCommandID):",
    "cancelSupersededKeyboardCommand(",
    "cancelCapture: supersededCommandID == previousActiveCommandID",
    "keyboardCoordinator.transition(commandID: command.id, to: .preparing)",
):
    if required not in prepare:
        raise AssertionError(f"latest-id admission lost invariant: {required}")
if prepare.index("keyboardCoordinator.acceptCommand(") > prepare.index("cancelSupersededKeyboardCommand"):
    raise AssertionError("B must claim lifecycle ownership before canceling A")

supersede = block(app, "private func cancelSupersededKeyboardCommand(")
for required in (
    "startTask?.cancel()",
    "processingTask?.cancel()",
    "recorder.stop(deactivateSession: true)",
    "keyboardAudioSession.cancelRecording()",
    "keyboardStartTask = nil",
    "keyboardProcessingTask = nil",
):
    if required not in supersede:
        raise AssertionError(f"superseded command cleanup lost invariant: {required}")
if "await startTask?.value" in supersede or "await processingTask?.value" in supersede:
    raise AssertionError("a new command must not wait for a superseded command to unwind")

stop_pipeline = block(app, "func stopAndSend(")
if stop_pipeline.count("KeyboardDarwinNotificationName.dictationStopped") != 1:
    raise AssertionError("stopAndSend must emit dictationStopped exactly once")
for required in (
    "guard shouldContinueKeyboardOperation(effectiveKeyboardCommandID)",
):
    if required not in stop_pipeline:
        raise AssertionError(f"processing result lost ownership guard: {required}")

begin_stop = block(app, "private func beginKeyboardStopAndSend(")
for required in (
    "KeyboardCommandControlPolicy.stopEffect(during: lifecycle.stage)",
    "case .cancelBeforeRecording:",
    "case .ignore:",
    "case .stopAndProcess:",
    "keyboardProcessingCommandID = commandID",
    "keyboardProcessingTask = task",
    "await self.stopAndSend(keyboardCommandID: commandID)",
    "self.finishKeyboardProcessing(commandID: commandID)",
):
    if required not in begin_stop:
        raise AssertionError(f"exact processing task is not retained: {required}")

refine = block(app, "private func refineKeyboardText(")
for required in (
    "guard await prepareKeyboardRefine(command)",
    "guard shouldContinueKeyboardOperation(command.id)",
    "processingStage: .refining",
):
    if required not in refine:
        raise AssertionError(f"refine command lost lifecycle ownership: {required}")

finish_processing = block(app, "private func finishKeyboardProcessing(")
for required in (
    "keyboardProcessingCommandID == commandID",
    "keyboardProcessingTask = nil",
    "keyboardProcessingCommandID = nil",
    "keyboardCoordinator.latestCommandToken?.id == commandID",
    "failKeyboardCommand(",
):
    if required not in finish_processing:
        raise AssertionError(f"processing terminal cleanup lost invariant: {required}")
if "publishKeyboardStatus(.standby" in finish_processing:
    raise AssertionError("processing completion can overwrite a terminal result with standby")

start_flight = block(app, "private func runKeyboardRecordingStart(")
for required in (
    "keyboardStartCommandID = commandID",
    "keyboardStartTask = task",
    "await task.value",
):
    if required not in start_flight:
        raise AssertionError(f"exact start task is not retained: {required}")

lifecycle_handler = block(keyboard, "private func handleCommandLifecycleNotification(")
for required in (
    "loadCommandLifecycle()",
    "switch snapshot.stage",
    "case .accepted, .preparing:",
    "case .recording:",
    "case .transcribing, .refining:",
    "case .completed:",
    "case .cancelled:",
    "case .failed:",
    "acknowledgeHostStartProgress(snapshot, now: now)",
    "snapshot.command.id == currentCommandLifecycleID",
):
    if required not in lifecycle_handler:
        raise AssertionError(f"keyboard no longer consumes command lifecycle: {required}")
start_progress = block(keyboard, "private func acknowledgeHostStartProgress(")
for required in (
    "cancelDarwinStartAckTimeout()",
    "pendingStartCommandID = snapshot.command.id",
    "activeRecordingCommandID = snapshot.command.id",
):
    if required not in start_progress:
        raise AssertionError(f"positive lifecycle progress lost acknowledgement: {required}")

for required in (
    'keyboard.command-intent.v1',
    'keyboard.command-lifecycle.v1',
    "static func saveCommandIntent(",
    "static func loadCommandIntent(",
    "static func saveCommandLifecycle(",
    "static func loadCommandLifecycle(",
):
    if required not in shared:
        raise AssertionError(f"single-slot command contract missing: {required}")

lifecycle_policy = block(handshake, "enum KeyboardCommandLifecyclePolicy")
for required in (
    "incoming.issuedAt > current.issuedAt",
    "guard !current.isTerminal",
    "(.recording, .transcribing)",
    "(.refining, .completed)",
    "static func canPublishStatus(",
    "guard commandID == lifecycle.command.id",
):
    if required not in lifecycle_policy:
        raise AssertionError(f"lifecycle reducer lost invariant: {required}")

cancel_command = block(app, "private func cancelKeyboardCommand(")
for required in (
    "startTask?.cancel()",
    "processingTask?.cancel()",
    "await startTask?.value",
    "await processingTask?.value",
    "phase == .sending || phase == .refining",
):
    if required not in cancel_command:
        raise AssertionError(f"keyboard cancel lost exact task cleanup: {required}")

darwin = block(app, "private func configureKeyboardDarwinBridge(")
if "_ = self.beginKeyboardStopAndSend(commandID: command.id)" not in darwin:
    raise AssertionError("Darwin stop bypasses the retained processing task")
if "await self.stopAndSend(keyboardCommandID:" in darwin:
    raise AssertionError("Darwin stop directly awaits an unowned processing operation")
for required in (
    "KeyboardDarwinNotificationName.commandIntentChanged",
    "KeyboardSharedDefaults.loadCommandIntent()",
    "switch command.action",
):
    if required not in darwin:
        raise AssertionError(f"Darwin no longer consumes one complete intent snapshot: {required}")
if darwin.index("await self.prepareKeyboardStart(command)") > darwin.index("self.applyKeyboardDefaultCorrectionMode(requestedMode)"):
    raise AssertionError("a stale Darwin start can change the active correction mode")
if darwin.index("await self.prepareKeyboardStart(command)") > darwin.index("self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording"):
    raise AssertionError("Darwin B must supersede and cancel A before checking capture capability")
for forbidden in (
    "requestStartDictation",
    "requestStopDictation",
    "requestCancelDictation",
    "consumeDarwinCommand",
):
    if forbidden in darwin:
        raise AssertionError(f"parallel Darwin command lane returned: {forbidden}")

local_command = block(app, "private func handleKeyboardCommand(")
switch_prefix = local_command[:local_command.index("switch command.action")]
if "guard keyboardStandbyEnabled || keyboardAudioSession.isRecording" in switch_prefix:
    raise AssertionError("capture capability must not reject stop/cancel commands")
for forbidden in (
    "scheduleStartConfirmationTimeout",
    "scheduleHostOpenIfStartStalls",
    "startConfirmationTask",
    "scheduledHostOpenTask",
):
    if forbidden in keyboard:
        raise AssertionError(f"parallel start watchdog returned: {forbidden}")

unpair = block(app, "func unpair() async")
for required in (
    "startTask?.cancel()",
    "processingTask?.cancel()",
    "await automaticPiPStartTask?.value",
    "await startTask?.value",
    "await processingTask?.value",
    "keyboardAudioSession.stop(discardInputEngine: true)",
):
    if required not in unpair:
        raise AssertionError(f"unpair does not finish active capture work: {required}")

if "pairingRevision" not in app or "expectedPairingRevision" not in app:
    raise AssertionError("pairing async commits are not revision scoped")

darwin_observers = block(keyboard, "private func configureKeyboardDarwinBridge(")
if "KeyboardDarwinNotificationName.commandLifecycleChanged" not in darwin_observers:
    raise AssertionError("keyboard is not observing the lifecycle snapshot")
stopped = darwin_observers[darwin_observers.index("KeyboardDarwinNotificationName.dictationStopped"):]
stopped = stopped[:stopped.index("KeyboardDarwinNotificationName.transcriptionReady")]
for forbidden in (
    "finishStoppedNotification()",
    "isStartRequestInFlight = false",
    "activeRecordingCommandID = nil",
):
    if forbidden in stopped:
        raise AssertionError(f"unscoped dictationStopped regained command ownership: {forbidden}")
if "handleCommandLifecycleNotification()" not in stopped:
    raise AssertionError("dictationStopped no longer reloads the ID-scoped lifecycle")

finish_skip = block(keyboard, "private func finishStoppedLivePartialRefine(")
if "stopBridgeStatusStream" in finish_skip:
    raise AssertionError("local refine skip must keep the status stream alive")

ignore_suppressed = block(keyboard, "private func shouldIgnoreSuppressedRefineStatus(")
if "status.state == .result" in ignore_suppressed:
    raise AssertionError("suppressed A must ignore every command-scoped status, not only Result")

voice_press = block(keyboard, "@objc private func voicePressDown(")
if "stopActiveStyleRewriteFromUserAction()" not in voice_press:
    raise AssertionError("style rewrite stop boundary is missing")
skip_call = voice_press.index("stopLivePartialRefineFromUserAction()")
next_start = voice_press.index("guard !isVoicePressActive", skip_call)
if "return" not in voice_press[skip_call:next_start]:
    raise AssertionError("voice-mode Send Without Refine must not also start the next recording")

text_voice = block(keyboard, "@objc private func textVoiceTapped(")
if "if stopLivePartialRefineFromUserAction()" not in text_voice:
    raise AssertionError("text keyboard mic lost the active-refine boundary")
if "stopActiveStyleRewriteFromUserAction()" not in text_voice:
    raise AssertionError("text keyboard style rewrite stop boundary is missing")
skip_call = text_voice.index("if stopLivePartialRefineFromUserAction()")
next_start = text_voice.index("beginDictationFromKeyboard(")
if "return" in text_voice[skip_call:next_start].split("}", 1)[-1]:
    raise AssertionError("text keyboard mic stops after skipping A instead of starting B")

text_space = block(keyboard, "private func handleTextSpace(")
space_sending = text_space[text_space.index("if currentBridgeStatus?.state == .sending"):]
space_sending = space_sending[:space_sending.index("clearTransientKeyboardErrorIfShowing()")]
if "stopActiveRefineFromUserAction()" not in space_sending or "return" not in space_sending:
    raise AssertionError("text-keyboard Send Without Refine must commit A without starting B")

rime_mutation = block(keyboard, "private func applyRimeUpdate(")
if "validateRimeDocumentForMutation()" not in rime_mutation:
    raise AssertionError("Rime proxy mutation is not document scoped")
for required in (
    "composition.revision > currentRimeComposition.revision",
    "for committedText in update.committedTexts",
    "currentRimeComposition = composition",
    "currentRimeCandidateWindow = update.candidateWindow",
):
    if required not in rime_mutation:
        raise AssertionError(f"Rime update projection lost invariant: {required}")
rime_discard = block(keyboard, "private func discardStaleRimeInput(")
for forbidden in ("textDocumentProxy", "replaceMarkedText", "unmarkText"):
    if forbidden in rime_discard:
        raise AssertionError(f"stale Rime cleanup mutates the new input target: {forbidden}")

apply_status = block(keyboard, "private func applyBridgeStatus(")
if "status.state == .error" not in apply_status or "finishStartRequestIfNeeded(status: status)" not in apply_status:
    raise AssertionError("a command-matched start error can leave the start flight active")

if "activeStatusReconcileTask" in keyboard or "reconcileActiveBridgeStatusIfNeeded" in keyboard:
    raise AssertionError("post-accept periodic status watchdog returned")

for marker in (
    "private func waitForSourceView() async throws",
    "private func waitUntilPictureInPictureIsPossible(",
    "private func waitUntilPictureInPictureIsActive(",
):
    wait = block(pip, marker)
    if "try? await Task.sleep" in wait:
        raise AssertionError(f"PiP cancellation is swallowed in {marker}")

pip_retry = block(app, "private func startPiPVisibilityWithForegroundRetry(")
if "try? await Task.sleep" in pip_retry or "guard !Task.isCancelled" not in pip_retry:
    raise AssertionError("PiP outer retry does not propagate cancellation")
active_wait = block(app, "private func waitUntilApplicationIsActive(")
if "try? await Task.sleep" in active_wait or "!Task.isCancelled" not in active_wait:
    raise AssertionError("foreground wait swallows PiP cancellation")

stop_visible_audio = block(app, "private func stopBackgroundAudioCaptureForVisibleMode(")
if "keyboardStandbyRefreshTask" in stop_visible_audio:
    raise AssertionError("PiP capture cleanup must not cancel the refresh task that invoked it")

ensure_ready = block(local_server, "func ensureReady(")
for required in ("catch is CancellationError", "wasCancelled = true", "!wasCancelled"):
    if required not in ensure_ready:
        raise AssertionError(f"local bridge cancellation can mutate readiness: {required}")
self_probe = block(local_server, "private func selfProbe(")
if "async throws -> Bool" not in self_probe or "catch is CancellationError" not in self_probe:
    raise AssertionError("cancelled self-probe can be treated as a bridge failure")

final_plan = block(keyboard, "private func livePartialFinalCommitPlan(")
if "anchoredCommitted" in final_plan or "visibleCommitted" in final_plan:
    raise AssertionError("live partial final must not search or move the cursor")

ownership = block(keyboard, "private func ownsActiveLivePartialMarkedText(")
for required in (
    "KeyboardLivePartialOwnershipPolicy.ownsMarkedText",
    "expectedCommandID: preview.commandID",
    "documentIdentifier: textDocumentProxy.documentIdentifier",
    "hasLivePartialOwner: activeMarkedTextOwner == .livePartial",
):
    if required not in ownership:
        raise AssertionError(f"voice partial ownership lost invariant: {required}")
for forbidden in ("documentContextBeforeInput", "documentContextAfterInput"):
    if forbidden in ownership:
        raise AssertionError(f"voice partial ownership regained host-context inference: {forbidden}")

for forbidden in (
    "refineTimeoutTask",
    "sendingTimeoutTask",
    "updateRefineTimeoutWatchdog",
    "updateSendingTimeoutWatchdog",
):
    if forbidden in keyboard:
        raise AssertionError(f"keyboard duplicated host terminal ownership: {forbidden}")
if "correctionTimeoutMs" in shared or "correctionTimeoutMs" in keyboard:
    raise AssertionError("keyboard status still carries a duplicate refine timeout contract")

for required in ("KeyboardLivePartialOwnershipPolicy", "KeyboardRimeInlineEditPolicy"):
    if required not in marked_policy:
        raise AssertionError(f"separate marked-text ownership policy missing: {required}")
for forbidden in ("observedContextMode", "contextsMatch", "beforeCandidates"):
    if forbidden in marked_policy:
        raise AssertionError(f"marked-text ownership regained context inference: {forbidden}")
if "rimeCompositionContextsMatch" in marked_policy:
    raise AssertionError("Rime composition returned to per-key context ownership checks")

partial_update = block(keyboard, "private func canPresentLivePartialPreview(")
for required in (
    "guard state.commandID == commandID else { return false }",
    "state.ownershipInvalidated = true",
    "activeMarkedTextOwner == .livePartial",
    "activeDictationInsertionAnchor",
    "insertionAnchor.commandID == commandID",
    "matchesCurrentInsertionAnchor(insertionAnchor)",
    'event: "live_preview_unowned_controller_ignored"',
    'event: "live_preview_initial_target_changed"',
):
    if required not in partial_update:
        raise AssertionError(f"live partial ownership loss is not fail-closed: {required}")
if partial_update.index('event: "live_preview_unowned_controller_ignored"') > partial_update.index("matchesCurrentInsertionAnchor(insertionAnchor)"):
    raise AssertionError("an unowned keyboard controller must be rejected before target validation")

expected_results = block(keyboard, "private func expectedRecordingResultCommandIDs(")
if "currentBridgeStatus" in expected_results:
    raise AssertionError("observing Host sending state must not make another keyboard controller the result owner")
if "activeDictationInsertionAnchor?.commandID" not in expected_results:
    raise AssertionError("plain voice results lost their command-scoped insertion owner")

if "controllerOwnsCommand" not in marked_policy:
    raise AssertionError("voice delivery lacks a pure command-owner policy")
result_delivery = apply_status[apply_status.index("if status.state == .result,"):]
result_delivery = result_delivery[:result_delivery.index("if status.state == .error || status.state == .idle")]
if "controllerOwnsVoiceCommand(commandID)" not in result_delivery:
    raise AssertionError("an observing keyboard controller can still consume another controller's voice result")
stale_result = block(keyboard, "private func shouldIgnoreStaleResultStatus(")
if "guard !expectedIDs.isEmpty else { return false }" not in stale_result:
    raise AssertionError("an unowned controller cannot observe Host terminal state and may remain Transcribing")

safe_clear = block(keyboard, "private func clearLivePartialMarkedTextIfStillOwned(")
for required in (
    "state.commandID != commandID",
    "ownsActiveLivePartialMarkedText",
    "clearLocalMarkedTextState()",
):
    if required not in safe_clear:
        raise AssertionError(f"live partial clear lost command/anchor proof: {required}")

rime_session = block(keyboard, "private func currentRimeCompositionSession(")
if "textDocumentProxy.documentIdentifier" not in rime_session:
    raise AssertionError("Rime session lost its document identity")
for forbidden in ("documentContextBeforeInput", "documentContextAfterInput", "markedTextContextMode"):
    if forbidden in rime_session:
        raise AssertionError(f"Rime session regained context ownership: {forbidden}")

rime_target_match = block(keyboard, "private func rimeCompositionSessionIsCurrent(")
for required in (
    "KeyboardRimeCompositionPolicy.targetIsCurrent(",
    "rimeCompositionSession.documentIdentifier",
    "textDocumentProxy.documentIdentifier",
):
    if required not in rime_target_match:
        raise AssertionError(f"Rime document matching lost ownership proof: {required}")

text_will_change = block(keyboard, "override func textWillChange(")
for forbidden in ("discardStaleRimeInput", "clearComposition", "replaceMarkedText", "finishRimeTextTransaction"):
    if forbidden in text_will_change:
        raise AssertionError(f"host callbacks must delegate Rime ownership resolution: {forbidden}")

space_cursor = block(keyboard, "@objc private func handleTextSpaceCursorGesture(")
for forbidden in ("commitComposition", "commitDisplayedRimeCompositionIfNeeded", "clearComposition"):
    if forbidden in space_cursor:
        raise AssertionError(f"space trackpad must preserve marked Rime text: {forbidden}")
if "setTextTrackpadMode(true)" not in space_cursor:
    raise AssertionError("space trackpad no longer enters cursor mode")

text_return = block(keyboard, "private func handleTextReturn(")
if "commitDisplayedRimeCompositionIfNeeded()" not in text_return:
    raise AssertionError("Return must preserve a confirmed prefix and commit only the active suffix as raw input")
if "rimeInput.commitRawInput()" in text_return or "func commitRawInput()" in rime_controller:
    raise AssertionError("Return must not flatten a partially converted composition back to raw keystrokes")
for required in ("if !pendingRimeInput.isEmpty", "pendingRimeInput.appendReturnKey()"):
    if required not in text_return:
        raise AssertionError(f"Return lost pending Rime semantics: {required}")

rime_update = block(rime_controller, "struct RimeKeyboardUpdate")
for required in (
    "let documentCommitText: String",
    "documentCommitText ?? committedTexts.joined()",
    "func appendingDocumentText(",
):
    if required not in rime_update:
        raise AssertionError(f"Rime commit batch lost ordered document semantics: {required}")

apply_rime_update = block(keyboard, "private func applyRimeUpdate(")
for required in (
    "let documentCommitText = update.documentCommitText",
    "commitTextReplacingMarkedText(documentCommitText, reason: .rimeCommit)",
):
    if required not in apply_rime_update:
        raise AssertionError(f"Rime commit events are no longer one marked-text mutation: {required}")
if "commitTextReplacingMarkedText(committedText, reason: .rimeCommit)" in apply_rime_update:
    raise AssertionError("Rime commit events must not be written as separate proxy mutations")

rime_literal_boundary = block(keyboard, "private func commitDisplayedRimeCompositionIfNeeded(")
for required in (
    "appending documentSuffix: String = \"\"",
    "currentRimeComposition.committableCompositionText(",
    ".commitVisibleComposition(text)",
    ".appendingDocumentText(documentSuffix)",
):
    if required not in rime_literal_boundary:
        raise AssertionError(f"Rime Return/direct boundary lost visible composition semantics: {required}")

chinese_direct_key = block(keyboard, "private func insertChineseDirectTextKey(")
if "commitDisplayedRimeCompositionIfNeeded(appending: directText)" not in chinese_direct_key:
    raise AssertionError("Chinese symbol input no longer commits Return-equivalent text before the symbol")
for forbidden in ("commitComposition", "selectCandidate", "deferTextAfterRimeComposition"):
    if forbidden in chinese_direct_key:
        raise AssertionError(f"Chinese symbol input regained implicit candidate selection/state: {forbidden}")
literal_shortcut = block(keyboard, "private func insertLiteralTextShortcut(")
if "commitDisplayedRimeCompositionIfNeeded(appending: text)" not in literal_shortcut:
    raise AssertionError("literal shortcut no longer shares the Return-equivalent Rime boundary")
pending_direct_boundary = block(keyboard, "private func queuePendingRimeDirectBoundary(")
for required in ("pendingRimeInput.appendRawLiteralBoundary(text)", "replayPendingRimeInputIfReady()"):
    if required not in pending_direct_boundary:
        raise AssertionError(f"startup Rime direct boundary can select a candidate: {required}")

text_space = block(keyboard, "private func handleTextSpace(")
for required in ("if !pendingRimeInput.isEmpty", "pendingRimeInput.appendSpaceKey()"):
    if required not in text_space:
        raise AssertionError(f"Space lost first-candidate semantics while Rime starts: {required}")
if 'commitPendingRimeInputAsLiteral(appending: " ")' in text_space:
    raise AssertionError("pending Space must not flatten pinyin into literal text")
for required in (
    "pendingRimeSpaceUsesRawLiteralBoundary",
    'pendingRimeInput.appendRawLiteralBoundary(" ")',
):
    if required not in text_space:
        raise AssertionError(f"pending Space diverges from live literal/candidate routing: {required}")

start_dictation = block(keyboard, "private func startDictationCommand(")
if "finishRimeTextTransaction()" not in start_dictation:
    raise AssertionError("voice start does not finish pending and marked Rime ownership first")

finish_rime = block(keyboard, "private func finishRimeTextTransaction(")
for required in ("commitPendingRimeInputAsLiteral()", "commitDisplayedRimeCompositionIfNeeded()"):
    if required not in finish_rime:
        raise AssertionError(f"Rime transaction boundary lost ordered ownership: {required}")

# Mixed English belongs to Rime's translator. The keyboard frontend must not
# parse or cache a second copy of the dictionary to guess whether raw input is
# English; unknown Latin input remains explicitly available through Return.
for forbidden in (
    "englishWordCodes",
    "literalEnglishCandidatePlacement",
    "literalSelectionIndex",
    "isShortLiteralLatinComposition",
    "isEnglishCompletionCandidate",
    "typeforme_english.codes.txt",
):
    if (forbidden in keyboard or forbidden in rime_controller
            or forbidden in rime_stage or forbidden in rime_outputs):
        raise AssertionError(f"Swift-side English dictionary ownership returned: {forbidden}")
if "table_translator@english_word" not in rime_schema:
    raise AssertionError("Rime schema lost its engine-owned English translator")
english_translator = rime_schema.split("english_word:", 1)[1].split("\npunctuator:", 1)[0]
if "enable_completion: false" not in english_translator:
    raise AssertionError("mixed English must not flood the candidate window with completions")
if "RimeKeyboardCandidate.literalSelectionIndex" in keyboard:
    raise AssertionError("removed synthetic English candidates regained a frontend selection branch")

# Rime publishes one-shot updates; the keyboard retains only reusable
# composition/window projections. UI-only interactions must never recapture
# the engine or manufacture a fake update.
for forbidden in (
    "rimeInput.state(",
    "RimeKeyboardState",
    "renderRimeState",
    "applyRimeState",
    "expandedCandidateState",
):
    if forbidden in keyboard or forbidden in rime_controller:
        raise AssertionError(f"legacy full-state Rime ownership returned: {forbidden}")
if "func state(" in rime_controller:
    raise AssertionError("Rime query API can bypass the published projection")
if "RimeKeyboardUpdate(" in keyboard:
    raise AssertionError("keyboard UI must not fabricate one-shot Rime updates")

candidate_extension = block(rime_controller, "func expandedCandidateWindow(")
for required in (
    ") -> RimeCandidateWindow?",
    "isLatestRevision(expectedWindow.revision)",
    "liveIdentity == expectedWindow.compositionIdentity",
):
    if required not in candidate_extension:
        raise AssertionError(f"candidate-only extension lost revision ownership: {required}")
if "RimeKeyboardUpdate" in candidate_extension or "drainCommit" in candidate_extension:
    raise AssertionError("candidate scrolling can produce a text update or commit")

queued_replay = block(rime_controller, "func processInputIfReady(")
for required in (
    "var committedTexts: [String] = []",
    'var documentCommitText = ""',
    "func drainEngineCommit()",
    "drainCommit(into: &committedTexts)",
    "documentCommitText += rawInput + text",
    "documentCommitText: documentCommitText",
    "case .engineCharacters",
    "case .spaceKey",
    "case .rawLiteralBoundary",
    "case .returnKey",
    "api.processKeyCode(32",
    "api.getInput(session)",
):
    if required not in queued_replay:
        raise AssertionError(f"queued Rime replay lost atomic batch behavior: {required}")
if "committedTexts.append(contentsOf:" in queued_replay:
    raise AssertionError("UI-owned literal text must not become a Rime learning event")
if "case .literalTextKeys" in queued_replay or "api.commitComposition(session)" in queued_replay:
    raise AssertionError("queued direct text must not implicitly accept the first Rime candidate")
if queued_replay.count("captureUpdateOnQueue(") != 1:
    raise AssertionError("queued Rime replay must capture candidates exactly once")

rime_key = block(keyboard, "private func processChineseRimeTextKey(")
pending_guard = rime_key.index("if !pendingRimeInput.isEmpty")
direct_mutation = rime_key.index("rimeInput.processInputIfReady(")
if pending_guard > direct_mutation:
    raise AssertionError("new Rime keys can bypass the startup-owned input transaction")

pending_replay = block(keyboard, "private func replayPendingRimeInputIfReady(")
for required in (
    "let input = pendingRimeInput",
    "case .notReady(let update):",
    "case .processed(let update):",
    "pendingRimeInput.consumeAfterSuccessfulReplay()",
):
    if required not in pending_replay:
        raise AssertionError(f"pending Rime ownership lost replay invariant: {required}")
if pending_replay.index("consumeAfterSuccessfulReplay()") < pending_replay.index("case .processed"):
    raise AssertionError("pending Rime input is consumed before a processed result")
not_ready_branch = pending_replay[
    pending_replay.index("case .notReady"):pending_replay.index("case .processed")
]
if "consumeAfterSuccessfulReplay" in not_ready_branch or "removeAll" in not_ready_branch:
    raise AssertionError("not-ready Rime replay consumes pending input")
if "applyPendingRimeUpdate(update)" not in not_ready_branch:
    raise AssertionError("not-ready Rime replay must preserve its marked-text transaction")

pending_projection = block(keyboard, "private func renderPendingRimeInput(")
for required in (
    "pendingRimeInput.flattenedLiteralText()",
    "replaceMarkedText(text, owner: .rimeComposition)",
):
    if required not in pending_projection:
        raise AssertionError(f"pending Rime input lost UIKit marked-text ownership: {required}")

preferences = block(keyboard, "private func refreshKeyboardPreferencesFromHost(")
session_boundary = preferences.index("finishRimeTextTransaction()", preferences.index("Session replacement"))
desired_phrases = preferences.index("rimeInput.setDesiredConfiguration(")
configuration_activation = preferences.index(
    "rimeInput.activateDesiredConfigurationAfterTextBoundary()",
    desired_phrases,
)
if session_boundary > configuration_activation:
    raise AssertionError("Rime session replacement can clear a live text transaction")
if desired_phrases > configuration_activation:
    raise AssertionError("Rime activation can race ahead of the complete desired configuration")

desired_phrase_setter = block(rime_controller, "func setDesiredConfiguration(")
for required in (
    "resetUserDataGeneration: Int",
    "activationPolicy.replaceDesiredConfiguration(configuration)",
):
    if required not in desired_phrase_setter:
        raise AssertionError(f"desired Rime snapshot lost complete configuration: {required}")
for forbidden in ("cleanAllSession", "startIfNeeded", "rimeQueue", "api."):
    if forbidden in desired_phrase_setter:
        raise AssertionError(f"desired phrase setter mutates the live engine: {forbidden}")

input_options = block(rime_controller, "func applyInputOptions(")
for required in (
    "setDesiredOptions(",
    "applyDesiredOptionsToLiveSession()",
):
    if required not in input_options:
        raise AssertionError(f"Rime live options lost serialized mutation: {required}")
for forbidden in ("replaceDesiredConfiguration", "startIfNeeded"):
    if forbidden in input_options:
        raise AssertionError(f"Rime live options invalidated activation: {forbidden}")
for forbidden in ("rimeQueue.sync", "rimeQueue.async", "api.", "resetUserDataOnQueue"):
    if forbidden in input_options:
        raise AssertionError(f"Rime input-options entrypoint performs direct engine work: {forbidden}")

configuration_activation_entry = block(
    rime_controller,
    "func activateDesiredConfigurationAfterTextBoundary(",
)
if "_ = startIfNeeded()" not in configuration_activation_entry:
    raise AssertionError("Rime destructive configuration no longer uses the shared activation flight")

start_rime = block(rime_controller, "func startIfNeeded(")
for required in (
    "activationPolicy.requestActivation(",
    "scheduleActivationFlight(target, bundle: bundle)",
):
    if required not in start_rime:
        raise AssertionError(f"Rime startup bypasses the shared activation flight: {required}")
for forbidden in ("rimeQueue.sync", "rimeQueue.async", "api."):
    if forbidden in start_rime:
        raise AssertionError(f"Rime startup entrypoint performs engine work: {forbidden}")

if rime_controller.count("rimeQueue.async {") != 2:
    raise AssertionError("Rime must have one activation scheduler and one live-options scheduler")
activation_scheduler = block(rime_controller, "private func scheduleActivationFlight(")
activation_drain = block(rime_controller, "private func drainActivationFlight(")
live_options = block(rime_controller, "private func applyDesiredOptionsToLiveSession(")
for required in (
    "target.configuration",
    "activationPolicy.complete(",
    "case .continueWith(let latestTarget):",
    "shouldDeliverActivationPublication(for: target)",
):
    if required not in activation_drain:
        raise AssertionError(f"Rime activation flight lost latest-generation ownership: {required}")
for forbidden in ("asyncAfter", "Timer", "heartbeat", "watchdog"):
    if forbidden in activation_scheduler or forbidden in activation_drain or forbidden in live_options:
        raise AssertionError(f"Rime activation gained an autonomous recovery branch: {forbidden}")

activation_configuration = block(
    rime_controller,
    "private struct DesiredRimeActivationConfiguration",
)
for forbidden in ("asciiMode", "asciiPunctuation"):
    if forbidden in activation_configuration:
        raise AssertionError(f"live input option re-entered destructive activation: {forbidden}")
desired_options = block(rime_controller, "private func setDesiredOptions(")
if "replaceDesiredConfiguration" in desired_options or "startIfNeeded" in desired_options:
    raise AssertionError("live input options must not invalidate or start activation")

ready = block(rime_controller, "var isReady: Bool")
if "activationPolicy.isReady" not in ready:
    raise AssertionError("Rime readiness is not tied to the applied desired generation")
for forbidden in ("Date(", "session", "selectedSchemaID", "fallback"):
    if forbidden in ready:
        raise AssertionError(f"public Rime readiness reads queue/time-owned state: {forbidden}")
queue_ready = block(rime_controller, "private var isReadyOnQueue: Bool")
for forbidden in ("Date(", "effectiveStartupProfile", "activeStartupFallback"):
    if forbidden in queue_ready:
        raise AssertionError(f"queue readiness can change fallback mid-session: {forbidden}")
for forbidden in (
    "activeEffectiveProfile(",
    "effectiveDesiredProfileOnQueue",
    "desiredProfileOnQueue",
    "desiredUserPhraseSnapshotOnQueue",
):
    if forbidden in rime_controller:
        raise AssertionError(f"dynamic cross-generation Rime getter returned: {forbidden}")

for forbidden in (
    "probeGutterValidity",
    "probeSession",
    "ensureProbeSessionOnQueue",
    "RimeProbeValidity",
    "gutterProbeWinner",
    "pinyinProbeLetter",
):
    if forbidden in rime_controller or forbidden in keyboard:
        raise AssertionError(f"synchronous Rime touch probe returned: {forbidden}")

for signature in (
    "private func textKeyButtonBandTarget(",
    "private func learnedInterKeyGapWinner(",
    "private func resolveGutterCandidate(",
    "private func interKeyGapWinner(",
    "private func gutterResolutionWinner(",
):
    if "rimeInput." in block(keyboard, signature):
        raise AssertionError(f"text hit-testing calls the input engine: {signature}")
if "gutterGapBiasWinner(" not in block(keyboard, "private func interKeyGapWinner("):
    raise AssertionError("whole-gap routing no longer delegates to the learned gap policy")
if "gutterGaussianWinner(" not in block(keyboard, "private func gutterResolutionWinner("):
    raise AssertionError("gutter routing no longer delegates to the learned Gaussian policy")

apply_options = block(rime_controller, "private func applyOptionsOnQueue(")
for required in ("appliedInputOptions", "guard appliedInputOptions != options"):
    if required not in apply_options:
        raise AssertionError(f"Rime input option mutation is not deduplicated: {required}")

for required in (
    "replaceDesiredConfiguration",
    "desiredGeneration",
    "appliedGeneration",
    "inFlightSnapshot",
    "shouldDeliverPublication",
    "KeyboardRimeSessionProfilePolicy",
    "KeyboardRimeSessionMutationPlan",
):
    if required not in rime_activation_policy:
        raise AssertionError(f"testable Rime activation policy lost invariant: {required}")

reset_ack = block(keyboard, "private func configureRimeStateCallback(")
for required in (
    "onResetUserDataApplied",
    "generation > self.defaults.integer",
    "self.defaults.set(generation",
    "self.chineseLearningRecorder.reset()",
):
    if required not in reset_ack:
        raise AssertionError(f"Rime reset acknowledgement lost success boundary: {required}")
if "defaults.set(payload.rimeLearningResetGeneration" in preferences:
    raise AssertionError("Rime reset is acknowledged before engine deletion succeeds")

direct_key_route = block(keyboard, "private func shouldProcessChineseDirectTextKeyInRime(")
if "KeyboardRimeCompositionPolicy.isPinyinSeparatorContinuation(" not in direct_key_route:
    raise AssertionError("pinyin apostrophe can escape the active Rime composition")

literal_shortcut = block(keyboard, "private func insertLiteralTextShortcut(")
for required in (
    "commitPendingRimeInputAsLiteral(appending: text)",
    "latinLiteralCommitTextForBoundary(",
    "commitRawRimeInput(literalText, appending: text)",
):
    if required not in literal_shortcut:
        raise AssertionError(f"URL/email shortcut lost literal-text ownership: {required}")

grid_toggle = block(keyboard, "@objc private func toggleCandidateGrid(")
if "rimeInput." in grid_toggle:
    raise AssertionError("opening candidate grid must reuse the published window")
recording_overlay = block(keyboard, "private func updateTextRecordingStatus(")
if "rimeInput." in recording_overlay:
    raise AssertionError("recording overlay restore must reuse the published window")
grid_expansion = block(keyboard, "private func setCandidateGridExpanded(")
if "KeyboardCandidateWindowPolicy.nonShrinkingTarget(" not in grid_expansion:
    raise AssertionError("inline/grid switching can shrink an expanded candidate window")

inline_candidate_render = block(keyboard, "private func renderInlineCandidateWindow(")
if "KeyboardCandidateWindowPolicy.initialInlineRenderCount(" not in inline_candidate_render:
    raise AssertionError("inline candidates lost viewport-derived initial materialization")
if "candidateInlineRenderChunkCount" in keyboard:
    raise AssertionError("inline candidate rendering regained a fixed cell-count window")
projection_render = block(keyboard, "private func renderRimeProjectionImmediately(")
if "renderInlineCandidateWindow(candidateWindow)" not in projection_render:
    raise AssertionError("collapsed per-key rendering regained a synchronous candidate extension")

inline_candidate_reconcile = block(keyboard, "private func reconcileInlineCandidateLayoutIfNeeded(")
for required in (
    "nextSignature != candidateInlineLayoutSignature",
    "KeyboardCandidateWindowPolicy.initialInlineRenderCount(",
    "adoptCandidateWindow(currentWindow)",
):
    if required not in inline_candidate_reconcile:
        raise AssertionError(f"inline width reconciliation lost surface ownership: {required}")
if "extendedCandidateWindow(" in inline_candidate_reconcile or "rimeInput." in inline_candidate_reconcile:
    raise AssertionError("inline width reconciliation must not synchronously extend Rime")
layout = block(keyboard, "override func viewDidLayoutSubviews(")
if "reconcileInlineCandidateLayoutIfNeeded()" not in layout:
    raise AssertionError("inline candidates do not reconcile a live composition after width changes")

inline_drag = block(keyboard, "func scrollViewWillBeginDragging(")
for required in (
    "scrollView === candidateScrollView",
    "appendInlineCandidatesForScrollPositionIfNeeded()",
):
    if required not in inline_drag:
        raise AssertionError(f"wide inline candidates lost gesture-owned extension: {required}")

inline_scroll_extension = block(keyboard, "private func appendInlineCandidatesForScrollPositionIfNeeded(")
if "!isReconcilingInlineCandidateLayout" not in inline_scroll_extension:
    raise AssertionError("inline layout reconcile can re-enter candidate extension")

grid_render = block(keyboard, "private func renderCandidateGrid(")
for required in (
    "guard isCandidateGridExpanded else { return }",
    "KeyboardCandidateWindowPolicy.canAppendRenderedPrefix(",
    "appendCandidateGridCells(",
):
    if required not in grid_render:
        raise AssertionError(f"expanded candidate rendering lost append-only ownership: {required}")
if "candidateGridStack.arrangedSubviews.forEach" in grid_render:
    raise AssertionError("expanded candidate rendering rebuilds every row before checking its prefix")

grid_reconcile = block(keyboard, "private func reconcileExpandedCandidateGridLayoutIfNeeded(")
for required in (
    "signature != renderState.layoutSignature",
    "resetScrollPosition: false",
):
    if required not in grid_reconcile:
        raise AssertionError(f"expanded grid does not reconcile changed geometry: {required}")

grid_offset_restore = block(keyboard, "private func layoutCandidateGridAndRestoreOffset(")
for required in (
    "semanticAnchor: CandidateGridScrollAnchor?",
    "candidateGridRow(containing: anchor.selectionIndex)",
    "anchor.offsetFromViewportTop",
):
    if required not in grid_offset_restore:
        raise AssertionError(f"expanded grid reflow lost semantic scroll ownership: {required}")

candidate_accessibility = block(keyboard, "private func configureCandidateAccessibility(")
for required in (
    "accessibilityRespondsToUserInteraction = true",
    "accessibilityActivateBlock",
    "return activation(button)",
):
    if required not in candidate_accessibility:
        raise AssertionError(f"candidate accessibility lost explicit activation: {required}")
for marker in (
    "private func makeCandidateGridButton(",
    "private func reusableCandidateButton(",
):
    if "configureCandidateAccessibility(" not in block(keyboard, marker):
        raise AssertionError(f"candidate surface bypasses shared accessibility activation: {marker}")

root_configuration = block(keyboard, "private func configureRoot(")
if "candidateTextOverlay.accessibilityElementsHidden = true" not in root_configuration:
    raise AssertionError("purely visual candidate labels can shadow semantic buttons in accessibility")

candidate_overlay = block(keyboard, "private func updateCandidateTextOverlay(")
if "visibleInlineCandidateButtons(" not in candidate_overlay:
    raise AssertionError("inline candidate overlay scans the entire loaded window")
if "candidateStack.arrangedSubviews.compactMap" in candidate_overlay:
    raise AssertionError("inline candidate overlay regained an unbounded hierarchy scan")

visible_grid_rows = block(keyboard, "private func visibleCandidateGridRows(")
if "visibleOrderedCandidateViews(" not in visible_grid_rows or ".filter" in visible_grid_rows:
    raise AssertionError("grid visibility lookup is not bounded to the viewport")

candidate_refresh = block(keyboard, "private func performCandidateRefreshWithoutAnimation(")
if "if isCandidateGridExpanded" not in candidate_refresh:
    raise AssertionError("candidate refresh lays out both hidden and active surfaces")
if "removeAnimationsRecursively" in keyboard:
    raise AssertionError("candidate refresh recursively walks the entire loaded hierarchy")

idle_surface = block(keyboard, "private func renderIdleCandidateSurface(")
if "RimeKeyboardUpdate" in idle_surface or "currentRimeComposition =" in idle_surface:
    raise AssertionError("idle toolbar rendering must not replace the engine projection")

trackpad_end = block(keyboard, "private func endTextSpaceCursorTracking(")
for required in (
    "currentRimeComposition.isComposing",
    "renderCurrentRimeProjection()",
    "renderRefineSuggestionsIfIdle()",
):
    if required not in trackpad_end:
        raise AssertionError(f"space trackpad end lost composition-aware candidate rendering: {required}")

trackpad_cursor = block(keyboard, "private func updateTrackpadCursorPosition(")
for required in (
    "activeMarkedTextOwner == .rimeComposition",
    "KeyboardRimeInlineEditPolicy.partialCompositionSplit(",
    "targetOffset != endOffset",
    "caretOffset: targetOffset",
    "rimeInlineEditCaretOffset = nextOffset",
    "replaceMarkedText(",
    "textDocumentProxy.adjustTextPosition(byCharacterOffset: deltaStepX)",
):
    if required not in trackpad_cursor:
        raise AssertionError(f"space trackpad lost cursor routing: {required}")
for forbidden in ("rimeInput.moveCaret",):
    if forbidden in trackpad_cursor:
        raise AssertionError(f"moving the display caret must not change Rime candidates: {forbidden}")
if "else if !composition.isComposing" not in trackpad_cursor:
    raise AssertionError("active Rime composition must never fall through to the host document cursor")
if "rimeInput." in trackpad_cursor:
    raise AssertionError("trackpad movement must read the published projection without recapturing Rime")

partial_rebase = block(keyboard, "private func rebasePartialRimeCompositionForInlineEdit(")
for required in (
    "rimeInput.replaceCompositionInput(",
    "commitTextReplacingMarkedText(split.committedPrefix",
    "rimeCompositionSession = currentRimeCompositionSession()",
    "caretOffset,",
    "in: remainingUpdate.composition.input",
    "applyRimeUpdate(remainingUpdate)",
):
    if required not in partial_rebase:
        raise AssertionError(f"partial Rime rebase lost stack boundary: {required}")

inline_character = block(rime_controller, "func replaceCompositionInput(")
for required in (
    "api.cleanComposition(session)",
    "for scalar in input.unicodeScalars",
    "drainCommit(into: &committedTexts)",
    "captureUpdateOnQueue(committedTexts: committedTexts)",
):
    if required not in inline_character:
        raise AssertionError(f"inline Rime edit lost whole-input replay: {required}")
for forbidden in ("0xFF51", "0xFF53", "0xFF57"):
    if forbidden in inline_character:
        raise AssertionError(f"inline Rime edit must not navigate candidate segments: {forbidden}")

replace_marked = block(keyboard, "private func replaceMarkedText(")
if "selectedRange: NSRange(location: nextSelectionLocation" not in replace_marked:
    raise AssertionError("marked-text writes do not preserve the Rime caret")

text_did_change = block(keyboard, "override func textDidChange(")
if "discardRimeInputIfTargetChanged" in text_did_change:
    raise AssertionError("keyboard-owned proxy writes must not be treated as external context changes")
if "discardRimeInputIfDocumentChanged" not in text_did_change:
    raise AssertionError("document switches must still clear stale Rime state")
text_will_change = block(keyboard, "override func textWillChange(")
selection_will_change = block(keyboard, "override func selectionWillChange(")
for callback in (text_will_change, selection_will_change):
    if "resolveRimeInputForExternalHostChange(" not in callback:
        raise AssertionError("external host changes can replay Rime at a new insertion point")
host_change_boundary = block(keyboard, "private func resolveRimeInputForExternalHostChange(")
for required in (
    "KeyboardRimeCompositionPolicy.externalHostChangeResolution(",
    "activeMarkedTextOwner == .rimeComposition",
    "isMutatingDocumentMarkedText",
    "targetIsCurrent: rimeCompositionSessionIsCurrent()",
    "case .relinquishCurrentTarget",
    "relinquishRimeInputToExternalHost(reason: reason)",
    "case .discardStaleTarget",
    "discardStaleRimeInput(reason: reason)",
):
    if required not in host_change_boundary:
        raise AssertionError(f"Rime host-change ownership lost boundary: {required}")
for forbidden in ("documentContextBeforeInput", "documentContextAfterInput"):
    if forbidden in host_change_boundary:
        raise AssertionError(f"Rime ownership regressed to host-context polling: {forbidden}")

host_relinquish = block(keyboard, "private func relinquishRimeInputToExternalHost(")
for required in (
    "unmarkDocumentMarkedText()",
    "resetRimeInputState()",
    'event: "rime_input_relinquished_to_host"',
):
    if required not in host_relinquish:
        raise AssertionError(f"Rime host relinquish lost invariant: {required}")
for forbidden in (
    "setDocumentMarkedText",
    "commitDocumentMarkedText",
    "clearDocumentMarkedText",
    "insertDocumentText",
    "deleteDocumentTextBackward",
    "finishRimeTextTransaction",
    "commitDisplayedRimeCompositionIfNeeded",
):
    if forbidden in host_relinquish:
        raise AssertionError(f"external host changes must not replay Rime text: {forbidden}")

rime_reset = block(keyboard, "private func resetRimeInputState(")
for required in (
    "pendingRimeInput.removeAll()",
    "rimeCompositionSession = nil",
    "clearLocalMarkedTextState()",
    "rimeInput.clearComposition()",
    "renderCurrentRimeProjection()",
):
    if required not in rime_reset:
        raise AssertionError(f"Rime ownership reset lost invariant: {required}")
for forbidden in (
    "textDocumentProxy",
    "setDocumentMarkedText",
    "commitDocumentMarkedText",
    "unmarkDocumentMarkedText",
    "clearDocumentMarkedText",
    "insertDocumentText",
    "deleteDocumentTextBackward",
):
    if forbidden in rime_reset:
        raise AssertionError(f"Rime ownership reset must not mutate the host document: {forbidden}")

for marker in (
    "private func setDocumentMarkedText(",
    "private func commitDocumentMarkedText(",
    "private func unmarkDocumentMarkedText(",
    "private func clearDocumentMarkedText(",
):
    if "withLocalMarkedTextMutation" not in block(keyboard, marker):
        raise AssertionError(f"owned marked-text callback lost local-mutation guard: {marker}")

apply_rime = block(keyboard, "private func applyRimeUpdate(")
for required in (
    "commitTextReplacingMarkedText(documentCommitText",
    "rimeCompositionSession = currentRimeCompositionSession()",
    "selectionLocation: rimeMarkedTextSelectionLocation(for: composition)",
):
    if required not in apply_rime:
        raise AssertionError(f"Rime commit/composition transaction lost step: {required}")
if not (
    apply_rime.index("commitTextReplacingMarkedText(documentCommitText")
    < apply_rime.index("rimeCompositionSession = currentRimeCompositionSession()")
    < apply_rime.index("selectionLocation: rimeMarkedTextSelectionLocation(for: composition)")
):
    raise AssertionError("Rime commit + composition must rebase between commit and the new marked text")

start_command = block(keyboard, "private func startDictationCommand(")
if start_command.index("clearLivePartialMarkedTextIfStillOwned(") > start_command.index("livePartialPreviewState = nil"):
    raise AssertionError("new command forgets the old preview before safely clearing it")
for required in (
    "finishRimeTextTransaction()",
    "PendingDictationInsertionAnchor(",
    "contextBefore: limitedContextBefore",
    "contextAfter: limitedContextAfter",
):
    if required not in start_command:
        raise AssertionError(f"plain dictation lost insertion anchor: {required}")
if start_command.index("finishRimeTextTransaction()") > start_command.index("currentDictationContext()"):
    raise AssertionError("voice input captures its anchor before committing Rime composition")

if "dictateWithRouteRetry" in app:
    raise AssertionError("dictation must not retry an upload after a resolved route already accepted the job")
dictate_once = block(app, "private func dictateUsingResolvedRoute(")
if "refreshRoute(" in dictate_once or "shouldRetryBridgeRequest" in dictate_once:
    raise AssertionError("resolved dictation transport regained hidden route retry behavior")
if "requiresCurrentRouteEvidence: isKeyboardPath" not in stop_pipeline:
    raise AssertionError("keyboard audio must validate its route before the one upload attempt")

release_audio = block(audio, "static func releaseCaptureRouteAndNotifyOthers(")
for required in (
    "setActive(false, options: .notifyOthersOnDeactivation)",
    "setCategory(.playback, mode: .default, options: [.mixWithOthers])",
):
    if required not in release_audio:
        raise AssertionError(f"capture audio category is not released to passive playback: {required}")
if release_audio.index("setActive(false") > release_audio.index("setCategory(.playback"):
    raise AssertionError("capture session must deactivate before changing to the passive category")
generic_deactivate = block(audio, "static func deactivateAndNotifyOthers(")
if "setCategory" in generic_deactivate:
    raise AssertionError("generic standby deactivation must not change the category during session preparation")
if "recordingShouldYieldOtherAudio" in audio:
    raise AssertionError("recording teardown regained cross-mode other-audio ownership")
restore_standby = block(audio, "private func restoreStandbyAfterRecording(")
for forbidden in (
    "releaseCaptureRouteAndNotifyOthers",
    "setActive(false",
    "engine.stop()",
    "isActive = false",
):
    if forbidden in restore_standby:
        raise AssertionError(f"Background Mic completion tears down persistent standby: {forbidden}")
for required in (
    "configureActiveSessionCategory(purpose: .standby)",
    "KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)",
):
    if required not in restore_standby:
        raise AssertionError(f"Background Mic completion does not restore persistent standby: {required}")
if "keyboardAudioSession.stopAfterCapture(discardInputEngine: true)" not in stop_pipeline:
    raise AssertionError("PiP recording completion does not use the capture-scoped route release")
for signature in (
    "private func cancelSupersededKeyboardCommand(",
    "private func cancelActiveRecordingWithoutSending(",
):
    cancel_path = block(app, signature)
    if "keyboardDictationCaptureMode == .pictureInPicture" not in cancel_path \
            or "keyboardAudioSession.stopAfterCapture(discardInputEngine: true)" not in cancel_path:
        raise AssertionError(f"PiP cancellation does not release its capture-scoped route: {signature}")

interruption_began = block(app, "private func handleAudioSessionInterruptionBegan(")
for required in (
    'event: "audio_session_interruption_began"',
    '"command_id": activeKeyboardRecordingCommandID ?? keyboardBridgeStatus.commandID ?? "none"',
    '"application_state": applicationState',
    '"reason": interruptionReason',
    '"reason_raw": rawReason.map(String.init) ?? "missing"',
    "pipDictationCoordinator.refreshContentAfterInterruption()",
    "if hadCapture",
    "failKeyboardCommand(",
    "code: .audioInterrupted",
):
    if required not in interruption_began:
        raise AssertionError(f"PiP interruption diagnosis/repaint lost invariant: {required}")
interruption_ended = block(app, "private func handleAudioSessionInterruptionEnded(")
for required in (
    'event: "audio_session_interruption_ended"',
    "pipDictationCoordinator.refreshContentAfterInterruption()",
):
    if required not in interruption_ended:
        raise AssertionError(f"PiP interruption recovery lost invariant: {required}")
if "func refreshContentAfterInterruption()" not in pip:
    raise AssertionError("PiP content cannot be explicitly repainted after a system interruption")
interruption_observer = block(app, "private func installLifecycleObservers(")
if "AVAudioSessionInterruptionReasonKey" not in interruption_observer:
    raise AssertionError("audio interruption observer does not preserve the system reason")
for event in (
    "pip_will_start",
    "pip_did_start",
    "pip_failed_to_start",
    "pip_will_stop",
    "pip_did_stop",
):
    if event not in pip:
        raise AssertionError(f"persistent PiP lifecycle diagnosis missing: {event}")

media_reset = block(app, "private func handleMediaServicesReset(")
for required in (
    "KeyboardCommandCaptureEventPolicy.effect(",
    "of: .mediaServicesReset",
    "code: .mediaServicesReset",
    "The next explicit recording or capture-mode action rebuilds it",
):
    if required not in media_reset:
        raise AssertionError(f"media-services reset lost lifecycle invariant: {required}")
if "AVAudioSession.mediaServicesWereResetNotification" not in audio:
    raise AssertionError("standby input engine is not rebuilt after media-services reset")

send_command = block(keyboard, "private func sendBridgeCommand(_ command:")
for required in (
    "if action == .cancel",
    "clearLivePartialMarkedTextIfStillOwned(",
    "livePartialPreviewState = nil",
):
    if required not in send_command:
        raise AssertionError(f"cancel lost immediate owned-preview cleanup: {required}")
if send_command.index("clearLivePartialMarkedTextIfStillOwned(") > send_command.index("livePartialPreviewState = nil"):
    raise AssertionError("cancel forgets preview ownership before clearing marked text")

for forbidden in ("hasRecentProcessingTransportContact", "processing_host_unavailable"):
    if forbidden in keyboard:
        raise AssertionError(f"transport timeout can override Host lifecycle again: {forbidden}")

apply_status = block(keyboard, "private func applyBridgeStatus(")
for required in (
    "anchor.commandID == commandID",
    "matchesCurrentInsertionAnchor(anchor)",
):
    if required not in apply_status:
        raise AssertionError(f"unanchored final can insert at the current cursor: {required}")

anchor_match = block(keyboard, "private func matchesCurrentInsertionAnchor(")
for required in (
    "KeyboardLivePartialOwnershipPolicy.insertionTargetIsCurrent(",
    "anchor.documentIdentifier",
    "textDocumentProxy.documentIdentifier",
    "capturedContextBefore: anchor.contextBefore",
    "capturedContextAfter: anchor.contextAfter",
):
    if required not in anchor_match:
        raise AssertionError(f"dictation insertion anchor lost target proof: {required}")

if "case .recording, .sending, .result, .error:" not in handshake:
    raise AssertionError("start handshake accepts an unscoped or mismatched active status")

print("OK: iOS command/status ownership invariants passed.")
PY
