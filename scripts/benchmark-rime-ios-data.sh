#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
BUILD_DIR="$RIME_DIR/build"
SCHEMA_ID="${RIME_SCHEMA_ID:-typeforme_pinyin}"

if [[ ! -f "$BUILD_DIR/default.yaml" ]]; then
    cat >&2 <<EOF
error: Rime iOS data is not built.

Run:
  scripts/build-rime-ios-data.sh
EOF
    exit 1
fi

BREW_PREFIX="${HOMEBREW_PREFIX:-}"
if [[ -z "$BREW_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix)"
fi
INCLUDE_DIR="${RIME_INCLUDE_DIR:-${BREW_PREFIX:+$BREW_PREFIX/include}}"
LIB_DIR="${RIME_LIB_DIR:-${BREW_PREFIX:+$BREW_PREFIX/lib}}"

if [[ -z "$INCLUDE_DIR" || ! -f "$INCLUDE_DIR/rime_api.h" ]]; then
    cat >&2 <<EOF
error: rime_api.h was not found.

Install librime first, for example:
  brew install librime

Or set RIME_INCLUDE_DIR=/path/to/include.
EOF
    exit 1
fi

if [[ -z "$LIB_DIR" || ! -e "$LIB_DIR/librime.dylib" ]]; then
    cat >&2 <<EOF
error: librime.dylib was not found.

Install librime first, for example:
  brew install librime

Or set RIME_LIB_DIR=/path/to/lib.
EOF
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typeforme-rime-bench.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

SRC="$ROOT/scripts/benchmark-rime-ios-data.c"
BIN="$TMP_DIR/benchmark_rime"
USER_DIR="$TMP_DIR/user"
STAGING_DIR="$USER_DIR/build"
mkdir -p "$STAGING_DIR"

cc -std=c11 -Wall -Wextra -I"$INCLUDE_DIR" -L"$LIB_DIR" "$SRC" -lrime -o "$BIN"

export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
"$BIN" "$RIME_DIR" "$USER_DIR" "$BUILD_DIR" "$STAGING_DIR" "$SCHEMA_ID" "$@"
