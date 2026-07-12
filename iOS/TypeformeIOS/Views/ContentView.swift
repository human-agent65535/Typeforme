import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showingSettings = false
    @State private var settingsInitialRoute: HostSettingsRoute?
    @State private var rawTranscriptExpanded = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Typeforme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .sheet(isPresented: $showingSettings, onDismiss: {
                    settingsInitialRoute = nil
                    activateHostCaptureAfterReturningToMain()
                }) {
                    HostSettingsView(initialRoute: settingsInitialRoute)
                    .environment(state)
                }
                .overlay(alignment: .top) {
                    ToastView(message: state.transientMessage)
                        .padding(.top, 8)
                        .animation(.snappy(duration: 0.22), value: state.transientMessage)
                }
                .background(alignment: .topTrailing) {
                    PiPSourceViewMount()
                }
                .onAppear {
#if targetEnvironment(simulator)
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "simulator_host_ui_ready"
                    )
#endif
                    presentFirstRunReadinessIfNeeded()
                }
                .onChange(of: state.shouldPresentSetupReadiness) { _, _ in
                    presentFirstRunReadinessIfNeeded()
                }
        }
    }

    private func presentFirstRunReadinessIfNeeded() {
        state.refreshSetupReadinessStatuses()
        guard state.shouldPresentSetupReadiness, !showingSettings else { return }
        presentSettings(.setupAccess)
    }

    private func presentSettings(_ route: HostSettingsRoute? = nil) {
        settingsInitialRoute = route
        showingSettings = true
    }

    private func activateHostCaptureAfterReturningToMain() {
        Task { await state.prepareHostForegroundCapture(honorRecentPiPStop: false) }
    }

    @ViewBuilder
    private var content: some View {
        HostHomeView(
            rawTranscriptExpanded: $rawTranscriptExpanded,
            onShowPairing: { presentSettings(.pairing) },
            onShowSetup: { presentSettings(.setupAccess) }
        )
    }
}

private struct PiPSourceViewMount: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.keyboardDictationCaptureMode == .pictureInPicture {
            PiPSourceViewHost()
                .frame(
                    width: PiPSourceViewHost.preferredContentSize.width,
                    height: PiPSourceViewHost.preferredContentSize.height
                )
                .padding(.top, 16)
                .padding(.trailing, 16)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
