#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
BUILD_DIR="$RIME_DIR/build"

# shellcheck source=scripts/lib/rime-ios-schemas.sh
. "$ROOT/scripts/lib/rime-ios-schemas.sh"

if [ ! -f "$BUILD_DIR/default.yaml" ]; then
    cat >&2 <<EOF
error: Rime iOS data is not built.

Run:
  scripts/build-rime-ios-data.sh
EOF
    exit 1
fi

while IFS= read -r schema; do
    if [ ! -f "$BUILD_DIR/${schema}.schema.yaml" ]; then
        cat >&2 <<EOF
error: Rime iOS data is stale; missing built schema: ${schema}

Run:
  scripts/build-rime-ios-data.sh
EOF
        exit 1
    fi
done < <(typeforme_rime_required_schemas)

if [ -f "$RIME_DIR/user.yaml" ]; then
    cat >&2 <<EOF
error: RimeSharedSupport/user.yaml is local user state and would be copied into the keyboard bundle.

Remove it or rebuild:
  rm -f iOS/TypeformeKeyboard/RimeSharedSupport/user.yaml
  scripts/build-rime-ios-data.sh
EOF
    exit 1
fi
