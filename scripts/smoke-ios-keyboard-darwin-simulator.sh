#!/usr/bin/env bash
# Simulator-only smoke test for the keyboard Darwin control plane.
#
# This verifies:
#   debug URL -> keyboard intent snapshot -> authenticated Darwin wake-up ->
#   Host lifecycle snapshot. Simulator audio may legitimately end as failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$ROOT/.build/ios-simulator-derived}"
PREFERRED_SIMULATOR_NAME="${PREFERRED_SIMULATOR_NAME:-iPhone 17 Pro Max}"
COMMAND_ID="${COMMAND_ID:-sim-darwin-$(date +%s)-$RANDOM}"

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
# shellcheck source=scripts/lib/ios-bundle-checks.sh
. "$ROOT/scripts/lib/ios-bundle-checks.sh"
typeforme_configure_xcode "run iOS keyboard Darwin simulator smoke test"
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

SIMCTL_LIST_JSON="$(mktemp -t typeforme-smoke-simulators)"
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
START_URL="typeforme://debug/keyboard-darwin-start?command_id=$COMMAND_ID"

echo "==> Posting simulator keyboard Darwin start command"
simctl openurl "$SIMULATOR_ID" "$START_URL" >/dev/null

wait_result="$(
    /usr/bin/python3 - "$DIAGNOSTIC_LOG" "$PREFS_PLIST" "$COMMAND_ID" <<'PY'
import json
import plistlib
import sys
import time

diagnostic_log, prefs_plist, command_id = sys.argv[1:]
terminal_prefixes = (
    "start_keyboard_recording_failed_",
)
terminal_events = {
    "start_keyboard_recording_succeeded",
    "start_keyboard_recording_reused_active_recording",
}
terminal_stages = {"recording", "failed"}

deadline = time.time() + 8.0
last_stage = None
intent_loaded = False
terminal_event = None

def scan_log():
    global intent_loaded, terminal_event, last_stage
    try:
        with open(diagnostic_log, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        return
    for line in lines[-300:]:
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
        if event in terminal_events or any(event.startswith(prefix) for prefix in terminal_prefixes):
            terminal_event = event

def read_lifecycle_stage():
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
    return lifecycle.get("stage")

while time.time() < deadline:
    scan_log()
    persisted_stage = read_lifecycle_stage()
    if persisted_stage is not None:
        last_stage = persisted_stage
    if intent_loaded and terminal_event and last_stage in terminal_stages:
        break
    time.sleep(0.15)

print(json.dumps({
    "command_id": command_id,
    "intent_loaded": intent_loaded,
    "stage": last_stage,
    "terminal_event": terminal_event,
}, sort_keys=True))
PY
)"

echo "==> Smoke result: $wait_result"

/usr/bin/python3 - "$wait_result" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
errors = []
if not result.get("intent_loaded"):
    errors.append("host did not load the Darwin command intent")
if result.get("stage") not in ("recording", "failed"):
    errors.append(f"lifecycle did not reach recording/failed: {result.get('stage')!r}")
if not result.get("terminal_event"):
    errors.append("host did not finish the start attempt")

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY

stage="$(/usr/bin/python3 - "$wait_result" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("stage") or "")
PY
)"
if [ "$stage" = "recording" ]; then
    echo "==> Recording started in simulator; posting stop"
    simctl openurl "$SIMULATOR_ID" "typeforme://debug/keyboard-darwin-stop?command_id=$COMMAND_ID" >/dev/null
    /usr/bin/python3 - "$DIAGNOSTIC_LOG" "$COMMAND_ID" <<'PY'
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
    for line in reversed(lines[-300:]):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        fields = entry.get("fields") or {}
        if entry.get("event") == "capture_writer_stopped" and fields.get("command_id") == command_id:
            matched = fields
            break
    if matched is not None:
        break
    time.sleep(0.15)

if matched is None:
    raise SystemExit("error: host did not report that the capture writer stopped")
if matched.get("keyboard_recording") != "false" or matched.get("recorder_recording") != "false":
    raise SystemExit(f"error: capture writer remained active after stop: {matched}")
print("==> Stop confirmed: both capture writers inactive")
PY
fi

echo "OK: keyboard Darwin simulator smoke test passed."
