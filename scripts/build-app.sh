#!/usr/bin/env bash
# Build a macOS app bundle from the Xcode-built package executable, including
# AppIcon and bundled helper binaries when present.
#
# Usage:
#   scripts/build-app.sh [debug|release] [--install|--deploy]  # default: debug
#   scripts/run-mac-debug.sh
#   scripts/build-mac-release.sh
#   scripts/build-mac-github-release.sh
#   INSTALL_DIR=/Applications scripts/build-app.sh debug --install
#   IDENTITY="Developer ID Application: ..." scripts/build-app.sh release --install
#
# Release builds without IDENTITY are Developer ID direct-download builds.
# Other release channels pass their own IDENTITY explicitly, for example the
# GitHub release script's stable self-signed identity.
set -euo pipefail

CONFIG="debug"
INSTALL_APP=0
LAUNCH_AFTER_INSTALL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Typeforme"
BINARY_NAME="Typeforme"
SCHEME="Typeforme"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TYPEFORME_MAC_DIST_ROOT="${TYPEFORME_MAC_DIST_ROOT:-$ROOT/dist/mac}"
APP_DIR=""
BIN_DIR=""
RES_DIR=""
LLAMA_DIR=""
NVIDIA_NEMOTRON_DIR=""

usage() {
    cat <<EOF
Usage:
  scripts/build-app.sh [debug|release] [--install|--deploy] [--launch]

Environment:
  IDENTITY=...     Codesigning identity. Release without IDENTITY requires Developer ID Application.
  INSTALL_DIR=...  Install destination directory. Defaults to /Applications.
  TYPEFORME_MAC_DIST_ROOT=...  Root for macOS app outputs. Defaults to dist/mac.
  TYPEFORME_MAC_OUTPUT_DIR=... Output directory for this build. Defaults to dist/mac/dev or dist/mac/release.
  TYPEFORME_MAC_APP_DIR=...    Full .app output path override.
  TYPEFORME_BUNDLE_PREFIX=...         Bundle prefix. Defaults to com.example.
  TYPEFORME_MAC_BUNDLE_IDENTIFIER=... Full macOS bundle id override.
  TYPEFORME_LOAD_ENV=0         Skip loading root .env. Defaults to 1.
EOF
}

if [ "${TYPEFORME_LOAD_ENV:-1}" != "0" ] && [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi
# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
# shellcheck source=scripts/lib/macho-bundle.sh
. "$ROOT/scripts/lib/macho-bundle.sh"
typeforme_configure_xcode "build Typeforme"

TYPEFORME_BUNDLE_PREFIX="${TYPEFORME_BUNDLE_PREFIX:-com.example}"
TYPEFORME_MAC_BUNDLE_IDENTIFIER="${TYPEFORME_MAC_BUNDLE_IDENTIFIER:-$TYPEFORME_BUNDLE_PREFIX.typeforme.mac}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        debug|release)
            CONFIG="$1"
            ;;
        --install|--deploy)
            INSTALL_APP=1
            ;;
        --launch)
            INSTALL_APP=1
            LAUNCH_AFTER_INSTALL=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$CONFIG" in
    debug|release) ;;
    *) echo "config must be debug|release, got: $CONFIG" >&2; exit 1 ;;
esac

OUTPUT_PROFILE="dev"
if [ "$CONFIG" = "release" ]; then
    OUTPUT_PROFILE="release"
fi
TYPEFORME_MAC_OUTPUT_DIR="${TYPEFORME_MAC_OUTPUT_DIR:-$TYPEFORME_MAC_DIST_ROOT/$OUTPUT_PROFILE}"
APP_DIR="${TYPEFORME_MAC_APP_DIR:-$TYPEFORME_MAC_OUTPUT_DIR/${APP_NAME}.app}"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
LLAMA_DIR="$RES_DIR/llama"
NVIDIA_NEMOTRON_DIR="$RES_DIR/nvidia-nemotron"

wait_for_installed_app_to_exit() {
    local installed_app="$1"
    local pattern="$installed_app/Contents/"
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        return 0
    fi

    echo "stopping running $APP_NAME from $installed_app"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true

    for _ in $(seq 1 40); do
        if ! pgrep -f "$pattern" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done

    echo "error: $APP_NAME is still running from $installed_app; quit it and rerun with --install" >&2
    return 1
}

