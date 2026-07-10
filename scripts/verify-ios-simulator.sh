#!/usr/bin/env bash
# Build, install, launch, and screenshot the iOS host app + keyboard extension
# on the existing simulator state expected by AGENTS.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/iOS/TypeformeIOS.xcodeproj"
SCHEME="TypeformeIOS"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$ROOT/.build/ios-simulator-derived}"
SCREENSHOT="${SCREENSHOT:-$ROOT/.build/ios-simulator-launch.png}"
BUILD_LOG="${BUILD_LOG:-$ROOT/.build/ios-simulator-xcodebuild.log}"
PREFERRED_SIMULATOR_NAME="${PREFERRED_SIMULATOR_NAME:-iPhone 17 Pro Max}"

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
# shellcheck source=scripts/lib/ios-bundle-checks.sh
. "$ROOT/scripts/lib/ios-bundle-checks.sh"
typeforme_configure_xcode "run iOS simulator verification"
typeforme_configure_xcrun

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required to parse simctl JSON." >&2
    exit 2
fi

echo "==> Checking iOS URL handoff security invariants"
"$ROOT/scripts/smoke-ios-url-handoff-security.sh"
echo "==> Checking iOS keyboard command/status invariants"
"$ROOT/scripts/smoke-ios-command-status-invariants.sh"
echo "==> Checking iOS mailbox/destination/Rime ownership invariants"
"$ROOT/scripts/smoke-ios-mailbox-ownership-invariants.sh"

simctl() {
    typeforme_xcrun simctl "$@"
}

run_simctl_quiet() {
    local description="$1"
    shift
    local output
    if ! output="$(simctl "$@" 2>&1)"; then
        echo "error: $description failed:" >&2
        printf '%s\n' "$output" | sanitize_output >&2
        exit 1
    fi
}

