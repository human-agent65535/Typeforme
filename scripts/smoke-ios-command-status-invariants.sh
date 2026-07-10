#!/usr/bin/env bash
# Static smoke for cross-process keyboard command and status ordering invariants.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required for the command/status invariant smoke." >&2
    exit 2
fi

/usr/bin/python3 - \
    "$ROOT/iOS/Shared/KeyboardBridgeModels.swift" \
    "$ROOT/iOS/TypeformeIOS/AppState.swift" \
    "$ROOT/iOS/TypeformeKeyboard/KeyboardViewController.swift" \
    "$ROOT/iOS/TypeformeIOS/Bridge/KeyboardLocalServer.swift" \
    "$ROOT/iOS/TypeformeIOS/Bridge/BridgeClient.swift" \
    "$ROOT/iOS/TypeformeKeyboard/KeyboardLocalClient.swift" <<'PY'
from pathlib import Path
import re
import sys

(
    shared_path,
    app_state_path,
    keyboard_path,
    local_server_path,
    bridge_client_path,
    keyboard_local_client_path,
) = map(Path, sys.argv[1:])
shared = shared_path.read_text(encoding="utf-8")
app_state = app_state_path.read_text(encoding="utf-8")
keyboard = keyboard_path.read_text(encoding="utf-8")
local_server = local_server_path.read_text(encoding="utf-8")
bridge_client = bridge_client_path.read_text(encoding="utf-8")
keyboard_local_client = keyboard_local_client_path.read_text(encoding="utf-8")


def block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"missing declaration: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated body: {signature}")


def require(source: str, snippet: str, message: str) -> None:
    if snippet not in source:
        raise AssertionError(message)


def segment(source: str, start: str, end: str) -> str:
    start_index = source.find(start)
    if start_index < 0:
        raise AssertionError(f"missing segment start: {start}")
    end_index = source.find(end, start_index + len(start))
    if end_index < 0:
        raise AssertionError(f"missing segment end: {end}")
    return source[start_index:end_index]


# Every host status frame carries ordering metadata, including derived and
# redacted copies. Losing either field lets delayed frames regress keyboard UI.
status = block(shared, "struct KeyboardBridgeStatus:")
if not re.search(r"\blet\s+hostInstanceID:\s*String\b", status):
    raise AssertionError("KeyboardBridgeStatus lost hostInstanceID")
if not re.search(r"\blet\s+revision:\s*UInt64\b", status):
    raise AssertionError("KeyboardBridgeStatus lost revision")

for declaration in (
    "func withAudioLevel(_ level: Float?)",
    "func withLivePartialTranscript(_ text: String?)",
    "var redactedForSharedDefaults: KeyboardBridgeStatus",
):
    body = block(shared, declaration)
    require(body, "hostInstanceID: hostInstanceID", f"{declaration} drops hostInstanceID")
    require(body, "revision: revision", f"{declaration} drops revision")


# AppState has three egresses: stored/snapshot status, snapshot provider, and
# high-frequency audio-level frames. All must allocate the next host revision.
set_status = block(app_state, "private func setKeyboardBridgeStatus(")
require(
    set_status,
    "let orderedStatus = nextKeyboardStatusFrame(status)",
    "stored keyboard status is not assigned an outbound revision",
)
require(set_status, "keyboardBridgeStatus = orderedStatus", "unordered status is stored")
require(set_status, "keyboardServer.publishStatus(orderedStatus)", "unordered status is streamed")
require(set_status, "saveStatusSnapshot(orderedStatus)", "unordered status is persisted")

configure_server = block(app_state, "private func configureKeyboardServer()")
require(
    configure_server,
    "return self.nextKeyboardStatusFrame(status)",
    "status snapshot provider returns a frame without a fresh revision",
)

audio_push = block(app_state, "private func updateKeyboardStatusAudioLevelPush(")
require(
    audio_push,
    "let status = self.nextKeyboardStatusFrame(",
    "audio-level status bypasses host ordering",
)
require(audio_push, "self.keyboardServer.publishStatus(status)", "audio-level frame is not published")

