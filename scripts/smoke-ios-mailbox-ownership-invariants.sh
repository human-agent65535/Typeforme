#!/usr/bin/env bash
# Static smoke for durable result delivery and keyboard/Rime ownership boundaries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required for the mailbox/ownership invariant smoke." >&2
    exit 2
fi

/usr/bin/python3 - \
    "$ROOT/iOS/TypeformeIOS/AppState.swift" \
    "$ROOT/iOS/TypeformeKeyboard/KeyboardViewController.swift" \
    "$ROOT/iOS/Shared/KeyboardBridgeModels.swift" <<'PY'
from pathlib import Path
import re
import sys

app_state_path, keyboard_path, shared_models_path = map(Path, sys.argv[1:])
app_state = app_state_path.read_text(encoding="utf-8")
keyboard = keyboard_path.read_text(encoding="utf-8")
shared_models = shared_models_path.read_text(encoding="utf-8")


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


# The mailbox is a single protected App Group file. Keychain remains reserved
# for the bridge token; result text must not return to shared defaults or a
# second Keychain-backed payload store.
mailbox = block(shared_models, "enum KeyboardSharedMailbox")
for snippet, message in (
    ('private static let fileName = "keyboard-mailbox.v1.json"', "mailbox file name changed unexpectedly"),
    ("options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]", "mailbox write lost atomic file protection"),
    ("resourceValues.isExcludedFromBackup = true", "mailbox file is no longer excluded from backup"),
    ("guard var mailbox = load(now: now),", "host result can be saved without an existing destination mailbox"),
    ("mailbox.commandID == result.commandID", "host result no longer matches the destination command"),
):
    require(mailbox, snippet, message)

envelope = block(shared_models, "private struct KeyboardPendingMailbox")
for snippet, message in (
    ("destination.commandID == commandID", "mailbox destination is not command-scoped"),
    ("finalResult.commandID == commandID", "mailbox result is not command-scoped"),
):
    require(envelope, snippet, message)

keychain = block(shared_models, "enum KeyboardSharedKeychain")
for forbidden in (
    "pendingFinalResultAccount",
    "pendingDestinationAccount",
    "savePendingFinalResult",
    "savePendingDestination",
):
    if forbidden in keychain:
        raise AssertionError(f"Keychain still stores mailbox payloads: {forbidden}")

# The host persists the final result before publishing any status that can wake
# the keyboard consumer.
publish_status = block(app_state, "private func publishKeyboardStatus(")
require(publish_status, "if state == .result,", "final result persistence lost its result-state guard")
save_result_index = publish_status.find("KeyboardSharedMailbox.savePendingFinalResult(")
publish_result_index = publish_status.find("setKeyboardBridgeStatus(")
if save_result_index < 0:
    raise AssertionError("host no longer saves a pending final result")
if publish_result_index < 0:
    raise AssertionError("host no longer publishes keyboard status")
if save_result_index >= publish_result_index:
    raise AssertionError("host publishes result status before saving the durable final result")
require(
    publish_status,
    "KeyboardPendingFinalResult(\n                    commandID: commandID,\n                    text: resultText,",
    "host pending final result is not tied to the published command and text",
)


# A keyboard start must snapshot the exact insertion destination before the
# command leaves the extension, so a delayed/recovered result cannot drift.
start_dictation = block(keyboard, "private func startDictationCommand(")
plain_destination = segment(
    start_dictation,
    "if textEditContext == nil {",
    "} else if case .selection",
)
for snippet, message in (
    ("commandID: command.id", "pending destination lost the start command ID"),
    (
        "documentIdentifier: textDocumentProxy.documentIdentifier.uuidString",
        "pending destination lost the document identifier",
    ),
    (
        'contextBefore: contextBefore ?? ""',
        "pending destination lost context before the cursor",
    ),
    (
        'contextAfter: contextAfter ?? ""',
        "pending destination lost context after the cursor",
    ),
    (
        "contextBeforeAvailable: contextBefore != nil",
        "pending destination lost context-before availability",
    ),
    (
        "contextAfterAvailable: contextAfter != nil",
        "pending destination lost context-after availability",
    ),
    ("selectedText: textDocumentProxy.selectedText", "pending destination lost the selection snapshot"),
):
    require(plain_destination, snippet, message)

