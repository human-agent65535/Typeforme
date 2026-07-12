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
        if !state.isConfigured {
            UnpairedHero { presentSettings(.pairing) }
        } else {
            VStack(spacing: 12) {
                RouteStatusBar()
                ScrollView {
                    VStack(spacing: 16) {
                        HeroRecordCard(audio: state.audioCoordinator)
                        // Errors sit directly under the orb — at the old
                        // position (below Result/Raw) they were off-screen
                        // whenever the page had content.
                        if let error = state.errorMessage, !error.isEmpty {
                            ErrorBanner(message: error, canRepair: state.isConfigured) {
                                presentSettings(.pairing)
                            } onDismiss: {
                                state.errorMessage = nil
                            }
                        }
                        if state.setupReadinessNeedsAttention {
                            SetupReadinessBanner {
                                presentSettings(.setupAccess)
                            }
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
            .accessibilityLabel("Bridge route: \(routeStatusTitle)")
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
        state.isCheckingRouteStatus ? "Checking" : state.routeStatus.activeKind.rawValue
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

// MARK: - Hero record orb

/// Test-record surface mirroring the keyboard's UIKit orb: vertical gradient,
/// soft inner highlight, state-tinted shadow, and concentric pulse rings during
/// recording. The mic icon swaps out for a voiceprint while recording.
private struct HeroRecordCard: View {
    @Environment(AppState.self) private var state
    @ObservedObject var audio: AudioCoordinator
    @State private var isPressed = false

    /// Compact enough for `TestDictationSection` while remaining tappable and
    /// large enough to show the gradient and recording state.
    private let orbDiameter: CGFloat = 120

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if isRecording, let startedAt = state.recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                        Text(Self.elapsedString(from: startedAt, to: context.date))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 24)

            ZStack {
                if isRecording {
                    PulseRingsHalo(tint: pulseTint, diameter: orbDiameter)
                        .allowsHitTesting(false)
                }
                orb
                    .scaleEffect(isPressed ? 0.92 : 1)
                    .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isPressed)
                    .animation(.snappy(duration: 0.22), value: state.phase)
                    .gesture(pressGesture)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(accessibilityHint)
            }
            .frame(height: orbDiameter + 40)
            .opacity(state.canInteractWithHostDictation ? 1 : 0.5)

            if showsOfflineRefresh {
                Button {
                    Task {
                        await state.refreshRoute(
                            force: true,
                            syncPairingEndpoints: true,
                            reason: "offline_refresh"
                        )
                    }
                } label: {
                    Label("Refresh Bridge", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isRefreshingRoute || state.isBusy)
            }

            Picker("Input mode", selection: inputModeBinding) {
                ForEach(VoiceInputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)
            .disabled(isRecording || state.isBusy)
            .opacity((isRecording || state.isBusy) ? 0.55 : 1)
        }
        .padding(.horizontal, 16)
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: gradientStops,
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
                )
                .shadow(color: shadowTint.opacity(0.42), radius: 28, x: 0, y: 14)

            // Specular highlight, upper-left
            Ellipse()
                .fill(.white.opacity(0.22))
                .frame(width: orbDiameter * 0.55, height: orbDiameter * 0.32)
                .blur(radius: 10)
                .offset(x: -orbDiameter * 0.16, y: -orbDiameter * 0.22)
                .blendMode(.plusLighter)

            // Center content: voiceprint while recording, spinner while sending,
            // mic icon otherwise.
            Group {
                if isRecording {
                    VoicePrintBars(level: state.hostRecordingLevel, isActive: true, tint: .white)
                        .frame(width: orbDiameter * 0.62, height: orbDiameter * 0.34)
                } else if state.phase == .preparing || state.phase == .sending || state.phase == .refining {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    // 36% of orb diameter ≈ readable mic glyph without
                    // overwhelming the demoted 120pt orb.
                    Image(systemName: iconName)
                        .font(.system(size: orbDiameter * 0.36, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
            }

        }
        .frame(width: orbDiameter, height: orbDiameter)
        .compositingGroup()
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                guard state.canInteractWithHostDictation else { return }
                isPressed = true
                lightImpact()
                if state.inputMode == .hold {
                    Task { await state.beginHostHoldRecording() }
                }
            }
            .onEnded { _ in
                guard isPressed else { return }
                isPressed = false
                lightImpact()
                switch state.inputMode {
                case .hold:
                    Task { await state.endHostHoldRecording() }
                case .tap:
                    Task { await state.toggleHostTapRecording() }
                }
            }
    }

    private func lightImpact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var inputModeBinding: Binding<VoiceInputMode> {
        Binding(
            get: { state.inputMode },
            set: { state.setInputMode($0) }
        )
    }

    private var isRecording: Bool {
        (audio.recorder.isRecording || state.phase == .recording) && !state.isStopAndSendInFlight
    }

    /// Title carries the live stage label when a job is in flight (so it
    /// stays in lock-step with the keyboard's status label and the bridge's
    /// `processingStatusMessage`); otherwise it shows the input-mode prompt.
    private var title: String {
        if state.phase == .preparing {
            return NSLocalizedString("Preparing…", comment: "Host recording preparing title")
        }
        if isRecording { return state.inputMode.recordingTitle }
        if state.phase == .sending || state.phase == .refining,
           let stage = state.processingStatusMessage,
           !stage.isEmpty {
            return stage
        }
        switch state.phase {
        case .sending:
            return NSLocalizedString("Transcribing", comment: "Bridge job stage")
        case .refining:
            return NSLocalizedString("Refining", comment: "Bridge job stage")
        default:
            return state.inputMode.idleTitle
        }
    }

    private var detail: String {
        if !state.isConfigured {
            return "Pair the Mac Bridge first."
        }
        if isRecording {
            return state.inputMode == .tap ? "Tap again when you're done." : "Keep holding while you speak."
        }
        if let installing = state.activeModelInstallText,
           state.phase == .sending || state.phase == .refining {
            return installing
        }
        switch state.phase {
        case .sending, .refining:
            // Title carries the live stage label; keep detail empty so the
            // hero does not repeat "Transcribing" / "Refining" on two lines.
            return ""
        case .success(.ready): return "Result ready."
        case .success(.copied): return "Result copied to the clipboard."
        case .success(.inserted): return "Result inserted."
        case .failure, .idle, .preparing, .recording:
            if state.routeStatus.activeURL == nil {
                return "Recording is local. Bridge will be resolved when you send."
            }
            return state.inputMode.idleDetail
        }
    }

    private var iconName: String {
        switch state.phase {
        case .success: return "checkmark"
        default: return "mic.fill"
        }
    }

    private var showsOfflineRefresh: Bool {
        state.isConfigured
            && state.routeStatus.activeURL == nil
            && !isRecording
            && state.phase != .sending
            && state.phase != .refining
    }

    private var accessibilityHint: String {
        state.canInteractWithHostDictation
            ? detail
            : NSLocalizedString("Start Typeforme on Mac, then refresh before recording.", comment: "Host recording disabled accessibility hint")
    }

    /// Gradient only shifts color for states the user actively triggered. A
    /// background-task `.failure` (route probe died, audio session hiccup)
    /// doesn't repaint the orb orange — it lives in the error banner.
    private var gradientStops: [Color] {
        gradient.swiftUIColors
    }

    private var gradient: OrbGradient {
        if isPressed || isRecording { return .recording }
        switch state.phase {
        case .sending, .refining: return .sending
        case .success:             return .success
        default:                   return .idle
        }
    }

    private var shadowTint: Color { gradientStops.last ?? .blue }
    private var pulseTint: Color { gradientStops.last ?? .blue }
}

/// Concentric pulse rings that bloom outward from the orb during recording.
/// Three rings, phase-offset by 0.6s each, scale 1.0 → 1.55, alpha 0 → 0.5 → 0.
private struct PulseRingsHalo: View {
    let tint: Color
    let diameter: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let localPhase = ((phase - Double(i) * 0.55).truncatingRemainder(dividingBy: 1.65)) / 1.65
                    let lp = max(0, localPhase)
                    let scale = 1.0 + lp * 0.55
                    let alpha = lp < 0.18
                        ? (lp / 0.18) * 0.5
                        : max(0, (1 - (lp - 0.18) / 0.82) * 0.5)
                    Circle()
                        .stroke(tint.opacity(alpha), lineWidth: 1.6)
                        .frame(width: diameter * scale, height: diameter * scale)
                }
            }
        }
        .frame(width: diameter + 80, height: diameter + 80)
    }
}

