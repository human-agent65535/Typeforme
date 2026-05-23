#!/usr/bin/env bash
# Build the iOS host app + keyboard extension and install on a connected
# iPhone via devicectl. Auto-picks the first usable paired iPhone unless
# DEVICE_ID is set. DEVICE_NAME can be set to prefer a specific device name.
#
# Defaults to Release because Debug builds in modern Xcode emit a stub
# executable plus `.debug.dylib`, and iOS's keyboard daemon won't load the
# dylib without a debugger attached — the on-device keyboard then silently
# falls back to the previously installed version. Release embeds everything
# in the main binary so the OS can load it standalone.
#
# Usage:
#   scripts/deploy-ios.sh                     # Release build + install
#   scripts/deploy-ios.sh launch              # + launch (phone must be unlocked)
#   CONFIG=Debug scripts/deploy-ios.sh        # only useful when Xcode runs it
#   TEAM=... DEVICE_ID=... scripts/deploy-ios.sh  # TEAM is an explicit override
#   DEVICE_NAME="Example iPhone" scripts/deploy-ios.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/iOS/TypeformeIOS.xcodeproj"
SCHEME="TypeformeIOS"
BUNDLE_ID="com.example.typeforme"
KEYBOARD_BUNDLE_ID="com.example.typeforme.keyboard"
CONFIG="${CONFIG:-Release}"
DERIVED="${DERIVED:-/tmp/TypeformeIOS-DD-${CONFIG}}"
TEAM="${TEAM:-}"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
RIME_BUILD_DIR="$RIME_DIR/build"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "Xcode not found at $DEVELOPER_DIR. Set DEVELOPER_DIR explicitly." >&2
    exit 1
fi

ACTION="${1:-install}"

if [ -z "${DEVICE_ID:-}" ]; then
    DEVICE_LIST_JSON="$(mktemp -t typeforme-devices)"
    DEVICE_LIST_TEXT="$(mktemp -t typeforme-devices-text)"
    if ! xcrun devicectl list devices --json-output "$DEVICE_LIST_JSON" >"$DEVICE_LIST_TEXT" 2>&1; then
        cat "$DEVICE_LIST_TEXT" >&2
        rm -f "$DEVICE_LIST_JSON" "$DEVICE_LIST_TEXT"
        exit 1
    fi
    DEVICE_ID="$(/usr/bin/python3 - "$DEVICE_LIST_JSON" "${DEVICE_NAME:-}" <<'PY'
import json
import sys

path = sys.argv[1]
preferred_name = sys.argv[2].casefold()
with open(path, "r", encoding="utf-8") as handle:
    devices = json.load(handle).get("result", {}).get("devices", [])

def is_usable_iphone(device):
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    return (
        hardware.get("platform") == "iOS"
        and hardware.get("deviceType") == "iPhone"
        and connection.get("pairingState") == "paired"
        and connection.get("tunnelState") not in {"unavailable", "disconnected"}
    )

usable = [device for device in devices if is_usable_iphone(device)]
if preferred_name:
    for device in usable:
        names = [
            device.get("deviceProperties", {}).get("name", ""),
            device.get("hardwareProperties", {}).get("marketingName", ""),
        ]
        if any(preferred_name in name.casefold() for name in names):
            print(device.get("identifier", ""))
            raise SystemExit
else:
    if usable:
        print(usable[0].get("identifier", ""))
PY
)"
    if [ -z "$DEVICE_ID" ]; then
        echo "No usable paired iPhone found. Connect/unlock the target device and finish any trust/pairing dialog." >&2
        if [ -n "${DEVICE_NAME:-}" ]; then
            echo "Requested DEVICE_NAME=$DEVICE_NAME" >&2
        fi
        /usr/bin/python3 - "$DEVICE_LIST_JSON" <<'PY' >&2
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    devices = json.load(handle).get("result", {}).get("devices", [])

for device in devices:
    hardware = device.get("hardwareProperties", {})
    if hardware.get("platform") != "iOS" or hardware.get("deviceType") != "iPhone":
        continue
    props = device.get("deviceProperties", {})
    conn = device.get("connectionProperties", {})
    name = props.get("name", "<unnamed>")
    model = hardware.get("marketingName") or hardware.get("productType") or "iPhone"
    identifier = device.get("identifier", "<unknown>")
    pairing = conn.get("pairingState", "unknown")
    tunnel = conn.get("tunnelState", "unknown")
    print(f"- {name} ({model}) id={identifier} pairing={pairing} tunnel={tunnel}")
PY
        rm -f "$DEVICE_LIST_JSON" "$DEVICE_LIST_TEXT"
        exit 1
    fi
    rm -f "$DEVICE_LIST_JSON" "$DEVICE_LIST_TEXT"
fi
if [ -z "$DEVICE_ID" ]; then
    echo "No paired iPhone found. Connect via cable or set DEVICE_ID." >&2
    xcrun devicectl list devices >&2 || true
    exit 1
fi

