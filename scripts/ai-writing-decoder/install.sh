#!/usr/bin/env bash
# Install an optional, relocatable Mac decoder runtime. The model and personal
# manifest stay in Application Support and are never part of a public release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/macho-bundle.sh"
source "$ROOT/scripts/lib/macos-signing.sh"
source "$ROOT/scripts/lib/xcode-tools.sh"
typeforme_configure_xcode "install the AI Writing decoder"

: "${TYPEFORME_DECODER_MODEL:?Set TYPEFORME_DECODER_MODEL to a local Qwen ChatML GGUF file}"
: "${TYPEFORME_DECODER_GRAMMAR:?Set TYPEFORME_DECODER_GRAMMAR to wanxiang-lts-zh-hans.gram}"
: "${TYPEFORME_LLAMA_LIB:?Set TYPEFORME_LLAMA_LIB to the llama.cpp libraries used by build.sh}"
TYPEFORME_DECODER_BUILD="${TYPEFORME_DECODER_BUILD:-$ROOT/.build/ai-writing-decoder-tools}"
TYPEFORME_DECODER_PLUGIN="${TYPEFORME_DECODER_PLUGIN:-/opt/homebrew/lib/rime-plugins/librime-octagram.dylib}"
TYPEFORME_DECODER_PYTHON="${TYPEFORME_DECODER_PYTHON:-$(command -v python3)}"
TYPEFORME_DECODER_ROOT="${TYPEFORME_DECODER_ROOT:-$HOME/Library/Application Support/Typeforme/ai-writing}"
TYPEFORME_DECODER_SIGN_IDENTITY="${TYPEFORME_DECODER_SIGN_IDENTITY:-}"
if [[ -z "$TYPEFORME_DECODER_SIGN_IDENTITY" ]]; then
    TYPEFORME_DECODER_SIGN_IDENTITY="$(typeforme_find_codesign_identity 'Apple Development:')"
fi
if [[ -z "$TYPEFORME_DECODER_SIGN_IDENTITY" ]]; then
    echo "error: an Apple Development identity is required for a local runtime install" >&2
    exit 1
fi
case "$TYPEFORME_DECODER_SIGN_IDENTITY" in
    'Apple Development:'*|'Developer ID Application:'*) ;;
    *) echo "error: local decoder installation requires an official Apple developer identity" >&2; exit 1 ;;
esac
for file in "$TYPEFORME_DECODER_MODEL" "$TYPEFORME_DECODER_GRAMMAR" "$TYPEFORME_DECODER_PLUGIN" "$TYPEFORME_DECODER_PYTHON"; do
    [[ -f "$file" ]] || { echo "error: missing decoder dependency: $file" >&2; exit 1; }
done

mkdir -p "$TYPEFORME_DECODER_ROOT"
stage="$(mktemp -d "$TYPEFORME_DECODER_ROOT/runtime-XXXXXXXX")"
installed=0
trap 'if [[ "$installed" == 0 ]]; then rm -rf "$stage"; fi' EXIT
mkdir -p "$stage/bin" "$stage/python" "$stage/rime/build"
cp "$ROOT/scripts/ai-writing-decoder/"{decode,candidates,runtime}.py "$stage/python/"
for tool in rime_analysis rime_sentences llama_score layout; do
    cp "$TYPEFORME_DECODER_BUILD/$tool" "$stage/bin/$tool"
done
cp "$TYPEFORME_DECODER_PLUGIN" "$stage/bin/librime-octagram.dylib"
# ggml loads the Metal/CPU backends at runtime, so seed their relative dylibs
# before recursively collecting absolute dependencies such as librime/Boost.
for library in "$TYPEFORME_LLAMA_LIB"/libllama.dylib "$TYPEFORME_LLAMA_LIB"/libllama.[0-9]*.dylib "$TYPEFORME_LLAMA_LIB"/libggml*.dylib; do
    [[ -f "$library" ]] || continue
    cp -L "$library" "$stage/bin/$(basename "$library")"
done
for tool in rime_analysis rime_sentences llama_score layout; do
    typeforme_bundle_non_system_deps "$stage/bin" "$tool"
done
for binary in "$stage/bin/"*; do
    codesign --force --sign "$TYPEFORME_DECODER_SIGN_IDENTITY" "$binary" >/dev/null 2>&1
    codesign --verify --strict "$binary" >/dev/null 2>&1
done
cp "$ROOT/iOS/TypeformeKeyboard/RimeSharedSupport/build/"typeforme_pinyin.{table,prism,reverse}.bin "$stage/rime/build/"
cp "$TYPEFORME_DECODER_GRAMMAR" "$stage/wanxiang-lts-zh-hans.gram"

"$TYPEFORME_DECODER_PYTHON" - "$stage" "$TYPEFORME_DECODER_ROOT" "$TYPEFORME_DECODER_PYTHON" "$TYPEFORME_DECODER_MODEL" <<'PY'
import json
from pathlib import Path
import sys

stage, root, python, model = [Path(p).absolute() for p in sys.argv[1:]]
value = dict(version=1, python=str(python), script=str(stage/'python/decode.py'),
             tools=str(stage/'bin'), rimeData=str(stage/'rime'),
             grammar=str(stage/'wanxiang-lts-zh-hans.gram'),
             plugin=str(stage/'bin/librime-octagram.dylib'), model=str(model),
             backendDirectory=str(stage/'bin'))
manifest = root/'runtime.json'
temporary = root/'runtime.json.installing'
temporary.write_text(json.dumps(value, indent=2)+'\n')
temporary.chmod(0o600)
temporary.replace(manifest)
print('Installed decoder runtime:', manifest)
PY
installed=1
echo "Select Pinyin decoder (Rime + Qwen) in Mac Settings > Writing > Prompts."
