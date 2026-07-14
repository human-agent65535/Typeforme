import SwiftUI

struct HostHomeView: View {
    @Environment(AppState.self) private var state
    @Binding var rawTranscriptExpanded: Bool

    let onShowPairing: () -> Void
    let onShowSetup: () -> Void

    var body: some View {
        if !state.isConfigured {
            UnpairedHero(onTapPair: onShowPairing)
        } else {
            VStack(spacing: 12) {
                RouteStatusBar()
                ScrollView {
                    VStack(spacing: 16) {
                        HeroRecordCard(audio: state.audioCoordinator)
                        if let error = state.errorMessage, !error.isEmpty {
                            ErrorBanner(
                                message: error,
                                canRepair: state.isConfigured,
                                onRepair: onShowPairing
                            ) {
                                state.errorMessage = nil
                            }
                        }
                        if state.setupReadinessNeedsAttention {
                            SetupReadinessBanner(onShowSetup: onShowSetup)
                        }
                        ModeChipsRow()
                        LanguagesRow()
                        ResultCard()
                        RawTranscriptCard(expanded: $rawTranscriptExpanded)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct SetupReadinessBanner: View {
    @Environment(AppState.self) private var state
    let onShowSetup: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup needs attention")
                    .font(.footnote.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        onShowSetup()
                    } label: {
                        Label("Setup", systemImage: "checklist")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 0.5)
        )
    }

    private var message: LocalizedStringKey {
        if !state.microphonePermissionStatus.isGranted {
            return "Allow Microphone so the host app can own dictation audio."
        }
        if state.keyboardNeedsFullAccessSetup {
            return "Enable the Typeforme keyboard and allow Full Access."
        }
        return "Review setup and permissions."
    }
}


private struct UnpairedHero: View {
    let onTapPair: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("Pair your Mac")
                    .font(.title2.weight(.semibold))
                Text("Typeforme uses your Mac's local ASR + LLM to clean up dictation. Pair the Mac Bridge URL and token to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button(action: onTapPair) {
                Label("Pair Mac Bridge", systemImage: "link")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
            Text("Or copy the pairing JSON from the Mac app.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Route status bar

private struct RouteStatusBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                refreshRoute()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 9, height: 9)
                        Text(routeStatusTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let detail = latencyDetail {
                            Text("· \(detail)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    // Install state and server timing coexist — previously the
                    // installing line suppressed timings for its whole duration.
                    if let installing = state.activeModelInstallText {
                        Text(installing)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    if let timing = state.latestServerTiming?.displayText {
                        Text(timing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRefresh)
            .accessibilityLabel(Text(String(
                format: NSLocalizedString("Bridge route: %@", comment: "Current bridge route accessibility label"),
                routeStatusTitle
            )))
            .accessibilityHint("Double tap to re-check the connection")

            Button {
                refreshRoute()
            } label: {
                Group {
                    if state.isRefreshingRoute {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(!canRefresh)
            .accessibilityLabel("Refresh Bridge")
            .accessibilityHint("Re-check the host connection")
        }
        .padding(.horizontal, 16)
    }

    private var canRefresh: Bool {
        !state.isRefreshingRoute && !state.isBusy
    }

    private func refreshRoute() {
        Task {
            await state.refreshRoute(
                force: true,
                syncPairingEndpoints: true,
                reason: "user_refresh"
            )
        }
    }

    private var routeStatusTitle: String {
        if state.isCheckingRouteStatus {
            return NSLocalizedString("Checking", comment: "Bridge route check in progress")
        }
        switch state.routeStatus.activeKind {
        case .local:
            return NSLocalizedString("Local", comment: "Local bridge route")
        case .cloud:
            return NSLocalizedString("Cloud", comment: "Cloud bridge route")
        case .unavailable:
            return NSLocalizedString("Offline", comment: "No bridge route available")
        }
    }

    private var dotColor: Color {
        if state.isCheckingRouteStatus {
            return .secondary
        }
        switch state.routeStatus.activeKind {
        case .local: return .green
        case .cloud: return .blue
        case .unavailable: return .orange
        }
    }

    private var latencyDetail: String? {
        if state.isCheckingRouteStatus {
            return nil
        }
        switch state.routeStatus.activeKind {
        case .local:
            return state.routeStatus.localLatencyMs.map { "RTT \($0)ms" }
        case .cloud:
            return state.routeStatus.cloudLatencyMs.map { "RTT \($0)ms" }
        case .unavailable:
            return nil
        }
    }
}

// MARK: - Mode chips

private struct ModeChipsRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CorrectionMode.allCases) { mode in
                    ModeChip(
                        mode: mode,
                        isSelected: state.correctionMode == mode,
                        isDisabled: state.isBusy
                            || state.correctionMode == mode
                            || !state.isCorrectionModeAvailable(mode)
                    ) {
                        Task { await state.applyCorrectionMode(mode) }
                    }
                }
            }
        }
    }
}

private struct ModeChip: View {
    let mode: CorrectionMode
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Color(.separator), lineWidth: 0.5)
                )
        }
        .disabled(isDisabled)
        .opacity(isDisabled && !isSelected ? 0.5 : 1)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: String {
        mode.title
    }
}

// MARK: - Languages row

private struct LanguagesRow: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var state = state
        NavigationLink {
            LanguageSelectionView(
                selection: $state.selectedLanguageIDs,
                options: state.config.supportedLanguageOptions,
                livePreviewEnabled: state.keyboardLivePreviewEnabled && state.keyboardLivePreviewSource == .appleSpeech,
                livePreviewRecognitionMode: state.keyboardLivePreviewSource == .appleSpeech
                    ? state.keyboardLivePreviewRecognitionMode
                    : nil
            )
            .onChange(of: state.selectedLanguageIDs) { _, _ in
                state.persistLanguageSelection()
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            languagesTitle
                            Spacer()
                            disclosureIndicator
                        }
                        Text(languageSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.leading, 28)
                    }
                } else {
                    HStack {
                        languagesTitle
                        Spacer()
                        Text(languageSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        disclosureIndicator
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private var languagesTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("Languages")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    private var disclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var languageSummary: String {
        LanguageDisplay.summary(
            for: state.selectedLanguageIDs,
            options: state.config.supportedLanguageOptions
        )
    }
}
