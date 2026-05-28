#!/usr/bin/env bash
# Build the iOS host app + keyboard extension and install on a connected
# iPhone via devicectl. Auto-picks the first paired iPhone with an active
# tunnel unless DEVICE_ID is set. If a paired iPhone is visible but its tunnel
# is still unavailable/disconnected, the script still tries that id directly
# because devicectl can often acquire the tunnel during build/install.
# DEVICE_NAME can be set to prefer a specific device name.
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
#   TEAM=... TYPEFORME_BUNDLE_PREFIX=... DEVICE_ID=... scripts/deploy-ios.sh
#   DEVICE_NAME="Example iPhone" scripts/deploy-ios.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/iOS/TypeformeIOS.xcodeproj"
SCHEME="TypeformeIOS"
CONFIG="${CONFIG:-Release}"
DERIVED="${DERIVED:-/tmp/TypeformeIOS-DD-${CONFIG}}"

if [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

TEAM="${TEAM:-}"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
RIME_BUILD_DIR="$RIME_DIR/build"

env_setting_is_present() {
    local name="$1"
    [ "${!name+x}" = "x" ] && [ -n "${!name}" ]
}

add_build_setting_from_env() {
    local name="$1"
    if env_setting_is_present "$name"; then
        BUILD_ARGS+=("$name=${!name}")
    fi
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
typeforme_configure_xcode "deploy Typeforme iOS"
typeforme_configure_xcrun

xcrun_tool() {
    typeforme_xcrun "$@"
}

ACTION="${1:-install}"

if [ -z "${DEVICE_ID:-}" ]; then
    DEVICE_LIST_JSON="$(mktemp -t typeforme-devices)"
    DEVICE_LIST_TEXT="$(mktemp -t typeforme-devices-text)"
    if ! xcrun_tool devicectl list devices --json-output "$DEVICE_LIST_JSON" >"$DEVICE_LIST_TEXT" 2>&1; then
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

def is_paired_iphone(device):
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    return (
        hardware.get("platform") == "iOS"
        and hardware.get("deviceType") == "iPhone"
        and connection.get("pairingState") == "paired"
    )

def has_ready_tunnel(device):
    connection = device.get("connectionProperties", {})
    return connection.get("tunnelState") not in {"unavailable", "disconnected"}

def names_match(device):
    if not preferred_name:
        return True
    names = [
        device.get("deviceProperties", {}).get("name", ""),
        device.get("hardwareProperties", {}).get("marketingName", ""),
    ]
    return any(preferred_name in name.casefold() for name in names)

def warn_tunnel_fallback(device):
    props = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    name = props.get("name", "<unnamed>")
    identifier = device.get("identifier", "<unknown>")
    tunnel = connection.get("tunnelState", "unknown")
    print(
        f"→ Paired iPhone {name} id={identifier} has tunnel={tunnel}; "
        "trying direct id deployment anyway.",
        file=sys.stderr,
    )

paired = [device for device in devices if is_paired_iphone(device) and names_match(device)]
ready = [device for device in paired if has_ready_tunnel(device)]
fallback = [device for device in paired if not has_ready_tunnel(device)]

if ready:
    print(ready[0].get("identifier", ""))
    raise SystemExit
if fallback:
    warn_tunnel_fallback(fallback[0])
    print(fallback[0].get("identifier", ""))
    raise SystemExit
PY
)"
    if [ -z "$DEVICE_ID" ]; then
        echo "No paired iPhone found. Connect/unlock the target device and finish any trust/pairing dialog." >&2
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
    xcrun_tool devicectl list devices >&2 || true
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
# Only command-line override identifiers when the user explicitly supplied
# them via the environment or .env. Otherwise, let Typeforme.xcconfig and the
# ignored LocalSigning.xcconfig provide the effective bundle/app-group settings.
add_build_setting_from_env TYPEFORME_BUNDLE_PREFIX
add_build_setting_from_env TYPEFORME_HOST_BUNDLE_IDENTIFIER
add_build_setting_from_env TYPEFORME_KEYBOARD_BUNDLE_IDENTIFIER
add_build_setting_from_env TYPEFORME_APP_GROUP_IDENTIFIER

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

"$XCODEBUILD" "${XCODEBUILD_ARGS[@]}" build

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
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
HOST_CONFIGURED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :TypeformeHostBundleIdentifier' "$APP_PATH/Info.plist")"
KEYBOARD_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :TypeformeKeyboardBundleIdentifier' "$APP_PATH/Info.plist")"
KEYBOARD_BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_CONFIGURED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :TypeformeKeyboardBundleIdentifier' "$KEYBOARD_APPEX_PATH/Info.plist")"
HOST_APP_GROUP_ID="$(/usr/libexec/PlistBuddy -c 'Print :TypeformeAppGroupIdentifier' "$APP_PATH/Info.plist")"
KEYBOARD_APP_GROUP_ID="$(/usr/libexec/PlistBuddy -c 'Print :TypeformeAppGroupIdentifier' "$KEYBOARD_APPEX_PATH/Info.plist")"
KEYBOARD_EXTENSION_POINT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$KEYBOARD_APPEX_PATH/Info.plist")"
if [ "$HOST_CONFIGURED_BUNDLE_ID" != "$BUNDLE_ID" ]; then
    echo "Built host bundle id mismatch: CFBundleIdentifier=$BUNDLE_ID, TypeformeHostBundleIdentifier=$HOST_CONFIGURED_BUNDLE_ID" >&2
    exit 1
fi
if [ "$KEYBOARD_BUILT_BUNDLE_ID" != "$KEYBOARD_BUNDLE_ID" ]; then
    echo "Built keyboard extension bundle id mismatch: CFBundleIdentifier=$KEYBOARD_BUILT_BUNDLE_ID, host expects $KEYBOARD_BUNDLE_ID" >&2
    exit 1
fi
if [ "$KEYBOARD_CONFIGURED_BUNDLE_ID" != "$KEYBOARD_BUNDLE_ID" ]; then
    echo "Built keyboard configuration mismatch: extension TypeformeKeyboardBundleIdentifier=$KEYBOARD_CONFIGURED_BUNDLE_ID, host expects $KEYBOARD_BUNDLE_ID" >&2
    exit 1
fi
if [ "$HOST_APP_GROUP_ID" != "$KEYBOARD_APP_GROUP_ID" ]; then
    echo "Built app group mismatch: host=$HOST_APP_GROUP_ID, keyboard=$KEYBOARD_APP_GROUP_ID" >&2
    exit 1
fi
if [ "$KEYBOARD_EXTENSION_POINT" != "com.apple.keyboard-service" ]; then
    echo "Built keyboard extension point mismatch: $KEYBOARD_EXTENSION_POINT" >&2
    exit 1
fi
if [ "$KEYBOARD_VERSION" != "$HOST_VERSION" ] || [ "$KEYBOARD_BUILD" != "$HOST_BUILD" ]; then
    echo "Built host and keyboard versions diverged: host $HOST_VERSION ($HOST_BUILD), keyboard $KEYBOARD_VERSION ($KEYBOARD_BUILD)" >&2
    exit 1
fi
echo "→ Built bundle ids: host $BUNDLE_ID, keyboard $KEYBOARD_BUNDLE_ID"

echo "→ Verifying packaged host app and keyboard extension"
/usr/bin/codesign --verify --deep --strict --verbose=1 "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=1 "$KEYBOARD_APPEX_PATH"

echo "→ Installing $APP_PATH"
xcrun_tool devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "→ Verifying installed host app"
APP_INFO_JSON="$(mktemp -t typeforme-installed-apps)"
APP_INFO_TEXT="$(mktemp -t typeforme-installed-apps-text)"
VERIFY_OK=0
for attempt in 1 2 3 4 5; do
    if xcrun_tool devicectl device info apps \
        --device "$DEVICE_ID" \
        --include-removable-apps \
        --json-output "$APP_INFO_JSON" >"$APP_INFO_TEXT" 2>&1 &&
       /usr/bin/python3 - "$APP_INFO_JSON" "$BUNDLE_ID" "$HOST_VERSION" "$HOST_BUILD" <<'PY'
import json
import sys

path, host_id, host_version, host_build = sys.argv[1:]
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

def find_record(bundle_id):
    for item in walk(payload):
        if not isinstance(item, dict):
            continue
        identifiers = [
            item.get("bundleIdentifier"),
            item.get("CFBundleIdentifier"),
            item.get("bundleID"),
        ]
        if any(identifier == bundle_id for identifier in identifiers):
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
        "version",
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
PY
    then
        VERIFY_OK=1
        break
    fi
    sleep 1
done
if [ "$VERIFY_OK" != "1" ]; then
    cat "$APP_INFO_TEXT" >&2
    echo "Installed app verification failed. Expected host $HOST_VERSION ($HOST_BUILD)." >&2
    rm -f "$APP_INFO_JSON" "$APP_INFO_TEXT"
    exit 1
fi
rm -f "$APP_INFO_JSON" "$APP_INFO_TEXT"

if [ "$ACTION" = "launch" ]; then
    echo "→ Launching $BUNDLE_ID"
    xcrun_tool devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || {
        echo "Launch failed — unlock the device and tap the app icon." >&2
        exit 1
    }
fi

echo "✔ Deployed."
