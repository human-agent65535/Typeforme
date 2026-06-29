import SwiftUI

/// Menu bar commands rendered by the parent `MenuBarExtra` as an `NSMenu`.
struct MenuBarMenu: View {
    @ObservedObject var coordinator: DictationCoordinator
    let onOpenSettings: () -> Void
    let onResetHUDPosition: () -> Void

    @State private var axTrusted = AppPermissions.accessibilityTrusted

    var body: some View {
        Group {
            Label(statusLine, systemImage: statusSymbol)

            Divider()

            Button(dictationActionTitle) {
                Task { await coordinator.toggleDictation() }
            }

            Divider()

            if !axTrusted {
                Button {
                    AppPermissions.requestAccessibility()
                    AppPermissions.openAccessibilitySettings()
                    refreshAccessibilityState()
                } label: {
                    Label("Grant Accessibility…", systemImage: "exclamationmark.triangle")
                }
            }

            Button("Reset HUD Position") { onResetHUDPosition() }

            Button("Settings…") { onOpenSettings() }
                .keyboardShortcut(",", modifiers: .command)

            Divider()

            Label("Typeforme \(Self.appVersion)", systemImage: "info.circle")

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

    private var statusLine: String {
        switch coordinator.state {
        case .idle:
            let mode = AppSettings.processingMode == .server
                ? NSLocalizedString("Server Mode", comment: "Menu status")
                : NSLocalizedString("Client Mode", comment: "Menu status")
            guard axTrusted else {
                return String(format: NSLocalizedString("%@ · Accessibility missing", comment: "Menu status"), mode)
            }
            return String(format: NSLocalizedString("Ready · %@", comment: "Menu status"), mode)
        case .recording:    return NSLocalizedString("Recording…", comment: "Menu status")
        case .transcribing:
            let base = coordinator.isProcessingCommandTextEdit
                ? NSLocalizedString("Understanding", comment: "Menu status while understanding a voice command")
                : NSLocalizedString("Transcribing…", comment: "Menu status")
            return coordinator.statusTextWithTranscriptionProgress(base)
        case .correcting:
            return coordinator.isProcessingCommandTextEdit
                ? NSLocalizedString("Editing", comment: "Menu status while applying a voice command")
                : NSLocalizedString("Refining…", comment: "Menu status")
        case .inserting:    return NSLocalizedString("Inserting…", comment: "Menu status")
        case .success:      return NSLocalizedString("Inserted", comment: "Menu status")
        case .error:        return coordinator.lastError ?? NSLocalizedString("Error", comment: "Menu status")
        }
    }

    private var statusSymbol: String {
        switch coordinator.state {
        case .idle:         return axTrusted ? "checkmark.circle" : "exclamationmark.triangle"
        case .recording:    return "record.circle"
        case .transcribing, .correcting, .inserting: return "waveform"
        case .success:      return "checkmark.circle.fill"
        case .error:        return "exclamationmark.triangle.fill"
        }
    }

    private var dictationActionTitle: String {
        switch coordinator.state {
        case .idle, .success, .error:
            return NSLocalizedString("Start Dictation", comment: "Menu action")
        case .recording:
            return NSLocalizedString("Stop Recording", comment: "Menu action")
        case .transcribing, .correcting, .inserting:
            return NSLocalizedString("Cancel Dictation", comment: "Menu action")
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    private func refreshAccessibilityState() {
        let trusted = AppPermissions.accessibilityTrusted
        if trusted != axTrusted {
            axTrusted = trusted
        }
    }
}
