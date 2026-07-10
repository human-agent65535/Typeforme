#!/usr/bin/env bash
# Fail closed when a release would bundle unreviewed native vendor bytes.
set -euo pipefail

ROOT="${TYPEFORME_VENDOR_VERIFY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST="${TYPEFORME_VENDOR_MANIFEST:-$ROOT/Resources/vendor-artifacts.sha256}"

artifacts=()
add_if_present() {
    local path="$1"
    [ -f "$path" ] && artifacts+=("$path")
}

add_if_present "$ROOT/vendor/llama-server-arm64"
for path in "$ROOT"/vendor/*.dylib "$ROOT"/vendor/*.metallib; do
    [ -e "$path" ] && artifacts+=("$path")
done
add_if_present "$ROOT/vendor/nvidia-nemotron/typeforme-nemotron-asr"
for path in "$ROOT"/vendor/nvidia-nemotron/*.dylib; do
    [ -e "$path" ] && artifacts+=("$path")
done

[ "${#artifacts[@]}" -gt 0 ] || exit 0

if [ ! -f "$MANIFEST" ]; then
    echo "error: native vendor artifacts are present but $MANIFEST is missing." >&2
    exit 2
fi

for artifact in "${artifacts[@]}"; do
    relative="${artifact#"$ROOT"/}"
    matches="$(awk -v path="$relative" '$1 !~ /^#/ && $2 == path { print $1 }' "$MANIFEST")"
    count="$(printf '%s\n' "$matches" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [ "$count" -ne 1 ]; then
        echo "error: $relative must have exactly one reviewed hash in $MANIFEST." >&2
        exit 2
    fi

    expected="$(printf '%s\n' "$matches" | head -n 1)"
    actual="$(shasum -a 256 "$artifact" | awk '{ print $1 }')"
    if [ "$actual" != "$expected" ]; then
        echo "error: native vendor artifact hash mismatch: $relative" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        echo "Review the rebuilt artifact and update the tracked manifest intentionally." >&2
        exit 2
    fi
done

echo "verified ${#artifacts[@]} native vendor artifact(s) against $MANIFEST"
