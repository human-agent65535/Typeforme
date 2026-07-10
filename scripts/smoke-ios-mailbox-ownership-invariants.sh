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
    "$ROOT/iOS/TypeformeKeyboard/KeyboardViewController.swift" <<'PY'
from pathlib import Path
import re
import sys

app_state_path, keyboard_path = map(Path, sys.argv[1:])
app_state = app_state_path.read_text(encoding="utf-8")
keyboard = keyboard_path.read_text(encoding="utf-8")


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


# The host's durable mailbox is the source of truth for a final result. Persist
# it before publishing any result status that can wake the keyboard consumer.
publish_status = block(app_state, "private func publishKeyboardStatus(")
require(publish_status, "if state == .result,", "final result persistence lost its result-state guard")
save_result_index = publish_status.find("KeyboardSharedKeychain.savePendingFinalResult(")
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

save_destination_index = start_dictation.find("KeyboardSharedKeychain.savePendingDestination(destination)")
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
    "result.commandID == destination.commandID",
    "recovery no longer binds result and destination to the same command",
)
validation_index = recovery.find("guard dictationDestinationIsCurrent(destination),")
commit_index = recovery.find("commitTextReplacingMarkedText(result.text, reason: .bridgeResult)")
if validation_index < 0 or commit_index < 0 or validation_index >= commit_index:
    raise AssertionError("recovery can insert a final result before validating its destination")

already_inserted = segment(
    recovery,
    "if defaults.string(forKey: lastInsertedCommandIDKey) == result.commandID {",
    "guard dictationDestinationIsCurrent(destination),",
)
for acknowledgment in (
    "acknowledgePendingFinalResult(commandID: result.commandID)",
    "acknowledgePendingDestination(commandID: result.commandID)",
):
    require(already_inserted, acknowledgment, "idempotent recovery uses an unscoped mailbox acknowledgment")
    require(recovery[commit_index:], acknowledgment, "successful recovery uses an unscoped mailbox acknowledgment")

if re.search(r"acknowledgePending(?:FinalResult|Destination)\s*\(\s*\)", recovery):
    raise AssertionError("recovery contains an unscoped mailbox acknowledgment")


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
    "KeyboardSharedKeychain.acknowledgePendingFinalResult(commandID: commandID)",
    "normal result delivery does not ACK the matching final-result command",
)
require(
    normal_result,
    "clearDictationDestinationIfMatching(commandID: commandID)",
    "normal result delivery clears destination without command ownership",
)
if re.search(r"acknowledgePendingFinalResult\s*\(\s*\)", normal_result):
    raise AssertionError("normal result delivery contains an unscoped final-result ACK")

clear_destination = block(keyboard, "private func clearDictationDestinationIfMatching(")
require(
    clear_destination,
    "KeyboardSharedKeychain.clearPendingDestination(commandID: commandID)",
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
