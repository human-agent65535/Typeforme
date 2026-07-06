#!/usr/bin/env bash
# Simulator-only smoke test for the keyboard Darwin control plane.
#
# This verifies:
#   debug URL -> host writes a keyboard start command -> authenticated Darwin
#   requestStartDictation -> host consumes command -> host writes a command
#   receipt. Simulator audio may legitimately finish as capture_not_ready.
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
terminal_phases = {"recording_started", "capture_not_ready", "failed"}
phase_rank = {
    None: 0,
    "accepted": 1,
    "bridge_ready": 2,
    "bridge_unavailable": 2,
    "recording_started": 3,
    "capture_not_ready": 3,
    "failed": 3,
}

deadline = time.time() + 8.0
last_phase = None
consumed = False
receipt_posted = False
terminal_event = None

def scan_log():
    global consumed, receipt_posted, terminal_event, last_phase
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
        if event == "darwin_request_start_command_consumed":
            consumed = True
        if event in {"darwin_start_receipt_posted", "command_receipt_posted"}:
            receipt_posted = True
            phase = fields.get("phase")
            if phase_rank.get(phase, 0) >= phase_rank.get(last_phase, 0):
                last_phase = phase
        if event in terminal_events or any(event.startswith(prefix) for prefix in terminal_prefixes):
            terminal_event = event

def read_receipt_phase():
    try:
        with open(prefs_plist, "rb") as handle:
            prefs = plistlib.load(handle)
    except FileNotFoundError:
        return None
    raw = prefs.get("keyboard.command-receipt.v1")
    if not isinstance(raw, str):
        return None
    try:
        receipt = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if receipt.get("command_id") != command_id:
        return None
    return receipt.get("phase")

while time.time() < deadline:
    scan_log()
    phase = read_receipt_phase()
    if phase_rank.get(phase, 0) >= phase_rank.get(last_phase, 0):
        last_phase = phase
    if consumed and receipt_posted and terminal_event and last_phase in terminal_phases:
        break
    time.sleep(0.15)

print(json.dumps({
    "command_id": command_id,
    "consumed": consumed,
    "receipt_posted": receipt_posted,
    "phase": last_phase,
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
if not result.get("consumed"):
    errors.append("host did not consume the Darwin start command")
if not result.get("receipt_posted"):
    errors.append("host did not post a command receipt")
if result.get("phase") in (None, "accepted"):
    errors.append(f"receipt did not advance beyond {result.get('phase')!r}")
if not result.get("terminal_event"):
    errors.append("host did not finish the start attempt")

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY

phase="$(/usr/bin/python3 - "$wait_result" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("phase") or "")
PY
)"
if [ "$phase" = "recording_started" ]; then
    echo "==> Recording started in simulator; posting stop"
    simctl openurl "$SIMULATOR_ID" "typeforme://debug/keyboard-darwin-stop?command_id=$COMMAND_ID" >/dev/null
fi

echo "OK: keyboard Darwin simulator smoke test passed."