publish_calls = re.findall(r"keyboardServer\.publishStatus\(([^\n]+)\)", app_state)
if sorted(argument.strip() for argument in publish_calls) != ["orderedStatus", "status"]:
    raise AssertionError(
        f"unexpected direct keyboard status egress bypasses the reviewed ordering paths: {publish_calls}"
    )


# Reject stale revisions before any command/UI reconciliation mutates local
# keyboard state.
apply_status = block(keyboard, "private func applyBridgeStatus(")
first_statement = apply_status.lstrip()
if not first_statement.startswith("if shouldIgnoreOutOfOrderHostStatus(status)"):
    raise AssertionError("applyBridgeStatus does not reject out-of-order frames first")
status_signature = segment(
    apply_status,
    "let signature = [",
    "guard signature != lastStatusSignature",
)
if "status.revision" in status_signature or "status.updatedAt" in status_signature:
    raise AssertionError("ordering/heartbeat metadata triggers full keyboard UI rebuilds")
out_of_order = block(keyboard, "private func shouldIgnoreOutOfOrderHostStatus(")
require(out_of_order, "status.revision > activeHostStatusRevision", "status revision is not monotonic")
require(
    out_of_order,
    "status.updatedAt > activeHostStatusUpdatedAt",
    "an older process instance can replace the active host instance",
)
require(out_of_order, "return true", "out-of-order status is not rejected")

for forbidden in ("TimeoutWatchdog", "timedOutBridgeCommandIDs"):
    if forbidden in keyboard:
        raise AssertionError(f"keyboard regained a second business completion clock: {forbidden}")


# Host-to-keyboard Darwin events are authenticated just like keyboard requests;
# a public fixed-name stopped event must not be able to mutate keyboard state.
darwin_post = block(shared, "static func post(_ name: String)")
darwin_observe = block(shared, "static func observe(_ name: String, callback:")
for body, direction in ((darwin_post, "post"), (darwin_observe, "observe")):
    require(
        body,
        "KeyboardDarwinNotificationName.authenticatedHostEvent(",
        f"Darwin host event {direction} bypasses token-derived naming",
    )


# Job events are progress-only. The HTTP request is the sole terminal authority,
# so Result cannot become visible while the Host still owns the command.
dictate_retry = block(app_state, "private func dictateWithRouteRetry(")
for forbidden in ("BridgeRequestCancellationHandle", "BridgeDictateTerminal"):
    if forbidden in dictate_retry:
        raise AssertionError(f"WS terminal competes with HTTP completion: {forbidden}")
job_progress = block(app_state, "private func applyBridgeJobStatus(")
require(
    job_progress,
    "guard phase.isBusy, !event.stage.isTerminal else { return }",
    "job event path can publish a terminal command state",
)

stop_and_send_pipeline = block(app_state, "private func performStopAndSend(")
if "if isBenignEmptyTranscript(error)" not in stop_and_send_pipeline:
    raise AssertionError("empty transcript is not handled as a benign HTTP outcome")


# Darwin stop/cancel notifications have no payload. A missing or mismatched
# App Group command must never fall back to an unscoped host stop.
darwin = block(app_state, "private func configureKeyboardDarwinBridge()")
darwin_stop = segment(
    darwin,
    "KeyboardDarwinBridge.observe(requestStopName)",
    "KeyboardDarwinBridge.observe(requestCancelName)",
)
require(
    darwin_stop,
    "guard let command = KeyboardSharedDefaults.consumeDarwinCommand(action: .stop)",
    "Darwin stop accepts a notification without its command payload",
)
require(
    darwin_stop,
    "guard self.keyboardCaptureOperationBelongs(to: command.id)",
    "Darwin stop does not verify capture ownership",
)
if "stopAndSend(" in darwin_stop:
    raise AssertionError("Darwin stop directly calls stopAndSend and can become unscoped")

darwin_cancel = segment(
    darwin,
    "KeyboardDarwinBridge.observe(requestCancelName)",
    "KeyboardDarwinBridge.observe(requestSessionStatusName)",
)
require(
    darwin_cancel,
    "guard self.keyboardCaptureOperationBelongs(to: command.id)",
    "Darwin cancel does not verify capture ownership",
)


