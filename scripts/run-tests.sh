#!/usr/bin/env bash
# Run the macOS test suite through the project Xcode scheme.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
typeforme_configure_xcode "test Typeforme"

exec "$XCODEBUILD" \
    -scheme Typeforme \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug \
    -derivedDataPath "$ROOT/.build/xcode-derived" \
    test \
    "$@"
