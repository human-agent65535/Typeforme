#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

failures=0

fail() {
    printf 'error: %s\n' "$*" >&2
    failures=$((failures + 1))
}

warn() {
    printf 'warn: %s\n' "$*" >&2
}

require_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        fail "missing $path"
    fi
}

require_file "iOS/TypeformeIOS/PrivacyInfo.xcprivacy"
require_file "iOS/TypeformeKeyboard/PrivacyInfo.xcprivacy"
require_file "docs/app-store-review-notes.md"

xcconfig_value() {
    local key="$1"
    local path="$2"
    [ -f "$path" ] || return 0
    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value = $2
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            print value
        }
    ' "$path" | tail -n 1
}

bundle_prefix="${TYPEFORME_BUNDLE_PREFIX:-}"
if [ -z "$bundle_prefix" ]; then
    bundle_prefix="$(xcconfig_value TYPEFORME_BUNDLE_PREFIX iOS/LocalSigning.xcconfig)"
fi
if [ -z "$bundle_prefix" ]; then
    bundle_prefix="$(xcconfig_value TYPEFORME_BUNDLE_PREFIX iOS/Config/Typeforme.xcconfig)"
fi

if [ -z "$bundle_prefix" ] || [ "$bundle_prefix" = "com.example" ]; then
    fail "TYPEFORME_BUNDLE_PREFIX is not set to an App Store-owned prefix; set TYPEFORME_BUNDLE_PREFIX in the environment or iOS/LocalSigning.xcconfig"
fi

private_api_patterns=(
    'LSApplicationWorkspace'
    'openSensitiveURL'
    'openApplicationWithBundleID'
    'PKService'
    '_hostApplicationBundleIdentifier'
    '_hostBundleIdentifier'
    '_hostBundleID'
    '_hostProcessIdentifier'
    '_hostPID'
    'xpc_connection_copy_bundle_id'
    'proc_pidpath'
)

for pattern in "${private_api_patterns[@]}"; do
    if rg -n "$pattern" iOS >/dev/null; then
        fail "private or non-public API pattern remains in iOS sources: $pattern"
    fi
done

if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' iOS/TypeformeIOS/Info.plist >/dev/null 2>&1; then
    if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' iOS/TypeformeIOS/Info.plist | grep -q 'audio'; then
        if ! rg -q 'background audio mode' docs/app-store-review-notes.md \
            || ! rg -q 'Picture in Picture|PiP' docs/app-store-review-notes.md; then
            fail "iOS host declares UIBackgroundModes=audio but docs/app-store-review-notes.md does not explain the background audio and PiP review rationale"
        fi
        warn "iOS host declares UIBackgroundModes=audio; App Review notes must keep the PiP/background audio rationale accurate"
    fi
fi

if ! rg -n 'PrivacyInfo\.xcprivacy' iOS/TypeformeIOS.xcodeproj/project.pbxproj >/dev/null; then
    fail "Xcode project does not reference PrivacyInfo.xcprivacy"
fi

if /usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:RequestsOpenAccess' iOS/TypeformeKeyboard/Info.plist 2>/dev/null | grep -q true; then
    if ! rg -n 'Full Access lets the keyboard' iOS/TypeformeIOS >/dev/null; then
        fail "keyboard requests Open Access but host app does not include the Full Access disclosure copy"
    fi
    warn "keyboard RequestsOpenAccess=true; App Store privacy labels and review notes must explain keyboard data use"
fi

if [ "$failures" -gt 0 ]; then
    printf 'App Store readiness checks failed with %d issue(s).\n' "$failures" >&2
    exit 1
fi

printf 'App Store readiness checks passed.\n'
