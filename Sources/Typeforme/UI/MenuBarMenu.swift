import SwiftUI

/// Menu bar commands rendered by the parent `MenuBarExtra` as an `NSMenu`.
struct MenuBarMenu: View {
    let onOpenSettings: () -> Void

    @AppStorage(AppSettings.Keys.alwaysShowHUD) private var alwaysShowHUD: Bool = false
    @State private var axTrusted = AccessibilityPermissions.isTrusted

    var body: some View {
        Group {
            if axTrusted {
                Label("Accessibility Granted", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)

                Divider()
            } else {
                Button {
                    AccessibilityPermissions.requestTrustPrompt()
                    AccessibilityPermissions.openAccessibilitySettings()
                    refreshAccessibilityState()
                } label: {
                    Label("Grant Accessibility…", systemImage: "exclamationmark.triangle")
                }

                Divider()
            }

            Toggle("Always show HUD", isOn: $alwaysShowHUD)

            Divider()

            Button("Settings…") { onOpenSettings() }
                .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Typeforme") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            refreshAccessibilityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityState()
        }
    }

    private func refreshAccessibilityState() {
        let trusted = AccessibilityPermissions.isTrusted
        if trusted != axTrusted {
            axTrusted = trusted
        }
    }
}
