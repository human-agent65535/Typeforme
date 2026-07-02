#!/usr/bin/env bash
# Build dist/mac/github-release/Typeforme.app with a stable self-signed
# identity for GitHub Release artifacts.
#
# This profile intentionally avoids Apple Developer identity metadata. Gatekeeper
# will treat the result as an unidentified-developer app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GITHUB_RELEASE_IDENTITY="${TYPEFORME_MAC_GITHUB_RELEASE_IDENTITY:-Typeforme Unidentified}"

usage() {
    cat <<EOF
Usage:
  scripts/build-mac-github-release.sh

Environment:
  IDENTITY=...     Codesigning identity override. Defaults to $GITHUB_RELEASE_IDENTITY.
  TYPEFORME_MAC_GITHUB_RELEASE_IDENTITY=... Self-signed identity name. Defaults to Typeforme Unidentified.
  TYPEFORME_BUNDLE_PREFIX=...         Bundle prefix. Defaults to com.example.
  TYPEFORME_MAC_BUNDLE_IDENTIFIER=... Full macOS bundle id override.
  TYPEFORME_MAC_DIST_ROOT=...         Root for macOS app outputs. Defaults to dist/mac.
  TYPEFORME_MAC_OUTPUT_DIR=...        Output directory. Defaults to dist/mac/github-release.
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
        echo "build-mac-github-release.sh does not accept build arguments; use scripts/build-app.sh for advanced options." >&2
        usage >&2
        exit 1
        ;;
esac

if [ -z "${IDENTITY:-}" ]; then
    if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$GITHUB_RELEASE_IDENTITY\""; then
        cat >&2 <<EOF
error: '$GITHUB_RELEASE_IDENTITY' signing identity was not found.

Create it once with:
  IDENTITY="$GITHUB_RELEASE_IDENTITY" scripts/create-signing-identity.sh

Then rerun:
  scripts/build-mac-github-release.sh
EOF
        exit 2
    fi
    export IDENTITY="$GITHUB_RELEASE_IDENTITY"
fi

export TYPEFORME_LOAD_ENV=0
export TYPEFORME_BUNDLE_PREFIX="${TYPEFORME_BUNDLE_PREFIX:-com.example}"
export TYPEFORME_MAC_BUNDLE_IDENTIFIER="${TYPEFORME_MAC_BUNDLE_IDENTIFIER:-$TYPEFORME_BUNDLE_PREFIX.typeforme.mac}"
TYPEFORME_MAC_DIST_ROOT="${TYPEFORME_MAC_DIST_ROOT:-$ROOT/dist/mac}"
export TYPEFORME_MAC_OUTPUT_DIR="${TYPEFORME_MAC_OUTPUT_DIR:-$TYPEFORME_MAC_DIST_ROOT/github-release}"

"$ROOT/scripts/build-app.sh" release

APP_DIR="${TYPEFORME_MAC_APP_DIR:-$TYPEFORME_MAC_OUTPUT_DIR/Typeforme.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
ZIP_PATH="$TYPEFORME_MAC_OUTPUT_DIR/Typeforme-$VERSION-$BUILD-mac-github-release-arm64.zip"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
echo "artifact: $ZIP_PATH"
