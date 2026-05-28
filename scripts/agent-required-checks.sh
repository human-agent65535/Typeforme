#!/usr/bin/env bash
# Print the verification gates implied by the current git diff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${BASE:-HEAD}"

cd "$ROOT"

tracked_changes() {
    git diff --name-only "$BASE" --
}

untracked_changes() {
    git ls-files --others --exclude-standard
}

changed_files="$(mktemp -t typeforme-agent-files)"
trap 'rm -f "$changed_files"' EXIT

{
    tracked_changes
    untracked_changes
} | awk 'NF && !seen[$0]++' >"$changed_files"

if [ ! -s "$changed_files" ]; then
    echo "No changed files relative to $BASE."
    exit 0
fi

matches_any_file() {
    local pattern="$1"
    rg -q "$pattern" "$changed_files"
}

diff_matches_in_files() {
    local file_pattern="$1"
    local content_pattern="$2"
    local matched=1
    while IFS= read -r file; do
        if ! printf '%s\n' "$file" | rg -q "$file_pattern"; then
            continue
        fi
        if git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
            if git diff --unified=0 "$BASE" -- "$file" | rg -q "$content_pattern"; then
                matched=0
                break
            fi
        elif [ -f "$file" ] && rg -q "$content_pattern" "$file"; then
            matched=0
            break
        fi
    done <"$changed_files"
    return "$matched"
}

print_changed_files() {
    echo "Changed files:"
    sed 's/^/  - /' "$changed_files"
}

macos_pattern='^(Sources/Typeforme/|Tests/TypeformeTests/|Package.swift|Resources/)'
ios_pattern='^(iOS/TypeformeIOS/|iOS/TypeformeKeyboard/|iOS/Shared/|iOS/TypeformeIOS\.xcodeproj/|Sources/Typeforme/Bridge/BridgeProtocolModels\.swift|Sources/Typeforme/Bridge/BridgeMultipart\.swift|Sources/Typeforme/Models/(ASRLanguageSelection|CorrectionMode|OutputPreferences)\.swift)'
shell_pattern='(^|/)scripts/[^/]+\.sh$'
deployable_metadata_pattern='^(Resources/Info\.plist|iOS/TypeformeIOS\.xcodeproj/project\.pbxproj|iOS/TypeformeIOS/Info\.plist|iOS/TypeformeKeyboard/Info\.plist|iOS/TypeformeIOS/Assets\.xcassets/|iOS/TypeformeIOS/.*\.entitlements|iOS/TypeformeKeyboard/.*\.entitlements)'
ios_behavior_file_pattern='^(iOS/TypeformeIOS/|iOS/TypeformeKeyboard/|iOS/Shared/)'
ios_high_risk_diff_pattern='AVAudioSession|StandbyAudioSession|StandbyKeeper|KeyboardDarwinBridge|KeyboardDarwinNotificationName|handleOpenURL|openHostApp|typeforme://|microphone|requestStartDictation|requestStopDictation|dictationStarted|dictationStopped|sessionStarted|sessionEnded|KeyboardLocal(Server|Client)|KeyboardHostHandoff'

needs_macos=0
needs_ios=0
needs_shell_syntax=0
needs_version_review=0
needs_ios_device=0

if matches_any_file "$macos_pattern"; then
    needs_macos=1
fi
if matches_any_file "$ios_pattern"; then
    needs_ios=1
fi
if matches_any_file "$shell_pattern"; then
    needs_shell_syntax=1
fi
if matches_any_file "$deployable_metadata_pattern"; then
    needs_version_review=1
fi
if diff_matches_in_files "$ios_behavior_file_pattern" "$ios_high_risk_diff_pattern"; then
    needs_ios_device=1
fi

print_changed_files
echo
echo "Required checks:"

printed=0
if [ "$needs_shell_syntax" = "1" ]; then
    echo "  - bash -n <changed shell scripts>"
    printed=1
fi
if [ "$needs_macos" = "1" ]; then
    echo "  - scripts/run-tests.sh"
    printed=1
fi
if [ "$needs_ios" = "1" ]; then
    echo "  - scripts/verify-ios-simulator.sh"
    printed=1
fi
if [ "$printed" = "0" ]; then
    echo "  - No build/test gate inferred from changed paths."
fi

echo
echo "Manual review flags:"
flags=0
if [ "$needs_version_review" = "1" ]; then
    echo "  - Check whether the app version/build must be bumped per AGENTS.md."
    flags=1
fi
if [ "$needs_ios_device" = "1" ]; then
    echo "  - iOS recording/standby/URL/Darwin/local-bridge behavior changed or was touched."
    echo "    Verify the root AGENTS.md iOS flow checks; deploy to a real device if microphone behavior changed."
    flags=1
fi
if [ "$flags" = "0" ]; then
    echo "  - None inferred."
fi
