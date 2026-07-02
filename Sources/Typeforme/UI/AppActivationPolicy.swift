import AppKit

@MainActor
enum AppActivationPolicy {
    static func applyPreferredPolicy() {
        if AppSettings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func showDocumentWindow() {
        applyPreferredPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func restoreAccessoryIfNoDocumentWindows(excluding closingWindow: NSWindow) {
        applyPreferredPolicy()
    }
}
