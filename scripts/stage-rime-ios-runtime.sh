#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
BUILD_DIR="$RIME_DIR/build"

DEST="${1:-}"
if [ -z "$DEST" ]; then
    if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
        cat >&2 <<'EOF'
error: destination missing.

Run from Xcode, or pass an explicit destination:
  scripts/stage-rime-ios-runtime.sh /tmp/RimeSharedSupport
EOF
        exit 1
    fi
    DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/RimeSharedSupport"
fi

"$ROOT/scripts/check-rime-ios-data.sh"

rm -rf "$DEST"
mkdir -p "$DEST" "$DEST/build"

copy_required_file() {
    local source="$1"
    local target_dir="$2"
    if [ ! -f "$source" ]; then
        echo "error: required Rime runtime file missing: $source" >&2
        exit 1
    fi
    cp "$source" "$target_dir/"
}

copy_optional_file() {
    local source="$1"
    local target_dir="$2"
    if [ -f "$source" ]; then
        cp "$source" "$target_dir/"
    fi
}

copy_required_file "$RIME_DIR/default.yaml" "$DEST"
copy_optional_file "$RIME_DIR/LICENSE.rime-ice.txt" "$DEST"
copy_optional_file "$RIME_DIR/SOURCES.md" "$DEST"

shopt -s nullglob
for file in "$RIME_DIR"/*.schema.yaml "$RIME_DIR"/*.dict.yaml; do
    cp "$file" "$DEST/"
done
shopt -u nullglob

while IFS= read -r -d '' file; do
    cp "$file" "$DEST/build/"
done < <(find "$BUILD_DIR" -maxdepth 1 -type f -print0)

if [ -d "$DEST/cn_dicts" ]; then
    echo "error: source Chinese dictionaries must not be copied into the keyboard bundle" >&2
    exit 1
fi
if [ -f "$DEST/user.yaml" ]; then
    echo "error: local Rime user state must not be copied into the keyboard bundle" >&2
    exit 1
fi

runtime_kb="$(du -sk "$DEST" | awk '{print $1}')"
echo "Staged Rime iOS runtime: ${runtime_kb}KB at $DEST"
