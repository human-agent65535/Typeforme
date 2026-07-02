#!/usr/bin/env bash
# Build, notarize, staple, and zip dist/mac/release/Typeforme.app for direct
# Developer ID distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage:
  scripts/build-mac-release.sh

Environment:
  IDENTITY=...     Codesigning identity override.
  TYPEFORME_NOTARIZE=0  Build and zip without notarization. Defaults to 1.
  TYPEFORME_NOTARY_PROFILE=...  notarytool keychain profile. Defaults to typeforme-notarytool.
  TYPEFORME_NOTARY_KEY_PATH=... App Store Connect API private key path.
  TYPEFORME_NOTARY_KEY_ID=...   App Store Connect API key id.
  TYPEFORME_NOTARY_ISSUER_ID=... App Store Connect issuer id.
  TYPEFORME_NOTARY_TIMEOUT=...  notarytool wait timeout. Defaults to 30m.
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

if [ "${TYPEFORME_LOAD_ENV:-1}" != "0" ] && [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
typeforme_configure_xcode "notarize Typeforme"
typeforme_configure_xcrun

"$ROOT/scripts/build-app.sh" release

TYPEFORME_MAC_DIST_ROOT="${TYPEFORME_MAC_DIST_ROOT:-$ROOT/dist/mac}"
TYPEFORME_MAC_OUTPUT_DIR="${TYPEFORME_MAC_OUTPUT_DIR:-$TYPEFORME_MAC_DIST_ROOT/release}"
APP_DIR="${TYPEFORME_MAC_APP_DIR:-$TYPEFORME_MAC_OUTPUT_DIR/Typeforme.app}"
APP_NAME="$(basename "$APP_DIR" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
ARTIFACT_BASENAME="${TYPEFORME_MAC_ARTIFACT_BASENAME:-$APP_NAME-$VERSION-$BUILD-mac-developer-id-arm64}"
UPLOAD_ZIP_PATH="$TYPEFORME_MAC_OUTPUT_DIR/$ARTIFACT_BASENAME.notary-upload.zip"
ZIP_PATH="${TYPEFORME_MAC_ZIP_PATH:-$TYPEFORME_MAC_OUTPUT_DIR/$ARTIFACT_BASENAME.zip}"
NOTARIZE="${TYPEFORME_NOTARIZE:-1}"
NOTARY_TIMEOUT="${TYPEFORME_NOTARY_TIMEOUT:-30m}"

SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS"; then
    cat >&2 <<EOF
error: $APP_DIR is not signed with a Developer ID Application identity.

Set IDENTITY="Developer ID Application: ..." or run with TYPEFORME_NOTARIZE=0
for a local non-notarized release bundle.
EOF
    exit 2
fi

zip_app() {
    local app_dir="$1"
    local zip_path="$2"
    rm -f "$zip_path"
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
    echo "artifact: $zip_path"
}

if [ "$NOTARIZE" != "0" ]; then
    notarytool_auth_args=()
    if [ -n "${TYPEFORME_NOTARY_KEY_PATH:-}" ] || [ -n "${TYPEFORME_NOTARY_KEY_ID:-}" ] || [ -n "${TYPEFORME_NOTARY_ISSUER_ID:-}" ]; then
        missing=0
        for var in TYPEFORME_NOTARY_KEY_PATH TYPEFORME_NOTARY_KEY_ID TYPEFORME_NOTARY_ISSUER_ID; do
            if [ -z "${!var:-}" ]; then
                echo "error: $var is required when using App Store Connect API key notarization." >&2
                missing=1
            fi
        done
        [ "$missing" -eq 0 ] || exit 2
        notarytool_auth_args=(--key "$TYPEFORME_NOTARY_KEY_PATH" --key-id "$TYPEFORME_NOTARY_KEY_ID" --issuer "$TYPEFORME_NOTARY_ISSUER_ID")
    else
        notarytool_auth_args=(--keychain-profile "${TYPEFORME_NOTARY_PROFILE:-typeforme-notarytool}")
    fi

    zip_app "$APP_DIR" "$UPLOAD_ZIP_PATH"

    echo "notarizing: $UPLOAD_ZIP_PATH"
    typeforme_xcrun notarytool submit "$UPLOAD_ZIP_PATH" \
        "${notarytool_auth_args[@]}" \
        --wait \
        --timeout "$NOTARY_TIMEOUT"

    echo "stapling: $APP_DIR"
    typeforme_xcrun stapler staple "$APP_DIR"
    typeforme_xcrun stapler validate "$APP_DIR"
else
    echo "warn: notarization skipped because TYPEFORME_NOTARIZE=0" >&2
fi

zip_app "$APP_DIR" "$ZIP_PATH"
codesign --verify --deep --strict --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/release verify: /'

if [ "$NOTARIZE" != "0" ]; then
    spctl -a -vvv -t exec "$APP_DIR" 2>&1 | sed 's/^/gatekeeper: /'
    rm -f "$UPLOAD_ZIP_PATH"
fi