display_path() {
    case "$1" in
        "$ROOT"/*) printf '.%s\n' "${1#$ROOT}" ;;
        "$HOME"/*) printf '<home>%s\n' "${1#$HOME}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

sanitize_output() {
    sed -E \
        -e "s|$ROOT|<repo>|g" \
        -e "s|$HOME|<home>|g" \
        -e 's/group\.[A-Za-z0-9][A-Za-z0-9.-]*\.typeforme/<typeforme-app-group>/g' \
        -e 's/[A-Za-z0-9][A-Za-z0-9.-]*\.typeforme(\.keyboard)?/<typeforme-bundle-id>/g' \
        -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g'
}

SIMCTL_LIST_JSON="$(mktemp -t typeforme-simulators)"
trap 'rm -f "$SIMCTL_LIST_JSON"' EXIT

simctl list devices available -j >"$SIMCTL_LIST_JSON"

select_simulator() {
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
    for device in runtime_devices:
        if not device.get("isAvailable", False):
            continue
        devices.append(device)

if explicit_id:
    for device in devices:
        if device.get("udid") == explicit_id:
            print(f"explicit\t{device['udid']}\t{device.get('name', '')}\t{device.get('state', '')}")
            raise SystemExit
    raise SystemExit("error: SIMULATOR_ID is not an available iOS simulator")

booted = [device for device in devices if device.get("state") == "Booted"]
if booted:
    preferred_booted = [device for device in booted if device.get("name") == preferred_name]
    selected = (preferred_booted or booted)[0]
    print(f"booted\t{selected['udid']}\t{selected.get('name', '')}\t{selected.get('state', '')}")
    raise SystemExit

preferred = [device for device in devices if device.get("name") == preferred_name]
if preferred:
    selected = preferred[0]
    print(f"preferred\t{selected['udid']}\t{selected.get('name', '')}\t{selected.get('state', '')}")
    raise SystemExit

available = ", ".join(sorted({device.get("name", "<unnamed>") for device in devices}))
raise SystemExit(
    f"error: no booted iOS simulator and configured simulator '{preferred_name}' is unavailable. "
    f"Available iOS simulators: {available}"
)
PY
}

IFS=$'\t' read -r SIMULATOR_SOURCE SIMULATOR_ID SIMULATOR_NAME SIMULATOR_STATE < <(select_simulator)

if [ "$SIMULATOR_STATE" != "Booted" ] && { [ "$SIMULATOR_SOURCE" = "preferred" ] || [ "$SIMULATOR_SOURCE" = "explicit" ]; }; then
    echo "==> Booting simulator $SIMULATOR_NAME"
    run_simctl_quiet "boot simulator" boot "$SIMULATOR_ID"
    run_simctl_quiet "wait for simulator boot" bootstatus "$SIMULATOR_ID" -b
else
    echo "==> Reusing simulator $SIMULATOR_NAME ($SIMULATOR_STATE)"
fi

echo "==> Building Typeforme iOS ($CONFIG) for simulator $SIMULATOR_NAME"
XCODEBUILD_ARGS=(
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED" \
    build \
    "$@"
)
if [ "${VERBOSE_BUILD:-0}" = "1" ]; then
    "$XCODEBUILD" "${XCODEBUILD_ARGS[@]}"
else
    mkdir -p "$(dirname "$BUILD_LOG")"
    if ! "$XCODEBUILD" "${XCODEBUILD_ARGS[@]}" >"$BUILD_LOG" 2>&1; then
        echo "error: xcodebuild failed. Last 200 sanitized log lines from $(display_path "$BUILD_LOG"):" >&2
        tail -200 "$BUILD_LOG" | sanitize_output >&2 || true
        exit 1
    fi
    echo "==> Build log: $(display_path "$BUILD_LOG")"
fi

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphonesimulator/Typeforme.app"
KEYBOARD_APPEX_PATH="$APP_PATH/PlugIns/TypeformeKeyboard.appex"
typeforme_verify_ios_host_keyboard_bundle "$APP_PATH" "$KEYBOARD_APPEX_PATH" "built"
BUNDLE_ID="$TYPEFORME_IOS_HOST_BUNDLE_ID"
APP_GROUP_ID="$TYPEFORME_IOS_HOST_APP_GROUP_ID"

echo "==> Built identifiers verified"
echo "==> Installing built app"
run_simctl_quiet "install app" install "$SIMULATOR_ID" "$APP_PATH"

GROUP_PATH="$(simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" "$APP_GROUP_ID")"
DIAGNOSTIC_LOG="$GROUP_PATH/Library/Caches/KeyboardDiagnostics/host-app.jsonl"
LAUNCH_STARTED_AT="$(/usr/bin/python3 - <<'PY'
import time
print(time.time())
PY
)"

echo "==> Launching Typeforme"
LAUNCH_OUTPUT="$(simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID")"
LAUNCH_PID="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' 'NF > 1 {print $NF; exit}')"
if [ -n "$LAUNCH_PID" ]; then
    echo "==> Launch pid: $LAUNCH_PID"
else
    printf '%s\n' "$LAUNCH_OUTPUT" | sanitize_output
fi

echo "==> Waiting for host UI readiness marker"
/usr/bin/python3 - "$DIAGNOSTIC_LOG" "$LAUNCH_STARTED_AT" <<'PY'
import json
import sys
import time

diagnostic_log, launch_started_at = sys.argv[1], float(sys.argv[2])
deadline = time.time() + 12.0
while time.time() < deadline:
    try:
        with open(diagnostic_log, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        lines = []
    for line in reversed(lines[-400:]):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            entry.get("event") == "simulator_host_ui_ready"
            and float(entry.get("timestamp", 0)) >= launch_started_at
        ):
            print("==> Host UI readiness marker observed")
            raise SystemExit
    time.sleep(0.1)
raise SystemExit("error: Typeforme did not publish the host UI readiness marker within 12 seconds")
PY

echo "==> Verifying installed app info"
run_simctl_quiet "verify installed app container" get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" app

mkdir -p "$(dirname "$SCREENSHOT")"
run_simctl_quiet "capture screenshot" io "$SIMULATOR_ID" screenshot "$SCREENSHOT"
echo "==> Screenshot: $(display_path "$SCREENSHOT")"

echo "OK: iOS simulator verification passed."