install_app_bundle() {
    local install_dir="$1"
    local installed_app="$install_dir/${APP_NAME}.app"
    local installing_app="$install_dir/.${APP_NAME}.app.installing"

    mkdir -p "$install_dir"
    wait_for_installed_app_to_exit "$installed_app"

    rm -rf "$installing_app"
    ditto "$APP_DIR" "$installing_app"
    codesign --verify --deep --strict --verbose=1 "$installing_app" 2>&1 | sed 's/^/install verify: /'

    rm -rf "$installed_app"
    mv "$installing_app" "$installed_app"
    codesign --verify --deep --strict --verbose=1 "$installed_app" 2>&1 | sed 's/^/installed verify: /'

    echo "installed: $installed_app"
    if [ "$LAUNCH_AFTER_INSTALL" -eq 1 ]; then
        open "$installed_app"
        echo "launched: $installed_app"
    fi
}

cd "$ROOT"

XCODE_CONFIG="Debug"
if [ "$CONFIG" = "release" ]; then
    XCODE_CONFIG="Release"
fi

XCODE_DERIVED="$ROOT/.build/xcode-derived"
"$XCODEBUILD" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' \
    -configuration "$XCODE_CONFIG" \
    -derivedDataPath "$XCODE_DERIVED" \
    build
BIN_SRC="$XCODE_DERIVED/Build/Products/$XCODE_CONFIG/$BINARY_NAME"
[ -x "$BIN_SRC" ] || { echo "built binary not found" >&2; exit 1; }
PRODUCT_DIR="$(cd "$(dirname "$BIN_SRC")" && pwd)"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR" "$LLAMA_DIR"

cp "$BIN_SRC" "$BIN_DIR/${BINARY_NAME}"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TYPEFORME_MAC_BUNDLE_IDENTIFIER" "$APP_DIR/Contents/Info.plist"

# SwiftPM dependencies can generate resource bundles even when they are linked
# statically. KeyboardShortcuts uses this for localized UI strings; omitting it
# makes NSBundle.module trap when the shortcut recorder is rendered.
for bundle in "$PRODUCT_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$RES_DIR/"
done

# App icon — render via scripts/generate-icon.swift if missing, then iconutil.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    if [ -d "$ROOT/Resources/AppIcon.iconset" ]; then
        iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
    else
        echo "warn: AppIcon.icns missing and no iconset to compile — bundle will have no icon" >&2
    fi
fi
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

# Localization bundles. Placing the .lproj dirs at `.app/Contents/Resources/`
# is what lets Bundle.main pick them up at runtime, so SwiftUI `Text("Ready")`
# and `NSLocalizedString("Ready", comment: ...)` auto-localize without per-
# call-site bundle parameters.
for lproj in "$ROOT/Resources"/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$RES_DIR/"
done

find_codesign_identity() {
    local prefix="$1"
    local identities preferred
    identities="$(security find-identity -p codesigning -v 2>/dev/null \
        | sed -n "s/.*\"\(${prefix}[^\"]*\)\".*/\1/p" \
        || true)"
    if [ "$prefix" = "Apple Development:" ]; then
        # Prefer modern person-name development certificates over older
        # email-labelled ones. The latter can linger in the keychain after
        # revocation and still pass `security find-identity`, then helpers get
        # killed at runtime by Gatekeeper.
        preferred="$(printf '%s\n' "$identities" | grep -v '@' | head -n 1 || true)"
        if [ -n "$preferred" ]; then
            printf '%s\n' "$preferred"
            return
        fi
    fi
    printf '%s\n' "$identities" | head -n 1
}

select_default_sign_identity() {
    local identity=""
    if [ "$CONFIG" = "release" ]; then
        identity="$(find_codesign_identity "Developer ID Application:")"
        [ -n "$identity" ] && { printf '%s\n' "$identity"; return; }

        cat >&2 <<EOF
error: release builds need an explicit signing identity for the target channel.

Direct download:
  IDENTITY="Developer ID Application: ..." scripts/build-app.sh release

GitHub release:
  scripts/build-mac-github-release.sh

App Store / TestFlight:
  use the Xcode archive/export flow, or pass an explicit channel-appropriate IDENTITY.
EOF
        exit 2
    fi

    identity="$(find_codesign_identity "Apple Development:")"
    [ -n "$identity" ] && { printf '%s\n' "$identity"; return; }

    identity="$(find_codesign_identity "Typeforme Local Dev")"
    [ -n "$identity" ] && { printf '%s\n' "$identity"; return; }

    printf '%s\n' "-"
}

