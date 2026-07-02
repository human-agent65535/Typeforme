#!/usr/bin/env bash
# Build dist/mac/release/Typeforme.app for distribution checks.
#
# This intentionally does not install or launch the app. Release builds default
# to Developer ID Application signing when that identity is available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  scripts/build-mac-release.sh

Environment:
  IDENTITY=...     Codesigning identity override.
  TYPEFORME_BUNDLE_PREFIX=...         Bundle prefix. Defaults to com.example.
  TYPEFORME_MAC_BUNDLE_IDENTIFIER=... Full macOS bundle id override.
EOF
}

case "${1:-}" in
    "")
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "build-mac-release.sh does not accept build arguments; use scripts/build-app.sh for advanced options." >&2
        usage >&2
        exit 1
        ;;
esac

exec "$ROOT/scripts/build-app.sh" release
