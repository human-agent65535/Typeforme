#!/usr/bin/env bash

typeforme_ios_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

typeforme_verify_ios_host_keyboard_bundle() {
    local app_path="$1"
    local keyboard_appex_path="$2"
    local label="${3:-Built}"
    local app_plist="$app_path/Info.plist"
    local keyboard_plist="$keyboard_appex_path/Info.plist"

    if [ ! -d "$app_path" ]; then
        echo "error: built app not found at $app_path" >&2
        return 1
    fi
    if [ ! -d "$keyboard_appex_path" ]; then
        echo "error: built keyboard extension not found at $keyboard_appex_path" >&2
        return 1
    fi

    TYPEFORME_IOS_HOST_VERSION="$(typeforme_ios_plist_value CFBundleShortVersionString "$app_plist")"
    TYPEFORME_IOS_HOST_BUILD="$(typeforme_ios_plist_value CFBundleVersion "$app_plist")"
    TYPEFORME_IOS_KEYBOARD_VERSION="$(typeforme_ios_plist_value CFBundleShortVersionString "$keyboard_plist")"
    TYPEFORME_IOS_KEYBOARD_BUILD="$(typeforme_ios_plist_value CFBundleVersion "$keyboard_plist")"
    TYPEFORME_IOS_HOST_BUNDLE_ID="$(typeforme_ios_plist_value CFBundleIdentifier "$app_plist")"
    TYPEFORME_IOS_HOST_CONFIGURED_BUNDLE_ID="$(typeforme_ios_plist_value TypeformeHostBundleIdentifier "$app_plist")"
    TYPEFORME_IOS_KEYBOARD_BUNDLE_ID="$(typeforme_ios_plist_value TypeformeKeyboardBundleIdentifier "$app_plist")"
    TYPEFORME_IOS_KEYBOARD_BUILT_BUNDLE_ID="$(typeforme_ios_plist_value CFBundleIdentifier "$keyboard_plist")"
    TYPEFORME_IOS_KEYBOARD_CONFIGURED_BUNDLE_ID="$(typeforme_ios_plist_value TypeformeKeyboardBundleIdentifier "$keyboard_plist")"
    TYPEFORME_IOS_HOST_APP_GROUP_ID="$(typeforme_ios_plist_value TypeformeAppGroupIdentifier "$app_plist")"
    TYPEFORME_IOS_KEYBOARD_APP_GROUP_ID="$(typeforme_ios_plist_value TypeformeAppGroupIdentifier "$keyboard_plist")"
    TYPEFORME_IOS_KEYBOARD_EXTENSION_POINT="$(typeforme_ios_plist_value NSExtension:NSExtensionPointIdentifier "$keyboard_plist")"

    if [ "$TYPEFORME_IOS_HOST_CONFIGURED_BUNDLE_ID" != "$TYPEFORME_IOS_HOST_BUNDLE_ID" ]; then
        echo "error: $label host bundle id mismatch: CFBundleIdentifier=$TYPEFORME_IOS_HOST_BUNDLE_ID, TypeformeHostBundleIdentifier=$TYPEFORME_IOS_HOST_CONFIGURED_BUNDLE_ID" >&2
        return 1
    fi
    if [ "$TYPEFORME_IOS_KEYBOARD_BUILT_BUNDLE_ID" != "$TYPEFORME_IOS_KEYBOARD_BUNDLE_ID" ]; then
        echo "error: $label keyboard extension bundle id mismatch: CFBundleIdentifier=$TYPEFORME_IOS_KEYBOARD_BUILT_BUNDLE_ID, host expects $TYPEFORME_IOS_KEYBOARD_BUNDLE_ID" >&2
        return 1
    fi
    if [ "$TYPEFORME_IOS_KEYBOARD_CONFIGURED_BUNDLE_ID" != "$TYPEFORME_IOS_KEYBOARD_BUNDLE_ID" ]; then
        echo "error: $label keyboard configuration mismatch: extension TypeformeKeyboardBundleIdentifier=$TYPEFORME_IOS_KEYBOARD_CONFIGURED_BUNDLE_ID, host expects $TYPEFORME_IOS_KEYBOARD_BUNDLE_ID" >&2
        return 1
    fi
    if [ "$TYPEFORME_IOS_HOST_APP_GROUP_ID" != "$TYPEFORME_IOS_KEYBOARD_APP_GROUP_ID" ]; then
        echo "error: $label app group mismatch: host=$TYPEFORME_IOS_HOST_APP_GROUP_ID, keyboard=$TYPEFORME_IOS_KEYBOARD_APP_GROUP_ID" >&2
        return 1
    fi
    if [ "$TYPEFORME_IOS_KEYBOARD_EXTENSION_POINT" != "com.apple.keyboard-service" ]; then
        echo "error: $label keyboard extension point mismatch: $TYPEFORME_IOS_KEYBOARD_EXTENSION_POINT" >&2
        return 1
    fi
    if [ "$TYPEFORME_IOS_KEYBOARD_VERSION" != "$TYPEFORME_IOS_HOST_VERSION" ] || [ "$TYPEFORME_IOS_KEYBOARD_BUILD" != "$TYPEFORME_IOS_HOST_BUILD" ]; then
        echo "error: $label host and keyboard versions diverged: host $TYPEFORME_IOS_HOST_VERSION ($TYPEFORME_IOS_HOST_BUILD), keyboard $TYPEFORME_IOS_KEYBOARD_VERSION ($TYPEFORME_IOS_KEYBOARD_BUILD)" >&2
        return 1
    fi
}
