import SwiftUI

private let typeformePrivacyPolicyURL = URL(string: "https://github.com/human-agent65535/Typeforme/blob/main/docs/app-store/privacy-policy.md")!

enum HostSettingsRoute: Hashable {
    case voiceDictation
    case textKeyboard
    case connectedMac
    case setupAccess
    case keyboardGuide
    case pairing
    case macProcessing
}
struct HostSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @State private var path: [HostSettingsRoute]

    init(initialRoute: HostSettingsRoute?) {
        _path = State(initialValue: initialRoute.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            HostSettingsOverview()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .navigationDestination(for: HostSettingsRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    @ViewBuilder
    private func destination(for route: HostSettingsRoute) -> some View {
        switch route {
        case .voiceDictation:
            VoiceDictationSettingsView()
        case .textKeyboard:
            KeyboardSettingsView()
        case .connectedMac:
            ConnectedMacSettingsView()
        case .setupAccess:
            SetupReadinessView()
        case .keyboardGuide:
            KeyboardGuideView()
        case .pairing:
            PairingView(config: state.config, routeStatus: state.routeStatus)
        case .macProcessing:
            MacSettingsView {
                path = [.connectedMac, .pairing]
            }
        }
    }
}

private struct HostSettingsOverview: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            Section {
                NavigationLink(value: primaryStatusRoute) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primaryStatusTitle)
                            Text(primaryStatusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: primaryStatusIcon)
                            .foregroundStyle(primaryStatusColor)
                    }
                }
            }

            Section("Preferences") {
                NavigationLink(value: HostSettingsRoute.voiceDictation) {
                    SettingsRowLabel(
                        icon: "waveform",
                        title: "Voice Dictation",
                        detail: "Default mode and live preview"
                    )
                }
                NavigationLink(value: HostSettingsRoute.textKeyboard) {
                    SettingsRowLabel(
                        icon: "keyboard",
                        title: "Text Keyboard",
                        detail: "Chinese input, typing, feedback, and learning"
                    )
                }
            }

            Section("System") {
                NavigationLink(value: HostSettingsRoute.connectedMac) {
                    SettingsRowLabel(
                        icon: "desktopcomputer",
                        title: "Connected Mac",
                        detail: connectedMacDetail
                    )
                }
                NavigationLink(value: HostSettingsRoute.setupAccess) {
                    SettingsRowLabel(
                        icon: "checklist",
                        title: "Capture Mode & Permissions",
                        detail: "Capture mode and permissions"
                    )
                }
            }

            Section("Help & About") {
                NavigationLink(value: HostSettingsRoute.keyboardGuide) {
                    Label("Keyboard Guide", systemImage: "questionmark.circle")
                }
                Link(destination: typeformePrivacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
    }

    private var primaryStatusRoute: HostSettingsRoute {
        if !state.isConfigured { return .connectedMac }
        if state.setupReadinessNeedsAttention { return .setupAccess }
        return .connectedMac
    }

    private var primaryStatusTitle: LocalizedStringKey {
        if !state.isConfigured { return "Connect a Mac" }
        if state.setupReadinessNeedsAttention { return "Setup needs attention" }
        if state.routeStatus.activeKind == .unavailable { return "Mac is offline" }
        return "Ready"
    }

    private var primaryStatusDetail: LocalizedStringKey {
        if !state.isConfigured { return "Pair this iPhone before dictating" }
        if state.setupReadinessNeedsAttention { return "Review permissions and keyboard access" }
        if state.routeStatus.activeKind == .unavailable { return "Check the bridge connection" }
        switch state.routeStatus.activeKind {
        case .local: return "Connected via Local"
        case .cloud: return "Connected via Cloud"
        case .unavailable: return "Check the bridge connection"
        }
    }

    private var primaryStatusIcon: String {
        if !state.isConfigured { return "link.badge.plus" }
        if state.setupReadinessNeedsAttention || state.routeStatus.activeKind == .unavailable {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var primaryStatusColor: Color {
        if !state.isConfigured || state.setupReadinessNeedsAttention || state.routeStatus.activeKind == .unavailable {
            return .orange
        }
        return .green
    }

    private var connectedMacDetail: LocalizedStringKey {
        guard state.isConfigured else { return "Not paired" }
        switch state.routeStatus.activeKind {
        case .local: return "Local route"
        case .cloud: return "Cloud route"
        case .unavailable: return "Offline route"
        }
    }
}

struct SettingsRowLabel: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

private struct VoiceDictationSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            Section {
                Picker("Default Mode", selection: defaultCorrectionModeBinding) {
                    ForEach(CorrectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                            .disabled(!state.isCorrectionModeAvailable(mode))
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Applies to this iPhone and the Typeforme keyboard. Fast skips refine.")
            }

            LivePreviewSettingsSection()
        }
        .navigationTitle("Voice Dictation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var defaultCorrectionModeBinding: Binding<CorrectionMode> {
        Binding {
            state.config.correctionMode
        } set: { mode in
            state.setDefaultCorrectionMode(mode)
        }
    }
}

private struct ConnectedMacSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Active Route") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(routeColor)
                            .frame(width: 8, height: 8)
                        Text(activeRouteTitle)
                    }
                }
                if let latencyDetail {
                    LabeledContent("Latency", value: latencyDetail)
                }
                Button {
                    refreshRoute()
                } label: {
                    Label(
                        state.isRefreshingRoute ? "Checking…" : "Check Connection",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!state.isConfigured || state.isRefreshingRoute || state.isBusy)
            }

            Section {
                NavigationLink(value: HostSettingsRoute.macProcessing) {
                    SettingsRowLabel(
                        icon: "slider.horizontal.3",
                        title: "Mac Processing",
                        detail: "Recognition, refine, languages, vocabulary, and models"
                    )
                }
                .disabled(!state.isConfigured)

                NavigationLink(value: HostSettingsRoute.pairing) {
                    Label(state.isConfigured ? "Change or Repair Pairing" : "Pair a Mac", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .navigationTitle("Connected Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var latencyDetail: String? {
        switch state.routeStatus.activeKind {
        case .local:
            return state.routeStatus.localLatencyMs.map { "\($0) ms" }
        case .cloud:
            return state.routeStatus.cloudLatencyMs.map { "\($0) ms" }
        case .unavailable:
            return nil
        }
    }

    private var activeRouteTitle: LocalizedStringKey {
        if state.isCheckingRouteStatus { return "Checking" }
        switch state.routeStatus.activeKind {
        case .local: return "Local"
        case .cloud: return "Cloud"
        case .unavailable: return "Offline"
        }
    }

    private var routeColor: Color {
        if state.isCheckingRouteStatus { return .secondary }
        switch state.routeStatus.activeKind {
        case .local: return .green
        case .cloud: return .blue
        case .unavailable: return .orange
        }
    }

    private func refreshRoute() {
        Task {
            await state.refreshRoute(
                force: true,
                probeAllEndpoints: true,
                showIndicator: true,
                syncPairingEndpoints: true,
                reason: "connected_mac_settings"
            )
        }
    }
}
