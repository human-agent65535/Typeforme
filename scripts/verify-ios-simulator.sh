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
PREFERRED_SIMULATOR_NAME="${PREFERRED_SIMULATOR_NAME:-iPhone 17 Pro Max}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
if [ ! -x "$XCODEBUILD" ]; then
    cat >&2 <<EOF
error: full Xcode is required for iOS simulator verification.

Set DEVELOPER_DIR to Xcode, for example:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
EOF
    exit 2
fi

if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
    echo "error: /usr/bin/python3 is required to parse simctl JSON." >&2
    exit 2
fi

SIMCTL_LIST_JSON="$(mktemp -t typeforme-simulators)"
trap 'rm -f "$SIMCTL_LIST_JSON"' EXIT

xcrun simctl list devices available -j >"$SIMCTL_LIST_JSON"

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
    raise SystemExit(f"error: SIMULATOR_ID={explicit_id} is not an available iOS simulator")

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
    echo "==> Booting simulator $SIMULATOR_NAME ($SIMULATOR_ID)"
    xcrun simctl boot "$SIMULATOR_ID"
    xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null
else
    echo "==> Reusing simulator $SIMULATOR_NAME ($SIMULATOR_ID, $SIMULATOR_STATE)"
fi

echo "==> Building Typeforme iOS ($CONFIG) for simulator $SIMULATOR_NAME"
"$XCODEBUILD" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED" \
    build \
    "$@"

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

echo "==> Built bundle ids: host $BUNDLE_ID, keyboard $KEYBOARD_BUNDLE_ID"
echo "==> Installing $APP_PATH"
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

echo "==> Launching $BUNDLE_ID"
LAUNCH_OUTPUT="$(xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID")"
echo "$LAUNCH_OUTPUT"

echo "==> Verifying installed app info"
xcrun simctl appinfo "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null

mkdir -p "$(dirname "$SCREENSHOT")"
xcrun simctl io "$SIMULATOR_ID" screenshot "$SCREENSHOT" >/dev/null
echo "==> Screenshot: $SCREENSHOT"

echo "OK: iOS simulator verification passed."
