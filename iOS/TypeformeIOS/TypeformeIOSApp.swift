import SwiftUI
import UIKit

private extension Notification.Name {
    static let typeformeOpenURL = Notification.Name("TypeformeOpenURL")
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NotificationCenter.default.post(
            name: .typeformeOpenURL,
            object: url,
            userInfo: [
                "sourceApplication": options[.sourceApplication] as? String as Any
            ]
        )
        return true
    }
}

@main
struct TypeformeIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @State private var foregroundPresenceTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .task {
                    updateHostForegroundPresence(for: scenePhase)
                    await state.bootstrap()
                }
                .onReceive(NotificationCenter.default.publisher(for: .typeformeOpenURL)) { notification in
                    guard let url = notification.object as? URL else { return }
                    let sourceApplication = notification.userInfo?["sourceApplication"] as? String
                    Task { await state.handleOpenURL(url, sourceApplication: sourceApplication) }
                }
                .onOpenURL { url in
                    Task { await state.handleOpenURL(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    updateHostForegroundPresence(for: phase)
                    guard phase == .active else { return }
                    guard !state.isEditingMacSettings else { return }
                    // Refresh dictation settings whenever the app comes to the
                    // foreground. Mac-side changes to ASR / correction /
                    // languages stay invisible otherwise — users would never
                    // know to open the Dictation Settings sheet to pull a fresh
                    // copy. Silent: failures populate the existing
                    // errorMessage banner without disrupting current input.
                    Task { try? await state.refreshMacSettings() }
                }
        }
    }

    private func updateHostForegroundPresence(for phase: ScenePhase) {
        foregroundPresenceTask?.cancel()
        foregroundPresenceTask = nil
        guard phase == .active else {
            KeyboardSharedDefaults.saveHostForegroundActive(false)
            return
        }

        KeyboardSharedDefaults.saveHostForegroundActive(true)
        foregroundPresenceTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                KeyboardSharedDefaults.saveHostForegroundActive(true)
            }
        }
    }
}
