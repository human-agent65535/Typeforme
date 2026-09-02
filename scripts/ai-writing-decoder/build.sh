#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/xcode-tools.sh"
typeforme_configure_xcode "build the AI writing decoder diagnostic"
typeforme_configure_xcrun

BREW_PREFIX="${HOMEBREW_PREFIX:-}"
if [[ -z "$BREW_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix)"
fi
: "${TYPEFORME_RIME_SOURCE:?Set TYPEFORME_RIME_SOURCE to a librime 1.17.0 source checkout}"
: "${TYPEFORME_LLAMA_SOURCE:?Set TYPEFORME_LLAMA_SOURCE to the llama.cpp source matching its built libraries}"
TYPEFORME_DECODER_BUILD="${TYPEFORME_DECODER_BUILD:-$ROOT/.build/ai-writing-decoder-tools}"
TYPEFORME_LLAMA_LIB="${TYPEFORME_LLAMA_LIB:-$TYPEFORME_LLAMA_SOURCE/build/bin}"
TYPEFORME_BOOST_INCLUDE="${TYPEFORME_BOOST_INCLUDE:-${BREW_PREFIX}/include}"

required=(
    "$TYPEFORME_RIME_SOURCE/src/rime/gear/poet.h"
    "$TYPEFORME_LLAMA_SOURCE/include/llama.h"
    "$TYPEFORME_LLAMA_LIB/libllama.dylib"
    "$BREW_PREFIX/include/rime_api.h"
    "$BREW_PREFIX/lib/librime.dylib"
    "$TYPEFORME_BOOST_INCLUDE/boost/algorithm/string.hpp"
)
for path in "${required[@]}"; do
    if [[ ! -f "$path" ]]; then
        echo "error: required decoder build dependency is missing: $path" >&2
        exit 1
    fi
done

mkdir -p "$TYPEFORME_DECODER_BUILD/include/rime"
cat > "$TYPEFORME_DECODER_BUILD/include/rime/build_config.h" <<'EOF'
#pragma once
#define RIME_ENABLE_LOGGING 1
EOF

for component in rime_analysis rime_sentences; do
    typeforme_xcrun clang++ -std=c++17 -O2 -DGLOG_USE_GLOG_EXPORT \
        -I"$TYPEFORME_DECODER_BUILD/include" \
        -I"$TYPEFORME_RIME_SOURCE/src" -I"$TYPEFORME_RIME_SOURCE/include" \
        -I"$TYPEFORME_BOOST_INCLUDE" -I"$BREW_PREFIX/include" \
        "$ROOT/scripts/ai-writing-decoder/native/$component.cc" \
        -L"$BREW_PREFIX/lib" -lrime -lglog \
        -o "$TYPEFORME_DECODER_BUILD/$component"
done

typeforme_xcrun clang++ -std=c++17 -O3 \
    -I"$TYPEFORME_LLAMA_SOURCE/include" -I"$TYPEFORME_LLAMA_SOURCE/ggml/include" \
    -I"$TYPEFORME_LLAMA_SOURCE/vendor" \
    "$ROOT/scripts/ai-writing-decoder/native/llama_score.cc" \
    -L"$TYPEFORME_LLAMA_LIB" -Wl,-rpath,"$TYPEFORME_LLAMA_LIB" \
    -lllama -lggml -lggml-base -framework Accelerate \
    -o "$TYPEFORME_DECODER_BUILD/llama_score"

typeforme_xcrun swiftc -O \
    "$ROOT/scripts/ai-writing-decoder/native/main.swift" \
    "$ROOT/scripts/ai-writing-decoder/native/UnusedRecognitionSource.swift" \
    "$ROOT/Sources/Typeforme/Utils/VerbatimSpanMask.swift" \
    "$ROOT/Sources/Typeforme/Utils/UnicodeScriptClassifier.swift" \
    "$ROOT/Sources/Typeforme/Utils/LocaleTextNormalizer.swift" \
    "$ROOT/Sources/Typeforme/Models/ASRLanguageSelection.swift" \
    "$ROOT/Sources/Typeforme/Models/OutputPreferences.swift" \
    "$ROOT/Sources/Typeforme/Models/AppCategory.swift" \
    "$ROOT/Sources/Typeforme/Models/DictionaryEntry.swift" \
    "$ROOT/Sources/Typeforme/Models/TextEditRequest.swift" \
    "$ROOT/Sources/Typeforme/Bridge/BridgeTextEditContract.swift" \
    "$ROOT/Sources/Typeforme/Bridge/BridgeJSON.swift" \
    "$ROOT/Sources/Typeforme/LLM/PinyinDraftLayout.swift" \
    "$ROOT/Sources/Typeforme/LLM/TextEditValidator.swift" \
    "$ROOT/Sources/Typeforme/LLM/TranscriptPostProcessor.swift" \
    "$ROOT/Sources/Typeforme/LLM/ModelJSONOutputValidator.swift" \
    "$ROOT/Sources/Typeforme/LLM/ModelOutputCleaner.swift" \
    "$ROOT/Sources/Typeforme/Prompts/OutputPreferencePrompt.swift" \
    -o "$TYPEFORME_DECODER_BUILD/layout"

echo "Decoder tools built in $TYPEFORME_DECODER_BUILD"
