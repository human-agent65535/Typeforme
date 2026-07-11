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
shared = (root / "iOS/Shared/KeyboardBridgeModels.swift").read_text()
pip = (root / "iOS/TypeformeIOS/PiP/PiPDictationCoordinator.swift").read_text()
handshake = (root / "Sources/Typeforme/Models/KeyboardStartHandshakePolicy.swift").read_text()


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
    "documentIdentifier",
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

darwin = block(app, "private func configureKeyboardDarwinBridge(")
if "_ = self.beginKeyboardStopAndSend(commandID: command.id)" not in darwin:
    raise AssertionError("Darwin stop bypasses the retained processing task")
if "await self.stopAndSend(keyboardCommandID:" in darwin:
    raise AssertionError("Darwin stop directly awaits an unowned processing operation")

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
skip_call = voice_press.index("stopActiveRefineFromUserAction()")
next_start = voice_press.index("guard !isVoicePressActive")
if "return" in voice_press[skip_call:next_start]:
    raise AssertionError("the same mic press must continue from skipping A into starting B")

text_voice = block(keyboard, "@objc private func textVoiceTapped(")
if "guard stopActiveRefineFromUserAction()" not in text_voice:
    raise AssertionError("text keyboard mic cannot replace an active refine")
skip_call = text_voice.index("guard stopActiveRefineFromUserAction()")
next_start = text_voice.index("beginDictationFromKeyboard(")
if "return" in text_voice[skip_call:next_start].split("}", 1)[-1]:
    raise AssertionError("text keyboard mic stops after skipping A instead of starting B")

final_plan = block(keyboard, "private func livePartialFinalCommitPlan(")
if "anchoredCommitted" in final_plan or "visibleCommitted" in final_plan:
    raise AssertionError("live partial final must not search or move the cursor")

ownership = block(keyboard, "private func canCommitOwnedLivePartialMarkedText(")
for required in (
    "activeMarkedText == preview.text",
    "before.hasSuffix(activeMarkedText)",
    "beforeMatches && afterMatches",
):
    if required not in ownership:
        raise AssertionError(f"marked text proof lost invariant: {required}")

partial_update = block(keyboard, "private func canPresentLivePartialPreview(")
for required in (
    "guard state.commandID == commandID else { return false }",
    "state.ownershipInvalidated = true",
    "activeMarkedTextOwner == .livePartial",
):
    if required not in partial_update:
        raise AssertionError(f"live partial ownership loss is not fail-closed: {required}")

safe_clear = block(keyboard, "private func clearLivePartialMarkedTextIfStillOwned(")
for required in (
    "state.commandID != commandID",
    "canCommitOwnedLivePartialMarkedText",
    "clearLocalMarkedTextState()",
):
    if required not in safe_clear:
        raise AssertionError(f"live partial clear lost command/anchor proof: {required}")

start_command = block(keyboard, "private func startDictationCommand(")
if start_command.index("clearLivePartialMarkedTextIfStillOwned(") > start_command.index("livePartialPreviewState = nil"):
    raise AssertionError("new command forgets the old preview before safely clearing it")
for required in (
    "PendingDictationInsertionAnchor(",
    "contextBefore: limitedContextBefore",
    "contextAfter: limitedContextAfter",
):
    if required not in start_command:
        raise AssertionError(f"plain dictation lost insertion anchor: {required}")

apply_status = block(keyboard, "private func applyBridgeStatus(")
for required in (
    "anchor.commandID == commandID",
    "matchesCurrentInsertionAnchor(anchor)",
):
    if required not in apply_status:
        raise AssertionError(f"unanchored final can insert at the current cursor: {required}")

anchor_match = block(keyboard, "private func matchesCurrentInsertionAnchor(")
if "!anchor.contextBefore.isEmpty || !anchor.contextAfter.isEmpty" not in anchor_match:
    raise AssertionError("two unrelated empty inputs can share a plain-result anchor")

if "case .recording, .sending, .result, .error:" not in handshake:
    raise AssertionError("start handshake accepts an unscoped or mismatched active status")

print("OK: iOS command/status ownership invariants passed.")
PY
