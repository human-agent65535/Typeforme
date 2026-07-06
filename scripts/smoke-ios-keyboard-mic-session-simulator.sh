#!/usr/bin/env bash
# Simulator-only smoke test for the host-owned keyboard mic session.
#
# This verifies:
#   debug URL -> setKeyboardStandby(true) -> prepareKeyboardInputStandby ->
#   host keyboard audio session active + local bridge running.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$ROOT/.build/ios-simulator-derived}"
PREFERRED_SIMULATOR_NAME="${PREFERRED_SIMULATOR_NAME:-iPhone 17 Pro Max}"
RUN_ID="${RUN_ID:-sim-mic-$(date +%s)-$RANDOM}"

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
# shellcheck source=scripts/lib/ios-bundle-checks.sh
. "$ROOT/scripts/lib/ios-bundle-checks.sh"
typeforme_configure_xcode "run iOS keyboard mic session simulator smoke test"
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

SIMCTL_LIST_JSON="$(mktemp -t typeforme-mic-smoke-simulators)"
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
START_URL="typeforme://debug/keyboard-mic-session?run_id=$RUN_ID&request_mic=true&warm_input_engine=true"
STOP_URL="typeforme://debug/keyboard-mic-session-stop?run_id=$RUN_ID"

echo "==> Granting simulator microphone permission"
simctl privacy "$SIMULATOR_ID" grant microphone "$BUNDLE_ID"

echo "==> Posting simulator keyboard mic session smoke URL"
simctl openurl "$SIMULATOR_ID" "$START_URL" >/dev/null

wait_result="$(
    /usr/bin/python3 - "$DIAGNOSTIC_LOG" "$RUN_ID" <<'PY'
import json
import sys
import time

diagnostic_log, run_id = sys.argv[1:]
deadline = time.time() + 10.0
result = None

while time.time() < deadline:
    try:
        with open(diagnostic_log, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        lines = []
    for line in lines[-300:]:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("event") != "simulator_keyboard_mic_session_result":
            continue
        fields = entry.get("fields") or {}
        if fields.get("run_id") == run_id:
            result = fields
    if result is not None:
        break
    time.sleep(0.15)

print(json.dumps(result or {"run_id": run_id}, sort_keys=True))
PY
)"

echo "==> Smoke result: $wait_result"

/usr/bin/python3 - "$wait_result" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
errors = []
if result.get("ready") != "true":
    errors.append(f"mic session was not ready: {result}")
if result.get("keyboard_active") != "true":
    errors.append(f"keyboard audio session was not active: {result}")
if result.get("host_session_active") != "true":
    errors.append(f"host keyboard session was not active: {result}")
if result.get("server_running") != "true":
    errors.append(f"keyboard local server was not running: {result}")
if result.get("status_state") != "standby":
    errors.append(f"keyboard status was not standby: {result}")

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY

echo "==> Stopping simulator keyboard mic session"
simctl openurl "$SIMULATOR_ID" "$STOP_URL" >/dev/null

echo "OK: keyboard mic session simulator smoke test passed."