echo "→ Building Typeforme iOS ($CONFIG) for device $DEVICE_ID"
if [ ! -f "$RIME_BUILD_DIR/default.yaml" ]; then
    echo "→ Rime iOS data missing; building precompiled keyboard data"
    "$ROOT/scripts/build-rime-ios-data.sh"
fi
rm -f "$RIME_DIR/user.yaml"
"$ROOT/scripts/check-rime-ios-data.sh"

BUILD_ARGS=()
if [ -n "$TEAM" ]; then
    echo "→ Overriding project DEVELOPMENT_TEAM with TEAM=$TEAM"
    BUILD_ARGS+=(DEVELOPMENT_TEAM="$TEAM")
fi

XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -destination "id=$DEVICE_ID"
    -configuration "$CONFIG"
    -allowProvisioningUpdates
    -derivedDataPath "$DERIVED"
)
if [ "${#BUILD_ARGS[@]}" -gt 0 ]; then
    XCODEBUILD_ARGS+=("${BUILD_ARGS[@]}")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

APP_PRODUCTS_DIR="$DERIVED/Build/Products/${CONFIG}-iphoneos"
APP_PATH="$APP_PRODUCTS_DIR/Typeforme.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Built app not found at $APP_PATH" >&2
    exit 1
fi
KEYBOARD_APPEX_PATH="$APP_PATH/PlugIns/TypeformeKeyboard.appex"
if [ ! -d "$KEYBOARD_APPEX_PATH" ]; then
    echo "Built keyboard extension not found at $KEYBOARD_APPEX_PATH" >&2
    exit 1
fi
HOST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
HOST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
KEYBOARD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$KEYBOARD_APPEX_PATH/Info.plist")"
if [ "$KEYBOARD_BUILT_BUNDLE_ID" != "$KEYBOARD_BUNDLE_ID" ]; then
    echo "Built keyboard extension bundle id mismatch: $KEYBOARD_BUILT_BUNDLE_ID" >&2
    exit 1
fi

echo "→ Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "→ Verifying installed host app and keyboard extension"
APP_INFO_JSON="$(mktemp -t typeforme-installed-apps)"
APP_INFO_TEXT="$(mktemp -t typeforme-installed-apps-text)"
VERIFY_OK=0
for attempt in 1 2 3 4 5; do
    if xcrun devicectl device info apps \
        --device "$DEVICE_ID" \
        --bundle-id "$BUNDLE_ID" \
        --include-removable-apps \
        --json-output "$APP_INFO_JSON" >"$APP_INFO_TEXT" 2>&1 &&
       /usr/bin/python3 - "$APP_INFO_JSON" "$BUNDLE_ID" "$KEYBOARD_BUNDLE_ID" "$HOST_VERSION" "$HOST_BUILD" "$KEYBOARD_VERSION" "$KEYBOARD_BUILD" <<'PY'
import json
import sys

path, host_id, keyboard_id, host_version, host_build, keyboard_version, keyboard_build = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def contains_string(value, expected):
    if isinstance(value, str):
        return value == expected
    if isinstance(value, dict):
        return any(contains_string(child, expected) for child in value.values())
    if isinstance(value, list):
        return any(contains_string(child, expected) for child in value)
    return False

def find_record(bundle_id):
    for item in walk(payload):
        if contains_string(item, bundle_id):
            return item
    return None

def find_value(value, names):
    lowered = {name.lower() for name in names}
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in lowered and isinstance(child, (str, int)):
                return str(child)
        for child in value.values():
            found = find_value(child, names)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_value(child, names)
            if found is not None:
                return found
    return None

def require_record(bundle_id, expected_version, expected_build):
    record = find_record(bundle_id)
    if record is None:
        raise SystemExit(f"missing installed bundle record for {bundle_id}")
    version = find_value(record, [
        "CFBundleShortVersionString",
        "bundleShortVersionString",
        "shortVersionString",
        "marketingVersion",
    ])
    build = find_value(record, [
        "CFBundleVersion",
        "bundleVersion",
        "buildVersion",
        "build",
    ])
    if version != expected_version or build != expected_build:
        raise SystemExit(
            f"{bundle_id} installed version mismatch: "
            f"version={version!r} build={build!r}, expected version={expected_version!r} build={expected_build!r}"
        )

require_record(host_id, host_version, host_build)
require_record(keyboard_id, keyboard_version, keyboard_build)
PY
    then
        VERIFY_OK=1
        break
    fi
    sleep 1
done
if [ "$VERIFY_OK" != "1" ]; then
    cat "$APP_INFO_TEXT" >&2
    echo "Installed app verification failed. Expected host $HOST_VERSION ($HOST_BUILD) and keyboard $KEYBOARD_VERSION ($KEYBOARD_BUILD)." >&2
    rm -f "$APP_INFO_JSON" "$APP_INFO_TEXT"
    exit 1
fi
rm -f "$APP_INFO_JSON" "$APP_INFO_TEXT"

if [ "$ACTION" = "launch" ]; then
    echo "→ Launching $BUNDLE_ID"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || {
        echo "Launch failed — unlock the device and tap the app icon." >&2
        exit 1
    }
fi

echo "✔ Deployed."