# Local stop/cancel follows the same command ownership contract. Configure is
# settings-only and must not clear an in-flight capture's context.
handle_command = block(app_state, "private func handleKeyboardCommand(")
local_stop = segment(handle_command, "case .stop:", "case .cancel:")
require(
    local_stop,
    "beginKeyboardStopAndSend(commandID: command.id)",
    "local stop bypasses the ownership-checked stop helper",
)
stop_helper = block(app_state, "private func beginKeyboardStopAndSend(commandID: String)")
if not stop_helper.lstrip().startswith("guard keyboardCaptureOperationBelongs(to: commandID)"):
    raise AssertionError("local stop helper does not verify capture ownership first")
require(
    stop_helper,
    "captureStartInFlightOwner == .keyboard(commandID: commandID)",
    "an early stop can be lost while keyboard capture preparation is in flight",
)

local_cancel = segment(handle_command, "case .cancel:", "case .configure:")
require(
    local_cancel,
    "guard keyboardCaptureOperationBelongs(to: command.id)",
    "local cancel does not verify capture ownership",
)

configure = segment(handle_command, "case .configure:", "case .refineText:")
if "clearKeyboardCaptureContext" in configure:
    raise AssertionError("configure clears the active keyboard capture context")

stop_and_send = block(app_state, "func stopAndSend(keyboardCommandID: String? = nil) async")
require(
    stop_and_send,
    "!keyboardCaptureOperationBelongs(to: keyboardCommandID)",
    "stopAndSend does not reject a non-owning keyboard command",
)


# Standby refresh is a mode/generation-owned preparation. Mode changes cancel
# the refresh, and no stale catch path may unconditionally resurrect audio.
mode_setter = block(app_state, "func setKeyboardDictationCaptureMode(")
if mode_setter.find("cancelKeyboardStandbyRefresh()") > mode_setter.find("beginCapturePreparation()"):
    raise AssertionError("mode change invalidates standby refresh too late")
standby_resume = block(app_state, "private func resumeKeyboardStandbyAfterCommand(")
for snippet in (
    "let selectedMode = keyboardDictationCaptureMode",
    "let preparationGeneration = beginCapturePreparation()",
    "capturePreparationIsCurrent(preparationGeneration, mode: selectedMode)",
    "expectedMode: selectedMode",
):
    require(standby_resume, snippet, "standby refresh is not mode/generation-owned")
if "startSilentStandbyKeeperIfNeeded()" in standby_resume:
    raise AssertionError("stale standby refresh can resurrect the silent keeper")


# Listener readiness owns process infrastructure, not a recording command.
# Call cancellation must leave the short shared readiness flight running.
ensure_ready = block(local_server, "func ensureReady(")
require(ensure_ready, "acquireReadinessFlight(", "local bridge readiness is not single-flight")
require(
    ensure_ready,
    "let sharedResult = await flight.task.value",
    "recording cancellation can cancel shared bridge readiness",
)
if "withTaskCancellationHandler" in ensure_ready:
    raise AssertionError("recording cancellation is coupled to bridge readiness")
perform_ensure = block(local_server, "private func performEnsureReady(")
require(perform_ensure, "initialGeneration", "readiness work is not generation-owned")
force_restart = block(local_server, "private func forceRestart(")
require(force_restart, "expectedGeneration", "listener restart is not conditioned on the failed generation")
is_cancellation = block(local_server, "private static func isCancellation(_ error: Error, depth: Int)")
require(is_cancellation, 'nsError.domain == "Swift.CancellationError"', "Swift NSError cancellation is misclassified")


# There is one Host processing deadline; local refine transport owners merely
# outlive it and do not create keyboard-side business watchdogs.
require(
    bridge_client,
    "processingRequestTimeout: TimeInterval = 210",
    "BridgeClient lost its single processing deadline",
)
require(
    keyboard_local_client,
    "return 220",
    "keyboard refine transport expires before BridgeClient's legal ceiling",
)
require(
    local_server,
    "refineHandlingTimeoutNanoseconds: UInt64 = 225_000_000_000",
    "local server cancels a legal refine command before its client deadline",
)

print("OK: iOS keyboard command/status invariants passed.")
PY
