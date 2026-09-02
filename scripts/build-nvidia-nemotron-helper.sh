#!/usr/bin/env bash
# Build the local Rust Nemotron ASR helper that scripts/build-app.sh bundles
# into Typeforme.app. Nemotron model files are managed by Typeforme Settings,
# the same way Qwen ASR model files are downloaded/deleted from the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_DIR="$ROOT/Tools/NvidiaNemotronHelper"
TARGET_DIR="$ROOT/.build/nvidia-nemotron-helper-target"
OUT_DIR="$ROOT/vendor/nvidia-nemotron"
BIN_NAME="typeforme-nemotron-asr"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo is required to build $BIN_NAME. Install Rust first, e.g. brew install rust." >&2
    exit 1
fi

mkdir -p "$OUT_DIR" "$TARGET_DIR"

# Rust panic locations include dependency source paths even in release builds.
# Remap those paths before the helper is embedded in public app bundles. Encoded
# flags keep paths containing spaces intact and preserve supplied environment flags.
TYPEFORME_HELPER_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:-}"
if [ "${CARGO_ENCODED_RUSTFLAGS+x}" != x ] && [ -n "${RUSTFLAGS:-}" ]; then
    TYPEFORME_HELPER_RUSTFLAGS="$(printf '%s' "$RUSTFLAGS" | awk '
        { for (i = 1; i <= NF; i++) { printf "%s%s", separator, $i; separator = sprintf("%c", 31) } }
    ')"
fi
for mapping in "$HOME=/typeforme-build" "$ROOT=/typeforme" "${CARGO_HOME:-$HOME/.cargo}=/cargo"; do
    TYPEFORME_HELPER_RUSTFLAGS+="${TYPEFORME_HELPER_RUSTFLAGS:+$'\x1f'}--remap-path-prefix=$mapping"
done

CARGO_ENCODED_RUSTFLAGS="$TYPEFORME_HELPER_RUSTFLAGS" CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo build --release --locked --manifest-path "$HELPER_DIR/Cargo.toml"
cp "$TARGET_DIR/release/$BIN_NAME" "$OUT_DIR/$BIN_NAME"
chmod +x "$OUT_DIR/$BIN_NAME"

echo "built helper: $OUT_DIR/$BIN_NAME"