save_destination_index = start_dictation.find("KeyboardSharedMailbox.savePendingDestination(destination)")
send_start_index = start_dictation.find("sendBridgeCommand(command)")
if save_destination_index < 0 or send_start_index < 0:
    raise AssertionError("keyboard start lost destination persistence or command dispatch")
if save_destination_index >= send_start_index:
    raise AssertionError("keyboard start dispatches before saving its pending destination")


# Destination validity includes document identity, both surrounding contexts,
# and selection. Recovery must pass this complete check before inserting text.
destination_is_current = block(keyboard, "private func dictationDestinationIsCurrent(")
for snippet, message in (
    (
        "textDocumentProxy.documentIdentifier.uuidString == destination.documentIdentifier",
        "destination validation lost document identity",
    ),
    (
        "(currentBefore != nil) == destination.contextBeforeAvailable",
        "destination validation conflates missing and empty context before",
    ),
    (
        "(currentAfter != nil) == destination.contextAfterAvailable",
        "destination validation conflates missing and empty context after",
    ),
    (
        '(currentBefore ?? "") == destination.contextBefore',
        "destination validation lost context-before equality",
    ),
    (
        '(currentAfter ?? "") == destination.contextAfter',
        "destination validation lost context-after equality",
    ),
    (
        "textDocumentProxy.selectedText == destination.selectedText",
        "destination validation lost selection equality",
    ),
):
    require(destination_is_current, snippet, message)

recovery = block(keyboard, "private func recoverPendingFinalResultIfPossible()")
require(
    recovery,
    "let delivery = KeyboardSharedMailbox.loadPendingDelivery()",
    "recovery no longer consumes one atomic destination/result snapshot",
)
for snippet, message in (
    (
        "preview.commandID == result.commandID",
        "mailbox recovery no longer scopes live partial replacement to the result command",
    ),
    (
        "guard activeMarkedText.isEmpty || activeMarkedTextOwner == .livePartial else {",
        "mailbox recovery can replace Rime or unknown marked text",
    ),
    (
        "let didApply = applyFinalResultForLivePartialPreview(",
        "mailbox recovery no longer reuses the live partial final-commit plan",
    ),
    (
        "finishRecoveredPendingFinalResult(result, didApply: didApply)",
        "mailbox recovery does not finish or safely copy a live partial result",
    ),
):
    require(recovery, snippet, message)
commit_index = recovery.find("commitTextReplacingMarkedText(result.text, reason: .bridgeResult)")
validation_index = recovery.rfind(
    "guard dictationDestinationIsCurrent(destination),",
    0,
    commit_index,
)
if validation_index < 0 or commit_index < 0 or validation_index >= commit_index:
    raise AssertionError("recovery can insert a final result before validating its destination")

already_inserted = segment(
    recovery,
    "if defaults.string(forKey: lastInsertedCommandIDKey) == result.commandID {",
    "guard dictationDestinationIsCurrent(destination),",
)
acknowledgment = "KeyboardSharedMailbox.clear(commandID: result.commandID)"
require(already_inserted, acknowledgment, "idempotent recovery uses an unscoped mailbox acknowledgment")
require(
    recovery[commit_index:],
    "finishRecoveredPendingFinalResult(result, didApply: true)",
    "successful direct recovery bypasses its command-scoped completion helper",
)
finish_recovery = block(keyboard, "private func finishRecoveredPendingFinalResult(")
require(finish_recovery, acknowledgment, "recovery completion uses an unscoped mailbox acknowledgment")
require(
    finish_recovery,
    "copyFallbackText(result.text)",
    "failed live partial recovery can discard the final result instead of copying it",
)


