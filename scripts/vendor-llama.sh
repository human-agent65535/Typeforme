#!/usr/bin/env bash
# Vendor llama-server + its peer dylibs into ./vendor/, rewriting build-time
# rpaths so the bundled binary resolves its dylibs from the same directory
# (Contents/Resources/llama/) at runtime.
#
# Usage:
#   scripts/vendor-llama.sh <path-to-llama.cpp/build/bin>
#
# Re-run any time llama.cpp is rebuilt.
set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "usage: $0 <path-to-llama.cpp/build/bin>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"

# shellcheck source=scripts/lib/macho-bundle.sh
. "$ROOT/scripts/lib/macho-bundle.sh"

mkdir -p "$VENDOR"
rm -f "$VENDOR/llama-server-arm64" "$VENDOR"/*.dylib

[ -x "$SRC/llama-server" ] || { echo "missing $SRC/llama-server" >&2; exit 1; }
cp "$SRC/llama-server" "$VENDOR/llama-server-arm64"

for dy in "$SRC"/*.dylib; do
    [ -e "$dy" ] || continue
    cp "$dy" "$VENDOR/"
done

typeforme_bundle_non_system_deps "$VENDOR" "llama-server-arm64"

echo "vendored to $VENDOR:"
ls -1 "$VENDOR"
