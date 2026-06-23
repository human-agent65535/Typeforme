#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIME_DIR="$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport"
BUILD_DIR="$RIME_DIR/build"

# shellcheck source=scripts/lib/rime-ios-schemas.sh
. "$ROOT/scripts/lib/rime-ios-schemas.sh"

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

generate_schema_variant() {
    local source_schema="$1"
    local target_schema="$2"
    local display_name="$3"
    local correction_enabled="$4"
    local learning_enabled="$5"
    local target_file="$TMP_RIME_DIR/${target_schema}.schema.yaml"

    cp "$TMP_RIME_DIR/${source_schema}.schema.yaml" "$target_file"
    perl -0pi -e "s/schema_id: ${source_schema}/schema_id: ${target_schema}/; s/^  name: .*$/  name: ${display_name}/m; s/enable_correction: true/enable_correction: ${correction_enabled}/; s/enable_user_dict: true/enable_user_dict: ${learning_enabled}/" "$target_file"
}

while IFS=$'\t' read -r source_schema target_schema display_name correction_enabled learning_enabled; do
    generate_schema_variant "$source_schema" "$target_schema" "$display_name" "$correction_enabled" "$learning_enabled"
    perl -0pi -e "s/^  - schema: ${source_schema}\n/  - schema: ${source_schema}\n  - schema: ${target_schema}\n/m;" "$TMP_RIME_DIR/default.yaml"
done < <(typeforme_rime_generated_schema_variants)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rime_deployer --build "$TMP_RIME_DIR" "$TMP_RIME_DIR" "$BUILD_DIR"
rm -f "$RIME_DIR/user.yaml"

echo "built Rime iOS data: $BUILD_DIR"
