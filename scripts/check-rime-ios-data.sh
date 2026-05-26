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

required_schemas=(
    typeforme_pinyin
    typeforme_pinyin_no_correction
    typeforme_pinyin_ext
    typeforme_pinyin_ext_no_correction
    typeforme_pinyin_large
    typeforme_pinyin_large_no_correction
)

for schema in "${required_schemas[@]}"; do
    if [ ! -f "$BUILD_DIR/${schema}.schema.yaml" ]; then
        cat >&2 <<EOF
error: Rime iOS data is stale; missing built schema: ${schema}

Run:
  scripts/build-rime-ios-data.sh
EOF
        exit 1
    fi
done

if [ -f "$RIME_DIR/user.yaml" ]; then
    cat >&2 <<EOF
error: RimeSharedSupport/user.yaml is local user state and would be copied into the keyboard bundle.

Remove it or rebuild:
  rm -f iOS/TypeformeKeyboard/RimeSharedSupport/user.yaml
  scripts/build-rime-ios-data.sh
EOF
    exit 1
fi
