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

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
XCRUN="/usr/bin/xcrun"
if [ ! -x "$XCODEBUILD" ]; then
    cat >&2 <<EOF
error: full Xcode is required for iOS simulator verification.

Set DEVELOPER_DIR to Xcode, for example:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
EOF
    exit 2
fi
if [ ! -x "$XCRUN" ]; then
    echo "error: xcrun not found at $XCRUN." >&2
    exit 2
fi

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required to parse simctl JSON." >&2
    exit 2
fi

simctl() {
    DEVELOPER_DIR="$DEVELOPER_DIR" "$XCRUN" simctl "$@"
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
    sed \
        -e "s|$ROOT|<repo>|g" \
        -e "s|$HOME|<home>|g" \
        -E 's/group\.[A-Za-z0-9][A-Za-z0-9.-]*\.typeforme/<typeforme-app-group>/g' \
        -E 's/[A-Za-z0-9][A-Za-z0-9.-]*\.typeforme(\.keyboard)?/<typeforme-bundle-id>/g' \
        -E 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g'
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
if [ ! -d "$APP_PATH" ]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
fi
KEYBOARD_APPEX_PATH="$APP_PATH/PlugIns/TypeformeKeyboard.appex"
if [ ! -d "$KEYBOARD_APPEX_PATH" ]; then
    echo "error: built keyboard extension not found at $KEYBOARD_APPEX_PATH" >&2
    exit 1
fi

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

BUNDLE_ID="$(plist_value CFBundleIdentifier "$APP_PATH/Info.plist")"
HOST_VERSION="$(plist_value CFBundleShortVersionString "$APP_PATH/Info.plist")"
HOST_BUILD="$(plist_value CFBundleVersion "$APP_PATH/Info.plist")"
KEYBOARD_VERSION="$(plist_value CFBundleShortVersionString "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_BUILD="$(plist_value CFBundleVersion "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_BUNDLE_ID="$(plist_value TypeformeKeyboardBundleIdentifier "$APP_PATH/Info.plist")"
KEYBOARD_BUILT_BUNDLE_ID="$(plist_value CFBundleIdentifier "$KEYBOARD_APPEX_PATH/Info.plist")"
HOST_APP_GROUP_ID="$(plist_value TypeformeAppGroupIdentifier "$APP_PATH/Info.plist")"
KEYBOARD_APP_GROUP_ID="$(plist_value TypeformeAppGroupIdentifier "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_EXTENSION_POINT="$(plist_value NSExtension:NSExtensionPointIdentifier "$KEYBOARD_APPEX_PATH/Info.plist")"

if [ "$KEYBOARD_BUILT_BUNDLE_ID" != "$KEYBOARD_BUNDLE_ID" ]; then
    echo "error: keyboard bundle id mismatch: built=$KEYBOARD_BUILT_BUNDLE_ID host expects=$KEYBOARD_BUNDLE_ID" >&2
    exit 1
fi
if [ "$HOST_APP_GROUP_ID" != "$KEYBOARD_APP_GROUP_ID" ]; then
    echo "error: app group mismatch: host=$HOST_APP_GROUP_ID keyboard=$KEYBOARD_APP_GROUP_ID" >&2
    exit 1
fi
if [ "$KEYBOARD_EXTENSION_POINT" != "com.apple.keyboard-service" ]; then
    echo "error: keyboard extension point mismatch: $KEYBOARD_EXTENSION_POINT" >&2
    exit 1
fi
if [ "$KEYBOARD_VERSION" != "$HOST_VERSION" ] || [ "$KEYBOARD_BUILD" != "$HOST_BUILD" ]; then
    echo "error: host and keyboard versions diverged: host $HOST_VERSION ($HOST_BUILD), keyboard $KEYBOARD_VERSION ($KEYBOARD_BUILD)" >&2
    exit 1
fi

echo "==> Built identifiers verified"
echo "==> Installing built app"
run_simctl_quiet "install app" install "$SIMULATOR_ID" "$APP_PATH"

echo "==> Launching Typeforme"
LAUNCH_OUTPUT="$(simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID")"
LAUNCH_PID="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' 'NF > 1 {print $NF; exit}')"
if [ -n "$LAUNCH_PID" ]; then
    echo "==> Launch pid: $LAUNCH_PID"
else
    printf '%s\n' "$LAUNCH_OUTPUT" | sanitize_output
fi

echo "==> Verifying installed app info"
run_simctl_quiet "verify installed app container" get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" app

mkdir -p "$(dirname "$SCREENSHOT")"
run_simctl_quiet "capture screenshot" io "$SIMULATOR_ID" screenshot "$SCREENSHOT"
echo "==> Screenshot: $(display_path "$SCREENSHOT")"

echo "OK: iOS simulator verification passed."
