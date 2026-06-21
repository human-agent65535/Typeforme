#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor/LibrimeKit"
FRAMEWORK_ARCHIVE="$ROOT/vendor/LibrimeKit-Frameworks.tgz"
FRAMEWORK_URL="${LIBRIMEKIT_FRAMEWORK_URL:-https://github.com/amorphobia/LibrimeKit/releases/download/v0.1.0/Frameworks.tgz}"
FRAMEWORK_SHA256="${LIBRIMEKIT_FRAMEWORK_SHA256:-7b3d1d210c5a251a951685b722399c5eeb60f18a39a782a8850511edd12d0398}"
REPO_URL="${LIBRIMEKIT_REPO_URL:-https://github.com/mariorichp/LibrimeKit.git}"
REPO_REF="${LIBRIMEKIT_REPO_REF:-583a59e82702a3a057bdcc6f65f3fcab5fae52e6}"
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

verify_framework_archive() {
  local archive="$1"
  local expected="$2"
  local actual

  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    cat >&2 <<EOF
LibrimeKit framework archive checksum mismatch.
Expected: $expected
Actual:   $actual
Archive:  $archive
EOF
    exit 1
  fi
}

checkout_librimekit_ref() {
  (
    cd "$VENDOR_DIR"
    local current target_commit
    current="$(git rev-parse HEAD)"
    target_commit="$(git rev-parse --verify "$REPO_REF^{commit}" 2>/dev/null || true)"
    if [[ -z "$target_commit" || "$current" != "$target_commit" ]]; then
      git fetch --depth 1 origin "$REPO_REF" 2>/dev/null || git fetch origin
      git checkout --detach "$REPO_REF"
    fi
    git submodule update --init --recursive --depth 1
  )
}

mkdir -p "$ROOT/vendor"

if [[ ! -d "$VENDOR_DIR/.git" ]]; then
  rm -rf "$VENDOR_DIR"
  git clone "$REPO_URL" "$VENDOR_DIR"
fi
checkout_librimekit_ref

if [[ ! -d "$VENDOR_DIR/Frameworks/librime.xcframework" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -fL -o "$FRAMEWORK_ARCHIVE" "$FRAMEWORK_URL"
  verify_framework_archive "$FRAMEWORK_ARCHIVE" "$FRAMEWORK_SHA256"
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
