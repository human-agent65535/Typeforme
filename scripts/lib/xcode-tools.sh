#!/usr/bin/env bash
# Shared Xcode tool lookup for repository scripts.

typeforme_configure_xcode() {
    local purpose="${1:-run Typeforme scripts}"
    local default_developer_dir="/Applications/Xcode.app/Contents/Developer"

    if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$default_developer_dir" ]; then
        export DEVELOPER_DIR="$default_developer_dir"
    fi

    if [ -z "${DEVELOPER_DIR:-}" ]; then
        cat >&2 <<EOF
error: full Xcode is required to $purpose.

Set DEVELOPER_DIR to Xcode, for example:
  export DEVELOPER_DIR=$default_developer_dir

Use the Xcode-backed scripts for project verification.
EOF
        exit 2
    fi

    XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
    export XCODEBUILD
    if [ ! -x "$XCODEBUILD" ]; then
        cat >&2 <<EOF
error: xcodebuild not found at $XCODEBUILD.

Set DEVELOPER_DIR to a full Xcode installation, for example:
  export DEVELOPER_DIR=$default_developer_dir
EOF
        exit 2
    fi
}

typeforme_configure_xcrun() {
    XCRUN="/usr/bin/xcrun"
    export XCRUN
    if [ ! -x "$XCRUN" ]; then
        echo "error: xcrun not found at $XCRUN." >&2
        exit 2
    fi
}

typeforme_xcrun() {
    DEVELOPER_DIR="$DEVELOPER_DIR" "$XCRUN" "$@"
}
