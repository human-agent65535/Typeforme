import SwiftUI
import UIKit

struct SetupReadinessView: View {
    @Environment(AppState.self) private var state
    @State private var isRequestingMicrophone = false
    @State private var isRequestingSpeech = false

    var body: some View {
        readinessList
            .navigationTitle("Capture Mode & Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                state.refreshSetupReadinessStatuses()
            }
            .onDisappear {
                state.dismissSetupReadiness()
            }
    }

    private var readinessList: some View {
        List {
            introSection
            captureMethodSection
            requiredSection
            if showsSpeechPreviewPermission {
                optionalSection
            }
        }
    }

    @ViewBuilder
    private var captureMethodSection: some View {
        Section {
            DictationCaptureModeToggle()
        } header: {
            Text("Capture Mode")
        } footer: {
            Text("Background Mic uses the host audio session duration below. PiP uses a visible session and opens the microphone only while recording.")
        }
    }

    @ViewBuilder
    private var introSection: some View {
        Section {
            Text("Check the required host app setup before using Typeforme from the keyboard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var requiredSection: some View {
        Section("Required") {
            ReadinessActionRow(
                icon: "mic",
                title: "Microphone",
                detail: "Required because the host app owns keyboard dictation audio.",
                status: microphoneStatus,
                actionTitle: microphoneActionTitle,
                actionIcon: microphoneActionIcon,
                isWorking: isRequestingMicrophone,
                action: microphoneAction
            )

            ReadinessActionRow(
                icon: "keyboard",
                title: "Keyboard & Full Access",
                detail: "iOS exposes this only through Settings. Full Access lets the keyboard reach the host app.",
                status: keyboardStatus,
                actionTitle: keyboardActionTitle,
                actionIcon: "arrow.up.right.square",
                action: keyboardAction
            )
        }
    }

    @ViewBuilder
    private var optionalSection: some View {
        Section("Optional") {
            ReadinessActionRow(
                icon: "waveform",
                title: "Apple Speech Preview",
                detail: "Only needed for on-device live partial preview. Core dictation still works without it.",
                status: speechStatus,
                actionTitle: speechActionTitle,
                actionIcon: speechActionIcon,
                isWorking: isRequestingSpeech,
                action: speechAction
            )
        }
    }

    private var showsSpeechPreviewPermission: Bool {
        state.keyboardLivePreviewEnabled && state.keyboardLivePreviewSource == .appleSpeech
    }

    private var microphoneStatus: ReadinessStatusBadge {
        switch state.microphonePermissionStatus {
        case .granted:
            return .ready("Allowed")
        case .notDetermined:
            return .warning("Required")
        case .denied:
            return .blocked("Denied")
        case .restricted:
            return .blocked("Restricted")
        case .unavailable:
            return .blocked("Unavailable")
        case .unknown:
            return .warning("Unknown")
        }
    }

    private var microphoneActionTitle: String? {
        switch state.microphonePermissionStatus {
        case .notDetermined:
            return "Allow"
        case .denied:
            return "Open Settings"
        default:
            return nil
        }
    }

    private var microphoneActionIcon: String {
        state.microphonePermissionStatus == .denied ? "arrow.up.right.square" : "mic.fill"
    }

    private var microphoneAction: (() -> Void)? {
        guard microphoneActionTitle != nil else { return nil }
        return {
            isRequestingMicrophone = true
            Task {
                await state.requestMicrophonePermissionForSetup()
                isRequestingMicrophone = false
            }
        }
    }

    private var keyboardStatus: ReadinessStatusBadge {
        state.keyboardNeedsFullAccessSetup
            ? .warning("Required")
            : .ready("Ready")
    }

    private var keyboardActionTitle: String? {
        state.keyboardNeedsFullAccessSetup ? "Open Settings" : nil
    }

    private var keyboardAction: (() -> Void)? {
        if state.keyboardNeedsFullAccessSetup {
            return openAppSettings
        }
        return nil
    }

    private var speechStatus: ReadinessStatusBadge {
        switch state.speechRecognitionPermissionStatus {
        case .granted:
            return .ready("Allowed")
        case .notDetermined:
            return .neutral("Optional")
        case .denied:
            return .neutral("Off")
        case .restricted:
            return .warning("Restricted")
        case .unavailable:
            return .warning("Unavailable")
        case .unknown:
            return .neutral("Unknown")
        }
    }

    private var speechActionTitle: String? {
        switch state.speechRecognitionPermissionStatus {
        case .notDetermined:
            return "Allow Preview"
        case .denied:
            return "Open Settings"
        default:
            return nil
        }
    }

    private var speechActionIcon: String {
        state.speechRecognitionPermissionStatus == .denied ? "arrow.up.right.square" : "waveform"
    }

    private var speechAction: (() -> Void)? {
        guard speechActionTitle != nil else { return nil }
        return {
            switch state.speechRecognitionPermissionStatus {
            case .notDetermined:
                isRequestingSpeech = true
                Task {
                    await state.requestSpeechRecognitionPermissionForSetup()
                    isRequestingSpeech = false
                }
            case .denied:
                openAppSettings()
            default:
                break
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}


private struct DictationCaptureModeToggle: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Capture Mode", selection: captureModeBinding) {
                ForEach(KeyboardDictationCaptureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Capture Mode")
            .accessibilityValue(state.keyboardDictationCaptureMode.title)
            .disabled(state.isBusy)

            Text(state.keyboardDictationCaptureMode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if state.keyboardDictationCaptureMode != .pictureInPicture {
                Picker("Host audio session", selection: hostAudioSessionLengthBinding) {
                    ForEach(HostAudioSessionLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .disabled(state.isBusy)
            }
        }
        .padding(.vertical, 3)
    }

    private var captureModeBinding: Binding<KeyboardDictationCaptureMode> {
        Binding {
            state.keyboardDictationCaptureMode
        } set: { mode in
            state.setKeyboardDictationCaptureMode(mode)
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

private struct ReadinessStatusBadge {
    let title: String
    let systemImage: String
    let tint: Color

    static func ready(_ title: String) -> ReadinessStatusBadge {
        ReadinessStatusBadge(title: title, systemImage: "checkmark.circle.fill", tint: .green)
    }

    static func warning(_ title: String) -> ReadinessStatusBadge {
        ReadinessStatusBadge(title: title, systemImage: "exclamationmark.triangle.fill", tint: .orange)
    }

    static func blocked(_ title: String) -> ReadinessStatusBadge {
        ReadinessStatusBadge(title: title, systemImage: "xmark.circle.fill", tint: .red)
    }

    static func info(_ title: String) -> ReadinessStatusBadge {
        ReadinessStatusBadge(title: title, systemImage: "checkmark.circle.fill", tint: .blue)
    }

    static func neutral(_ title: String) -> ReadinessStatusBadge {
        ReadinessStatusBadge(title: title, systemImage: "circle", tint: .secondary)
    }
}

private struct ReadinessActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: ReadinessStatusBadge
    let actionTitle: String?
    let actionIcon: String
    var isWorking = false
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        detail: String,
        status: ReadinessStatusBadge,
        actionTitle: String? = nil,
        actionIcon: String = "arrow.right",
        isWorking: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.status = status
        self.actionTitle = actionTitle
        self.actionIcon = actionIcon
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(LocalizedStringKey(title))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Label {
                            Text(LocalizedStringKey(status.title))
                        } icon: {
                            Image(systemName: status.systemImage)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.tint)
                    }
                    Text(LocalizedStringKey(detail))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle, let action {
                Button(action: action) {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(LocalizedStringKey(actionTitle))
                        }
                    } else {
                        Label(LocalizedStringKey(actionTitle), systemImage: actionIcon)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Unpaired empty state