# Bundled llama-server (optional). When present, codesign with the
# llama-server entitlements (allow-jit) so it can JIT Metal kernels.
SIGN_IDENTITY="${IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(select_default_sign_identity)"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "signing identity: adhoc"
else
    echo "signing identity: $SIGN_IDENTITY"
    if [ "$CONFIG" = "release" ]; then
        case "$SIGN_IDENTITY" in
            Developer\ ID\ Application:*|Typeforme\ Unidentified) ;;
            Apple\ Distribution:*)
                echo "warn: Apple Distribution is only appropriate for App Store-style distribution, not direct downloads." >&2
                ;;
            *)
                echo "warn: explicit release identity is not Developer ID Application; verify the target channel expects this certificate." >&2
                ;;
        esac
    fi
fi
LLAMA_ENT="$ROOT/Resources/llama-server.entitlements"
LLAMA_SRC="$ROOT/vendor/llama-server-arm64"
if [ -x "$LLAMA_SRC" ]; then
    cp "$LLAMA_SRC" "$LLAMA_DIR/llama-server-arm64"
    chmod +x "$LLAMA_DIR/llama-server-arm64"
    # Bring along any sibling dylibs / metallib shipped next to the binary.
    for sib in "$ROOT"/vendor/*.dylib "$ROOT"/vendor/*.metallib; do
        [ -e "$sib" ] && cp "$sib" "$LLAMA_DIR/"
    done
    typeforme_bundle_non_system_deps "$LLAMA_DIR" "llama-server-arm64"
    # Sign the helper FIRST (deepest first), then the app bundle below.
    codesign --force --options runtime --entitlements "$LLAMA_ENT" \
             --sign "$SIGN_IDENTITY" "$LLAMA_DIR/llama-server-arm64"
    for sib in "$LLAMA_DIR"/*.dylib "$LLAMA_DIR"/*.metallib; do
        [ -e "$sib" ] || continue
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$sib"
    done
fi

NVIDIA_NEMOTRON_SRC="$ROOT/vendor/nvidia-nemotron"
NVIDIA_NEMOTRON_BIN="$NVIDIA_NEMOTRON_SRC/typeforme-nemotron-asr"
if [ -x "$NVIDIA_NEMOTRON_BIN" ]; then
    mkdir -p "$NVIDIA_NEMOTRON_DIR"
    cp "$NVIDIA_NEMOTRON_BIN" "$NVIDIA_NEMOTRON_DIR/typeforme-nemotron-asr"
    chmod +x "$NVIDIA_NEMOTRON_DIR/typeforme-nemotron-asr"
    for sib in "$NVIDIA_NEMOTRON_SRC"/*.dylib; do
        [ -e "$sib" ] && cp "$sib" "$NVIDIA_NEMOTRON_DIR/"
    done
    typeforme_bundle_non_system_deps "$NVIDIA_NEMOTRON_DIR" "typeforme-nemotron-asr"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$NVIDIA_NEMOTRON_DIR/typeforme-nemotron-asr"
    for sib in "$NVIDIA_NEMOTRON_DIR"/*.dylib; do
        [ -e "$sib" ] || continue
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$sib"
    done
fi

# Sign the app bundle. --deep so anything inside Resources/ is verified too.
APP_ENT="$ROOT/Resources/Typeforme.entitlements"
codesign --force --options runtime --entitlements "$APP_ENT" \
         --sign "$SIGN_IDENTITY" --deep "$APP_DIR"

# Sanity check
codesign --verify --deep --strict --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/verify: /'
SPCTL_OUTPUT="$(spctl -a -vv "$APP_DIR" 2>&1 || true)"
if grep -q 'CSSMERR_TP_CERT_REVOKED' <<<"$SPCTL_OUTPUT"; then
    printf '%s\n' "$SPCTL_OUTPUT" | sed 's/^/gatekeeper: /' >&2
    echo "error: $APP_DIR was signed with a revoked certificate; choose a different IDENTITY for this distribution channel." >&2
    exit 2
fi

echo "built: $APP_DIR"
if [ -x "$LLAMA_DIR/llama-server-arm64" ]; then
    echo "       (with llama-server-arm64)"
else
    echo "       (no llama-server-arm64 — drop one in vendor/ and rebuild for embedded LLM)"
fi
if [ -x "$NVIDIA_NEMOTRON_DIR/typeforme-nemotron-asr" ]; then
    echo "       (with nvidia-nemotron helper)"
else
    echo "       (no nvidia-nemotron helper — run scripts/build-nvidia-nemotron-helper.sh and rebuild for NVIDIA ASR)"
fi

if [ "$INSTALL_APP" -eq 1 ]; then
    install_app_bundle "$INSTALL_DIR"
fi
