import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingPairing = false
    @State private var showingMacSettings = false
    @State private var showingKeyboardSettings = false
    @State private var showingKeyboardGuide = false
    @State private var rawTranscriptExpanded = false
    /// First-launch setup guidance — once dismissed, the user can still reach
    /// it via the toolbar's "Keyboard Guide" menu item.

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Typeforme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if state.showsReturnButton {
                            Button {
                                Task { await state.returnToPreviousAppFromToolbar() }
                            } label: {
                                Label("Return", systemImage: "chevron.left")
                            }
                        } else {
                            Button {
                                Task { await state.refreshRoute(force: true) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(state.isBusy || state.isRefreshingRoute)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showingPairing = true
                            } label: {
                                Label("Pairing", systemImage: "qrcode.viewfinder")
                            }
                            Button {
                                showingMacSettings = true
                            } label: {
                                Label("Server Settings", systemImage: "desktopcomputer")
                            }
                            .disabled(!state.isConfigured)
                            Button {
                                showingKeyboardSettings = true
                            } label: {
                                Label("Keyboard Settings", systemImage: "keyboard")
                            }
                            Button {
                                showingKeyboardGuide = true
                            } label: {
                                Label("Keyboard Guide", systemImage: "questionmark.circle")
                            }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingPairing) {
                    PairingView(
                        config: state.config,
                        routeStatus: state.routeStatus,
                        onSave: { newConfig in
                            state.saveConfig(newConfig)
                        },
                        onUnpair: {
                            state.unpair()
                        }
                    )
                }
                .sheet(isPresented: $showingMacSettings) {
                    NavigationStack {
                        MacSettingsView {
                            showingPairing = true
                        }
                            .environmentObject(state)
                    }
                }
                .sheet(isPresented: $showingKeyboardSettings) {
                    NavigationStack {
                        KeyboardSettingsView()
                            .environmentObject(state)
                    }
                }
                .sheet(isPresented: $showingKeyboardGuide) {
                    NavigationStack {
                        KeyboardGuideView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingKeyboardGuide = false }
                                }
                            }
                    }
                }
                .overlay(alignment: .top) {
                    ToastView(message: state.transientMessage)
                        .padding(.top, 8)
                        .animation(.snappy(duration: 0.22), value: state.transientMessage)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !state.isConfigured {
            UnpairedHero { showingPairing = true }
        } else {
            VStack(spacing: 12) {
                RouteStatusBar()
                ScrollView {
                    // High-frequency surfaces at the top: orb, mode chips,
                    // language / session settings, then any active result.
                    // The setup guidance card is a once-per-install thing,
                    // so it sits at the bottom and can be dismissed.
                    VStack(spacing: 16) {
                        HeroRecordCard(audio: state.audioCoordinator)
                        if state.keyboardNeedsFullAccessSetup {
                            KeyboardFullAccessBanner {
                                showingKeyboardGuide = true
                            }
                        }
                        ModeChipsRow()
                        LanguagesRow()
                        ResultCard()
                        RawTranscriptCard(expanded: $rawTranscriptExpanded)
                        if let error = state.errorMessage, !error.isEmpty {
                            ErrorBanner(message: error, canRepair: state.isConfigured) {
                                showingPairing = true
                            } onDismiss: {
                                state.errorMessage = nil
                            }
                        }
                        SetupStatusCard(
                            onShowGuide: { showingKeyboardGuide = true }
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Setup guidance

/// Persistent onboarding card. Always present at the bottom of the scroll;
/// the chevron toggles between a one-line header and the full setup
/// guidance. We default to expanded until the keyboard extension has been
/// observed reaching the host (which implies both "keyboard enabled" and
/// "Full Access granted" — see AppState.keyboardEverContacted) and to
/// collapsed afterwards, while still letting the user re-expand any time.
private struct SetupStatusCard: View {
    @EnvironmentObject private var state: AppState
    let onShowGuide: () -> Void

    @State private var isExpanded: Bool = true
    @State private var didApplyInitialExpansion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.keyboardNeedsFullAccessSetup ? "lock.shield.fill" : "checkmark.seal.fill")
                        .foregroundStyle(state.keyboardNeedsFullAccessSetup ? Color.orange : Color.green)
                    Text(state.keyboardNeedsFullAccessSetup ? "Keyboard needs Full Access" : "Keyboard ready")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide setup steps" : "Show setup steps")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                Divider()

                Text(state.keyboardNeedsFullAccessSetup ? "Allow Full Access so the Typeforme keyboard can talk to this app." : "Typeforme dictates in any text field via its keyboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    SetupStepRow(
                        icon: "keyboard",
                        title: "Enable Typeforme keyboard",
                        subtitle: "Settings → General → Keyboard → Add New Keyboard"
                    )
                    SetupStepRow(
                        icon: "lock.shield",
                        title: "Allow Full Access",
                        subtitle: "Required so the keyboard can reach this app"
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        onShowGuide()
                    } label: {
                        Label("Guide", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .onAppear {
            guard !didApplyInitialExpansion else { return }
            didApplyInitialExpansion = true
            isExpanded = state.keyboardNeedsFullAccessSetup
        }
        .onChange(of: state.keyboardNeedsFullAccessSetup) { _, needsSetup in
            guard !needsSetup else {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded = true
                }
                return
            }
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded = false
            }
        }
    }
}

private struct KeyboardFullAccessBanner: View {
    let onShowGuide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard needs Full Access")
                    .font(.footnote.weight(.semibold))
                Text("Open iOS Settings, enable the Typeforme keyboard, then allow Full Access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        onShowGuide()
                    } label: {
                        Label("Guide", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
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
}

private struct SetupStepRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Unpaired empty state

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
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                Text(state.routeStatus.activeKind.rawValue)
                    .font(.subheadline.weight(.semibold))
                if let detail = latencyDetail {
                    Text("· \(detail)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let installing = state.activeModelInstallText {
                Text(installing)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let timing = state.latestServerTiming?.displayText {
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }

    private var dotColor: Color {
        switch state.routeStatus.activeKind {
        case .local: return .green
        case .cloud: return .blue
        case .unavailable: return .orange
        }
    }

    private var latencyDetail: String? {
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
    @EnvironmentObject private var state: AppState
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
                if !detail.isEmpty {
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
                    Task { await state.refreshRoute(force: true) }
                } label: {
                    if state.isRefreshingRoute {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking Bridge")
                        }
                    } else {
                        Label("Refresh Bridge", systemImage: "arrow.clockwise")
                    }
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
                } else if state.isRefreshingRoute || state.phase == .preparing || state.phase == .sending || state.phase == .restyling {
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
        if state.phase == .sending || state.phase == .restyling,
           let stage = state.processingStatusMessage,
           !stage.isEmpty {
            return stage
        }
        switch state.phase {
        case .sending:
            return NSLocalizedString("Transcribing", comment: "Bridge job stage")
        case .restyling:
            return NSLocalizedString("Refining", comment: "Bridge job stage")
        default:
            return state.isRefreshingRoute
                ? NSLocalizedString("Transcribing", comment: "Bridge job stage")
                : state.inputMode.idleTitle
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
           state.phase == .sending || state.phase == .restyling {
            return installing
        }
        switch state.phase {
        case .sending, .restyling:
            // Title now carries the live stage label — leave detail empty so
            // the orb doesn't show "Transcribing" / "Refining" twice on two
            // lines.
            return ""
        case .success(.ready): return "Result ready."
        case .success(.copied): return "Result copied to the clipboard."
        case .success(.inserted): return "Result inserted."
        case .failure, .idle, .preparing, .recording:
            if state.routeStatus.activeURL == nil {
                return "Recording is local. Bridge will be resolved when you send."
            }
            if state.isRefreshingRoute {
                return "Checking whether your paired Mac is reachable."
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
            && state.phase != .restyling
    }

    private var accessibilityHint: String {
        state.canInteractWithHostDictation
            ? detail
            : "Start the Mac app or Server, then refresh before recording."
    }

    /// Gradient only shifts color for states the user actively triggered. A
    /// background-task `.failure` (route probe died, audio session hiccup)
    /// doesn't repaint the orb orange — it lives in the error banner.
    private var gradientStops: [Color] {
        gradient.swiftUIColors
    }

    private var gradient: OrbGradient {
        if isPressed || isRecording { return .recording }
        if state.isRefreshingRoute { return .sending }
        switch state.phase {
        case .sending, .restyling: return .sending
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
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CorrectionModeID.allCases) { mode in
                    ModeChip(
                        mode: mode,
                        isSelected: state.correctionMode == mode,
                        isDisabled: state.isBusy
                    ) {
                        Task { await state.applyCorrectionMode(mode) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }
}

private struct ModeChip: View {
    let mode: CorrectionModeID
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
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationLink {
            LanguageSelectionView(
                selection: $state.selectedLanguageIDs,
                options: state.config.supportedLanguageOptions,
                livePreviewEnabled: state.keyboardLivePreviewEnabled,
                livePreviewRecognitionMode: state.keyboardLivePreviewRecognitionMode
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

// MARK: - Keyboard settings

private struct KeyboardSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Picker("Dictionary", selection: rimeDictionaryTierBinding) {
                    ForEach(KeyboardRimeDictionaryTier.allCases) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                Toggle("Pinyin Correction", isOn: rimeCorrectionBinding)
                Picker("Default text input", selection: defaultTextInputLanguageBinding) {
                    ForEach(KeyboardDefaultTextInputLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker("Chinese punctuation", selection: chinesePunctuationBinding) {
                    ForEach(KeyboardChinesePunctuationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Chinese Input")
            } footer: {
                Text("Changes apply immediately after Full Access is enabled.")
            }
            Section {
                Toggle("Character Preview", isOn: characterPreviewBinding)
            } header: {
                Text("Typing")
            }
            Section {
                Toggle("Auto-Capitalization", isOn: autoCapitalizationBinding)
            } header: {
                Text("English")
            } footer: {
                Text("Only active when the keyboard is in English mode.")
            }
            Section {
                LabeledContent("Self-learning") {
                    Text("On")
                }
                Button(role: .destructive) {
                    state.resetKeyboardRimeLearning()
                } label: {
                    Text("Reset Chinese Learning")
                }
                Button(role: .destructive) {
                    state.resetKeyboardTouchLearning()
                } label: {
                    Text("Reset Touch Learning")
                }
            } header: {
                Text("Learning")
            } footer: {
                Text("Chinese learning clears the Rime user dictionary. Touch learning clears the per-key tap-position model. Both apply once Full Access is enabled.")
            }
            Section {
                Toggle("Live Preview", isOn: livePreviewBinding)
                Picker("Preview Recognition", selection: livePreviewRecognitionModeBinding) {
                    ForEach(KeyboardLivePreviewRecognitionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!state.keyboardLivePreviewEnabled || state.isBusy)
                Picker("Host audio session", selection: hostAudioSessionLengthBinding) {
                    ForEach(HostAudioSessionLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .disabled(state.isBusy)
            } header: {
                Text("Audio")
            } footer: {
                Text("On-device Only keeps preview audio local. Cloud Fallback uses on-device when available and Apple servers otherwise. Preview punctuation follows Server Settings. Host audio session controls how long keyboard dictation stays ready.")
            }
        }
        .navigationTitle("Keyboard Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var autoCapitalizationBinding: Binding<Bool> {
        Binding {
            state.keyboardAutoCapitalizationEnabled
        } set: { enabled in
            state.setKeyboardAutoCapitalizationEnabled(enabled)
        }
    }

    private var characterPreviewBinding: Binding<Bool> {
        Binding {
            state.keyboardCharacterPreviewEnabled
        } set: { enabled in
            state.setKeyboardCharacterPreviewEnabled(enabled)
        }
    }

    private var livePreviewBinding: Binding<Bool> {
        Binding {
            state.keyboardLivePreviewEnabled
        } set: { enabled in
            state.setKeyboardLivePreviewEnabled(enabled)
        }
    }

    private var livePreviewRecognitionModeBinding: Binding<KeyboardLivePreviewRecognitionMode> {
        Binding {
            state.keyboardLivePreviewRecognitionMode
        } set: { mode in
            state.setKeyboardLivePreviewRecognitionMode(mode)
        }
    }

    private var rimeDictionaryTierBinding: Binding<KeyboardRimeDictionaryTier> {
        Binding {
            state.keyboardRimeDictionaryTier
        } set: { tier in
            state.setKeyboardRimeDictionaryTier(tier)
        }
    }

    private var rimeCorrectionBinding: Binding<Bool> {
        Binding {
            state.keyboardRimeCorrectionEnabled
        } set: { enabled in
            state.setKeyboardRimeCorrectionEnabled(enabled)
        }
    }

    private var defaultTextInputLanguageBinding: Binding<KeyboardDefaultTextInputLanguage> {
        Binding {
            state.keyboardDefaultTextInputLanguage
        } set: { language in
            state.setKeyboardDefaultTextInputLanguage(language)
        }
    }

    private var chinesePunctuationBinding: Binding<KeyboardChinesePunctuationStyle> {
        Binding {
            state.keyboardChinesePunctuationStyle
        } set: { style in
            state.setKeyboardChinesePunctuationStyle(style)
        }
    }

    private var hostAudioSessionLengthBinding: Binding<HostAudioSessionLength> {
        Binding {
            state.hostAudioSessionLength
        } set: { length in
            state.setHostAudioSessionLength(length)
        }
    }
}

// MARK: - Result card

private struct ResultCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Result", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == .restyling {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
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
            HStack(spacing: 10) {
                Button {
                    state.copyResult()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(role: .destructive) {
                    state.clearResult()
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Raw transcript card

private struct RawTranscriptCard: View {
    @EnvironmentObject private var state: AppState
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

// MARK: - Keyboard guide

private struct KeyboardGuideView: View {
    var body: some View {
        List {
            Section("Setup") {
                GuideStepRow(
                    icon: "desktopcomputer",
                    title: "Pair the Mac Server",
                    detail: "Paste the pairing JSON from the Mac app, then refresh Server Settings so iOS has the current languages and default mode."
                )
                GuideStepRow(
                    icon: "keyboard",
                    title: "Enable the keyboard",
                    detail: "In iOS Settings, add Typeforme and allow Full Access. The keyboard needs that to talk to the host app."
                )
            }

            Section("In Any App") {
                GuideStepRow(
                    icon: "mic.fill",
                    title: "Dictate",
                    detail: "Use Hold to Speak or Tap to Speak. Without a text selection, Typeforme inserts the new result at the cursor."
                )
                GuideStepRow(
                    icon: "text.cursor",
                    title: "Fix selected text",
                    detail: "Select the wrong span first, then press the mic and say the intended replacement. Only that selected span is replaced."
                )
                GuideStepRow(
                    icon: "wand.and.stars",
                    title: "Command edit",
                    detail: "Press the wand and speak an instruction like make this shorter, translate this, or turn it into bullets. With no selection, it targets the current input text."
                )
            }

            Section("Refine Buttons") {
                GuideStepRow(
                    icon: "sparkles",
                    title: "Refine existing text",
                    detail: "Clean, Polish, Polish+, Structure+, and Formal+ use the selected text first, then the current visible input text."
                )
                GuideStepRow(
                    icon: "exclamationmark.triangle",
                    title: "Selection changed",
                    detail: "If iOS no longer reports the same selection when the result returns, Typeforme copies the result instead of guessing where to paste it."
                )
            }

            Section {
                GuideStepRow(
                    icon: "checkmark.circle",
                    title: "Clean",
                    detail: "Lightest touch. Adds punctuation, casing, spacing; drops um/uh/嗯; collapses obvious ASR label fixes like \"hold to steak should be hold to speak\" → \"hold to speak\". Keeps wording, intensifiers (好得很, super well), and order unchanged. Does not invent lists or reorder."
                )
                GuideStepRow(
                    icon: "paintbrush",
                    title: "Polish",
                    detail: "Clean plus light readability fixes — small grammar/word repairs, sentence merge or split. Preserves the user's voice and any spoken edit intent (cancellations, quantity changes). Does not synthesize the final list state or restructure into bullets."
                )
                GuideStepRow(
                    icon: "paintbrush.fill",
                    title: "Polish+",
                    detail: "Full prose rewrite. Resolves anchored repairs (A 不对 B / A oh wait B / quantity updates) to the final intended state, reorders preconditions, fixes awkward causal flow. Outputs polished prose, not bullets. Keeps compound intensifiers (好得很, super useful) atomic; never invents structure for short utterances."
                )
                GuideStepRow(
                    icon: "list.bullet.rectangle",
                    title: "Structure+",
                    detail: "For multi-item content. Produces bullets / numbered lines / label lines for lists, schedules, todos, recipes, multi-step plans. Resolves spoken repairs and cancellations before structuring. A short single-clause utterance stays as prose — no fake structure."
                )
                GuideStepRow(
                    icon: "doc.text",
                    title: "Formal+",
                    detail: "Lifts casual speech into professional written prose. Drops fillers, fixes register, upgrades word choice. Resolves anchored repairs but preserves intensifiers, degree words, and emphatic constructions (好得很, 累得不得了, super well, really impressed) — does not flatten them. Does not add courtesy or invent business context."
                )
            } header: {
                Text("Refine Modes")
            } footer: {
                Text("All five modes preserve the user's meaning, names, numbers, URLs, code, and intentional mixed-language text. Anchored spoken repairs (A 不对 B / A should be B) collapse to the final intended state in every mode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keyboard Guide")
    }
}

private struct GuideStepRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
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

// MARK: - Dictation Settings

private struct TimeoutSecondsRow: View {
    let title: String
    @Binding var seconds: Double
    let range: ClosedRange<Double>

    private let step = 0.5

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button {
                    adjust(by: -step)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(seconds <= range.lowerBound)
                .accessibilityLabel("Decrease \(title)")

                TextField(
                    "0.0",
                    value: clampedSeconds,
                    format: .number
                        .precision(.fractionLength(0...1))
                        .grouping(.never)
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)

                Text("s")
                    .foregroundStyle(.secondary)

                Button {
                    adjust(by: step)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(seconds >= range.upperBound)
                .accessibilityLabel("Increase \(title)")
            }
        }
    }

    private var clampedSeconds: Binding<Double> {
        Binding {
            seconds
        } set: { value in
            seconds = clamped(value)
        }
    }

    private func adjust(by delta: Double) {
        seconds = clamped(roundToStep(seconds + delta))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func roundToStep(_ value: Double) -> Double {
        (value / step).rounded() * step
    }
}

private struct MacSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let onRepairPairing: () -> Void
    @State private var initialDraft: BridgeMacSettingsPayload?
    @State private var draft: BridgeMacSettingsPayload?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDiscardConfirmation = false

    private var hasUnsavedChanges: Bool {
        guard let draft, let initialDraft else { return false }
        return draft != initialDraft
    }

    var body: some View {
        List {
            if let draft {
                Section("Speech") {
                    Picker("ASR Engine", selection: asrProviderBinding) {
                        ForEach(draft.asrProviderOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    TimeoutSecondsRow(
                        title: "ASR Timeout",
                        seconds: asrTimeoutSecondsBinding,
                        range: 10...300
                    )

                    NavigationLink {
                        LanguageSelectionView(
                            selection: languageBinding,
                            options: draft.supportedLanguageOptions(for: draft.asrProvider)
                        )
                    } label: {
                        HStack {
                            Text("Languages")
                            Spacer()
                            Text(LanguageDisplay.summary(
                                for: Set(draft.languageIDs),
                                options: draft.supportedLanguageOptions(for: draft.asrProvider)
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                Section("Refine") {
                    Picker("Engine", selection: correctionBackendBinding) {
                        ForEach(draft.correctionBackendOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    TimeoutSecondsRow(
                        title: "Refine Timeout",
                        seconds: correctionTimeoutSecondsBinding,
                        range: 0.1...30
                    )

                    TimeoutSecondsRow(
                        title: "Model Startup Timeout",
                        seconds: correctionColdTimeoutSecondsBinding,
                        range: 1...60
                    )

                    Picker("Mode", selection: correctionModeBinding) {
                        ForEach(CorrectionModeID.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Numbers", selection: numberOutputPreferenceBinding) {
                        ForEach(NumberOutputPreferenceID.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Punctuation", selection: punctuationPreferenceBinding) {
                        ForEach(PunctuationPreferenceID.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)

                }

                Section("Vocabulary") {
                    NavigationLink {
                        ServerVocabularyView(entries: userDictionaryBinding)
                    } label: {
                        HStack {
                            Text("Server Vocabulary")
                            Spacer()
                            Text(vocabularySummary(for: draft.userDictionary))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading server settings")
                    }
                }
            }

            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                        HStack(spacing: 10) {
                            Button {
                                repairPairing(clearExisting: false)
                            } label: {
                                Label("Repair Pairing", systemImage: "qrcode.viewfinder")
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                repairPairing(clearExisting: true)
                            } label: {
                                Label("Unpair", systemImage: "link.badge.minus")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Server Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { attemptDismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await saveAndDismiss() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.72)
                        }
                        Text(isSaving
                            ? NSLocalizedString("Saving…", comment: "Server settings save in progress")
                            : NSLocalizedString("Save", comment: "Save server settings button"))
                    }
                }
                .disabled(draft == nil || isSaving || !hasUnsavedChanges)
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog(
            "Discard server settings changes?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("You have unsaved changes that won't be pushed to the server.")
        }
        .task {
            await load(force: false)
        }
        .onAppear {
            state.isEditingMacSettings = true
        }
        .onDisappear {
            state.isEditingMacSettings = false
        }
    }

    private func attemptDismiss() {
        if hasUnsavedChanges {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func repairPairing(clearExisting: Bool) {
        if clearExisting {
            state.unpair()
        }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onRepairPairing()
        }
    }

    private func saveAndDismiss() async {
        await save()
        if errorMessage == nil {
            dismiss()
        }
    }

    private var asrProviderBinding: Binding<String> {
        Binding {
            draft?.asrProvider ?? "whisperkit"
        } set: { value in
            draft?.asrProvider = value
            normalizeDraft()
        }
    }

    private var correctionBackendBinding: Binding<String> {
        Binding {
            draft?.correctionBackend ?? ""
        } set: { value in
            draft?.correctionBackend = value
        }
    }

    private var asrTimeoutSecondsBinding: Binding<Double> {
        Binding {
            draft?.asrTimeoutSec ?? 120
        } set: { value in
            draft?.asrTimeoutSec = min(max(value, 10), 300)
        }
    }

    private var correctionTimeoutSecondsBinding: Binding<Double> {
        Binding {
            Double(draft?.correctionTimeoutMs ?? 1500) / 1000
        } set: { value in
            let clamped = min(max(value, 0.1), 30)
            draft?.correctionTimeoutMs = Int((clamped * 1000).rounded())
        }
    }

    private var correctionColdTimeoutSecondsBinding: Binding<Double> {
        Binding {
            Double(draft?.correctionColdTimeoutMs ?? 8000) / 1000
        } set: { value in
            let clamped = min(max(value, 1), 60)
            draft?.correctionColdTimeoutMs = Int((clamped * 1000).rounded())
        }
    }

    private var correctionModeBinding: Binding<CorrectionModeID> {
        Binding {
            draft?.correctionMode ?? .polish
        } set: { value in
            draft?.correctionMode = value
        }
    }

    private var numberOutputPreferenceBinding: Binding<NumberOutputPreferenceID> {
        Binding {
            draft?.numberOutputPreference ?? .automatic
        } set: { value in
            draft?.numberOutputPreference = value
        }
    }

    private var punctuationPreferenceBinding: Binding<PunctuationPreferenceID> {
        Binding {
            draft?.punctuationPreference ?? .normal
        } set: { value in
            draft?.punctuationPreference = value
        }
    }

    private var languageBinding: Binding<Set<String>> {
        Binding {
            Set(draft?.languageIDs ?? [])
        } set: { value in
            guard var current = draft else { return }
            current.languageIDs = ASRLanguageSelection.validatedIDs(
                Array(value),
                supportedOptions: current.supportedLanguageOptions(for: current.asrProvider)
            )
            draft = current
        }
    }

    private var userDictionaryBinding: Binding<[BridgeUserDictionaryEntry]> {
        Binding {
            draft?.userDictionary ?? []
        } set: { value in
            draft?.userDictionary = value
            normalizeDraft()
        }
    }

    private func normalizeDraft() {
        guard var current = draft else { return }
        current.normalize()
        draft = current
    }

    private func load(force: Bool) async {
        guard force || draft == nil else { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await state.refreshMacSettings()
            draft = loaded
            initialDraft = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard let draft else { return }
        isSaving = true
        errorMessage = nil
        do {
            let updated = try await state.updateMacSettings(draft)
            self.draft = updated
            initialDraft = updated
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func vocabularySummary(for entries: [BridgeUserDictionaryEntry]) -> String {
        entries.count == 1 ? "1 entry" : "\(entries.count) entries"
    }
}

private struct ServerVocabularyView: View {
    @Binding var entries: [BridgeUserDictionaryEntry]
    @State private var newSurface = ""
    @State private var selectedType = "person"
    @State private var customType = ""
    @FocusState private var isNewSurfaceFocused: Bool

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("New word or phrase", text: $newSurface)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isNewSurfaceFocused)

                    HStack(spacing: 10) {
                        Picker("Type", selection: $selectedType) {
                            ForEach(BridgeUserDictionaryEntry.suggestedTypes, id: \.self) { type in
                                Text(displayType(type)).tag(type)
                            }
                            Text("custom").tag("custom")
                        }
                        .pickerStyle(.menu)

                        if selectedType == "custom" {
                            TextField("Custom type", text: $customType)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Button {
                            addEntry()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canAddEntry)
                    }
                }
            }

            Section(entriesHeader) {
                if entries.isEmpty {
                    Text("No vocabulary entries")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            ServerVocabularyEntryEditorView(entry: entry) { updated in
                                updateEntry(updated)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.surface)
                                    .foregroundStyle(.primary)
                                Text(entry.displayType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteEntries)
                }
            }
        }
        .navigationTitle("Server Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .onChange(of: entries) { _, value in
            let normalized = normalizedEntries(value)
            if normalized != value {
                entries = normalized
            }
        }
    }

    private var entriesHeader: String {
        entries.count == 1 ? "1 Entry" : "\(entries.count) Entries"
    }

    private var resolvedType: String {
        selectedType == "custom" ? customType : selectedType
    }

    private var canAddEntry: Bool {
        !BridgeUserDictionaryEntry.cleanedSurface(newSurface).isEmpty &&
            (selectedType != "custom" || !customType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func addEntry() {
        let surface = BridgeUserDictionaryEntry.cleanedSurface(newSurface)
        guard !surface.isEmpty else { return }
        let entry = BridgeUserDictionaryEntry(
            type: resolvedType,
            surface: surface
        )
        entries = normalizedEntries(entries + [entry])
        newSurface = ""
        isNewSurfaceFocused = true
    }

    private func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    private func updateEntry(_ updated: BridgeUserDictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == updated.id }) else { return }
        entries[index] = updated
        entries = normalizedEntries(entries)
    }

    private func normalizedEntries(_ values: [BridgeUserDictionaryEntry]) -> [BridgeUserDictionaryEntry] {
        var seenIDs = Set<UUID>()
        return values.compactMap { value in
            let entry = BridgeUserDictionaryEntry(
                id: value.id,
                type: value.type,
                surface: value.surface
            )
            guard entry.isValid else { return nil }
            guard seenIDs.insert(entry.id).inserted else { return nil }
            return entry
        }
        .sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            if $0.surface != $1.surface { return $0.surface < $1.surface }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func displayType(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ")
    }
}

private struct ServerVocabularyEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: BridgeUserDictionaryEntry
    let onSave: (BridgeUserDictionaryEntry) -> Void
    @State private var surface = ""
    @State private var selectedType = "other"
    @State private var customType = ""

    var body: some View {
        Form {
            Section("Word") {
                TextField("Word or phrase", text: $surface)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Type") {
                Picker("Type", selection: typeSelectionBinding) {
                    ForEach(BridgeUserDictionaryEntry.suggestedTypes, id: \.self) { type in
                        Text(displayType(type)).tag(type)
                    }
                    Text("custom").tag("custom")
                }
                .pickerStyle(.menu)

                if selectedType == "custom" {
                    TextField("Custom type", text: customTypeBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .navigationTitle("Vocabulary Entry")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: syncTypeState)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!canSave)
            }
        }
    }

    private var typeSelectionBinding: Binding<String> {
        Binding {
            selectedType
        } set: { value in
            selectedType = value
            if value == "custom" {
                customType = customType.isEmpty ? entry.type : customType
            } else {
                customType = ""
            }
        }
    }

    private var customTypeBinding: Binding<String> {
        Binding {
            customType
        } set: { value in
            customType = value
        }
    }

    private var resolvedType: String {
        selectedType == "custom" ? customType : selectedType
    }

    private var canSave: Bool {
        !BridgeUserDictionaryEntry.cleanedSurface(surface).isEmpty &&
            (selectedType != "custom" || !customType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func syncTypeState() {
        surface = entry.surface
        if BridgeUserDictionaryEntry.suggestedTypes.contains(entry.type) {
            selectedType = entry.type
            customType = ""
        } else {
            selectedType = "custom"
            customType = entry.type
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(BridgeUserDictionaryEntry(
            id: entry.id,
            type: resolvedType,
            surface: surface
        ))
        dismiss()
    }

    private func displayType(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ")
    }
}
