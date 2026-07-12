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
local_server = (root / "iOS/TypeformeIOS/Bridge/KeyboardLocalServer.swift").read_text()
handshake = (root / "Sources/Typeforme/Models/KeyboardStartHandshakePolicy.swift").read_text()
marked_policy = (root / "Sources/Typeforme/Models/KeyboardMarkedTextOwnershipPolicy.swift").read_text()


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
    "keyboardProcessingCommandID == currentID",
    "!hasAnyActiveRecordingCapture",
    "phase == .sending || phase == .refining",
    "activeKeyboardRecordingCommandID = command.id",
    "processingTask.cancel()",
    "await processingTask.value",
):
    if required not in prepare:
        raise AssertionError(f"refine supersession lost invariant: {required}")
if not (
    prepare.index("activeKeyboardRecordingCommandID = command.id")
    < prepare.index("processingTask.cancel()")
    < prepare.index("await processingTask.value")
):
    raise AssertionError("B must claim ownership before canceling and awaiting A")

stop_pipeline = block(app, "func stopAndSend(")
if stop_pipeline.count("KeyboardDarwinNotificationName.dictationStopped") != 1:
    raise AssertionError("stopAndSend must emit dictationStopped exactly once")
for required in (
    "guard shouldContinueKeyboardOperation(effectiveKeyboardCommandID)",
    "activeKeyboardRecordingCommandID == effectiveKeyboardCommandID",
):
    if required not in stop_pipeline:
        raise AssertionError(f"processing result lost ownership guard: {required}")

begin_stop = block(app, "private func beginKeyboardStopAndSend(")
for required in (
    "keyboardProcessingCommandID = commandID",
    "keyboardProcessingTask = task",
    "await self.stopAndSend(keyboardCommandID: commandID)",
):
    if required not in begin_stop:
        raise AssertionError(f"exact processing task is not retained: {required}")

start_flight = block(app, "private func runKeyboardRecordingStart(")
for required in (
    "keyboardStartCommandID = commandID",
    "keyboardStartTask = task",
    "await task.value",
):
    if required not in start_flight:
        raise AssertionError(f"exact start task is not retained: {required}")

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
if darwin.index("guard await self.prepareKeyboardStart(command)") > darwin.index("self.applyKeyboardDefaultCorrectionMode(requestedMode)"):
    raise AssertionError("a stale Darwin start can change the active correction mode")

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
stopped = darwin_observers[darwin_observers.index("KeyboardDarwinNotificationName.dictationStopped"):]
stopped = stopped[:stopped.index("KeyboardDarwinNotificationName.transcriptionReady")]
if stopped.index("if wasStarting") > stopped.index("self.finishStoppedNotification()"):
    raise AssertionError("an unscoped late A stop can clear the in-flight B start")

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
transport_guard = voice_press.index("if currentBridgeStatus?.state == .sending", skip_call)
if "return" not in voice_press[skip_call:transport_guard]:
    raise AssertionError("voice-mode Send Without Refine must not also start the next recording")

text_voice = block(keyboard, "@objc private func textVoiceTapped(")
if "guard stopLivePartialRefineFromUserAction()" not in text_voice:
    raise AssertionError("text keyboard mic cannot replace an active refine")
if "stopActiveStyleRewriteFromUserAction()" not in text_voice:
    raise AssertionError("text keyboard style rewrite stop boundary is missing")
skip_call = text_voice.index("guard stopLivePartialRefineFromUserAction()")
next_start = text_voice.index("beginDictationFromKeyboard(")
if "return" in text_voice[skip_call:next_start].split("}", 1)[-1]:
    raise AssertionError("text keyboard mic stops after skipping A instead of starting B")

text_space = block(keyboard, "private func handleTextSpace(")
space_sending = text_space[text_space.index("if currentBridgeStatus?.state == .sending"):]
space_sending = space_sending[:space_sending.index("clearTransientKeyboardErrorIfShowing()")]
if "stopActiveRefineFromUserAction()" not in space_sending or "return" not in space_sending:
    raise AssertionError("text-keyboard Send Without Refine must commit A without starting B")

rime_mutation = block(keyboard, "private func applyRimeState(")
if "validateRimeDocumentForMutation()" not in rime_mutation:
    raise AssertionError("Rime proxy mutation is not document scoped")
