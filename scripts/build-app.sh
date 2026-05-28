#!/usr/bin/env bash
# Build dist/Typeforme.app from the Xcode-built package executable, including
# AppIcon and bundled helper binaries when present.
#
# Usage:
#   scripts/build-app.sh [debug|release] [--install|--deploy]  # default: debug
#   INSTALL_DIR=/Applications scripts/build-app.sh debug --install
#   IDENTITY="Developer ID Application: ..." scripts/build-app.sh release --install
#
# Adhoc signing (default) is fine for local-only use on this machine.
# Pass IDENTITY=... to sign for distribution / notarization.
set -euo pipefail

CONFIG="debug"
INSTALL_APP=0
LAUNCH_AFTER_INSTALL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Typeforme"
BINARY_NAME="Typeforme"
SCHEME="Typeforme"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
LLAMA_DIR="$RES_DIR/llama"

usage() {
    cat <<EOF
Usage:
  scripts/build-app.sh [debug|release] [--install|--deploy] [--launch]

Environment:
  IDENTITY=...     Codesigning identity. Defaults to Typeforme Local Dev or adhoc.
  INSTALL_DIR=...  Install destination directory. Defaults to /Applications.
  TYPEFORME_BUNDLE_PREFIX=...         Bundle prefix. Defaults to com.example.
  TYPEFORME_MAC_BUNDLE_IDENTIFIER=... Full macOS bundle id override.
EOF
}

if [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi
# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
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

is_system_dep() {
    local dep="$1"
    [[ "$dep" == /usr/lib/* || "$dep" == /System/Library/* ]]
}

is_relative_dep() {
    local dep="$1"
    [[ "$dep" == @rpath/* || "$dep" == @loader_path/* || "$dep" == @executable_path/* ]]
}

strip_rpaths_to_loader_path() {
    local file="$1"
    while read -r rp; do
        [ -z "$rp" ] && continue
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
    done < <(otool -l "$file" 2>/dev/null | awk '/LC_RPATH/{getline; getline; print $2}')
    install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
}

normalize_install_names() {
    local file="$1"
    local dir="$2"
    local base
    base="$(basename "$file")"
    if [[ "$file" == *.dylib ]]; then
        install_name_tool -id "@rpath/$base" "$file" 2>/dev/null || true
    fi

    while read -r dep; do
        [ -n "$dep" ] || continue
        is_system_dep "$dep" && continue
        local dep_base
        dep_base="$(basename "$dep")"
        [ -f "$dir/$dep_base" ] || continue
        install_name_tool -change "$dep" "@rpath/$dep_base" "$file" 2>/dev/null || true
    done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

bundle_non_system_deps() {
    local dir="$1"
    local main_binary="$2"
    local queue=("$dir/$main_binary")
    for dy in "$dir"/*.dylib; do
        [ -e "$dy" ] && queue+=("$dy")
    done

    local i=0
    while [ "$i" -lt "${#queue[@]}" ]; do
        local file="${queue[$i]}"
        i=$((i + 1))
        while read -r dep; do
            [ -n "$dep" ] || continue
            is_relative_dep "$dep" && continue
            is_system_dep "$dep" && continue
            if [ ! -f "$dep" ]; then
                echo "warn: non-system dylib not found: $dep (needed by $(basename "$file"))" >&2
                continue
            fi
            local base
            base="$(basename "$dep")"
            if [ ! -f "$dir/$base" ]; then
                cp "$dep" "$dir/$base"
                queue+=("$dir/$base")
            fi
        done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done

    strip_rpaths_to_loader_path "$dir/$main_binary"
    normalize_install_names "$dir/$main_binary" "$dir"
    for dy in "$dir"/*.dylib; do
        [ -e "$dy" ] || continue
        strip_rpaths_to_loader_path "$dy"
        normalize_install_names "$dy" "$dir"
    done
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

# Bundled llama-server (optional). When present, codesign with the
# llama-server entitlements (allow-jit) so it can JIT Metal kernels.
# Prefer the stable local development identity created by
# scripts/create-signing-identity.sh so TCC permission grants survive rebuilds.
# Public builds can still override this with IDENTITY="Developer ID ..."; pass
# IDENTITY="-" explicitly for ad-hoc signing.
SIGN_IDENTITY="${IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -p codesigning -v 2>/dev/null | grep -q '"Typeforme Local Dev"'; then
        SIGN_IDENTITY="Typeforme Local Dev"
    else
        SIGN_IDENTITY="-"
    fi
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "signing identity: adhoc"
else
    echo "signing identity: configured via IDENTITY"
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
    bundle_non_system_deps "$LLAMA_DIR" "llama-server-arm64"
    # Sign the helper FIRST (deepest first), then the app bundle below.
    codesign --force --options runtime --entitlements "$LLAMA_ENT" \
             --sign "$SIGN_IDENTITY" "$LLAMA_DIR/llama-server-arm64"
    for sib in "$LLAMA_DIR"/*.dylib "$LLAMA_DIR"/*.metallib; do
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

echo "built: $APP_DIR"
if [ -x "$LLAMA_DIR/llama-server-arm64" ]; then
    echo "       (with llama-server-arm64)"
else
    echo "       (no llama-server-arm64 — drop one in vendor/ and rebuild for embedded LLM)"
fi

if [ "$INSTALL_APP" -eq 1 ]; then
    install_app_bundle "$INSTALL_DIR"
fi