# The live result path follows the same command ownership contract. Its final
# result ACK and destination cleanup must both be scoped to the result command.
apply_status = block(keyboard, "private func applyBridgeStatus(")
normal_result = segment(
    apply_status,
    "if status.state == .result,",
    "if status.state == .error || status.state == .idle || status.state == .standby",
)
require(
    normal_result,
    "acknowledgePendingMailbox(commandID: commandID)",
    "normal result delivery does not clear the matching mailbox command",
)

clear_destination = block(keyboard, "private func clearDictationDestinationIfMatching(")
require(
    clear_destination,
    "KeyboardSharedMailbox.clear(commandID: commandID)",
    "destination cleanup helper drops command ownership",
)


# Dictation takes ownership only after pending Rime input/composition has been
# committed. The replay path also rejects queued input from another document.
begin_dictation = block(keyboard, "private func beginDictationFromKeyboard(")
commit_rime_index = begin_dictation.find("commitPendingRimeInputForOwnershipBoundary()")
start_command_index = begin_dictation.find("startDictationCommand(")
if commit_rime_index < 0 or start_command_index < 0 or commit_rime_index >= start_command_index:
    raise AssertionError("dictation starts before committing the Rime ownership boundary")

commit_rime = block(keyboard, "private func commitPendingRimeInputForOwnershipBoundary()")
for snippet, message in (
    (
        "let pendingRawInput = pendingRimeCharacters.joined() + pendingRimeDirectTextKeys.joined()",
        "Rime ownership boundary no longer collects pending raw input",
    ),
    ("commitRawRimeInput(pendingRawInput)", "Rime ownership boundary drops pending raw input"),
    (
        "commitDisplayedRimeCompositionIfNeeded()",
        "Rime ownership boundary drops displayed composition",
    ),
):
    require(commit_rime, snippet, message)

rime_replay = block(keyboard, "private func applyReadyRimeStateOrRender(")
document_guard_index = rime_replay.find(
    "guard pendingRimeDocumentIdentifier == textDocumentProxy.documentIdentifier.uuidString else {"
)
direct_replay_index = rime_replay.find("textDocumentProxy.insertText(queuedDirectText)")
character_replay_index = rime_replay.find("rimeInput.processCharacter(")
if document_guard_index < 0:
    raise AssertionError("pending Rime replay lost its document-identifier guard")
if direct_replay_index < 0 or character_replay_index < 0:
    raise AssertionError("pending Rime replay paths are missing")
if document_guard_index >= min(direct_replay_index, character_replay_index):
    raise AssertionError("pending Rime input can replay before document identity is validated")


# Truncated UIKit context may only authorize deletion when the entire target is
# visible and verified. A target.hasSuffix(currentBefore) check proves only a
# fragment and must never authorize deleting target.count characters.
truncated_undo = block(keyboard, "private func replaceTextBeforeCursorAllowingTruncatedContext(")
if "target.hasSuffix(currentBefore)" in truncated_undo:
    raise AssertionError("truncated undo can delete a full target after matching only a suffix fragment")
for snippet, message in (
    (
        "let expectedBefore = contextBefore + target",
        "truncated undo lost its expected full before-context",
    ),
    (
        "expectedBefore.hasSuffix(currentBefore)",
        "truncated undo no longer verifies the visible truncated context",
    ),
    (
        "currentBefore.hasSuffix(target)",
        "truncated undo no longer requires the complete deletion target to be visible",
    ),
):
    require(truncated_undo, snippet, message)

delete_index = truncated_undo.find("deleteBackward(characterCount: target.count)")
full_target_index = truncated_undo.find("currentBefore.hasSuffix(target)")
if delete_index < 0 or full_target_index < 0 or full_target_index >= delete_index:
    raise AssertionError("truncated undo deletes before verifying the complete target")

print("OK: iOS mailbox/destination/Rime ownership invariants passed.")
PY
