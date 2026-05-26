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

TMP_RIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typeforme-rime-ios-data.XXXXXX")"
trap 'rm -rf "$TMP_RIME_DIR"' EXIT

cp -R "$RIME_DIR"/. "$TMP_RIME_DIR"/
rm -rf "$TMP_RIME_DIR/build" "$TMP_RIME_DIR/user.yaml"

generate_no_correction_schema() {
    local source_schema="$1"
    local target_schema="$2"
    local display_name="$3"
    local target_file="$TMP_RIME_DIR/${target_schema}.schema.yaml"

    cp "$TMP_RIME_DIR/${source_schema}.schema.yaml" "$target_file"
    perl -0pi -e "s/schema_id: ${source_schema}/schema_id: ${target_schema}/; s/^  name: .*$/  name: ${display_name}/m; s/enable_correction: true/enable_correction: false/" "$target_file"
}

generate_no_correction_schema "typeforme_pinyin" "typeforme_pinyin_no_correction" "Typeforme Pinyin No Correction"
generate_no_correction_schema "typeforme_pinyin_ext" "typeforme_pinyin_ext_no_correction" "Typeforme Pinyin Extended No Correction"
generate_no_correction_schema "typeforme_pinyin_large" "typeforme_pinyin_large_no_correction" "Typeforme Pinyin Large No Correction"

perl -0pi -e '
  s/^  - schema: typeforme_pinyin\n/  - schema: typeforme_pinyin\n  - schema: typeforme_pinyin_no_correction\n/m;
  s/^  - schema: typeforme_pinyin_ext\n/  - schema: typeforme_pinyin_ext\n  - schema: typeforme_pinyin_ext_no_correction\n/m;
  s/^  - schema: typeforme_pinyin_large\n/  - schema: typeforme_pinyin_large\n  - schema: typeforme_pinyin_large_no_correction\n/m;
' "$TMP_RIME_DIR/default.yaml"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rime_deployer --build "$TMP_RIME_DIR" "$TMP_RIME_DIR" "$BUILD_DIR"
rm -f "$RIME_DIR/user.yaml"

echo "built Rime iOS data: $BUILD_DIR"