// MARK: - Voiceprint visualization (SwiftUI)

/// Mirrors the keyboard extension's UIKit `VoicePrintView`. Drives 9 bars from
/// an audio level (0...1) plus phase-shifted sines for organic motion. The
/// `TimelineView(.animation)` is only mounted when `isActive` is true so it
/// doesn't burn 60fps cycles when the hero card is idle.
private struct VoicePrintBars: View {
    let level: Float
    let isActive: Bool
    let tint: Color

    private let barCount = 9

    var body: some View {
        GeometryReader { geo in
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, _ in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                        drawBars(context: context, size: geo.size, phase: phase)
                    }
                }
            } else {
                // Static at min-height; mounted but cheap.
                Canvas { context, _ in
                    drawBars(context: context, size: geo.size, phase: 0, forceMinimum: true)
                }
            }
        }
        .frame(height: 64)
    }

    private func drawBars(
        context: GraphicsContext,
        size: CGSize,
        phase: CFTimeInterval,
        forceMinimum: Bool = false
    ) {
        let centerY = size.height / 2
        let minH = max(6, size.height * 0.12)
        let maxH = size.height * 0.95
        let barW: CGFloat = 5
        let total = CGFloat(barCount)
        let gap = (size.width - total * barW) / (total + 1)

        // Keep speech below saturation so the bars track meter changes instead
        // of looking like a fixed full-range animation.
        let baseline: CGFloat = 0.22
        let voiceBoost = CGFloat(level) * 1.05
        let envelope = min(1.0, baseline + voiceBoost)

        for i in 0..<barCount {
            let barH: CGFloat
            if forceMinimum {
                barH = minH
            } else {
                let centerBias = abs(Double(i) - Double(barCount - 1) / 2.0) / (Double(barCount - 1) / 2.0)
                let centerBoost = 1.0 - centerBias * 0.30
                let bandPhase = Double(i) * 0.55
                let s = sin(phase * 5.4 + bandPhase) * 0.55 + sin(phase * 11.1 + bandPhase * 2.3) * 0.45
                let waveform = CGFloat((s + 1) / 2)
                let modulation = envelope * CGFloat(centerBoost) * (0.35 + 0.65 * waveform)
                barH = max(minH, min(maxH, minH + (maxH - minH) * modulation))
            }
            let x = gap + CGFloat(i) * (barW + gap)
            let rect = CGRect(x: x, y: centerY - barH / 2, width: barW, height: barH)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 2.5),
                with: .color(tint)
            )
        }
    }
}

