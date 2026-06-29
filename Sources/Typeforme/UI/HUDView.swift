import SwiftUI
import KeyboardShortcuts

/// Bottom-centered glass HUD. Idle collapses to a mic pip; clicking it (or
/// starting a dictation) opens the expanded layout: live transcript text on
/// top, action bar below. The bar morphs by state — Wand + style chips at
/// idle, pulsing dot + waveform + elapsed timer while recording, processing
/// label while transcribing/refining — and ✕ stays live as Cancel. Brief
/// terminal states (inserting/success/error) use a compact capsule.
struct HUDView: View {
    @ObservedObject var coordinator: DictationCoordinator
    /// Opens the Settings window — wired from AppDelegate so an error capsule
    /// can hand the user a fix path instead of just evaporating.
    let onOpenSettings: () -> Void

    private static let cornerRadius: CGFloat = 24

    /// Expanded layout: live transcript text on top (when present), action
    /// bar below. Active while dictating and while the idle bar is open.
    private var isExpandedPreview: Bool {
        switch coordinator.state {
        case .idle:
            return coordinator.voicePreviewHUDExpanded
        case .recording, .transcribing, .correcting:
            return true
        case .success:
            return !voicePreviewText.isEmpty
        case .inserting, .error:
            return false
        }
    }

    var body: some View {
        // ZStack so the surface ALWAYS fills the panel — `.background(surface)`
        // on a Group only paints behind the content's natural size, which left
        // the rest of a tall preview panel transparent (desktop showing
        // through).
        ZStack(alignment: .topLeading) {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isExpandedPreview {
                expandedPreviewBody
            } else if coordinator.state == .idle {
                idleDotBody
            } else {
                compactBody
            }
        }
    }

    /// Idle: a small circular presence indicator. The panel itself shrinks to
    /// a 40pt circle (see HUDWindowController). Hover surfaces the hotkey hint
    /// without expanding the idle HUD; click opens the action bar.
    private var idleDotBody: some View {
        Button {
            coordinator.expandVoicePreviewHUD()
        } label: {
            idleDotImage
        }
        .buttonStyle(.plain)
        .help("Ready · \(hotkeyDescription)")
    }

