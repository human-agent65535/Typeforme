import AppKit

@MainActor
enum AppActivationPolicy {
    static func applyPreferredPolicy() {
        if AppSettings.showDockIcon || hasVisibleDocumentWindows() {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func showDocumentWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func restoreAccessoryIfNoDocumentWindows(excluding closingWindow: NSWindow) {
        if AppSettings.showDockIcon || hasVisibleDocumentWindows(excluding: closingWindow) {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func hasVisibleDocumentWindows(excluding excludedWindow: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { window in
            window !== excludedWindow
                && window.isVisible
                && !window.isMiniaturized
                && !(window is HUDPanel)
        }
    }
}
