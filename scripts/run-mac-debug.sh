#!/usr/bin/env bash
# Build dist/mac/dev/Typeforme.app, install, and launch the local debug macOS app.
#
# This is the daily development entrypoint. It uses the debug configuration and
# the normal local signing identity selected by scripts/build-app.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  scripts/run-mac-debug.sh

Environment:
  INSTALL_DIR=...  Install destination directory. Defaults to /Applications.
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
        echo "run-mac-debug.sh does not accept build arguments; use scripts/build-app.sh for advanced options." >&2
        usage >&2
        exit 1
        ;;
esac

exec "$ROOT/scripts/build-app.sh" debug --install --launch
