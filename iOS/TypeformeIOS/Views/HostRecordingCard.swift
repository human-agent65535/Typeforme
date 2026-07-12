import SwiftUI
import UIKit

struct HeroRecordCard: View {
    @Environment(AppState.self) private var state
    @ObservedObject var audio: AudioCoordinator
    @State private var isPressed = false

    /// Compact enough for the host home screen while remaining tappable and
    /// large enough to show recording state clearly.
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
            .accessibilityLabel("Recording Control")
            .accessibilityValue(state.inputMode.title)
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
            return NSLocalizedString("Pair the Mac Bridge first.", comment: "Host recording requires pairing")
        }
        if isRecording {
            return state.inputMode == .tap
                ? NSLocalizedString("Tap again when you're done.", comment: "Tap recording help")
                : NSLocalizedString("Keep holding while you speak.", comment: "Hold recording help")
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
        case .success(.ready):
            return NSLocalizedString("Result ready.", comment: "Host result ready status")
        case .success(.copied):
            return NSLocalizedString("Result copied to the clipboard.", comment: "Host result copied status")
        case .success(.inserted):
            return NSLocalizedString("Result inserted.", comment: "Host result inserted status")
        case .failure, .idle, .preparing, .recording:
            if state.routeStatus.activeURL == nil {
                return NSLocalizedString("Recording is local. Bridge will be resolved when you send.", comment: "Host can record before resolving a bridge route")
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