rime_discard = block(keyboard, "private func discardStaleRimeInput(")
for forbidden in ("textDocumentProxy", "replaceMarkedText", "unmarkText"):
    if forbidden in rime_discard:
        raise AssertionError(f"stale Rime cleanup mutates the new input target: {forbidden}")

apply_status = block(keyboard, "private func applyBridgeStatus(")
if "status.state == .error" not in apply_status or "finishStartRequestIfNeeded(status: status)" not in apply_status:
    raise AssertionError("a command-matched start error can leave the start flight active")

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
    'event: "live_preview_initial_target_changed"',
):
    if required not in partial_update:
        raise AssertionError(f"live partial ownership loss is not fail-closed: {required}")

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
for forbidden in ("discardStaleRimeInput", "clearComposition", "replaceMarkedText"):
    if forbidden in text_will_change:
        raise AssertionError(f"selection changes must not clear marked Rime text: {forbidden}")

if "finishRimeInputBeforeExternalProxyChange" in keyboard:
    raise AssertionError("cursor movement must not finish marked Rime text")

space_cursor = block(keyboard, "@objc private func handleTextSpaceCursorGesture(")
for forbidden in ("commitComposition", "commitDisplayedRimeCompositionIfNeeded", "clearComposition"):
    if forbidden in space_cursor:
        raise AssertionError(f"space trackpad must preserve marked Rime text: {forbidden}")
if "setTextTrackpadMode(true)" not in space_cursor:
    raise AssertionError("space trackpad no longer enters cursor mode")

trackpad_end = block(keyboard, "private func endTextSpaceCursorTracking(")
for required in ("state.isComposing", "renderRimeState(state)", "renderRefineSuggestionsIfIdle()"):
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
if "else if !state.isComposing" not in trackpad_cursor:
    raise AssertionError("active Rime composition must never fall through to the host document cursor")

partial_rebase = block(keyboard, "private func rebasePartialRimeCompositionForInlineEdit(")
for required in (
    "rimeInput.replaceCompositionInput(",
    "commitTextReplacingMarkedText(split.committedPrefix",
    "rimeCompositionSession = currentRimeCompositionSession()",
    "caretOffset,",
    "in: remainingState.input",
    "applyRimeState(remainingState)",
):
    if required not in partial_rebase:
        raise AssertionError(f"partial Rime rebase lost stack boundary: {required}")

inline_character = block(rime_controller, "func replaceCompositionInput(")
for required in (
    "api.cleanComposition(session)",
    "for scalar in input.unicodeScalars",
    "committedText += drainCommit()",
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

apply_rime = block(keyboard, "private func applyRimeState(")
for required in (
    "commitTextReplacingMarkedText(state.commitText",
    "rimeCompositionSession = currentRimeCompositionSession()",
    "selectionLocation: rimeMarkedTextSelectionLocation(for: state)",
):
    if required not in apply_rime:
        raise AssertionError(f"Rime commit/composition transaction lost step: {required}")
if not (
    apply_rime.index("commitTextReplacingMarkedText(state.commitText")
    < apply_rime.index("rimeCompositionSession = currentRimeCompositionSession()")
    < apply_rime.index("selectionLocation: rimeMarkedTextSelectionLocation(for: state)")
):
    raise AssertionError("Rime commit + composition must rebase between commit and the new marked text")

start_command = block(keyboard, "private func startDictationCommand(")
if start_command.index("clearLivePartialMarkedTextIfStillOwned(") > start_command.index("livePartialPreviewState = nil"):
    raise AssertionError("new command forgets the old preview before safely clearing it")
for required in (
    "commitDisplayedRimeCompositionIfNeeded()",
    "PendingDictationInsertionAnchor(",
    "contextBefore: limitedContextBefore",
    "contextAfter: limitedContextAfter",
):
    if required not in start_command:
        raise AssertionError(f"plain dictation lost insertion anchor: {required}")
if start_command.index("commitDisplayedRimeCompositionIfNeeded()") > start_command.index("currentDictationContext()"):
    raise AssertionError("voice input captures its anchor before committing Rime composition")

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

if "hasRecentProcessingTransportContact" not in keyboard or "processing_host_unavailable" not in keyboard:
    raise AssertionError("lost host transport can leave the keyboard stuck in Sending")

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
