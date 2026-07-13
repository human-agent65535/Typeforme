#!/usr/bin/env bash
# Simulator-only matrix smoke test for keyboard capture recovery paths.
#
# This verifies:
#   - Background Mic standby and recovery when the simulator exposes audio input.
#   - Explicit microphone-unavailable lifecycle failures otherwise.
#   - A stopped local WebSocket server recovers before capture is attempted.
#   - PiP mode with inactive PiP reaches an explicit failed lifecycle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$ROOT/.build/ios-simulator-derived}"
PREFERRED_SIMULATOR_NAME="${PREFERRED_SIMULATOR_NAME:-iPhone 17 Pro Max}"
RUN_ID="${RUN_ID:-sim-capture-$(date +%s)-$RANDOM}"

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
# shellcheck source=scripts/lib/ios-bundle-checks.sh
. "$ROOT/scripts/lib/ios-bundle-checks.sh"
typeforme_configure_xcode "run iOS keyboard capture matrix simulator smoke test"
typeforme_configure_xcrun

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required to parse simulator state." >&2
    exit 2
fi

simctl() {
    typeforme_xcrun simctl "$@"
}

echo "==> Building/installing simulator app"
CONFIG="$CONFIG" DERIVED="$DERIVED" "$ROOT/scripts/verify-ios-simulator.sh" "$@"

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphonesimulator/Typeforme.app"
KEYBOARD_APPEX_PATH="$APP_PATH/PlugIns/TypeformeKeyboard.appex"
typeforme_verify_ios_host_keyboard_bundle "$APP_PATH" "$KEYBOARD_APPEX_PATH" "built"
BUNDLE_ID="$TYPEFORME_IOS_HOST_BUNDLE_ID"
APP_GROUP_ID="$TYPEFORME_IOS_HOST_APP_GROUP_ID"

SIMCTL_LIST_JSON="$(mktemp -t typeforme-capture-smoke-simulators)"
trap 'rm -f "$SIMCTL_LIST_JSON"' EXIT
simctl list devices available -j >"$SIMCTL_LIST_JSON"

SIMULATOR_ID="$(
    /usr/bin/python3 - "$SIMCTL_LIST_JSON" "$PREFERRED_SIMULATOR_NAME" "${SIMULATOR_ID:-}" <<'PY'
import json
import sys

path, preferred_name, explicit_id = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    devices_by_runtime = json.load(handle).get("devices", {})

devices = []
for runtime, runtime_devices in devices_by_runtime.items():
    if "iOS" not in runtime:
        continue
    devices.extend(device for device in runtime_devices if device.get("isAvailable", False))

if explicit_id:
    for device in devices:
        if device.get("udid") == explicit_id:
            print(device["udid"])
            raise SystemExit
    raise SystemExit("error: SIMULATOR_ID is not an available iOS simulator")

booted = [device for device in devices if device.get("state") == "Booted"]
preferred_booted = [device for device in booted if device.get("name") == preferred_name]
if preferred_booted:
    print(preferred_booted[0]["udid"])
    raise SystemExit
if booted:
    print(booted[0]["udid"])
    raise SystemExit
raise SystemExit("error: no booted iOS simulator after verify-ios-simulator.sh")
PY
)"

GROUP_PATH="$(simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" "$APP_GROUP_ID")"
DIAGNOSTIC_LOG="$GROUP_PATH/Library/Caches/KeyboardDiagnostics/host-app.jsonl"
PREFS_PLIST="$GROUP_PATH/Library/Preferences/$APP_GROUP_ID.plist"

debug_url() {
    local action="$1"
    local query="$2"
    simctl openurl "$SIMULATOR_ID" "typeforme://debug/$action?$query" >/dev/null
}

