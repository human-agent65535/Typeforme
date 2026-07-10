#!/usr/bin/env bash
# Static security smoke for the iOS custom-URL trust boundary.
#
# Custom URL schemes are callable by arbitrary apps and webpages. This check
# keeps state-changing actions behind the keyboard's one-time App Group
# handoff, while preserving the non-mutating setup route.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required for the URL handoff security smoke." >&2
    exit 2
fi

/usr/bin/python3 - \
    "$ROOT/iOS/TypeformeIOS/AppState.swift" \
    "$ROOT/iOS/TypeformeKeyboard/KeyboardViewController.swift" \
    "$ROOT/iOS/Shared/KeyboardBridgeModels.swift" <<'PY'
from pathlib import Path
import sys

app_state_path, keyboard_path, shared_path = map(Path, sys.argv[1:])
app_state = app_state_path.read_text(encoding="utf-8")
keyboard = keyboard_path.read_text(encoding="utf-8")
shared = shared_path.read_text(encoding="utf-8")


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"missing function signature: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function body: {signature}")


def require(body: str, snippet: str, message: str) -> None:
    if snippet not in body:
        raise AssertionError(message)


handle_url = function_body(app_state, "func handleOpenURL(_ url: URL) async")
require(
    handle_url,
    'else if action != "setup"',
    "unauthenticated external actions are not rejected before dispatch",
)
require(
    handle_url,
    'if action == "setup"',
    "the non-mutating setup URL route was removed",
)
require(
    handle_url,
    'source == "keyboard", let handoffID',
    "keyboard URLs no longer require a handoff id",
)
require(
    handle_url,
    "consumeKeyboardHostHandoff(id: handoffID, action: action)",
    "keyboard handoff is not consumed before action dispatch",
)
require(
    handle_url,
    "await handleKeyboardHostHandoff(action: action, handoff: keyboardHandoff)",
    "authenticated keyboard handoff no longer reaches its dispatcher",
)
require(
    handle_url,
    'action == "record"',
    "record URL route is missing its explicit rejection branch",
)
if "toggleRecording(" in handle_url:
    raise AssertionError("handleOpenURL can still toggle recording without an authenticated handoff")
if "applyKeyboardParameters(" in handle_url:
    raise AssertionError("handleOpenURL can still mutate dictation parameters without an authenticated handoff")

external_guard = handle_url.index('else if action != "setup"')
authenticated_dispatch = handle_url.index("if let keyboardHandoff")
if external_guard > authenticated_dispatch:
    raise AssertionError("external URL rejection happens after action dispatch")

record_branch = handle_url[handle_url.index('else if action == "record"'):]
record_branch = record_branch[:record_branch.find('else if action == "microphone"')]
require(record_branch, "return", "unauthenticated record URL does not return before side effects")

host_handoff = function_body(
    app_state,
    "private func handleKeyboardHostHandoff(",
)
require(
    host_handoff,
    'action == "record" || action == "microphone"',
    "authenticated microphone handoff route was removed",
)
require(
    host_handoff,
    "await prepareKeyboardCaptureFromHostOpen()",
    "authenticated microphone handoff no longer prepares capture",
)

consume_handoff = function_body(
    app_state,
    "private func consumeKeyboardHostHandoff(id: String, action: String) async",
)
require(
    consume_handoff,
    "KeyboardSharedDefaults.consumeHostHandoff(",
    "host no longer consumes the one-time App Group handoff",
)
require(
    consume_handoff,
    "handoff.action == action",
    "handoff action is not bound to the URL action",
)

open_keyboard_action = function_body(
    keyboard,
    "private func openHostAppForKeyboardAction(",
)
required_keyboard_snippets = (
    "KeyboardHostHandoff(",
    "KeyboardSharedDefaults.saveHostHandoff(handoff)",
    'URLQueryItem(name: "source", value: "keyboard")',
    'URLQueryItem(name: "handoff_id", value: handoff.id)',
    "openHostApp(url)",
)
for snippet in required_keyboard_snippets:
    require(
        open_keyboard_action,
        snippet,
        f"keyboard handoff construction lost required step: {snippet}",
    )
if open_keyboard_action.index("KeyboardSharedDefaults.saveHostHandoff(handoff)") > open_keyboard_action.index("openHostApp(url)"):
    raise AssertionError("keyboard opens the host before persisting its one-time handoff")

consume_shared = function_body(
    shared,
    "static func consumeHostHandoff(id: String, now: TimeInterval",
)
require(consume_shared, "handoff.id == id", "App Group handoff id is not verified")
require(consume_shared, "handoff.isFresh(now: now)", "expired App Group handoffs are accepted")
require(
    consume_shared,
    "defaults.removeObject(forKey: hostHandoffKey)",
    "App Group handoff is replayable because it is not removed on consumption",
)

print("OK: iOS URL handoff security invariants passed.")
PY