    private var idleDotImage: some View {
        Image(systemName: "mic")
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Compact capsule for the brief terminal states: inserting / success /
    /// error. Recording and processing always use the expanded panel.
    private var compactBody: some View {
        HStack(spacing: 12) {
            leadingArea
                .help(statusText)
            if coordinator.state == .error {
                // Error keeps the text; configuration failures keep a direct
                // Settings path, while transient context errors can be closed.
                Text(coordinator.lastError ?? "Error")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if errorUsesSettingsAction {
                        onOpenSettings()
                    } else {
                        coordinator.reset()
                    }
                } label: {
                    Image(systemName: errorUsesSettingsAction ? "gearshape" : "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(errorUsesSettingsAction ? Color.secondary : Color.red)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(errorUsesSettingsAction ? "Open Settings" : "Cancel")
            } else if coordinator.state == .success, let warningText {
                Text(warningText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if coordinator.state == .inserting, !coordinator.livePartialTranscript.isEmpty {
                Text(coordinator.livePartialTranscript)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedPreviewBody: some View {
        voicePreviewBody
    }

    private var voicePreviewBody: some View {
        VStack(alignment: .leading, spacing: voicePreviewText.isEmpty ? 0 : 12) {
            if !voicePreviewText.isEmpty {
                Text(voicePreviewText)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let warningText {
                Label(warningText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            VoicePreviewActionBar(
                coordinator: coordinator,
                drawsChrome: usesActionBarOnlySurface
            )
        }
        .padding(.horizontal, voicePreviewText.isEmpty ? 6 : 18)
        .padding(.top, voicePreviewText.isEmpty ? 6 : 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var warningText: String? {
        let trimmed = coordinator.lastWarning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var errorUsesSettingsAction: Bool {
        let message = coordinator.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = message.lowercased()
        return [
            "system settings",
            "microphone permission",
            "speech recognition permission",
            "accessibility",
            "client bridge",
            "external llm",
            "external model identifier",
            "api key",
            "api token",
            "model file is missing",
            "model not found",
            "model download url",
            "download url is empty",
            "download failed with http",
            "llama-server",
            "bundled llama-server",
            "nvidia nemotron asr runtime",
            "does not support the selected languages",
            "on-device recognition is unavailable",
            "recognizer is unavailable",
            "backend unavailable"
        ].contains { lower.contains($0) }
    }

    private var voicePreviewText: String {
        let live = coordinator.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            switch coordinator.state {
            case .recording, .transcribing, .correcting:
                return live
            default:
                break
            }
        }
        return coordinator.lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Surface

    @ViewBuilder
    private var surface: some View {
        if !usesActionBarOnlySurface {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    // Hairline border so the capsule has a defined edge in any bg.
                    // `.separatorColor` is the system semantic for thin dividers
                    // and reads correctly in both light + dark mode; hardcoded
                    // white-opacity was invisible in light mode.
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    private var usesActionBarOnlySurface: Bool {
        isExpandedPreview && voicePreviewText.isEmpty
    }

    // MARK: - Leading (state icon for the compact capsule)

    @ViewBuilder
    private var leadingArea: some View {
        switch coordinator.state {
        case .inserting:
            ProcessingIndicator(symbol: iconSymbol, tint: stateColor)
        default:
            Image(systemName: iconSymbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(stateColor == .clear ? Color.accentColor : stateColor)
                .frame(width: 22, height: 22)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - State helpers

    private var iconSymbol: String {
        if coordinator.state == .success, warningText != nil {
            return "exclamationmark.triangle.fill"
        }
        switch coordinator.state {
        case .idle:         return "mic"
        case .transcribing: return "waveform"
        case .correcting:   return "sparkles"
        case .inserting:    return "text.cursor"
        case .success:      return "checkmark.circle.fill"
        case .error:        return "exclamationmark.triangle.fill"
        case .recording:    return "mic.fill" // unused; waveform takes over
        }
    }

    private var stateColor: Color {
        if warningText != nil, coordinator.state == .success {
            return .orange
        }
        switch coordinator.state {
        case .idle:         return .clear
        case .recording:    return .red
        case .transcribing: return .blue
        case .correcting:   return .purple
        case .inserting:    return .accentColor
        case .success:      return .green
        case .error:        return .orange
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle:
            return String(format: NSLocalizedString("Ready · %@", comment: "HUD idle status with hotkey hint"), hotkeyDescription)
        case .recording:    return NSLocalizedString("Recording", comment: "HUD status")
        case .transcribing:
            let base = coordinator.isProcessingCommandTextEdit
                ? NSLocalizedString("Understanding", comment: "HUD status while understanding a voice command")
                : NSLocalizedString("Transcribing…", comment: "HUD status")
            return coordinator.statusTextWithTranscriptionProgress(base)
        case .correcting:
            if coordinator.isProcessingCommandTextEdit {
                return NSLocalizedString("Editing", comment: "HUD status while applying a voice command")
            }
            // Re-correct: keep the prior text on screen so the HUD doesn't
            // flash to "Refining…" mid-edit. First refine has no prior
            // text, so we still show the spinner copy.
            return coordinator.lastCorrected.isEmpty
                ? NSLocalizedString("Refining…", comment: "HUD status")
                : coordinator.lastCorrected
        case .inserting:    return NSLocalizedString("Inserting…", comment: "HUD status")
        case .success:      return warningText ?? NSLocalizedString("Done", comment: "HUD status")
        case .error:        return coordinator.lastError ?? NSLocalizedString("Error", comment: "HUD error fallback")
        }
    }

    private var hotkeyDescription: String {
        let combo = KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "⌘⇧Space"
        let hold = AppSettings.holdModifier
        guard hold != .none else { return combo }
        let format = NSLocalizedString("double-tap %@", comment: "Idle hint when hold-to-talk is configured")
        return String(format: format, shortHoldName(hold))
    }

    private func shortHoldName(_ hold: HoldModifier) -> String {
        switch hold {
        case .none:         return ""
        case .rightOption:  return NSLocalizedString("Right ⌥", comment: "Hold modifier")
        case .rightCommand: return NSLocalizedString("Right ⌘", comment: "Hold modifier")
        case .rightShift:   return NSLocalizedString("Right ⇧", comment: "Hold modifier")
        case .rightControl: return NSLocalizedString("Right ⌃", comment: "Hold modifier")
        case .leftOption:   return NSLocalizedString("Left ⌥", comment: "Hold modifier")
        case .fn:           return NSLocalizedString("Fn", comment: "Hold modifier")
        }
    }

}

// MARK: - Recording dot

/// Soft pulsing red dot — the universal "we are listening" cue.
private struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: Color.red.opacity(0.65), radius: pulse ? 4 : 2)
            .scaleEffect(pulse ? 1.0 : 0.78)
            .opacity(pulse ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Processing indicator

/// Soft rotating gradient ring around the state icon, for transcribing /
/// correcting / inserting. Cheaper than ProgressView and matches the visual
/// language of the rest of the HUD.
private struct ProcessingIndicator: View {
    let symbol: String
    let tint: Color
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.0), tint.opacity(0.85)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Mode chips

/// All five correction modes laid out as explicit chips. The active mode is
/// highlighted; the chevron-dropdown variant we tried first hid the + mode
/// variants behind a menu and gave users no signal of which one was in use.
private struct ModeChipRow: View {
    @ObservedObject var coordinator: DictationCoordinator
    let disabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CorrectionMode.allCases, id: \.self) { mode in
                ModeChip(
                    label: shortLabel(for: mode),
                    isActive: active == mode
                ) {
                    Task { await coordinator.requestCorrectionModeChange(to: mode) }
                }
                .help(mode.helpText)
                .disabled(disabled || !AppSettings.isCorrectionModeAvailable(mode))
            }
        }
        .opacity(disabled ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: disabled)
    }

    private var active: CorrectionMode {
        coordinator.previewCorrectionMode ?? AppSettings.correctionMode
    }

    private func shortLabel(for mode: CorrectionMode) -> String {
        switch mode {
        case .fast:              return "Fast"
        case .clean:             return "Clean"
        case .polish:            return "Polish"
        case .polishPlus:        return "Polish+"
        case .structurePlus:     return "Structure+"
        case .formalPlus:        return "Formal+"
        }
    }
}

private struct ModeChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).modifier(ChipStyle(isActive: isActive))
        }
        .buttonStyle(.plain)
    }
}

private struct ChipStyle: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .background(
                Capsule(style: .continuous)
                    // Primary is black-in-light / white-in-dark, so the
                    // inactive chip stays visible in both modes. Previously
                    // hardcoded white-opacity went invisible in light mode.
                    .fill(isActive ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(isActive ? 0.0 : 0.12), lineWidth: 0.5)
            )
    }
}

// MARK: - Voice Preview action bar

/// The HUD's persistent control strip. Idle shows Wand + style chips; while
/// a dictation is in flight the strip morphs into live recording feedback
/// (pulsing dot, waveform, elapsed/limit timer) or a processing label, with
/// ✕ staying live as Cancel the whole time.
private struct VoicePreviewActionBar: View {
    @ObservedObject var coordinator: DictationCoordinator
    let drawsChrome: Bool

    var body: some View {
        HStack(spacing: 4) {
            switch coordinator.state {
            case .recording:
                recordingCluster
            case .transcribing, .correcting:
                processingCluster
            case .success:
                successCluster
            default:
                idleCluster
            }

            Spacer(minLength: 4)

            if coordinator.isRecordingCommandTextEdit {
                Divider()
                    .frame(height: 18)

                Button {
                    Task { await coordinator.stopDictation() }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.green)
                .help("Finish recording")
            }

            Divider()
                .frame(height: 18)

            Button {
                if coordinator.state == .idle {
                    coordinator.collapseVoicePreviewHUD()
                } else if coordinator.state == .success {
                    coordinator.dismissVoicePreviewHUDFromKeyboard()
                } else {
                    Task { await coordinator.cancelDictation() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(closeButtonTint)
            .help(closeButtonHelp)
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background {
            if drawsChrome {
                Color.clear
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            }
        }
        .overlay {
            if drawsChrome {
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
        .mask {
            if drawsChrome {
                Capsule(style: .continuous)
            } else {
                Rectangle()
            }
        }
    }

    private var idleCluster: some View {
        HStack(spacing: 4) {
            VoicePreviewBarButton(
                title: "Wand",
                systemImage: "wand.and.stars"
            ) {
                Task { await coordinator.togglePreviewCommand() }
            }

            Divider()
                .frame(height: 18)

            Image(systemName: "paintbrush.pointed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 26)
                .help("Style")

            ModeChipRow(coordinator: coordinator, disabled: false)
        }
    }

    private var recordingCluster: some View {
        HStack(spacing: 10) {
            RecordingDot()
            WaveformView(level: coordinator.audioLevel, state: .recording)
                .frame(height: 24)
            RecordingElapsedLabel(
                startedAt: coordinator.recordingStartedAt ?? Date(),
                maxDuration: AppSettings.maxRecordingDuration
            )
            if coordinator.isRecordingCommandTextEdit {
                Text(commandCompletionHint)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var commandCompletionHint: String {
        let hold = AppSettings.holdModifier
        guard hold != .none else {
            return NSLocalizedString("Click ✓ to complete", comment: "HUD command recording completion hint")
        }
        let format = NSLocalizedString("Tap %@ to complete", comment: "HUD command recording completion hint")
        return String(format: format, shortHoldName(hold))
    }

    private func shortHoldName(_ hold: HoldModifier) -> String {
        switch hold {
        case .none:         return ""
        case .rightOption:  return NSLocalizedString("Right ⌥", comment: "Hold modifier")
        case .rightCommand: return NSLocalizedString("Right ⌘", comment: "Hold modifier")
        case .rightShift:   return NSLocalizedString("Right ⇧", comment: "Hold modifier")
        case .rightControl: return NSLocalizedString("Right ⌃", comment: "Hold modifier")
        case .leftOption:   return NSLocalizedString("Left ⌥", comment: "Hold modifier")
        case .fn:           return NSLocalizedString("Fn", comment: "Hold modifier")
        }
    }

    private var processingCluster: some View {
        HStack(spacing: 8) {
            ProcessingIndicator(
                symbol: coordinator.state == .correcting ? "sparkles" : "waveform",
                tint: coordinator.state == .correcting ? .purple : .blue
            )
            Text(processingStatusText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var processingStatusText: String {
        if coordinator.isProcessingCommandTextEdit {
            let base = coordinator.state == .correcting
                ? NSLocalizedString("Editing", comment: "HUD status while applying a voice command")
                : NSLocalizedString("Understanding", comment: "HUD status while understanding a voice command")
            return coordinator.statusTextWithTranscriptionProgress(base)
        }
        let base = coordinator.state == .correcting
            ? NSLocalizedString("Refining…", comment: "HUD status")
            : NSLocalizedString("Transcribing…", comment: "HUD status")
        return coordinator.statusTextWithTranscriptionProgress(base)
    }

    private var successCluster: some View {
        let message = successMessage
        let isWarning = coordinator.lastWarning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let tint: Color = isWarning ? .orange : .green
        return HStack(spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(1)
    }

    private var successMessage: String {
        let trimmed = coordinator.lastWarning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? NSLocalizedString("Done", comment: "HUD status") : trimmed
    }

    private var closeButtonTint: AnyShapeStyle {
        switch coordinator.state {
        case .idle, .success:
            return AnyShapeStyle(.secondary)
        default:
            return AnyShapeStyle(Color.red)
        }
    }

    private var closeButtonHelp: String {
        switch coordinator.state {
        case .idle:
            return "Collapse (Esc)"
        case .success:
            return "Dismiss (Esc)"
        default:
            return "Cancel (Esc)"
        }
    }
}

/// Elapsed recording time; switches to "elapsed / limit" in orange when the
/// auto-stop limit is a few seconds away so long thoughts aren't cut off
/// without warning.
private struct RecordingElapsedLabel: View {
    let startedAt: Date
    let maxDuration: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let nearLimit = maxDuration > 0 && maxDuration - elapsed <= 5.5
            Text(nearLimit
                 ? "\(Self.format(elapsed)) / \(Self.format(maxDuration))"
                 : Self.format(elapsed))
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(nearLimit ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VoicePreviewBarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VoicePreviewBarLabel(title: title, systemImage: systemImage)
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .help("Speak a command for the current input")
    }
}

private struct VoicePreviewBarLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}
