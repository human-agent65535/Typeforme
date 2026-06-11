import SwiftUI
import Foundation

@main
struct TypeformeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        CommandLineHandler.exitIfHandled()
        guard SingleInstanceGuard.shared.acquireOrActivateExisting() else {
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        // Native SwiftUI menu-bar item (macOS 13+). Replaces the AppKit
        // NSStatusItem + NSMenu boilerplate; the label and menu status line
        // re-render when coordinator state changes thanks to @ObservedObject.
        MenuBarExtra {
            MenuBarMenu(
                coordinator: appDelegate.coordinator,
                onOpenSettings: { appDelegate.openSettings() },
                onResetHUDPosition: { appDelegate.resetHUDPosition() }
            )
        } label: {
            MenuBarLabel(coordinator: appDelegate.coordinator)
        }
    }
}