// MARK: - Mode chips

private struct ModeChipsRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CorrectionMode.allCases) { mode in
                    ModeChip(
                        mode: mode,
                        isSelected: state.correctionMode == mode,
                        isDisabled: state.isBusy || !state.isCorrectionModeAvailable(mode)
                    ) {
                        Task { await state.applyCorrectionMode(mode) }
                    }
                }
            }
            .padding(.horizontal, 16)
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
                .padding(.horizontal, 14)
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
            HStack {
                Image(systemName: "globe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("Languages")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(LanguageDisplay.summary(
                    for: state.selectedLanguageIDs,
                    options: state.config.supportedLanguageOptions
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
}


// MARK: - Result card

private struct ResultCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let previewText = livePreviewText
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(showsLivePreview ? "Preview" : "Result", systemImage: showsLivePreview ? "waveform" : "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == .refining {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            if showsLivePreview {
                ScrollView {
                    Text(previewText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                .frame(minHeight: 120, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            } else {
                TextEditor(text: $state.resultText)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .overlay(alignment: .topLeading) {
                        if !hasResult {
                            Text("Dictation result appears here. Hold the orb and speak.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: 10) {
                Button {
                    state.copyResult()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!hasResult)

                Button(role: .destructive) {
                    state.clearResult()
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!hasResult && state.rawTranscript.isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var hasResult: Bool {
        !state.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var livePreviewText: String {
        state.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsLivePreview: Bool {
        guard !livePreviewText.isEmpty else { return false }
        switch state.phase {
        case .recording, .sending, .refining:
            return true
        default:
            return false
        }
    }
}

// MARK: - Raw transcript card

private struct RawTranscriptCard: View {
    @Environment(AppState.self) private var state
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Raw transcript", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide raw transcript" : "Show raw transcript")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                Group {
                    if state.rawTranscript.isEmpty {
                        Text("No raw transcript yet — start dictation to see the unedited recognition output here.")
                    } else {
                        Text(state.rawTranscript)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let message: String
    var canRepair = false
    var onRepair: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if canRepair {
                Button {
                    onRepair()
                } label: {
                    Label("Repair", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repair pairing")
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 0.5)
        )
    }
}

// MARK: - Toast

private struct ToastView: View {
    let message: String?

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
