#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor/LibrimeKit"
FRAMEWORK_ARCHIVE="$ROOT/vendor/LibrimeKit-Frameworks.tgz"
FRAMEWORK_URL="${LIBRIMEKIT_FRAMEWORK_URL:-https://github.com/amorphobia/LibrimeKit/releases/download/v0.1.0/Frameworks.tgz}"
REPO_URL="${LIBRIMEKIT_REPO_URL:-https://github.com/mariorichp/LibrimeKit.git}"
BUILD_ARM64_SIMULATOR="${TYPEFORME_BUILD_RIME_ARM64_SIMULATOR:-auto}"

# shellcheck source=scripts/lib/xcode-tools.sh
. "$ROOT/scripts/lib/xcode-tools.sh"
typeforme_configure_xcode "prepare LibrimeKit for iOS"

has_arm64_simulator_librime() {
  local binary="$VENDOR_DIR/Frameworks/librime.xcframework/ios-arm64_x86_64-simulator/librime_simulator_fat.a"

  [[ -f "$binary" ]] && lipo -archs "$binary" | grep -qw arm64
}

should_build_arm64_simulator() {
  case "$BUILD_ARM64_SIMULATOR" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    0|false|FALSE|no|NO)
      return 1
      ;;
    auto)
      [[ "$(uname -m)" == "arm64" ]] && ! has_arm64_simulator_librime
      ;;
    *)
      echo "Unknown TYPEFORME_BUILD_RIME_ARM64_SIMULATOR value: $BUILD_ARM64_SIMULATOR" >&2
      exit 1
      ;;
  esac
}

copy_boost_frameworks_to_librimekit() {
  local boost_framework_dir="$VENDOR_DIR/boost-iosx/frameworks"
  local framework

  for framework in boost_atomic boost_filesystem boost_regex boost_system; do
    rm -rf "$VENDOR_DIR/Frameworks/$framework.xcframework"
    cp -R "$boost_framework_dir/$framework.xcframework" "$VENDOR_DIR/Frameworks/"
  done
}

mkdir -p "$ROOT/vendor"

if [[ ! -d "$VENDOR_DIR/.git" ]]; then
  rm -rf "$VENDOR_DIR"
  git clone --depth 1 --recurse-submodules --shallow-submodules "$REPO_URL" "$VENDOR_DIR"
fi

if [[ ! -d "$VENDOR_DIR/Frameworks/librime.xcframework" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -L -o "$FRAMEWORK_ARCHIVE" "$FRAMEWORK_URL"
  tar -zxf "$FRAMEWORK_ARCHIVE" -C "$TMP_DIR"
  rm -rf "$VENDOR_DIR/Frameworks"
  mv "$TMP_DIR/Frameworks" "$VENDOR_DIR/Frameworks"
  rm -f "$FRAMEWORK_ARCHIVE"
fi

if should_build_arm64_simulator; then
  echo "Building LibrimeKit with arm64 iOS simulator support..."
  (
    cd "$VENDOR_DIR/boost-iosx"
    scripts/build.sh --libs=atomic,filesystem,regex,system --platforms=ios,iossim-both
  )
  copy_boost_frameworks_to_librimekit
  (
    cd "$VENDOR_DIR"
    PATH="/opt/homebrew/bin:$PATH" ./librimeBuild_arm64sim.sh
  )
fi

echo "LibrimeKit is ready at $VENDOR_DIR"
