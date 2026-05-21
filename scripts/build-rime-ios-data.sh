#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
BUILD_DIR="$RIME_DIR/build"

if ! command -v rime_deployer >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: rime_deployer is required.

Install librime first, for example:
  brew install librime
EOF
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rime_deployer --build "$RIME_DIR" "$RIME_DIR" "$BUILD_DIR"

echo "built Rime iOS data: $BUILD_DIR"