wait_event() {
    local event="$1"
    local label="$2"
    local deadline_seconds="${3:-8.0}"
    /usr/bin/python3 - "$DIAGNOSTIC_LOG" "$RUN_ID" "$event" "$label" "$deadline_seconds" <<'PY'
import json
import sys
import time

diagnostic_log, run_id, event, label, deadline_seconds = sys.argv[1:]
deadline = time.time() + float(deadline_seconds)
result = None

while time.time() < deadline:
    try:
        with open(diagnostic_log, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        lines = []
    for line in lines[-600:]:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("event") != event:
            continue
        fields = entry.get("fields") or {}
        if fields.get("run_id") == run_id and fields.get("label") == label:
            result = fields
    if result is not None:
        break
    time.sleep(0.15)

print(json.dumps(result or {"run_id": run_id, "label": label}, sort_keys=True))
PY
}

assert_fields() {
    local result_json="$1"
    shift
    /usr/bin/python3 - "$result_json" "$@" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
errors = []
for expectation in sys.argv[2:]:
    key, expected = expectation.split("=", 1)
    actual = result.get(key)
    if actual != expected:
        errors.append(f"{key}: expected {expected!r}, got {actual!r}; result={result}")

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

wait_darwin_result() {
    local command_id="$1"
    local expected_stage="$2"
    local expected_failure_code="${3:-}"
    /usr/bin/python3 - "$DIAGNOSTIC_LOG" "$PREFS_PLIST" "$command_id" "$expected_stage" "$expected_failure_code" <<'PY'
import json
import plistlib
import sys
import time

diagnostic_log, prefs_plist, command_id, expected_stage, expected_failure_code = sys.argv[1:]
terminal_prefixes = ("start_keyboard_recording_failed_",)
terminal_events = {
    "start_keyboard_recording_succeeded",
    "start_keyboard_recording_reused_active_recording",
}
deadline = time.time() + 10.0
intent_loaded = False
last_stage = None
failure_code = None
terminal_event = None

def scan_log():
    global intent_loaded, terminal_event, last_stage, failure_code
    try:
        with open(diagnostic_log, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        return
    for line in lines[-800:]:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        fields = entry.get("fields") or {}
        if fields.get("command_id") != command_id:
            continue
        event = entry.get("event")
        if event == "darwin_command_intent_loaded":
            intent_loaded = True
        if event == "command_lifecycle_published":
            last_stage = fields.get("stage")
            failure_code = fields.get("failure_code")
        if event in terminal_events or any(event.startswith(prefix) for prefix in terminal_prefixes):
            terminal_event = event

def read_lifecycle():
    global failure_code
    try:
        with open(prefs_plist, "rb") as handle:
            prefs = plistlib.load(handle)
    except FileNotFoundError:
        return None
    raw = prefs.get("keyboard.command-lifecycle.v1")
    if not isinstance(raw, str):
        return None
    try:
        lifecycle = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if (lifecycle.get("command") or {}).get("id") != command_id:
        return None
    failure_code = lifecycle.get("failure_code")
    return lifecycle.get("stage")

while time.time() < deadline:
    scan_log()
    # CFPreferences may delay rewriting the on-disk plist while Host is
    # running. A newer `command_lifecycle_published` diagnostic is emitted
    # only after the shared-defaults save succeeds, so never replace that
    # evidence with an older plist snapshot.
    if last_stage is None:
        last_stage = read_lifecycle()
    if intent_loaded and terminal_event and last_stage == expected_stage:
        break
    time.sleep(0.15)

result = {
    "command_id": command_id,
    "intent_loaded": intent_loaded,
    "stage": last_stage,
    "failure_code": failure_code,
    "terminal_event": terminal_event,
}
print(json.dumps(result, sort_keys=True))

errors = []
if not intent_loaded:
    errors.append("host did not load the Darwin command intent")
if last_stage != expected_stage:
    errors.append(f"stage expected {expected_stage!r}, got {last_stage!r}")
if expected_failure_code and failure_code != expected_failure_code:
    errors.append(f"failure_code expected {expected_failure_code!r}, got {failure_code!r}")
if terminal_event is None:
    errors.append("host did not finish start attempt")
if errors:
    for error in errors:
        print(f"error: {error}; result={result}", file=sys.stderr)
    raise SystemExit(1)
PY
}

wait_cancel_cleanup() {
    local command_id="$1"
    /usr/bin/python3 - "$DIAGNOSTIC_LOG" "$command_id" <<'PY'
import json
import sys
import time

diagnostic_log, command_id = sys.argv[1:]
deadline = time.time() + 6.0
matched = None
while time.time() < deadline:
    try:
        with open(diagnostic_log, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        lines = []
    for line in reversed(lines[-600:]):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        fields = entry.get("fields") or {}
        if entry.get("event") == "capture_cancel_cleanup_completed" and fields.get("command_id") == command_id:
            matched = fields
            break
    if matched is not None:
        break
    time.sleep(0.15)

if matched is None:
    raise SystemExit("error: host did not report cancel cleanup completion")
if matched.get("keyboard_recording") != "false" or matched.get("recorder_recording") != "false":
    raise SystemExit(f"error: capture writer remained active after cancel: {matched}")
print("==> Cancel confirmed: both capture writers inactive")
PY
}

post_start_and_expect() {
    local command_id="$1"
    local expected_stage="$2"
    local expected_failure_code="${3:-}"
    echo "==> Posting Darwin start $command_id expecting $expected_stage"
    debug_url "keyboard-darwin-start" "command_id=$command_id"
    local result
    result="$(wait_darwin_result "$command_id" "$expected_stage" "$expected_failure_code")"
    echo "==> Darwin result: $result"
    if [ "$expected_stage" = "recording" ]; then
        debug_url "keyboard-darwin-cancel" "command_id=$command_id"
        wait_cancel_cleanup "$command_id"
    fi
}

echo "==> Granting simulator microphone permission"
simctl privacy "$SIMULATOR_ID" grant microphone "$BUNDLE_ID"
simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
sleep 0.5

echo "==> Setting Background Mic mode"
debug_url "keyboard-capture-mode" "run_id=$RUN_ID&mode=background_mic"
mode_result="$(wait_event "simulator_keyboard_capture_mode_set" "capture_mode_set")"
echo "==> Mode result: $mode_result"
assert_fields "$mode_result" "mode=background_mic"

echo "==> Starting mic session"
debug_url "keyboard-mic-session" "run_id=$RUN_ID&request_mic=true&warm_input_engine=true"
mic_result="$(wait_event "simulator_keyboard_mic_session_result" "mic_session_result" 10.0)"
echo "==> Mic session result: $mic_result"
mic_ready="$(/usr/bin/python3 - "$mic_result" <<'PY'
import json
import sys
print((json.loads(sys.argv[1]).get("ready") or "false").lower())
PY
)"
if [ "$mic_ready" = "true" ]; then
    assert_fields "$mic_result" \
        "keyboard_active=true" \
        "host_session_active=true" \
        "server_running=true" \
        "status_state=standby"

    echo "==> Stopping background capture but keeping host/server alive"
    debug_url "keyboard-background-capture-stop" "run_id=$RUN_ID"
    background_stop_result="$(wait_event "simulator_keyboard_background_capture_stopped" "background_capture_stopped")"
    echo "==> Background stop result: $background_stop_result"
    assert_fields "$background_stop_result" \
        "mode=background_mic" \
        "host_session_active=false" \
        "server_running=true"

    post_start_and_expect "${RUN_ID}-missing-session" "recording"
else
    echo "==> Simulator audio input unavailable; validating explicit failure lifecycle"
    assert_fields "$mic_result" \
        "ready=false" \
        "keyboard_active=false" \
        "server_running=true" \
        "status_state=idle"
    post_start_and_expect \
        "${RUN_ID}-missing-session" \
        "failed" \
        "microphone_unavailable"
fi

echo "==> Stopping local server while host remains alive"
debug_url "keyboard-local-server-stop" "run_id=$RUN_ID"
server_stop_result="$(wait_event "simulator_keyboard_local_server_stopped" "local_server_stopped")"
echo "==> Local server stop result: $server_stop_result"
assert_fields "$server_stop_result" "server_running=false"

if [ "$mic_ready" = "true" ]; then
    post_start_and_expect "${RUN_ID}-missing-server" "recording"
else
    post_start_and_expect \
        "${RUN_ID}-missing-server" \
        "failed" \
        "microphone_unavailable"
fi

echo "==> Switching to PiP mode and ensuring PiP is inactive"
debug_url "keyboard-capture-mode" "run_id=$RUN_ID&mode=picture_in_picture"
sleep 0.5
debug_url "keyboard-pip-stop" "run_id=$RUN_ID"
pip_stop_result="$(wait_event "simulator_keyboard_pip_stopped" "pip_stopped")"
echo "==> PiP stop result: $pip_stop_result"
assert_fields "$pip_stop_result" \
    "mode=picture_in_picture" \
    "pip_active=false" \
    "audio_host_session_active=false" \
    "keyboard_active=false" \
    "standby_keeper_active=false"

post_start_and_expect "${RUN_ID}-pip-inactive" "failed" "picture_in_picture_closed"

echo "==> Restoring Background Mic mode and stopping simulator session"
debug_url "keyboard-capture-mode" "run_id=$RUN_ID&mode=background_mic"
sleep 0.3
debug_url "keyboard-mic-session-stop" "run_id=$RUN_ID"

echo "OK: keyboard capture matrix simulator smoke test passed."
