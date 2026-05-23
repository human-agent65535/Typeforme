#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
BUILD_DIR="$RIME_DIR/build"

if [ ! -f "$BUILD_DIR/default.yaml" ]; then
    cat >&2 <<EOF
error: Rime iOS data is not built.

Run:
  scripts/build-rime-ios-data.sh
EOF
    exit 1
fi

if [ -f "$RIME_DIR/user.yaml" ]; then
    cat >&2 <<EOF
error: RimeSharedSupport/user.yaml is local user state and would be copied into the keyboard bundle.

Remove it or rebuild:
  rm -f iOS/TypeformeKeyboard/RimeSharedSupport/user.yaml
  scripts/build-rime-ios-data.sh
EOF
    exit 1
fi
