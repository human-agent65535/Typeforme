import SwiftUI
import KeyboardShortcuts
import AppKit
import CoreImage.CIFilterBuiltins

private let typeformePrivacyPolicyURL = URL(string: "https://github.com/human-agent65535/Typeforme/blob/main/docs/app-store/privacy-policy.md")!

private struct IntegerSettingField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String

    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
                .onAppear(perform: syncFromValue)
                .onSubmit(commitDraft)
                .onChange(of: draft) { _, newValue in
                    let filtered = newValue.filter { $0.isWholeNumber }
                    if filtered != newValue {
                        draft = filtered
                        return
                    }
                    if let parsed = Int(filtered), range.contains(parsed) {
                        value = parsed
                    }
                }
                .onChange(of: value) { _, newValue in
                    let clamped = clamp(newValue)
                    if clamped != newValue {
                        value = clamped
                        return
                    }
                    if Int(draft) != clamped {
                        draft = String(clamped)
                    }
                }
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitDraft() {
        let parsed = Int(draft) ?? value
        let clamped = clamp(parsed)
        value = clamped
        draft = String(clamped)
    }

    private func syncFromValue() {
        let clamped = clamp(value)
        if clamped != value {
            value = clamped
        }
        draft = String(clamped)
    }

    private func clamp(_ value: Int) -> Int {
        min(max(range.lowerBound, value), range.upperBound)
    }
}

private struct RecognitionSourceSettingsLabel: View {
    let title: String
    let source: RecognitionSource
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(source.qualitySpeedLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue
    @AppStorage(AppSettings.Keys.launchAtLogin) private var launchAtLogin = true
    @AppStorage(AppSettings.Keys.showDockIcon) private var showDockIcon = false
    @State private var axTrusted = AppPermissions.accessibilityTrusted
    @State private var microphoneStatus = AppPermissions.microphoneStatus
    @State private var launchAtLoginStatus = LaunchAtLoginController.status
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("App") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion()).foregroundStyle(.secondary)
                }
                Button {
                    NotificationCenter.default.post(name: .setupGuideRequested, object: nil)
                } label: {
                    Label("Open Setup Guide", systemImage: "checklist")
                }
                Link(destination: typeformePrivacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                HStack {
                    Text("Bundle ID")
                    Spacer()
                    Text(BundleIdentity.mainBundleIdentifier)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Toggle("Open Typeforme at login", isOn: launchAtLoginBinding)
                    Spacer()
                    Text(LocalizedStringKey(launchAtLoginStatus.displayText))
                        .foregroundStyle(launchAtLoginStatusColor)
                    if launchAtLoginStatus == .requiresApproval {
                        Button("Open Login Items…") {
                            LaunchAtLoginController.openSystemSettings()
                        }
                    }
                }
                Text(LocalizedStringKey(launchAtLoginHelpText))
                    .font(.footnote)
                    .foregroundStyle(launchAtLoginHelpColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, _ in
                        AppActivationPolicy.applyPreferredPolicy()
                    }
            }
            Section("Role") {
                Picker("This Mac", selection: processingModeBinding) {
                    ForEach(ProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(processingMode.helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(axTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    if !axTrusted {
                        Button("Open System Settings…") {
                            AppPermissions.openAccessibilitySettings()
                        }
                    }
                    Menu {
                        Button("Refresh now") {
                            axTrusted = AppPermissions.accessibilityTrusted
                        }
                        Button("Reset & re-prompt") {
                            // tccutil reset wipes the record but doesn't re-register
                            // us in the Accessibility list; we have to "knock" via
                            // AXIsProcessTrustedWithOptions(prompt:true) to make
                            // macOS add Typeforme back so there's something to toggle.
                            _ = AppPermissions.resetAccessibilityGrant()
                            AppPermissions.requestAccessibility()
                            axTrusted = AppPermissions.accessibilityTrusted
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text(axTrusted
                     ? "Typeforme can insert refined text via synthesized input."
                     : "Toggle Typeforme on in System Settings → Privacy → Accessibility. This row refreshes automatically once you grant access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !axTrusted {
                    Text("Still says \"Not granted\" after toggling? Try \"Reset & re-prompt\" to clear the stale TCC record, then grant once more. Officially signed builds keep a stable app identity across rebuilds.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(microphoneStatusText)
                        .foregroundStyle(microphoneStatusColor)
                    if microphoneStatus == .notDetermined {
                        Button("Request Access") {
                            Task {
                                microphoneStatus = await AppPermissions.requestMicrophone()
                            }
                        }
                    } else if microphoneStatus != .granted {
                        Button("Open System Settings…") {
                            AppPermissions.openMicrophoneSettings()
                        }
                    }
                    Button("Refresh") {
                        microphoneStatus = AppPermissions.microphoneStatus
                    }
                }
                Text(microphoneHelpText)
                    .font(.footnote)
                    .foregroundStyle(microphoneHelpColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Poll while Settings is visible so the state flips to "Granted"
        // the moment the user toggles it in System Settings → Privacy.
        .task {
            while !Task.isCancelled {
                let now = AppPermissions.accessibilityTrusted
                if now != axTrusted { axTrusted = now }
                let mic = AppPermissions.microphoneStatus
                if mic != microphoneStatus { microphoneStatus = mic }
                let loginStatus = LaunchAtLoginController.status
                if loginStatus != launchAtLoginStatus { launchAtLoginStatus = loginStatus }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        // Belt-and-braces: also re-check the instant the user switches back
        // to Typeforme after granting in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AppPermissions.accessibilityTrusted
            microphoneStatus = AppPermissions.microphoneStatus
            launchAtLoginStatus = LaunchAtLoginController.status
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    private var processingModeBinding: Binding<String> {
        Binding {
            processingModeRaw
        } set: { raw in
            guard let mode = ProcessingMode(rawValue: raw) else { return }
            AppSettings.setProcessingMode(mode)
            processingModeRaw = AppSettings.processingMode.rawValue
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLogin
        } set: { enabled in
            launchAtLogin = enabled
            launchAtLoginError = nil
            do {
                launchAtLoginStatus = try LaunchAtLoginController.setEnabled(enabled)
            } catch {
                launchAtLoginStatus = LaunchAtLoginController.status
                launchAtLoginError = error.localizedDescription
                Log.app.error("Launch at login toggle failed enabled=\(enabled, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch launchAtLoginStatus {
        case .enabled: return .green
        case .disabled: return .secondary
        case .requiresApproval: return .orange
        case .unavailable: return .red
        }
    }

    private var launchAtLoginHelpText: String {
        switch launchAtLoginStatus {
        case .enabled:
            return "Typeforme will open automatically when you log in."
        case .disabled:
            return "Typeforme will not open automatically when you log in."
        case .requiresApproval:
            return "Approve Typeforme in System Settings to finish enabling login launch."
        case .unavailable:
            return "Login launch is unavailable for this build. Make sure the app bundle is code signed."
        }
    }

    private var launchAtLoginHelpColor: Color {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .disabled
            ? Color.secondary
            : Color.orange
    }

    private var microphoneStatusText: String {
        switch microphoneStatus {
        case .granted: return "Granted"
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphoneStatus {
        case .granted: return .green
        case .notDetermined: return .orange
        case .denied, .restricted, .unknown: return .red
        }
    }

    private var microphoneHelpText: String {
        switch microphoneStatus {
        case .granted:
            return "Typeforme can record dictation audio on this Mac."
        case .notDetermined:
            return "Grant Microphone access before recording locally."
        case .denied:
            return "Enable Typeforme in System Settings → Privacy & Security → Microphone."
        case .restricted:
            return "Microphone access is restricted by system policy."
        case .unknown:
            return "Microphone permission state could not be read."
        }
    }

    private var microphoneHelpColor: Color {
        microphoneStatus == .granted ? Color.secondary : Color.orange
    }
}

// MARK: - Setup Guide

extension Notification.Name {
    static let setupGuideRequested = Notification.Name("TypeformeSetupGuideRequested")
}

// MARK: - Client Server

struct ClientServerSettingsView: View {
    @AppStorage(AppSettings.Keys.clientLocalBridgeURLs) private var clientLocalBridgeURLsRaw = ""
    @AppStorage(AppSettings.Keys.clientCloudBridgeURL) private var clientCloudBridgeURL = ""
    @AppStorage(AppSettings.Keys.clientLanguageIDs) private var clientLanguageIDsRaw = ASRLanguageSelection.defaultRawValue
    @State private var clientBridgeToken = AppSettings.clientBridgeToken
    @State private var draft: BridgeSettingsPayload?
    @State private var isChecking = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var showAllClientLanguages = false
    @State private var showAllServerLanguages = false
    @State private var routeStatus = BridgeRouteResolutionStatus()

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Button {
                        pastePairingJSON()
                    } label: {
                        Label("Paste Pairing JSON", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        Task { await checkRoutes() }
                    } label: {
                        Label(isChecking ? "Checking…" : "Check Routes", systemImage: "network")
                    }
                    .disabled(isChecking || !clientConfig.isConfigured)
                    Button(role: .destructive) {
                        unpairClient()
                    } label: {
                        Label("Unpair", systemImage: "link.badge.minus")
                    }
                    .disabled(!clientConfig.isConfigured)
                    Spacer()
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? .orange : .green)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Local URLs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $clientLocalBridgeURLsRaw)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 54)
                        .scrollContentBackground(.hidden)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }

                TextField("Cloud URL", text: $clientCloudBridgeURL, prompt: Text("https://voice.example.com"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer token", text: $clientBridgeToken)
                    .textFieldStyle(.roundedBorder)

                ClientRouteRow(
                    title: "Local",
                    endpoint: primaryLocalEndpoint,
                    state: endpointState(
                        isConfigured: !clientConfig.localBridgeURLs.isEmpty,
                        isChecked: routeStatus.localChecked,
                        isOK: routeStatus.localOK
                    ),
                    latencyMs: routeStatus.localLatencyMs,
                    isActive: routeStatus.activeKind == .local,
                    tint: .green
                )
                ClientRouteRow(
                    title: "Cloud",
                    endpoint: cloudEndpoint,
                    state: endpointState(
                        isConfigured: !clientConfig.cloudBridgeURL.isEmpty,
                        isChecked: routeStatus.cloudChecked,
                        isOK: routeStatus.cloudOK
                    ),
                    latencyMs: routeStatus.cloudLatencyMs,
                    isActive: routeStatus.activeKind == .cloud,
                    tint: .blue
                )

                Text("Client mode records on this Mac, sends audio to Typeforme Bridge, then inserts the returned text locally. Requests try Local first and fall back to Cloud only when Local is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Client Input") {
                Text(clientLanguageSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                clientLanguageGrid(commonClientLanguageOptions)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAllClientLanguages.toggle()
                    }
                } label: {
                    DisclosureRow(
                        title: "All client languages",
                        count: allOtherClientLanguages.count,
                        isExpanded: showAllClientLanguages
                    )
                }
                .buttonStyle(.plain)

                if showAllClientLanguages {
                    clientLanguageGrid(allOtherClientLanguages)
                        .padding(.top, 2)
                }

                if let current = draft {
                    LabeledContent("Default mode") {
                        Text(CorrectionMode(rawValue: current.correctionMode)?.displayName ?? current.correctionMode)
                            .foregroundStyle(.secondary)
                    }
                    Text("Languages here are this Mac's local override. Default mode follows Server Settings and is refreshed from the active route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let current = draft {
                Section("Server Speech") {
                    Text("Server sections edit a draft — nothing changes on the server until you press Save to Server below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(visibleRecognitionSourceOptions(for: current)) { option in
                        if let source = RecognitionSource(rawValue: option.id) {
                            Toggle(isOn: serverRecognitionSourceBinding(source)) {
                                RecognitionSourceSettingsLabel(
                                    title: option.displayName,
                                    source: source
                                )
                            }
                            .toggleStyle(.switch)
                            .disabled(serverRecognitionSourceToggleDisabled(source, current: current))
                            if let reason = serverRecognitionSourceDisabledReason(source, current: current) {
                                Text(reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ForEach(visibleEnabledSources(for: current).filter(\.hasModelConfiguration)) { source in
                        if !current.asrModelOptions(for: source.rawValue).isEmpty {
                            Picker("\(source.displayName) model", selection: serverASRModelBinding(source)) {
                                ForEach(current.asrModelOptions(for: source.rawValue)) { option in
                                    Text(option.displayName).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    Text(selectedLanguageSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    serverLanguageGrid(commonServerLanguageOptions)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showAllServerLanguages.toggle()
                        }
                    } label: {
                        DisclosureRow(
                            title: "All server languages",
                            count: allOtherServerLanguages.count,
                            isExpanded: showAllServerLanguages
                        )
                    }
                    .buttonStyle(.plain)

                    if showAllServerLanguages {
                        serverLanguageGrid(allOtherServerLanguages)
                            .padding(.top, 2)
                    }
                }

                Section("Server Refine") {
                    Picker("Engine", selection: correctionBackendBinding) {
                        ForEach(correctionBackendOptions(for: current)) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Default mode", selection: correctionModeBinding) {
                        ForEach(CorrectionMode.allCases, id: \.rawValue) { mode in
                            Text(serverCorrectionModeTitle(mode)).tag(mode.rawValue)
                                .disabled(!isServerCorrectionModeEnabled(mode))
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Fast source", selection: serverFastASRSourceBinding) {
                        ForEach(visibleRecognitionSourceOptions(for: current)) { option in
                            if let source = RecognitionSource(rawValue: option.id) {
                                Text(option.displayName).tag(source.rawValue)
                                    .disabled(!isServerFastSourceReady(source))
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    if let issue = serverFastSourceIssue {
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    Picker("Numbers", selection: numberOutputPreferenceBinding) {
                        ForEach(NumberOutputPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Punctuation", selection: punctuationPreferenceBinding) {
                        ForEach(PunctuationOutputPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    if let downloadSummary = serverDraftDownloadSummary {
                        Label(downloadSummary, systemImage: "arrow.down.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button {
                            Task { await saveSettings() }
                        } label: {
                            Label(
                                isSaving ? "Saving…" : (serverDraftNeedsDownload ? "Save & Download to Server" : "Save to Server"),
                                systemImage: serverDraftNeedsDownload ? "arrow.down.circle" : "arrow.up.circle"
                            )
                        }
                        .disabled(isSaving || isLoading)

                        Button {
                            Task { await loadSettings(force: true) }
                        } label: {
                            Label("Reload from Server", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading || isSaving)
                    }
                }
            } else {
                Section("Server Settings") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading server settings")
                        }
                    } else {
                        Button {
                            Task { await loadSettings(force: true) }
                        } label: {
                            Label("Pull Server Settings", systemImage: "arrow.down.circle")
                        }
                        .disabled(!clientConfig.isConfigured)
                    }
                    Text("After pulling, this page shows the active Server ASR, language, refine engine, default mode, and auto-commit settings returned by /v1/settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            clientBridgeToken = AppSettings.clientBridgeToken
        }
        .onChange(of: clientBridgeToken) { _, newValue in
            AppSettings.setClientBridgeToken(newValue)
        }
        .task {
            await loadSettings(force: false)
        }
    }

    private var correctionBackendBinding: Binding<String> {
        Binding {
            draft?.correctionBackend ?? ""
        } set: { value in
            draft?.correctionBackend = value
            normalizeDraft()
        }
    }

    private var correctionModeBinding: Binding<String> {
        Binding {
            draft?.correctionMode ?? CorrectionMode.polishPlus.rawValue
        } set: { value in
            guard let mode = CorrectionMode(rawValue: value),
                  isServerCorrectionModeEnabled(mode)
            else { return }
            draft?.correctionMode = value
            normalizeDraft()
        }
    }

    private func isServerCorrectionModeEnabled(_ mode: CorrectionMode) -> Bool {
        guard mode == .fast else { return true }
        return draft?.fastASRReadiness.ready == true
    }

    private var serverFastASRSourceBinding: Binding<String> {
        Binding {
            draft?.fastASRSource ?? RecognitionSource.qwen.rawValue
        } set: { value in
            guard let source = RecognitionSource(rawValue: value),
                  isServerFastSourceReady(source)
            else { return }
            draft?.fastASRSource = source.rawValue
            normalizeDraft()
        }
    }

    private func isServerFastSourceReady(_ source: RecognitionSource) -> Bool {
        guard let draft, draft.isRecognitionSourceEnabled(source) else { return false }
        return draft.sourceAvailability(for: source)?.ready == true
    }

    private var serverFastSourceIssue: String? {
        guard let draft else { return nil }
        let readiness = draft.fastASRReadiness
        return readiness.ready ? nil : readiness.reason
    }

    private func visibleRecognitionSourceOptions(for settings: BridgeSettingsPayload) -> [BridgeSettingOption] {
        settings.recognitionSourceOptions
    }

    private func visibleEnabledSources(for settings: BridgeSettingsPayload) -> [RecognitionSource] {
        settings.enabledSources
    }

    private func serverCorrectionModeTitle(_ mode: CorrectionMode) -> String {
        mode.displayName
    }

    private var numberOutputPreferenceBinding: Binding<String> {
        Binding {
            draft?.numberOutputPreference ?? NumberOutputPreference.automatic.rawValue
        } set: { value in
            draft?.numberOutputPreference = value
            normalizeDraft()
        }
    }

    private var punctuationPreferenceBinding: Binding<String> {
        Binding {
            draft?.punctuationPreference ?? PunctuationOutputPreference.normal.rawValue
        } set: { value in
            draft?.punctuationPreference = value
            normalizeDraft()
        }
    }

    private var selectedServerLanguageIDs: [String] {
        draft?.languageIDs ?? []
    }

    private var serverSupportedLanguageOptions: [ASRLanguageOption] {
        guard let draft else { return [] }
        return draft.supportedLanguageOptionsForEnabledSources()
    }

    private var clientSupportedLanguageOptions: [ASRLanguageOption] {
        serverSupportedLanguageOptions
    }

    private var selectedClientLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(
            ASRLanguageSelection.parse(clientLanguageIDsRaw),
            supportedOptions: clientSupportedLanguageOptions
        )
    }

    private var commonServerLanguageOptions: [ASRLanguageOption] {
        serverSupportedLanguageOptions
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    private var allOtherServerLanguages: [ASRLanguageOption] {
        serverSupportedLanguageOptions.filter { !$0.isCommon }
    }

    private var commonClientLanguageOptions: [ASRLanguageOption] {
        clientSupportedLanguageOptions
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    private var allOtherClientLanguages: [ASRLanguageOption] {
        clientSupportedLanguageOptions.filter { !$0.isCommon }
    }

    private var languageColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: 10, alignment: .leading)]
    }

    private var selectedLanguageSummary: String {
        guard !serverSupportedLanguageOptions.isEmpty else {
            return "No ASR source enabled."
        }
        return "Server default: " + ASRLanguageSelection
            .displayNames(for: selectedServerLanguageIDs, supportedOptions: serverSupportedLanguageOptions)
            .joined(separator: ", ")
    }

    private var clientLanguageSummary: String {
        "Client override: " + ASRLanguageSelection
            .displayNames(for: selectedClientLanguageIDs, supportedOptions: clientSupportedLanguageOptions)
            .joined(separator: ", ")
    }

    private var clientConfig: ClientBridgeConfiguration {
        ClientBridgeConfiguration(
            localBridgeURLs: ClientBridgeConfiguration.uniqueBridgeURLs(
                clientLocalBridgeURLsRaw.components(separatedBy: CharacterSet(charactersIn: "\n,"))
            ),
            cloudBridgeURL: ClientBridgeConfiguration.normalizedBaseURL(clientCloudBridgeURL),
            token: clientBridgeToken
        )
    }

    private var primaryLocalEndpoint: String {
        if routeStatus.activeKind == .local, let activeURL = routeStatus.activeURL?.absoluteString {
            return activeURL
        }
        return clientConfig.localBridgeURLs.first ?? "Not configured"
    }

    private var cloudEndpoint: String {
        clientConfig.cloudBridgeURL.isEmpty ? "Not configured" : clientConfig.cloudBridgeURL
    }

    private var serverDraftNeedsDownload: Bool {
        serverDraftDownloadSummary != nil
    }

    private var serverDraftDownloadSummary: String? {
        guard let current = draft else { return nil }
        let statuses = current.modelStatuses.reduce(into: [String: BridgeModelStatus]()) { result, status in
            result[status.id] = status
        }
        var missing: [String] = []
        for source in current.enabledSources where source.hasModelConfiguration {
            let modelID = current.asrModelID(for: source.rawValue)
            let status = statuses[BridgeSettingsPayload.modelStatusID(source: source, modelID: modelID)]
            if status?.installed != true {
                missing.append("\(source.displayName) model")
            }
        }
        if let backend = CorrectionBackendKind(rawValue: current.correctionBackend),
           !backend.isExternalCompatible {
            let status = statuses[BridgeSettingsPayload.refineModelStatusID(backend: backend)]
            if status?.installed != true {
                missing.append("\(backend.displayName) refine model")
            }
        }
        guard !missing.isEmpty else { return nil }
        return "Save will start downloading on the server: \(missing.joined(separator: ", "))."
    }

    private func correctionBackendOptions(for current: BridgeSettingsPayload) -> [BridgeSettingOption] {
        current.correctionBackendOptions.isEmpty
            ? [BridgeSettingOption(id: current.correctionBackend, displayName: current.correctionBackend)]
            : current.correctionBackendOptions
    }

    private func serverLanguageGrid(_ options: [ASRLanguageOption]) -> some View {
        LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                serverLanguageToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func serverLanguageToggle(_ option: ASRLanguageOption) -> some View {
        Toggle(isOn: Binding(
            get: { selectedServerLanguageIDs.contains(option.id) },
            set: { setServerLanguage(option, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(serverSourceCoverageText(for: option))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(selectedServerLanguageIDs.contains(option.id) && selectedServerLanguageIDs.count == 1)
    }

    private func clientLanguageGrid(_ options: [ASRLanguageOption]) -> some View {
        LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                clientLanguageToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func clientLanguageToggle(_ option: ASRLanguageOption) -> some View {
        Toggle(isOn: Binding(
            get: { selectedClientLanguageIDs.contains(option.id) },
            set: { setClientLanguage(option, enabled: $0) }
        )) {
            Text(option.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
        .disabled(selectedClientLanguageIDs.contains(option.id) && selectedClientLanguageIDs.count == 1)
    }

    private func setServerLanguage(_ option: ASRLanguageOption, enabled: Bool) {
        var selected = Set(selectedServerLanguageIDs)
        if enabled {
            selected.insert(option.id)
        } else if selected.count > 1 {
            selected.remove(option.id)
        }
        draft?.languageIDs = serverSupportedLanguageOptions.map(\.id).filter { selected.contains($0) }
        normalizeDraft()
    }

    private func setClientLanguage(_ option: ASRLanguageOption, enabled: Bool) {
        var selected = Set(selectedClientLanguageIDs)
        if enabled {
            selected.insert(option.id)
        } else if selected.count > 1 {
            selected.remove(option.id)
        }
        let ordered = clientSupportedLanguageOptions.map(\.id).filter { selected.contains($0) }
        clientLanguageIDsRaw = ASRLanguageSelection.rawValue(
            for: ordered,
            supportedOptions: clientSupportedLanguageOptions
        )
    }

    private func normalizeDraft() {
        guard var current = draft else { return }
        current.normalize()
        draft = current
    }

    private func serverRecognitionSourceBinding(_ source: RecognitionSource) -> Binding<Bool> {
        Binding {
            return draft?.isRecognitionSourceEnabled(source) ?? false
        } set: { enabled in
            if let current = draft,
               enabled,
               serverRecognitionSourceToggleDisabled(source, current: current) {
                return
            }
            draft?.setRecognitionSource(source, enabled: enabled)
            normalizeDraft()
        }
    }

    private func serverRecognitionSourceToggleDisabled(
        _ source: RecognitionSource,
        current: BridgeSettingsPayload
    ) -> Bool {
        guard source == .appleSpeech,
              !current.isRecognitionSourceEnabled(.appleSpeech)
        else { return false }
        return current.sourceAvailability(for: .appleSpeech)?.canEnable != true
    }

    private func serverRecognitionSourceDisabledReason(
        _ source: RecognitionSource,
        current: BridgeSettingsPayload
    ) -> String? {
        guard serverRecognitionSourceToggleDisabled(source, current: current) else { return nil }
        return current.sourceAvailability(for: .appleSpeech)?.reason
    }

    private func serverASRModelBinding(_ source: RecognitionSource) -> Binding<String> {
        Binding {
            guard let draft else { return "" }
            return draft.asrModelID(for: source.rawValue)
        } set: { value in
            draft?.asrModelIDsByRecognitionSource[source.rawValue] = value
            normalizeDraft()
        }
    }

    private func serverSourceCoverageText(for option: ASRLanguageOption) -> String {
        guard let draft else { return "" }
        let names = draft.enabledSources
            .filter { draft.supportedLanguageOptions(for: $0.rawValue).contains(where: { $0.id == option.id }) }
            .map(\.displayName)
        return names.isEmpty ? "No enabled source" : names.joined(separator: ", ")
    }

    @MainActor
    private func checkRoutes() async {
        isChecking = true
        statusMessage = ""
        statusIsError = false
        defer { isChecking = false }
        routeStatus = await ClientBridgeRouteResolver().resolve(
            config: clientConfig,
            probeAllEndpoints: true
        )
        if routeStatus.activeURL != nil {
            statusMessage = "\(routeStatus.activeKind.rawValue) active"
            statusIsError = false
        } else {
            statusMessage = "Bridge unavailable"
            statusIsError = true
        }
    }

    @MainActor
    private func loadSettings(force: Bool) async {
        guard force || draft == nil else { return }
        guard clientConfig.isConfigured else { return }
        isLoading = true
        statusMessage = ""
        statusIsError = false
        defer { isLoading = false }
        do {
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: true)
            routeStatus = resolved.routeStatus
            var settings = try await resolved.client.settings()
            settings.normalize()
            draft = settings
            applyServerDefaults(settings)
            statusMessage = "Pulled from \(resolved.routeStatus.activeKind.rawValue)"
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    @MainActor
    private func saveSettings() async {
        guard var current = draft else { return }
        current.normalize()
        isSaving = true
        statusMessage = ""
        statusIsError = false
        defer { isSaving = false }
        do {
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: true)
            routeStatus = resolved.routeStatus
            var updated = try await resolved.client.updateSettings(current)
            updated.normalize()
            draft = updated
            applyServerDefaults(updated)
            statusMessage = "Saved to \(resolved.routeStatus.activeKind.rawValue)"
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func applyServerDefaults(_ settings: BridgeSettingsPayload) {
        ClientBridgeSettingsSync.applyServerDefaults(settings)
        clientLanguageIDsRaw = UserDefaults.standard.string(forKey: AppSettings.Keys.clientLanguageIDs)
            ?? ASRLanguageSelection.defaultRawValue
    }

    private func endpointState(isConfigured: Bool, isChecked: Bool, isOK: Bool) -> String {
        if !isConfigured { return "Not configured" }
        if isOK { return "Available" }
        return isChecked ? "Unavailable" : "Not checked"
    }

    private func pastePairingJSON() {
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            statusMessage = "Clipboard is empty"
            statusIsError = true
            return
        }
        do {
            let payload = try BridgeJSON.decode(BridgePairingPayload.self, from: data)
            let config = ClientBridgeConfiguration.fromPairingPayload(payload)
            clientLocalBridgeURLsRaw = ClientBridgeConfiguration.rawValue(for: config.localBridgeURLs)
            clientCloudBridgeURL = config.cloudBridgeURL
            clientBridgeToken = config.token
            statusMessage = "Pairing JSON applied"
            statusIsError = false
            Task {
                await checkRoutes()
                await loadSettings(force: true)
            }
        } catch {
            statusMessage = "Couldn't parse pairing JSON"
            statusIsError = true
        }
    }

    private func unpairClient() {
        clientLocalBridgeURLsRaw = ""
        clientCloudBridgeURL = ""
        clientBridgeToken = ""
        draft = nil
        routeStatus = BridgeRouteResolutionStatus()
        statusMessage = "Unpaired"
        statusIsError = false
    }
}

private struct DisclosureRow: View {
    let title: String
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct ClientRouteRow: View {
    let title: String
    let endpoint: String
    let state: String
    let latencyMs: Int?
    let isActive: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.16)))
                            .foregroundStyle(tint)
                    }
                }
                .font(.subheadline.weight(.medium))
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dotColor)
                if let latencyMs {
                    Text("RTT \(latencyMs)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        switch state {
        case "Available":
            return tint
        case "Unavailable":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Dictation Input

struct DictationInputSettingsView: View {
    @AppStorage(AppSettings.Keys.maxRecordingDuration) private var maxDuration: Double = 30
    @AppStorage(AppSettings.Keys.holdModifier)         private var holdModifierRaw: String = HoldModifier.rightOption.rawValue
    @AppStorage(AppSettings.Keys.voiceLivePreview)     private var voiceLivePreview: Bool = true
    @AppStorage(AppSettings.Keys.voiceLivePreviewSource) private var voiceLivePreviewSourceRaw: String = VoiceLivePreviewSource.off.rawValue
    @AppStorage(AppSettings.Keys.processingMode)       private var processingModeRaw: String = ProcessingMode.client.rawValue
    @AppStorage(AppSettings.Keys.clientBridgeEnabledRecognitionSources) private var clientBridgeEnabledRecognitionSourcesRaw: String = ""
    @AppStorage(AppSettings.Keys.asrQwenEnabled)       private var qwenEnabled: Bool = false
    @AppStorage(AppSettings.Keys.asrNvidiaNemotronEnabled) private var nvidiaEnabled: Bool = false
    @AppStorage(AppSettings.Keys.asrAppleSpeechEnabled) private var appleSpeechEnabled: Bool = false
    @AppStorage(AppSettings.Keys.correctionMode)       private var correctionModeRaw: String = CorrectionMode.polishPlus.rawValue
    @AppStorage(AppSettings.Keys.soundFeedback)        private var soundFeedback: Bool = true

    var body: some View {
        Form {
            Section("Feedback") {
                Toggle("Play sounds", isOn: $soundFeedback)
                Text("Short system sounds when recording starts, stops, or fails — so you don't need to look at the HUD to know the mic is live.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Live Transcript") {
                Picker("Preview", selection: previewSourceBinding) {
                    ForEach(VoiceLivePreviewSource.pickerOptions) { source in
                        Text(previewPickerTitle(for: source))
                            .tag(source.rawValue)
                            .disabled(!isPreviewSourceEnabled(source))
                    }
                }
                .pickerStyle(.menu)
                Text(selectedPreviewSource.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(previewHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Hold to talk (double-tap)") {
                HStack(spacing: 12) {
                    Text("Modifier")
                        .frame(minWidth: 90, alignment: .leading)
                    HoldModifierRecorder(selectionRaw: $holdModifierRaw)
                    Spacer()
                    Button("Off") {
                        holdModifierRaw = HoldModifier.none.rawValue
                    }
                    .disabled(selectedHoldModifier == .none)
                }
                Text("Click the recorder, press one modifier key, then use double-tap and HOLD on that key to record. Fn/Globe depends on keyboard hardware; if it cannot be captured, use another modifier or a combo shortcut.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Toggle (combo shortcut)") {
                HStack(spacing: 12) {
                    Text("Shortcut")
                        .frame(minWidth: 90, alignment: .leading)
                    KeyboardShortcuts.Recorder(for: .toggleDictation)
                    Spacer()
                    Button("Reset") { KeyboardShortcuts.reset(.toggleDictation) }
                }
                Text("Press once to start, press again to stop. While transcribing or refining, press again to cancel. Combo (⌘ ⌥ ⌃ ⇧ + key) only — single modifiers belong in the hold section above. Default is ⌘⇧Space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Command selected text") {
                HStack(spacing: 12) {
                    Text("Shortcut")
                        .frame(minWidth: 90, alignment: .leading)
                    KeyboardShortcuts.Recorder(for: .commandTextEdit)
                    Spacer()
                    Button("Reset") { KeyboardShortcuts.reset(.commandTextEdit) }
                }
                Text("Press once to speak an edit command for the current selection. If there is no selection, Typeforme uses the focused text field when Accessibility exposes it. Default is ⌘⌥Space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Recording Limit") {
                HStack {
                    Slider(value: $maxDuration, in: 5...120, step: 5)
                    Text("\(Int(maxDuration))s").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                Text("Auto-stop after this many seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: constrainPreviewSourceToCurrentSources)
        .onChange(of: qwenEnabled) { _, _ in
            constrainPreviewSourceToCurrentSources()
        }
        .onChange(of: nvidiaEnabled) { _, _ in
            constrainPreviewSourceToCurrentSources()
        }
        .onChange(of: appleSpeechEnabled) { _, _ in
            constrainPreviewSourceToCurrentSources()
        }
        .onChange(of: clientBridgeEnabledRecognitionSourcesRaw) { _, _ in
            constrainPreviewSourceToCurrentSources()
        }
        .onChange(of: processingModeRaw) { _, _ in
            constrainPreviewSourceToCurrentSources()
        }
        .onChange(of: correctionModeRaw) { _, _ in
            constrainPreviewSourceToCurrentSources()
        }
    }

    private var selectedHoldModifier: HoldModifier {
        HoldModifier(rawValue: holdModifierRaw) ?? .rightOption
    }

    private var previewSourceOptions: [VoiceLivePreviewSource] {
        if processingMode == .client {
            return VoiceLivePreviewSource.clientOptions(
                forRemoteRecognitionSources: clientBridgeEnabledRecognitionSources,
                correctionMode: selectedCorrectionMode
            )
        }
        return VoiceLivePreviewSource.options(
            forRecognitionSources: enabledRecognitionSources,
            correctionMode: selectedCorrectionMode
        )
    }

    private var selectedPreviewSource: VoiceLivePreviewSource {
        guard voiceLivePreview else { return .off }
        let source = VoiceLivePreviewSource(rawValue: voiceLivePreviewSourceRaw) ?? .off
        return previewSourceOptions.contains(source) ? source : .off
    }

    private var previewSourceBinding: Binding<String> {
        Binding(
            get: { selectedPreviewSource.rawValue },
            set: { rawValue in
                let source = VoiceLivePreviewSource(rawValue: rawValue) ?? .off
                if source == .off {
                    voiceLivePreview = false
                    voiceLivePreviewSourceRaw = VoiceLivePreviewSource.off.rawValue
                } else {
                    guard isPreviewSourceEnabled(source) else { return }
                    voiceLivePreview = true
                    voiceLivePreviewSourceRaw = source.rawValue
                }
            }
        )
    }

    private func constrainPreviewSourceToCurrentSources() {
        let source = VoiceLivePreviewSource(rawValue: voiceLivePreviewSourceRaw) ?? .off
        guard voiceLivePreview, !previewSourceOptions.contains(source) else { return }
        if let preferred = previewSourceOptions.first(where: { $0 != .off }) {
            voiceLivePreviewSourceRaw = preferred.rawValue
        } else {
            voiceLivePreview = false
            voiceLivePreviewSourceRaw = VoiceLivePreviewSource.off.rawValue
        }
    }

    private func isPreviewSourceEnabled(_ source: VoiceLivePreviewSource) -> Bool {
        if processingMode == .client {
            return source.isClientEnabled(
                forRemoteRecognitionSources: clientBridgeEnabledRecognitionSources,
                correctionMode: selectedCorrectionMode
            )
        }
        return source.isEnabled(
            forRecognitionSources: enabledRecognitionSources,
            correctionMode: selectedCorrectionMode
        )
    }

    private func previewPickerTitle(for source: VoiceLivePreviewSource) -> String {
        isPreviewSourceEnabled(source) ? source.displayName : "\(source.displayName) - \(previewDisabledReason)"
    }

    private var previewHelpText: String {
        switch processingMode {
        case .client:
            return "Preview follows the enabled Server ASR sources."
        case .server:
            return "Preview follows enabled ASR sources."
        }
    }

    private var previewDisabledReason: String {
        "Source off"
    }

    private var selectedCorrectionMode: CorrectionMode {
        CorrectionMode(rawValue: correctionModeRaw) ?? .polishPlus
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    private var enabledRecognitionSources: [RecognitionSource] {
        var sources: [RecognitionSource] = []
        if qwenEnabled { sources.append(.qwen) }
        if nvidiaEnabled { sources.append(.nvidiaNemotron) }
        if appleSpeechEnabled { sources.append(.appleSpeech) }
        return RecognitionSource.recognizedSources(sources.map(\.rawValue))
    }

    private var clientBridgeEnabledRecognitionSources: [RecognitionSource] {
        AppSettings.recognitionSources(fromRaw: clientBridgeEnabledRecognitionSourcesRaw)
    }
}

private struct HoldModifierRecorder: View {
    @Binding var selectionRaw: String
    @State private var isRecording = false
    @State private var statusText: String?
    @State private var globalMonitor: Any?
    @State private var localMonitor: Any?

    private var selectedModifier: HoldModifier {
        HoldModifier(rawValue: selectionRaw) ?? .rightOption
    }

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "record.circle" : "keyboard")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isRecording ? "Press modifier" : selectedModifier.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if let statusText {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 240, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isRecording ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press one supported modifier key" : "Click to record a modifier key")
        .accessibilityLabel("Hold modifier recorder")
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        statusText = "Waiting for key..."
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in capture(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in capture(event) }
            return event
        }
    }

    private func stopRecording() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecording = false
    }

    private func capture(_ event: NSEvent) {
        guard isRecording else { return }
        guard let modifier = HoldModifier.detected(from: event) else {
            statusText = "Press one supported modifier"
            return
        }
        selectionRaw = modifier.rawValue
        statusText = "Captured"
        stopRecording()
    }
}

// MARK: - ASR

struct ASRSettingsView: View {
    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @EnvironmentObject private var modelStatusCache: SettingsModelStatusCache
    @AppStorage(AppSettings.Keys.asrQwenEnabled)     private var savedQwenEnabled: Bool = false
    @AppStorage(AppSettings.Keys.asrNvidiaNemotronEnabled) private var savedNvidiaEnabled: Bool = false
    @AppStorage(AppSettings.Keys.asrAppleSpeechEnabled) private var savedAppleSpeechEnabled: Bool = false
    @AppStorage(AppSettings.Keys.asrLanguageIDs)     private var languageIDsRaw: String = ASRLanguageSelection.defaultRawValue
    @AppStorage(AppSettings.Keys.fastASRSource) private var fastASRSourceRaw: String = RecognitionSource.qwen.rawValue
    @AppStorage(AppSettings.Keys.asrNvidiaNemotronTimeoutSec) private var nvidiaTimeoutSec: Double = 40
    @AppStorage(AppSettings.Keys.asrNvidiaNemotronModelID) private var savedNvidiaModelID: String = NvidiaNemotronASRModelCatalog.defaultID
    @AppStorage(AppSettings.Keys.asrQwenLlamaTimeoutSec) private var qwenTimeoutSec: Double = 40
    @AppStorage(AppSettings.Keys.asrQwenLlamaModelID) private var savedQwenModelID: String = QwenASRModelCatalog.defaultID
    @AppStorage(AppSettings.Keys.asrQwenLlamaMaxTokens) private var qwenMaxTokens: Int = 2048
    @AppStorage(AppSettings.Keys.correctionMode) private var correctionModeRaw: String = CorrectionMode.polishPlus.rawValue
    @State private var draftQwenEnabled = false
    @State private var draftNvidiaEnabled = false
    @State private var draftAppleSpeechEnabled = false
    @State private var draftQwenModelID = QwenASRModelCatalog.defaultID
    @State private var draftNvidiaModelID = NvidiaNemotronASRModelCatalog.defaultID
    @State private var draftFastASRSourceRaw = RecognitionSource.qwen.rawValue
    @State private var asrSaveStatus: String?
    @State private var asrSaveIsError = false
    @State private var showAllLanguages = false
    @State private var showAdvanced = false
    @State private var appleSpeechLanguageSupportRevision = 0

    var body: some View {
        Form {
            Section("Recognition Sources") {
                ForEach(visibleRecognitionSources) { source in
                    Toggle(isOn: sourceEnabledBinding(source)) {
                        RecognitionSourceSettingsLabel(
                            title: source.displayName,
                            source: source,
                            detail: source.detail
                        )
                    }
                    .toggleStyle(.switch)
                    .disabled(sourceToggleDisabled(source))
                    if let reason = sourceDisabledReason(source) {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if source == .appleSpeech, draftAppleSpeechEnabled, appleSpeechNeedsPermission {
                        Button {
                            requestAppleSpeechPermission()
                        } label: {
                            Label("Request Speech Recognition", systemImage: "waveform")
                        }
                    }
                }

                Text("Enabled sources run independently. Each source contributes a transcript when it supports at least one selected language.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    if !selectedEnginesInstalled {
                        Label("One or more enabled local ASR models are not installed — download them below before dictating.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 10) {
                    Button("Save ASR") {
                        saveASRDraft()
                    }
                    .disabled(!canSaveASRDraft)
                    Button("Revert") {
                        syncASRDraftFromSettings()
                    }
                    .disabled(!asrDraftIsDirty)
                    if let asrSaveStatus {
                        Text(asrSaveStatus)
                            .font(.caption)
                            .foregroundStyle(asrSaveIsError ? .red : .secondary)
                            .lineLimit(2)
                    } else if let issue = asrDraftReadinessIssue {
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }

            Section("Fast ASR") {
                Picker("Fast source", selection: fastASRSourceBinding) {
                    ForEach(visibleRecognitionSources) { source in
                        Text(source.displayName).tag(source.rawValue)
                            .disabled(!fastSourceIsReady(source))
                    }
                }
                .pickerStyle(.menu)
                if let issue = fastSourceIssue {
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Text("Fast uses only the selected source and skips refine.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if draftQwenEnabled {
                Section("Qwen3-ASR") {
                    Picker("Model", selection: $draftQwenModelID) {
                        ForEach(QwenASRModelCatalog.all) { spec in
                            Text(spec.label).tag(spec.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(selectedQwenModel.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if draftNvidiaEnabled {
                Section("NVIDIA Nemotron") {
                    Picker("Model", selection: $draftNvidiaModelID) {
                        ForEach(NvidiaNemotronASRModelCatalog.all) { spec in
                            Text(spec.label).tag(spec.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(selectedNvidiaModel.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Languages") {
                Text(selectedLanguageSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                languageGrid(commonLanguageOptions)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAllLanguages.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showAllLanguages ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("All languages")
                        Spacer()
                        Text("\(allOtherLanguages.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAllLanguages {
                    languageGrid(allOtherLanguages)
                        .padding(.top, 2)
                }

                Text(languageHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if draftQwenEnabled {
                Section("Qwen3-ASR model") {
                    QwenASRModelRow(spec: selectedQwenModel)
                        .id(selectedQwenModel.id)
                }
            }
            if draftNvidiaEnabled {
                Section("NVIDIA Nemotron model") {
                    NvidiaNemotronASRModelRow(spec: selectedNvidiaModel)
                        .id(selectedNvidiaModel.id)
                }
            }
            Section("Advanced") {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Timeouts and limits")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    IntegerSettingField(
                        title: "ASR timeout",
                        value: Binding(
                            get: { Int(unifiedASRTimeoutSec) },
                            set: {
                                let timeout = Double($0)
                                qwenTimeoutSec = timeout
                                nvidiaTimeoutSec = timeout
                            }
                        ),
                        range: 5...40,
                        suffix: "s"
                    )
                    if draftQwenEnabled {
                        IntegerSettingField(
                            title: "Max transcript tokens",
                            value: $qwenMaxTokens,
                            range: 128...8192,
                            suffix: "tokens"
                        )
                        Text("This caps only Qwen-ASR transcript output. It is not the refine model token limit.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncASRDraftFromSettings()
            normalizeSources()
            refreshSelectedASRModelStatuses()
            refreshAppleSpeechLanguageSupportIfNeeded()
            clampLanguageSelection()
        }
        .task(id: selectedASRStatusSignature) {
            refreshSelectedASRModelStatuses()
        }
        .onChange(of: draftQwenEnabled) { _, _ in
            clearASRSaveStatus()
            clampLanguageSelection()
        }
        .onChange(of: draftNvidiaEnabled) { _, _ in
            clearASRSaveStatus()
            clampLanguageSelection()
        }
        .onChange(of: draftAppleSpeechEnabled) { _, _ in
            normalizeSources()
            refreshAppleSpeechLanguageSupportIfNeeded()
            clampLanguageSelection()
        }
        .onChange(of: draftQwenModelID) { _, _ in clearASRSaveStatus() }
        .onChange(of: draftNvidiaModelID) { _, _ in clearASRSaveStatus() }
        .onChange(of: savedQwenModelID) { _, _ in
            Task { @MainActor in
                await ASRFactory.shared.stopQwenLlama()
                await ASRFactory.shared.preloadCachedActiveModel()
            }
        }
        .onChange(of: savedNvidiaModelID) { _, _ in
            Task { @MainActor in
                ASRFactory.shared.stopNvidiaNemotron()
                await ASRFactory.shared.preloadCachedActiveModel()
            }
        }
        .onChange(of: languageIDsRaw) { _, _ in
            preloadEnabledASRModels()
        }
        .onChange(of: selectedASRDownloadRefreshToken) { _, _ in
            refreshSelectedASRModelStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshSelectedASRModelStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appleSpeechLanguageSupportDidChange)) { _ in
            appleSpeechLanguageSupportRevision &+= 1
            clampLanguageSelection()
        }
    }

    private var selectedSources: [RecognitionSource] {
        var sources: [RecognitionSource] = []
        if draftQwenEnabled { sources.append(.qwen) }
        if draftNvidiaEnabled { sources.append(.nvidiaNemotron) }
        if draftAppleSpeechEnabled { sources.append(.appleSpeech) }
        return RecognitionSource.recognizedSources(sources.map(\.rawValue))
    }

    private var unifiedASRTimeoutSec: Double {
        BridgeSettingsNormalization.clampedASRTimeoutSec(max(qwenTimeoutSec, nvidiaTimeoutSec))
    }

    private var selectedCorrectionMode: CorrectionMode {
        CorrectionMode(rawValue: correctionModeRaw) ?? .polishPlus
    }

    private var visibleRecognitionSources: [RecognitionSource] {
        RecognitionSource.allCases
    }

    private func preloadEnabledASRModels() {
        Task { @MainActor in
            await ASRFactory.shared.preloadCachedActiveModel()
        }
    }

    private var selectedLanguageIDs: [String] {
        ASRLanguageSelection.parse(languageIDsRaw, supportedOptions: supportedLanguageOptions)
    }

    private var selectedQwenModel: QwenASRModelSpec {
        QwenASRModelCatalog.spec(for: draftQwenModelID)
    }

    private var selectedNvidiaModel: NvidiaNemotronASRModelSpec {
        NvidiaNemotronASRModelCatalog.spec(for: draftNvidiaModelID)
    }

    /// Mirrors the install checks the download rows below use, so the Engine
    /// picker can warn about a missing model without scrolling.
    private var selectedEnginesInstalled: Bool {
        if draftQwenEnabled, qwenModelStatusLoaded, !qwenModelInstalled { return false }
        if draftNvidiaEnabled, nvidiaModelStatusLoaded, !nvidiaModelReady { return false }
        return true
    }

    private var asrDraftIsDirty: Bool {
        draftQwenEnabled != savedQwenEnabled
            || draftNvidiaEnabled != savedNvidiaEnabled
            || draftAppleSpeechEnabled != savedAppleSpeechEnabled
            || draftQwenModelID != QwenASRModelCatalog.spec(for: savedQwenModelID).id
            || draftNvidiaModelID != NvidiaNemotronASRModelCatalog.spec(for: savedNvidiaModelID).id
            || draftFastASRSourceRaw != normalizedFastSourceRaw(fastASRSourceRaw)
    }

    private var asrDraftReadinessIssue: String? {
        if RecognitionSource(rawValue: draftFastASRSourceRaw) == nil {
            return "Fast ASR source is invalid."
        }
        if selectedCorrectionMode == .fast, let issue = fastSourceIssue {
            return issue
        }
        if draftAppleSpeechEnabled {
            let report = AppleSpeechAvailability.report(languageIDs: ASRLanguageSelection.parse(languageIDsRaw))
            if !report.ready { return report.reason }
        }
        if draftQwenEnabled, !qwenModelStatusLoaded {
            return "Checking \(selectedQwenModel.label) install status."
        }
        if draftQwenEnabled, !qwenModelInstalled {
            return "\(selectedQwenModel.label) is not installed."
        }
        if draftNvidiaEnabled, !nvidiaModelStatusLoaded {
            return "Checking \(selectedNvidiaModel.label) install status."
        }
        if draftNvidiaEnabled, !nvidiaModelReady {
            return "\(selectedNvidiaModel.label) is not ready."
        }
        return nil
    }

    private var canSaveASRDraft: Bool {
        asrDraftIsDirty && asrDraftReadinessIssue == nil
    }

    private var qwenModelStatusLoaded: Bool {
        modelStatusCache.qwenASRModelLoaded(selectedQwenModel)
    }

    private var qwenModelInstalled: Bool {
        modelStatusCache.qwenASRModelInstalled(selectedQwenModel)
    }

    private var nvidiaModelStatusLoaded: Bool {
        modelStatusCache.nvidiaNemotronSnapshot(selectedNvidiaModel).loaded
    }

    private var nvidiaModelReady: Bool {
        modelStatusCache.nvidiaNemotronSnapshot(selectedNvidiaModel).status.isReady
    }

    private var selectedASRStatusSignature: String {
        let qwen = selectedQwenModel
        let nvidia = selectedNvidiaModel
        let qwenPaths = [
            modelStatusCache.effectivePath(forKey: qwen.modelPathKey, fallback: qwen.defaultModelPath),
            modelStatusCache.effectivePath(forKey: qwen.mmprojPathKey, fallback: qwen.defaultMMProjPath),
        ]
        let nvidiaPaths = nvidia.files.map {
            modelStatusCache.effectivePath(forKey: $0.pathKey, fallback: $0.defaultPath)
        }
        return ([qwen.id] + qwenPaths + [nvidia.id] + nvidiaPaths).joined(separator: "||")
    }

    private var selectedASRDownloadRefreshToken: String {
        let qwen = selectedQwenModel
        let nvidia = selectedNvidiaModel
        let states = [
            settingsDownloaderRefreshToken(modelDownloads.downloader(for: SettingsModelDownloadKey.qwenModel(qwen)).state),
            settingsDownloaderRefreshToken(modelDownloads.downloader(for: SettingsModelDownloadKey.qwenMMProj(qwen)).state),
        ] + nvidia.files.map {
            settingsDownloaderRefreshToken(modelDownloads.downloader(for: SettingsModelDownloadKey.nvidiaNemotronFile(model: nvidia, file: $0)).state)
        }
        return states.joined(separator: "||")
    }

    private func refreshSelectedASRModelStatuses() {
        modelStatusCache.refreshQwenASRModel(selectedQwenModel)
        modelStatusCache.refreshNvidiaNemotronModel(selectedNvidiaModel)
    }

    private var selectedLanguageSummary: String {
        if selectedSources.isEmpty {
            return "No ASR source enabled."
        }
        return "Enabled: " + ASRLanguageSelection
            .displayNames(for: selectedLanguageIDs, supportedOptions: supportedLanguageOptions)
            .joined(separator: ", ")
    }

    private var languageHelpText: String {
        "Each selected language must be covered by at least one enabled source. Unsupported languages are skipped only for sources that cannot handle them."
    }

    private var allOtherLanguages: [ASRLanguageOption] {
        supportedLanguageOptions.filter { !$0.isCommon }
    }

    private var supportedLanguageOptions: [ASRLanguageOption] {
        _ = appleSpeechLanguageSupportRevision
        return ASRLanguageSelection.supportedOptions(for: selectedSources)
    }

    private var commonLanguageOptions: [ASRLanguageOption] {
        _ = appleSpeechLanguageSupportRevision
        return ASRLanguageSelection.commonOptions(for: selectedSources)
    }

    private var languageColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: 10, alignment: .leading)]
    }

    private func languageGrid(_ options: [ASRLanguageOption]) -> some View {
        LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                languageToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func languageToggle(_ option: ASRLanguageOption) -> some View {
        let selected = selectedLanguageIDs.contains(option.id)
        Toggle(isOn: Binding(
            get: { selectedLanguageIDs.contains(option.id) },
            set: { setLanguage(option, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(sourceCoverageText(for: option))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(selected && selectedLanguageIDs.count == 1)
    }

    private func setLanguage(_ option: ASRLanguageOption, enabled: Bool) {
        var selected = Set(selectedLanguageIDs)
        if enabled {
            selected.insert(option.id)
        } else if selected.count > 1 {
            selected.remove(option.id)
        }
        let ordered = supportedLanguageOptions.map(\.id).filter { selected.contains($0) }
        languageIDsRaw = ASRLanguageSelection.rawValue(for: ordered, supportedOptions: supportedLanguageOptions)
    }

    private func normalizeSources() {
        let normalizedSavedQwenModelID = QwenASRModelCatalog.spec(for: savedQwenModelID).id
        if savedQwenModelID != normalizedSavedQwenModelID {
            savedQwenModelID = normalizedSavedQwenModelID
        }
        let normalizedSavedNvidiaModelID = NvidiaNemotronASRModelCatalog.spec(for: savedNvidiaModelID).id
        if savedNvidiaModelID != normalizedSavedNvidiaModelID {
            savedNvidiaModelID = normalizedSavedNvidiaModelID
        }
        draftQwenModelID = QwenASRModelCatalog.spec(for: draftQwenModelID).id
        draftNvidiaModelID = NvidiaNemotronASRModelCatalog.spec(for: draftNvidiaModelID).id
    }

    private func clampLanguageSelection() {
        let normalized = ASRLanguageSelection.rawValue(
            for: selectedLanguageIDs,
            supportedOptions: supportedLanguageOptions
        )
        if languageIDsRaw != normalized {
            languageIDsRaw = normalized
        }
    }

    private func sourceEnabledBinding(_ source: RecognitionSource) -> Binding<Bool> {
        Binding(
            get: {
                switch source {
                case .qwen:
                    return draftQwenEnabled
                case .nvidiaNemotron:
                    return draftNvidiaEnabled
                case .appleSpeech:
                    return draftAppleSpeechEnabled
                }
            },
            set: { enabled in
                if enabled, sourceToggleDisabled(source) { return }
                switch source {
                case .qwen:
                    draftQwenEnabled = enabled
                case .nvidiaNemotron:
                    draftNvidiaEnabled = enabled
                case .appleSpeech:
                    draftAppleSpeechEnabled = enabled
                    AppleSpeechLanguageSupport.refreshInBackgroundIfNeeded()
                }
                normalizeSources()
            }
        )
    }

    private func syncASRDraftFromSettings() {
        draftQwenEnabled = savedQwenEnabled
        draftNvidiaEnabled = savedNvidiaEnabled
        draftAppleSpeechEnabled = savedAppleSpeechEnabled
        draftQwenModelID = QwenASRModelCatalog.spec(for: savedQwenModelID).id
        draftNvidiaModelID = NvidiaNemotronASRModelCatalog.spec(for: savedNvidiaModelID).id
        draftFastASRSourceRaw = normalizedFastSourceRaw(fastASRSourceRaw)
        asrSaveStatus = nil
        asrSaveIsError = false
    }

    private func saveASRDraft() {
        guard asrDraftReadinessIssue == nil else {
            asrSaveStatus = asrDraftReadinessIssue
            asrSaveIsError = true
            return
        }
        savedQwenModelID = QwenASRModelCatalog.spec(for: draftQwenModelID).id
        savedNvidiaModelID = NvidiaNemotronASRModelCatalog.spec(for: draftNvidiaModelID).id
        savedQwenEnabled = draftQwenEnabled
        savedNvidiaEnabled = draftNvidiaEnabled
        savedAppleSpeechEnabled = draftAppleSpeechEnabled
        fastASRSourceRaw = normalizedFastSourceRaw(draftFastASRSourceRaw)
        clampLanguageSelection()
        asrSaveStatus = "ASR settings saved."
        asrSaveIsError = false
        preloadEnabledASRModels()
    }

    private func clearASRSaveStatus() {
        asrSaveStatus = nil
        asrSaveIsError = false
    }

    private func sourceCoverageText(for option: ASRLanguageOption) -> String {
        let names = selectedSources
            .filter { ASRLanguageSelection.effectiveIDs([option.id], for: $0).contains(option.id) }
            .map(\.displayName)
        return names.isEmpty ? "No enabled source" : names.joined(separator: ", ")
    }

    private func refreshAppleSpeechLanguageSupportIfNeeded() {
        guard draftAppleSpeechEnabled || savedAppleSpeechEnabled else { return }
        AppleSpeechLanguageSupport.refreshInBackgroundIfNeeded()
    }

    private var fastASRSourceBinding: Binding<String> {
        Binding {
            draftFastASRSourceRaw
        } set: { value in
            guard let source = RecognitionSource(rawValue: value),
                  fastSourceIsReady(source)
            else { return }
            draftFastASRSourceRaw = source.rawValue
            clearASRSaveStatus()
        }
    }

    private var fastSourceIssue: String? {
        guard let source = RecognitionSource(rawValue: draftFastASRSourceRaw) else {
            return "Fast ASR source is invalid."
        }
        guard selectedSources.contains(source) else {
            return "\(source.displayName) is not enabled."
        }
        let readiness = FastASRRoute.readinessReport(
            for: source,
            languageIDs: selectedLanguageIDs,
            enabledSources: selectedSources
        )
        return readiness.ready ? nil : readiness.reason
    }

    private func fastSourceIsReady(_ source: RecognitionSource) -> Bool {
        guard selectedSources.contains(source) else { return false }
        return FastASRRoute.readinessReport(
            for: source,
            languageIDs: selectedLanguageIDs,
            enabledSources: selectedSources
        ).ready
    }

    private func sourceToggleDisabled(_ source: RecognitionSource) -> Bool {
        guard source == .appleSpeech, !draftAppleSpeechEnabled else { return false }
        return !AppleSpeechAvailability.report(
            languageIDs: ASRLanguageSelection.parse(languageIDsRaw)
        ).canEnable
    }

    private func sourceDisabledReason(_ source: RecognitionSource) -> String? {
        guard source == .appleSpeech, !draftAppleSpeechEnabled else { return nil }
        let report = AppleSpeechAvailability.report(languageIDs: ASRLanguageSelection.parse(languageIDsRaw))
        return report.canEnable ? nil : report.reason
    }

    private var appleSpeechNeedsPermission: Bool {
        AppleSpeechAvailability.report(languageIDs: ASRLanguageSelection.parse(languageIDsRaw)).status == "needs_permission"
    }

    private func requestAppleSpeechPermission() {
        Task { @MainActor in
            _ = await AppPermissions.requestSpeechRecognition()
            appleSpeechLanguageSupportRevision &+= 1
            clearASRSaveStatus()
        }
    }

    private func normalizedFastSourceRaw(_ raw: String) -> String {
        RecognitionSource(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())?.rawValue
            ?? RecognitionSource.qwen.rawValue
    }
}

private enum SettingsModelDownloadKey {
    static func qwenModel(_ spec: QwenASRModelSpec) -> String {
        "asr.qwen.\(spec.id).model"
    }

    static func qwenMMProj(_ spec: QwenASRModelSpec) -> String {
        "asr.qwen.\(spec.id).mmproj"
    }

    static func nvidiaNemotronFile(model: NvidiaNemotronASRModelSpec, file: NvidiaNemotronASRFileSpec) -> String {
        "asr.nvidia-nemotron.\(model.id).\(file.id)"
    }

    static func localLlama(_ spec: LocalLlamaModelSpec) -> String {
        "correction.local-llama.\(spec.id)"
    }
}

@MainActor
private func strictDownloadChecksumPolicy(
    for url: URL,
    label: String,
    downloader: ModelDownloader
) -> ModelDownloadChecksumPolicy? {
    do {
        return try ModelDownloadIntegrity.checksumPolicy(for: url, label: label)
    } catch {
        downloader.fail(error.localizedDescription)
        return nil
    }
}

private func settingsDownloaderRefreshToken(_ state: ModelDownloader.State) -> String {
    switch state {
    case .idle:
        return "idle"
    case .downloading:
        return "downloading"
    case .completed(let url):
        return "completed:\(url.path)"
    case .failed:
        return "failed"
    }
}

private struct QwenASRModelRow: View {
    let spec: QwenASRModelSpec

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @EnvironmentObject private var modelStatusCache: SettingsModelStatusCache
    @AppStorage private var modelPath: String
    @AppStorage private var mmprojPath: String
    @AppStorage private var modelURL: String
    @AppStorage private var mmprojURL: String
    @State private var deleteError: String?

    init(spec: QwenASRModelSpec) {
        self.spec = spec
        self._modelPath = AppStorage(wrappedValue: spec.defaultModelPath, spec.modelPathKey)
        self._mmprojPath = AppStorage(wrappedValue: spec.defaultMMProjPath, spec.mmprojPathKey)
        self._modelURL = AppStorage(wrappedValue: spec.defaultModelURL, spec.modelURLKey)
        self._mmprojURL = AppStorage(wrappedValue: spec.defaultMMProjURL, spec.mmprojURLKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.label).bold()
                    Text(spec.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                combinedStatusLabel
            }
            downloadControls
            if let message = userVisibleProblem {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .task(id: modelStatusSignature) {
            refreshModelStatus()
        }
        .onChange(of: modelDownloadRefreshToken) { _, _ in
            refreshModelStatus()
        }
    }

    @ViewBuilder
    private var combinedStatusLabel: some View {
        if !modelSnapshot.loaded || !mmprojSnapshot.loaded {
            Text("Checking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let installed = modelExists && mmprojExists
            Text(installed ? "Installed" : (anyModelFileExists ? "Incomplete" : "Not installed"))
                .font(.caption)
                .foregroundStyle(installed ? .green : .secondary)
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: 4) {
                downloadProgress(received: aggregateReceivedBytes, total: aggregateTotalBytes)
                Button {
                    modelDownloader.cancel()
                    mmprojDownloader.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        } else {
            HStack {
                Button {
                    startDownloads()
                } label: {
                    Label(modelExists && mmprojExists ? "Reinstall" : "Download", systemImage: "arrow.down.circle")
                }
                .disabled(anyDownloadURLEmpty)
                Button(role: .destructive) {
                    deleteModel()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!modelExists && !mmprojExists)
                Button {
                    revealModelFolder()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                if let why = failureText {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if completedBothDownloads {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
    }

    private func downloadProgress(received: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
            HStack {
                Text("Downloading model: \(format(received)) / \(format(total))")
                    .font(.caption)
                    .monospacedDigit()
                Spacer()
            }
        }
    }

    private func startDownloads() {
        let modelURLString = effectiveModelURLString
        let mmprojURLString = effectiveMMProjURLString
        guard let modelDownloadURL = URL(string: modelURLString),
              let mmprojDownloadURL = URL(string: mmprojURLString)
        else { return }
        deleteError = nil
        Task { @MainActor in
            try? AppPaths.ensureDirectories()
            await ASRFactory.shared.stopQwenLlama()
            guard let modelChecksumPolicy = strictDownloadChecksumPolicy(
                for: modelDownloadURL,
                label: "Qwen3-ASR model",
                downloader: modelDownloader
            ),
                  let mmprojChecksumPolicy = strictDownloadChecksumPolicy(
                    for: mmprojDownloadURL,
                    label: "Qwen3-ASR mmproj",
                    downloader: mmprojDownloader
                  )
            else { return }
            modelDownloader.start(
                from: modelDownloadURL,
                to: URL(fileURLWithPath: effectiveModelPath),
                checksumPolicy: modelChecksumPolicy
            )
            mmprojDownloader.start(
                from: mmprojDownloadURL,
                to: URL(fileURLWithPath: effectiveMMProjPath),
                checksumPolicy: mmprojChecksumPolicy
            )
        }
    }

    private func deleteModel() {
        let targets = [URL(fileURLWithPath: effectiveModelPath), URL(fileURLWithPath: effectiveMMProjPath)]
        deleteError = nil
        Task { @MainActor in
            await ASRFactory.shared.stopQwenLlama()
            do {
                for target in targets where FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                modelDownloader.reset()
                mmprojDownloader.reset()
                refreshModelStatus()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func revealModelFolder() {
        let dir = URL(fileURLWithPath: effectiveModelPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var effectiveModelPath: String {
        modelPath.isEmpty ? spec.defaultModelPath : modelPath
    }

    private var effectiveMMProjPath: String {
        mmprojPath.isEmpty ? spec.defaultMMProjPath : mmprojPath
    }

    private var modelDownloader: ModelDownloader {
        modelDownloads.downloader(for: SettingsModelDownloadKey.qwenModel(spec))
    }

    private var mmprojDownloader: ModelDownloader {
        modelDownloads.downloader(for: SettingsModelDownloadKey.qwenMMProj(spec))
    }

    private var modelSnapshot: SettingsModelFileSnapshot {
        modelStatusCache.fileSnapshot(path: effectiveModelPath)
    }

    private var mmprojSnapshot: SettingsModelFileSnapshot {
        modelStatusCache.fileSnapshot(path: effectiveMMProjPath)
    }

    private var modelExists: Bool {
        modelSnapshot.exists
    }

    private var mmprojExists: Bool {
        mmprojSnapshot.exists
    }

    private var anyModelFileExists: Bool {
        modelExists || mmprojExists
    }

    private var effectiveModelURLString: String {
        let trimmed = modelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultModelURL : trimmed
    }

    private var effectiveMMProjURLString: String {
        let trimmed = mmprojURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultMMProjURL : trimmed
    }

    private var anyDownloadURLEmpty: Bool {
        effectiveModelURLString.isEmpty || effectiveMMProjURLString.isEmpty
    }

    private var isDownloading: Bool {
        if case .downloading = modelDownloader.state { return true }
        if case .downloading = mmprojDownloader.state { return true }
        return false
    }

    private var completedBothDownloads: Bool {
        if case .completed = modelDownloader.state,
           case .completed = mmprojDownloader.state {
            return true
        }
        return false
    }

    private var failureText: String? {
        if case .failed(let why) = modelDownloader.state { return "Model: \(why)" }
        if case .failed(let why) = mmprojDownloader.state { return "mmproj: \(why)" }
        return nil
    }

    private var userVisibleProblem: String? {
        if !(modelExists && mmprojExists), anyModelFileExists {
            return "Qwen3-ASR model is incomplete. Download again or delete it."
        }
        if anyDownloadURLEmpty {
            return "Qwen3-ASR model download URL is missing."
        }
        return nil
    }

    private var aggregateReceivedBytes: Int64 {
        downloaderReceivedBytes(modelDownloader, fallbackPath: effectiveModelPath)
            + downloaderReceivedBytes(mmprojDownloader, fallbackPath: effectiveMMProjPath)
    }

    private var aggregateTotalBytes: Int64 {
        let modelTotal = downloaderTotalBytes(modelDownloader)
        let mmprojTotal = downloaderTotalBytes(mmprojDownloader)
        return modelTotal + mmprojTotal
    }

    private func downloaderReceivedBytes(_ downloader: ModelDownloader, fallbackPath: String) -> Int64 {
        switch downloader.state {
        case .completed:
            return existingByteCount(atPath: fallbackPath)
        case .downloading(let received, _):
            return received
        default:
            return existingByteCount(atPath: fallbackPath)
        }
    }

    private func downloaderTotalBytes(_ downloader: ModelDownloader) -> Int64 {
        switch downloader.state {
        case .downloading(let received, let total):
            return max(received, total)
        default:
            return 0
        }
    }

    private func existingByteCount(atPath path: String) -> Int64 {
        modelStatusCache.fileSnapshot(path: path).byteCount
    }

    private var modelStatusSignature: String {
        [effectiveModelPath, effectiveMMProjPath].joined(separator: "||")
    }

    private var modelDownloadRefreshToken: String {
        [
            settingsDownloaderRefreshToken(modelDownloader.state),
            settingsDownloaderRefreshToken(mmprojDownloader.state),
        ].joined(separator: "||")
    }

    private func refreshModelStatus() {
        modelStatusCache.refreshFiles(paths: [effectiveModelPath, effectiveMMProjPath])
    }
}

private struct NvidiaNemotronASRModelRow: View {
    let spec: NvidiaNemotronASRModelSpec
    let files: [NvidiaNemotronASRFileSpec]

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @EnvironmentObject private var modelStatusCache: SettingsModelStatusCache
    @AppStorage private var encoderPath: String
    @AppStorage private var encoderDataPath: String
    @AppStorage private var decoderJointPath: String
    @AppStorage private var tokenizerPath: String
    @AppStorage private var encoderURL: String
    @AppStorage private var encoderDataURL: String
    @AppStorage private var decoderJointURL: String
    @AppStorage private var tokenizerURL: String
    @State private var deleteError: String?

    init(spec: NvidiaNemotronASRModelSpec) {
        self.spec = spec
        self.files = spec.files
        self._encoderPath = AppStorage(wrappedValue: spec.files[0].defaultPath, spec.files[0].pathKey)
        self._encoderDataPath = AppStorage(wrappedValue: spec.files[1].defaultPath, spec.files[1].pathKey)
        self._decoderJointPath = AppStorage(wrappedValue: spec.files[2].defaultPath, spec.files[2].pathKey)
        self._tokenizerPath = AppStorage(wrappedValue: spec.files[3].defaultPath, spec.files[3].pathKey)
        self._encoderURL = AppStorage(wrappedValue: spec.files[0].defaultURL, spec.files[0].urlKey)
        self._encoderDataURL = AppStorage(wrappedValue: spec.files[1].defaultURL, spec.files[1].urlKey)
        self._decoderJointURL = AppStorage(wrappedValue: spec.files[2].defaultURL, spec.files[2].urlKey)
        self._tokenizerURL = AppStorage(wrappedValue: spec.files[3].defaultURL, spec.files[3].urlKey)
    }

    var body: some View {
        let snapshot = runtimeSnapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.label).bold()
                    Text(spec.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusLabel(snapshot))
                    .font(.caption)
                    .foregroundStyle(statusColor(snapshot))
            }
            downloadControls
            if let message = userVisibleProblem(snapshot) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .task(id: runtimeStatusSignature) {
            refreshRuntimeStatus()
        }
        .onChange(of: downloadRefreshToken) { _, _ in
            refreshRuntimeStatus()
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: 4) {
                downloadProgress(received: aggregateReceivedBytes, total: totalExpectedBytes)
                Button {
                    cancelDownloads()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        } else {
            HStack {
                Button {
                    startDownloads()
                } label: {
                    Label(modelInstalled ? "Reinstall" : "Download", systemImage: "arrow.down.circle")
                }
                .disabled(anyDownloadURLEmpty)
                Button(role: .destructive) {
                    deleteModel()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!anyModelFileExists)
                Button {
                    revealModelFolder()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                if let why = failureText {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if completedAllDownloads {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
    }

    private func downloadProgress(received: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
            HStack {
                Text("Downloading model: \(format(received)) / \(format(total))")
                    .font(.caption)
                    .monospacedDigit()
                Spacer()
            }
        }
    }

    private func startDownloads() {
        deleteError = nil
        Task { @MainActor in
            try? AppPaths.ensureDirectories()
            startDownload(file: files[0], path: effectiveEncoderPath, url: encoderURL, downloader: encoderDownloader)
            startDownload(file: files[1], path: effectiveEncoderDataPath, url: encoderDataURL, downloader: encoderDataDownloader)
            startDownload(file: files[2], path: effectiveDecoderJointPath, url: decoderJointURL, downloader: decoderJointDownloader)
            startDownload(file: files[3], path: effectiveTokenizerPath, url: tokenizerURL, downloader: tokenizerDownloader)
        }
    }

    private func startDownload(file: NvidiaNemotronASRFileSpec, path: String, url: String, downloader: ModelDownloader) {
        guard let downloadURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        guard let checksumPolicy = strictDownloadChecksumPolicy(
            for: downloadURL,
            label: file.label,
            downloader: downloader
        ) else { return }
        downloader.start(
            from: downloadURL,
            to: URL(fileURLWithPath: path),
            checksumPolicy: checksumPolicy,
            expectedBytes: file.expectedBytes
        )
    }

    private func cancelDownloads() {
        encoderDownloader.cancel()
        encoderDataDownloader.cancel()
        decoderJointDownloader.cancel()
        tokenizerDownloader.cancel()
    }

    private func deleteModel() {
        deleteError = nil
        Task { @MainActor in
            do {
                for path in effectiveModelPaths {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                encoderDownloader.reset()
                encoderDataDownloader.reset()
                decoderJointDownloader.reset()
                tokenizerDownloader.reset()
                refreshRuntimeStatus()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func revealModelFolder() {
        let dir = URL(fileURLWithPath: effectiveEncoderPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private var runtimeSnapshot: SettingsNemotronRuntimeSnapshot {
        modelStatusCache.nvidiaNemotronSnapshot(spec, paths: effectiveModelPaths)
    }

    private var effectiveEncoderPath: String { effectivePath(encoderPath, fallback: files[0].defaultPath) }
    private var effectiveEncoderDataPath: String { effectivePath(encoderDataPath, fallback: files[1].defaultPath) }
    private var effectiveDecoderJointPath: String { effectivePath(decoderJointPath, fallback: files[2].defaultPath) }
    private var effectiveTokenizerPath: String { effectivePath(tokenizerPath, fallback: files[3].defaultPath) }

    private var effectiveModelPaths: [String] {
        [effectiveEncoderPath, effectiveEncoderDataPath, effectiveDecoderJointPath, effectiveTokenizerPath]
    }

    private var encoderDownloader: ModelDownloader {
        downloader(for: files[0])
    }

    private var encoderDataDownloader: ModelDownloader {
        downloader(for: files[1])
    }

    private var decoderJointDownloader: ModelDownloader {
        downloader(for: files[2])
    }

    private var tokenizerDownloader: ModelDownloader {
        downloader(for: files[3])
    }

    private func downloader(for file: NvidiaNemotronASRFileSpec) -> ModelDownloader {
        modelDownloads.downloader(for: SettingsModelDownloadKey.nvidiaNemotronFile(model: spec, file: file))
    }

    private var modelInstalled: Bool {
        runtimeSnapshot.loaded && runtimeSnapshot.status.isReady
    }

    private var anyModelFileExists: Bool {
        runtimeSnapshot.anyModelFileExists
    }

    private var anyDownloadURLEmpty: Bool {
        [encoderURL, encoderDataURL, decoderJointURL, tokenizerURL]
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isDownloading: Bool {
        if case .downloading = encoderDownloader.state { return true }
        if case .downloading = encoderDataDownloader.state { return true }
        if case .downloading = decoderJointDownloader.state { return true }
        if case .downloading = tokenizerDownloader.state { return true }
        return false
    }

    private var completedAllDownloads: Bool {
        if case .completed = encoderDownloader.state,
           case .completed = encoderDataDownloader.state,
           case .completed = decoderJointDownloader.state,
           case .completed = tokenizerDownloader.state {
            return true
        }
        return false
    }

    private var failureText: String? {
        if case .failed(let why) = encoderDownloader.state { return "Download failed: \(why)" }
        if case .failed(let why) = encoderDataDownloader.state { return "Download failed: \(why)" }
        if case .failed(let why) = decoderJointDownloader.state { return "Download failed: \(why)" }
        if case .failed(let why) = tokenizerDownloader.state { return "Download failed: \(why)" }
        return nil
    }

    private var totalExpectedBytes: Int64 {
        files.map(\.expectedBytes).reduce(0, +)
    }

    private var aggregateReceivedBytes: Int64 {
        let snapshot = runtimeSnapshot
        return zip(files, [encoderDownloader, encoderDataDownloader, decoderJointDownloader, tokenizerDownloader])
            .map { file, downloader in
                switch downloader.state {
                case .completed:
                    return file.expectedBytes
                case .downloading(let received, _):
                    return received
                default:
                    return snapshot.status.modelFiles.first { $0.spec.id == file.id }?.installed == true
                        ? file.expectedBytes
                        : snapshot.byteCount(for: file)
                }
            }
            .reduce(0, +)
    }

    private func statusLabel(_ snapshot: SettingsNemotronRuntimeSnapshot) -> String {
        guard snapshot.loaded else { return "Checking..." }
        let status = snapshot.status
        if !status.runnerReady { return "Runtime missing" }
        if status.isReady { return "Installed" }
        if anyModelFileExists { return "Incomplete" }
        return "Not installed"
    }

    private func statusColor(_ snapshot: SettingsNemotronRuntimeSnapshot) -> Color {
        guard snapshot.loaded else { return .secondary }
        let status = snapshot.status
        if status.isReady { return .green }
        if !status.runnerReady { return .red }
        return .secondary
    }

    private func userVisibleProblem(_ snapshot: SettingsNemotronRuntimeSnapshot) -> String? {
        guard snapshot.loaded else { return nil }
        let status = snapshot.status
        if !status.runnerReady {
            return "Nemotron runtime is missing from the app bundle. Rebuild the app and try again."
        }
        if !status.isReady && anyModelFileExists {
            return "Nemotron model is incomplete. Download again or delete it."
        }
        if anyDownloadURLEmpty {
            return "Nemotron model download URL is missing."
        }
        return nil
    }

    private func effectivePath(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private var runtimeStatusSignature: String {
        ([spec.id] + effectiveModelPaths).joined(separator: "||")
    }

    private var downloadRefreshToken: String {
        [
            settingsDownloaderRefreshToken(encoderDownloader.state),
            settingsDownloaderRefreshToken(encoderDataDownloader.state),
            settingsDownloaderRefreshToken(decoderJointDownloader.state),
            settingsDownloaderRefreshToken(tokenizerDownloader.state),
        ].joined(separator: "||")
    }

    private func refreshRuntimeStatus() {
        modelStatusCache.refreshNvidiaNemotronModel(spec, paths: effectiveModelPaths)
    }

    private func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

}

// MARK: - Correction

private struct ExternalLLMDraftConfig: Equatable {
    let backendRaw: String
    let baseURL: String
    let apiKey: String
    let model: String
}

struct CorrectionSettingsView: View {
    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @EnvironmentObject private var modelStatusCache: SettingsModelStatusCache
    @AppStorage(AppSettings.Keys.correctionBackend)       private var savedBackendRaw: String = CorrectionBackendKind.qwen35_4B.rawValue
    @AppStorage(AppSettings.Keys.correctionTimeoutMs)     private var timeoutMs: Int = 1500
    @AppStorage(AppSettings.Keys.correctionColdTimeoutMs) private var coldTimeoutMs: Int = 30000
    @AppStorage(AppSettings.Keys.correctionMaxTokens)     private var maxTokens: Int = 128
    @AppStorage(AppSettings.Keys.correctionContextSize)   private var contextSize: Int = 4096
    @AppStorage(AppSettings.Keys.correctionMode)   private var correctionModeRaw: String = CorrectionMode.polishPlus.rawValue
    @AppStorage(AppSettings.Keys.asrQwenEnabled)   private var qwenEnabled: Bool = false
    @AppStorage(AppSettings.Keys.processingMode)   private var processingModeRaw: String = ProcessingMode.client.rawValue
    @AppStorage(AppSettings.Keys.clientBridgeEnabledRecognitionSources) private var clientBridgeEnabledRecognitionSourcesRaw: String = ""
    @AppStorage(AppSettings.Keys.numberOutputPreference)  private var numberOutputPreferenceRaw: String = NumberOutputPreference.automatic.rawValue
    @AppStorage(AppSettings.Keys.punctuationPreference)   private var punctuationPreferenceRaw: String = PunctuationOutputPreference.normal.rawValue
    @AppStorage(AppSettings.Keys.externalLLMBaseURL)      private var savedExternalLLMBaseURL: String = "http://127.0.0.1:1234"
    @AppStorage(AppSettings.Keys.externalLLMModel)        private var savedExternalLLMModel: String = ""
    @State private var draftBackendRaw: String = CorrectionBackendKind.qwen35_4B.rawValue
    @State private var draftExternalLLMBaseURL: String = "http://127.0.0.1:1234"
    @State private var draftExternalLLMModel: String = ""
    @State private var draftExternalLLMAPIKey: String = AppSettings.externalLLMAPIKey
    @State private var showAdvanced = false
    @State private var modelLoadStatus: String?
    @State private var modelLoadIsError = false
    @State private var loadingBackendRaw: String?
    @State private var isCheckingExternalLLM = false
    @State private var externalLLMStatus = "Not checked"
    @State private var externalLLMDetail = "Configure an OpenAI-compatible or Anthropic-compatible server, then refresh models."
    @State private var externalLLMModels: [String] = []
    @State private var checkedExternalLLMConfig: ExternalLLMDraftConfig?
    @State private var suppressNextExternalLLMModelReset = false
    @State private var externalLLMCheckTask: Task<Void, Never>?
    @State private var externalLLMCheckID = UUID()

    private let selectableBackends: [CorrectionBackendKind] = [
        .qwen35_2B,
        .qwen35_4B,
        .qwen35_9B,
        .externalOpenAICompatible,
        .externalAnthropicCompatible,
    ]

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Refine engine", selection: $draftBackendRaw) {
                    ForEach(selectableBackends, id: \.rawValue) { kind in
                        Text(backendLabel(kind)).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if let issue = correctionDraftReadinessIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button("Save Refine") {
                        saveCorrectionDraft()
                    }
                    .disabled(!canSaveCorrectionDraft)
                    Button("Revert") {
                        syncCorrectionDraftFromSettings()
                    }
                    .disabled(!correctionDraftIsDirty)
                    if let modelLoadStatus {
                        HStack(spacing: 6) {
                            if loadingBackendRaw != nil {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(modelLoadStatus)
                                .font(.caption)
                                .foregroundStyle(modelLoadIsError ? .red : .secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
            if selectedBackendKind?.isExternalCompatible == true {
                Section("External correction server") {
                    TextField("Base URL", text: $draftExternalLLMBaseURL)
                        .textFieldStyle(.roundedBorder)
                    if externalLLMPickerModels.isEmpty {
                        TextField("Model ID", text: $draftExternalLLMModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $draftExternalLLMModel) {
                            if draftExternalLLMModel.isEmpty {
                                Text("Select a model").tag("")
                            }
                            ForEach(externalLLMPickerModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    SecureField("API key (optional)", text: $draftExternalLLMAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Circle()
                            .fill(externalLLMColor)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(externalLLMStatus)
                            Text(externalLLMDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }

                    HStack {
                        Button {
                            startExternalLLMCheck(selectFirstModel: draftExternalLLMModel.isEmpty)
                        } label: {
                            Label(isCheckingExternalLLM ? "Checking" : "Refresh Models", systemImage: "arrow.clockwise")
                        }
                        .disabled(isCheckingExternalLLM)
                    }

                    Text("Uses any reachable compatible server URL, including LAN URLs. Typeforme adds /v1/chat/completions for OpenAI-compatible requests and /v1/messages for Anthropic-compatible requests.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Output") {
                Picker("Mode", selection: correctionModeBinding) {
                    ForEach(CorrectionMode.allCases, id: \.rawValue) { mode in
                        Text(correctionModeTitle(mode)).tag(mode.rawValue)
                            .disabled(!isCorrectionModeEnabled(mode))
                    }
                }
                .pickerStyle(.menu)
                Text(correctionModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Numbers", selection: $numberOutputPreferenceRaw) {
                    ForEach(NumberOutputPreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text(numberOutputPreferenceDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Punctuation", selection: $punctuationPreferenceRaw) {
                    ForEach(PunctuationOutputPreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text(punctuationPreferenceDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Local LLM models (Qwen3.5 via llama.cpp)") {
                ForEach(localLlamaModels) { spec in
                    ModelDownloadRow(
                        spec: spec,
                        isSelected: draftBackendRaw == spec.backendKind.rawValue
                    )
                    if spec.id != (localLlamaModels.last?.id ?? "") {
                        Divider()
                    }
                }
            }
            Section("Advanced") {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Timing and generation limits")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    IntegerSettingField(title: "Normal timeout", value: $timeoutMs, range: 200...30000, suffix: "ms")
                    if let timeoutHint = effectiveTimeoutHint {
                        Text(timeoutHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    IntegerSettingField(title: "Model startup timeout", value: $coldTimeoutMs, range: 1000...60000, suffix: "ms")
                    IntegerSettingField(title: "Max output tokens", value: $maxTokens, range: 32...512, suffix: "tokens")
                    IntegerSettingField(title: "Context size", value: $contextSize, range: 1024...8192, suffix: "tokens")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncCorrectionDraftFromSettings()
            normalizeBackendSelection()
            refreshSelectedCorrectionModelStatus()
            if selectedBackendKind?.isExternalCompatible == true {
                startExternalLLMCheck(selectFirstModel: draftExternalLLMModel.isEmpty)
            }
        }
        .task(id: selectedCorrectionModelStatusSignature) {
            refreshSelectedCorrectionModelStatus()
        }
        .onDisappear {
            cancelExternalLLMCheck()
        }
        .onChange(of: draftBackendRaw) { _, _ in
            normalizeBackendSelection()
            resetDraftModelStatus()
            if selectedBackendKind?.isExternalCompatible == true {
                resetExternalLLMCheck(detail: "Refresh models before saving this external backend.")
            }
        }
        .onChange(of: draftExternalLLMBaseURL) { _, _ in
            resetExternalLLMCheck(detail: "Refresh models after changing the server URL.")
        }
        .onChange(of: draftExternalLLMModel) { _, _ in
            if suppressNextExternalLLMModelReset {
                suppressNextExternalLLMModelReset = false
                return
            }
            handleExternalLLMModelSelectionChange()
        }
        .onChange(of: selectedCorrectionDownloadRefreshToken) { _, _ in
            refreshSelectedCorrectionModelStatus()
        }
        .onChange(of: draftExternalLLMAPIKey) { _, _ in
            resetExternalLLMCheck(detail: "Refresh models after changing the API key.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshSelectedCorrectionModelStatus()
        }
    }

    private func backendLabel(_ kind: CorrectionBackendKind) -> String {
        kind.displayName
    }

    private var selectedBackendKind: CorrectionBackendKind? {
        CorrectionBackendKind(rawValue: draftBackendRaw)
    }

    private var correctionModeDescription: String {
        (CorrectionMode(rawValue: correctionModeRaw) ?? .polishPlus).helpText
    }

    private var correctionModeBinding: Binding<String> {
        Binding {
            correctionModeRaw
        } set: { value in
            guard let mode = CorrectionMode(rawValue: value),
                  isCorrectionModeEnabled(mode)
            else { return }
            correctionModeRaw = value
        }
    }

    private func isCorrectionModeEnabled(_ mode: CorrectionMode) -> Bool {
        AppSettings.isCorrectionModeAvailable(mode)
    }

    private func correctionModeTitle(_ mode: CorrectionMode) -> String {
        mode.displayName
    }

    private var enabledRecognitionSources: [RecognitionSource] {
        if processingMode == .client {
            return AppSettings.recognitionSources(fromRaw: clientBridgeEnabledRecognitionSourcesRaw)
        }
        var sources: [RecognitionSource] = []
        if qwenEnabled { sources.append(.qwen) }
        return AppSettings.normalizedServerRecognitionSources(sources)
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    private var numberOutputPreferenceDescription: String {
        NumberOutputPreference.normalized(numberOutputPreferenceRaw).helpText
    }

    private var punctuationPreferenceDescription: String {
        PunctuationOutputPreference.normalized(punctuationPreferenceRaw).helpText
    }

    private var effectiveTimeoutHint: String? {
        if selectedBackendKind?.isExternalCompatible == true,
           timeoutMs < ExternalCompatibleCorrectorService.minimumRequestTimeoutMs {
            return "External compatible requests use at least \(ExternalCompatibleCorrectorService.minimumRequestTimeoutMs) ms."
        }
        return nil
    }

    private var correctionDraftIsDirty: Bool {
        draftBackendRaw != savedBackendRaw
            || draftExternalLLMBaseURL != savedExternalLLMBaseURL
            || draftExternalLLMModel != savedExternalLLMModel
            || draftExternalLLMAPIKey != AppSettings.externalLLMAPIKey
    }

    private var correctionDraftReadinessIssue: String? {
        guard let kind = selectedBackendKind else {
            return "Choose a refine engine."
        }
        if kind.isExternalCompatible {
            let selectedModel = draftExternalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedModel.isEmpty {
                return "Select a listed external model before saving."
            }
            if checkedExternalLLMConfig != currentExternalLLMConfig || externalLLMStatus != "Ready" {
                return "Refresh models and verify the selected external model before saving."
            }
            if !externalLLMModels.isEmpty, !externalLLMModels.contains(selectedModel) {
                return "\(selectedModel) is not listed by the external server."
            }
            return nil
        }
        guard localDraftModelStatusLoaded else {
            return "Checking \(kind.displayName) install status."
        }
        guard localDraftModelInstalled else {
            return "\(kind.displayName) is not installed."
        }
        return nil
    }

    private var canSaveCorrectionDraft: Bool {
        correctionDraftIsDirty && correctionDraftReadinessIssue == nil && !isCheckingExternalLLM
    }

    private var currentExternalLLMConfig: ExternalLLMDraftConfig {
        ExternalLLMDraftConfig(
            backendRaw: draftBackendRaw,
            baseURL: draftExternalLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: draftExternalLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: draftExternalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var selectedLocalLlamaSpec: LocalLlamaModelSpec? {
        localLlamaModels.first { $0.backendKind.rawValue == draftBackendRaw }
    }

    private var localDraftModelStatusLoaded: Bool {
        guard let spec = selectedLocalLlamaSpec else {
            return false
        }
        return modelStatusCache.localLlamaSnapshot(spec).loaded
    }

    private var localDraftModelInstalled: Bool {
        guard let spec = selectedLocalLlamaSpec else {
            return false
        }
        return modelStatusCache.localLlamaSnapshot(spec).exists
    }

    private var selectedCorrectionModelStatusSignature: String {
        guard let spec = selectedLocalLlamaSpec else {
            return draftBackendRaw
        }
        let path = modelStatusCache.effectivePath(forKey: spec.pathKey, fallback: spec.defaultPath)
        return [draftBackendRaw, path].joined(separator: "||")
    }

    private var selectedCorrectionDownloadRefreshToken: String {
        guard let spec = selectedLocalLlamaSpec else {
            return "external"
        }
        return settingsDownloaderRefreshToken(
            modelDownloads.downloader(for: SettingsModelDownloadKey.localLlama(spec)).state
        )
    }

    private func refreshSelectedCorrectionModelStatus() {
        guard let spec = selectedLocalLlamaSpec else { return }
        modelStatusCache.refreshLocalLlamaModel(spec)
    }

    private func normalizeBackendSelection() {
        guard let kind = CorrectionBackendKind(rawValue: draftBackendRaw),
              selectableBackends.contains(kind) else {
            draftBackendRaw = CorrectionBackendKind.qwen35_4B.rawValue
            return
        }
    }

    private func syncCorrectionDraftFromSettings() {
        draftBackendRaw = CorrectionBackendKind(rawValue: savedBackendRaw)?.rawValue
            ?? CorrectionBackendKind.qwen35_4B.rawValue
        draftExternalLLMBaseURL = savedExternalLLMBaseURL
        draftExternalLLMModel = savedExternalLLMModel
        draftExternalLLMAPIKey = AppSettings.externalLLMAPIKey
        resetDraftModelStatus()
        if selectedBackendKind?.isExternalCompatible == true {
            resetExternalLLMCheck(detail: "Refresh models before saving this external backend.")
        }
    }

    private func saveCorrectionDraft() {
        guard correctionDraftReadinessIssue == nil else {
            modelLoadStatus = correctionDraftReadinessIssue
            modelLoadIsError = true
            return
        }
        savedExternalLLMBaseURL = draftExternalLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        savedExternalLLMModel = draftExternalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.setExternalLLMAPIKey(draftExternalLLMAPIKey)
        savedBackendRaw = draftBackendRaw
        preloadSavedBackend()
    }

    private func resetDraftModelStatus() {
        modelLoadStatus = nil
        modelLoadIsError = false
        loadingBackendRaw = nil
    }

    private func preloadSavedBackend() {
        guard let kind = CorrectionBackendKind(rawValue: savedBackendRaw) else { return }
        let raw = savedBackendRaw
        loadingBackendRaw = raw
        modelLoadIsError = false
        modelLoadStatus = kind.isExternalCompatible
            ? "Refine settings saved."
            : "Preparing \(backendLabel(kind))..."
        Task { @MainActor in
            await CorrectorFactory.shared.shutdownAll()
            if kind.isExternalCompatible {
                guard savedBackendRaw == raw else { return }
                loadingBackendRaw = nil
                modelLoadStatus = "Refine settings saved."
                modelLoadIsError = false
                return
            }
            let result = await CorrectorFactory.shared.preloadActiveModels()
            guard savedBackendRaw == raw else { return }
            loadingBackendRaw = nil
            modelLoadIsError = !result.isReady
            modelLoadStatus = result.isReady
                ? "Refine settings saved. \(result.message)"
                : "Load failed for \(backendLabel(kind)): \(result.message)"
        }
    }

    private var externalLLMColor: Color {
        if isCheckingExternalLLM { return .orange }
        if externalLLMStatus == "Ready" { return .green }
        if externalLLMStatus == "Failed" { return .red }
        return .secondary
    }

    private var externalLLMPickerModels: [String] {
        var models = externalLLMModels
        if !draftExternalLLMModel.isEmpty && !models.contains(draftExternalLLMModel) {
            models.insert(draftExternalLLMModel, at: 0)
        }
        return models
    }

    @MainActor
    private func startExternalLLMCheck(selectFirstModel: Bool) {
        externalLLMCheckTask?.cancel()
        guard let kind = selectedBackendKind,
              let apiKind = try? ExternalCompatibleCorrectorService.apiKind(for: kind)
        else { return }
        let checkID = UUID()
        let baseURL = draftExternalLLMBaseURL
        let apiKey = draftExternalLLMAPIKey
        let model = draftExternalLLMModel
        externalLLMCheckID = checkID
        isCheckingExternalLLM = true
        externalLLMStatus = "Checking"
        externalLLMDetail = baseURL
        checkedExternalLLMConfig = nil
        externalLLMCheckTask = Task {
            let report = await ExternalCompatibleCorrectorService.checkConfiguration(
                apiKind: apiKind,
                baseURL: baseURL,
                apiKey: apiKey,
                selectedModel: model
            )
            await MainActor.run {
                guard externalLLMCheckID == checkID else { return }
                externalLLMCheckTask = nil
                isCheckingExternalLLM = false
                applyExternalLLMReport(report, selectFirstModel: selectFirstModel)
                checkedExternalLLMConfig = report.ok ? currentExternalLLMConfig : nil
                modelLoadIsError = !report.ok
                modelLoadStatus = report.ok ? "\(kind.displayName) server is reachable." : "\(kind.displayName) server is not ready."
            }
        }
    }

    @MainActor
    private func resetExternalLLMCheck(detail: String) {
        cancelExternalLLMCheck()
        externalLLMModels = []
        checkedExternalLLMConfig = nil
        externalLLMStatus = "Not checked"
        externalLLMDetail = detail
    }

    @MainActor
    private func cancelExternalLLMCheck() {
        externalLLMCheckTask?.cancel()
        externalLLMCheckTask = nil
        externalLLMCheckID = UUID()
        isCheckingExternalLLM = false
    }

    private func handleExternalLLMModelSelectionChange() {
        let selected = draftExternalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, externalLLMModels.contains(selected) {
            checkedExternalLLMConfig = currentExternalLLMConfig
            externalLLMStatus = "Ready"
            externalLLMDetail = "Selected \(selected)."
            modelLoadStatus = "\(selectedBackendKind?.displayName ?? "External") server is reachable."
            modelLoadIsError = false
            return
        }
        resetExternalLLMCheck(detail: "Refresh models after changing the selected model.")
    }

    private func applyExternalLLMReport(_ report: ExternalLLMCheckReport, selectFirstModel: Bool) {
        externalLLMStatus = report.status
        externalLLMDetail = report.detail
        externalLLMModels = report.modelIDs
        if report.ok {
            let previousModel = draftExternalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let refreshedModel = ExternalCompatibleCorrectorService.modelSelectionAfterRefresh(
                current: draftExternalLLMModel,
                available: report.modelIDs,
                selectFirstModel: selectFirstModel
            )
            if refreshedModel != draftExternalLLMModel {
                suppressNextExternalLLMModelReset = true
                draftExternalLLMModel = refreshedModel
                if previousModel.isEmpty {
                    externalLLMDetail = "Selected \(refreshedModel). \(report.detail)"
                } else {
                    externalLLMDetail = "Previous model \(previousModel) is not listed. Switched to \(refreshedModel)."
                }
            }
        }
    }
}

/// One row for an embedded llama model. The UI treats the model as one
/// installable unit; path and URL settings remain internal configuration.
private struct ModelDownloadRow: View {
    let spec: LocalLlamaModelSpec
    let isSelected: Bool

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @EnvironmentObject private var modelStatusCache: SettingsModelStatusCache
    @AppStorage private var path: String
    @AppStorage private var url:  String
    @State private var deleteError: String?

    init(spec: LocalLlamaModelSpec, isSelected: Bool) {
        self.spec = spec
        self.isSelected = isSelected
        self._path = AppStorage(wrappedValue: spec.defaultPath, spec.pathKey)
        self._url  = AppStorage(wrappedValue: "", spec.urlKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.label).bold()
                        if isSelected {
                            Text("Selected")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(spec.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel
            }
            downloadControls
            if let message = userVisibleProblem {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .task(id: modelStatusSignature) {
            refreshModelStatus()
        }
        .onChange(of: modelDownloadRefreshToken) { _, _ in
            refreshModelStatus()
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var statusLabel: some View {
        let snapshot = modelSnapshot
        if !snapshot.loaded {
            Text("Checking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(snapshot.exists ? "Installed (\(ByteCountFormatter.string(fromByteCount: snapshot.byteCount, countStyle: .file)))"
                               : "Not installed")
                .font(.caption)
                .foregroundStyle(snapshot.exists ? .green : .secondary)
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch downloader.state {
        case .idle, .completed, .failed:
            HStack {
                Button {
                    startDownload()
                } label: {
                    Label(
                        modelExists ? "Reinstall" : "Download",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(effectiveURLString.isEmpty)
                Button(role: .destructive) {
                    deleteModel()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!modelExists || isDownloading)
                Button {
                    revealModelFolder()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                if case .failed(let why) = downloader.state {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if case .completed = downloader.state {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                HStack {
                    Text("Downloading model: \(format(received)) / \(format(total))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { downloader.cancel() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Actions

    private func startDownload() {
        let trimmed = effectiveURLString
        guard let u = URL(string: trimmed) else { return }
        let dest = URL(fileURLWithPath: effectivePath)
        deleteError = nil
        Task { @MainActor in
            try? AppPaths.ensureDirectories()
            await CorrectorFactory.shared.shutdownAll()
            guard let checksumPolicy = strictDownloadChecksumPolicy(
                for: u,
                label: spec.label,
                downloader: downloader
            ) else { return }
            downloader.start(
                from: u,
                to: dest,
                checksumPolicy: checksumPolicy
            )
        }
    }

    private func deleteModel() {
        let target = URL(fileURLWithPath: effectivePath)
        deleteError = nil
        Task { @MainActor in
            await CorrectorFactory.shared.shutdownAll()
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                downloader.reset()
                refreshModelStatus()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func revealModelFolder() {
        let dir = URL(fileURLWithPath: effectivePath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var effectivePath: String {
        path.isEmpty ? spec.defaultPath : path
    }

    private var effectiveURLString: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var downloader: ModelDownloader {
        modelDownloads.downloader(for: SettingsModelDownloadKey.localLlama(spec))
    }

    private var modelSnapshot: SettingsModelFileSnapshot {
        modelStatusCache.fileSnapshot(path: effectivePath)
    }

    private var modelExists: Bool {
        modelSnapshot.exists
    }

    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        return false
    }

    private var userVisibleProblem: String? {
        if effectiveURLString.isEmpty {
            return "Model download URL is missing."
        }
        return nil
    }

    private var modelStatusSignature: String {
        effectivePath
    }

    private var modelDownloadRefreshToken: String {
        settingsDownloaderRefreshToken(downloader.state)
    }

    private func refreshModelStatus() {
        modelStatusCache.refreshFile(path: effectivePath)
    }
}

// MARK: - Prompts

/// In-app editor for the base system prompt and per-mode addendum.
struct PromptsSettingsView: View {
    @AppStorage(AppSettings.Keys.promptAdditionalSystem) private var additionalSystemPrompt: String = ""
    @State private var correctionMode: CorrectionMode = .polishPlus
    @State private var systemPromptText: String = ""
    @State private var originalSystemPromptText: String = ""
    @State private var systemHasOverride: Bool = false
    @State private var modePromptText: String = ""
    @State private var originalModePromptText: String = ""
    @State private var modePromptHasOverride: Bool = false
    /// Unsaved per-mode edits, keyed by mode. Switching the mode picker
    /// stashes the current editor text here and restores it on the way back,
    /// so flipping between modes can't silently discard work.
    @State private var modeDrafts: [CorrectionMode: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                promptHeader(
                    title: "System prompt",
                    hasOverride: systemHasOverride,
                    isDirty: systemIsDirty,
                    reset: resetSystemOverride
                )

                promptEditor(text: $systemPromptText, minHeight: 160)

                HStack(alignment: .top) {
                    Text("Global correction contract. This file is shared by all correction modes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { saveSystemOverride() }
                        .disabled(!systemIsDirty || trimmed(systemPromptText).isEmpty)
                }

                Divider()

                Picker("Mode", selection: $correctionMode) {
                    ForEach(CorrectionMode.promptEditableCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                promptHeader(
                    title: "Mode prompt",
                    hasOverride: modePromptHasOverride,
                    isDirty: modeIsDirty,
                    reset: resetModeOverride
                )

                promptEditor(text: $modePromptText, minHeight: 110)

                HStack(alignment: .top) {
                    Text("Only the selected mode behavior. Save writes \(PromptOverrideStore.modePromptFile(for: correctionMode).lastPathComponent).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { saveModeOverride() }
                        .disabled(!modeIsDirty || trimmed(modePromptText).isEmpty)
                }

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(trimmed(additionalSystemPrompt).isEmpty ? Color.secondary : Color.accentColor)
                    Text("User prompt")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { additionalSystemPrompt = "" }
                        .controlSize(.small)
                        .disabled(trimmed(additionalSystemPrompt).isEmpty)
                }
                .font(.callout)

                promptEditor(text: $additionalSystemPrompt, minHeight: 86)
                    .frame(maxHeight: 120)

                Text("Personal preferences appended after system and mode prompts for every correction request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .onAppear {
            loadSystemPrompt()
            loadModePrompt()
        }
        .onChange(of: correctionMode) { oldMode, _ in
            stashModeDraft(for: oldMode)
            loadModePrompt()
        }
        // ⌘S saves whichever prompt editors have unsaved changes; per-editor
        // shortcuts would collide on the same key.
        .background(
            Button("") {
                if systemIsDirty, !trimmed(systemPromptText).isEmpty { saveSystemOverride() }
                if modeIsDirty, !trimmed(modePromptText).isEmpty { saveModeOverride() }
            }
            .keyboardShortcut("s")
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    private var systemIsDirty: Bool {
        systemPromptText != originalSystemPromptText
    }

    private var modeIsDirty: Bool {
        modePromptText != originalModePromptText
    }

    private func promptHeader(title: String, hasOverride: Bool, isDirty: Bool, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: hasOverride ? "pencil.circle.fill" : "doc.circle")
                .foregroundStyle(hasOverride ? Color.accentColor : Color.secondary)
            Text(title)
            Text(hasOverride ? "Custom override" : "Built-in default")
                .foregroundStyle(.secondary)
            if isDirty {
                Text("• Unsaved")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if hasOverride {
                Button("Reset to default") { reset() }
                    .controlSize(.small)
            }
        }
        .font(.callout)
    }

    private func promptEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: minHeight)
    }

    private func loadSystemPrompt() {
        try? AppPaths.ensureDirectories()
        if let override = PromptOverrideStore.readSystemPrompt() {
            systemPromptText = override
            systemHasOverride = true
        } else {
            systemPromptText = BuiltInPrompts.baseSystem
            systemHasOverride = false
        }
        originalSystemPromptText = systemPromptText
    }

    private func loadModePrompt() {
        try? AppPaths.ensureDirectories()
        if let override = PromptOverrideStore.readModePrompt(for: correctionMode) {
            originalModePromptText = override
            modePromptHasOverride = true
        } else {
            originalModePromptText = BuiltInPrompts.modePrompt(correctionMode)
            modePromptHasOverride = false
        }
        // Restore an unsaved draft for this mode if one was stashed.
        modePromptText = modeDrafts[correctionMode] ?? originalModePromptText
    }

    private func stashModeDraft(for mode: CorrectionMode) {
        if modePromptText != originalModePromptText {
            modeDrafts[mode] = modePromptText
        } else {
            modeDrafts[mode] = nil
        }
    }

    private func saveSystemOverride() {
        try? AppPaths.ensureDirectories()
        let file = PromptOverrideStore.systemFile()
        do {
            try systemPromptText.write(to: file, atomically: true, encoding: .utf8)
            systemHasOverride = true
            originalSystemPromptText = systemPromptText
        } catch {
            Log.store.error("prompt override save failed: \(error.localizedDescription)")
        }
    }

    private func saveModeOverride() {
        try? AppPaths.ensureDirectories()
        let file = PromptOverrideStore.modePromptFile(for: correctionMode)
        do {
            try modePromptText.write(to: file, atomically: true, encoding: .utf8)
            modePromptHasOverride = true
            originalModePromptText = modePromptText
            modeDrafts[correctionMode] = nil
        } catch {
            Log.store.error("prompt override save failed: \(error.localizedDescription)")
        }
    }

    private func resetSystemOverride() {
        try? FileManager.default.removeItem(at: PromptOverrideStore.systemFile())
        loadSystemPrompt()
    }

    private func resetModeOverride() {
        try? FileManager.default.removeItem(at: PromptOverrideStore.modePromptFile(for: correctionMode))
        modeDrafts[correctionMode] = nil
        loadModePrompt()
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Vocabulary

struct DictionarySettingsView: View {
    @ObservedObject var store: UserDictionaryStore
    @State private var selectedType = "person"
    @State private var customType = ""
    @State private var surface = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Type", selection: $selectedType) {
                        ForEach(DictionaryEntry.suggestedTypes, id: \.self) { type in
                            Text(DictionaryEntry.displayType(for: type)).tag(type)
                        }
                        Text("custom").tag("custom")
                    }
                    .frame(width: 180)

                    if selectedType == "custom" {
                        TextField("Custom type", text: $customType)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }

                    TextField("Term, e.g. Ada Lovelace, AcmeDB, GraphRAG", text: $surface)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addEntryIfValid)

                    Button("Add", action: addEntryIfValid)
                        .disabled(!canAddEntry)
                }
            }

            List {
                ForEach(store.entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.displayType)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(entry.surface)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(role: .destructive) {
                            store.remove(entry)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { store.remove(at: $0) }
            }
            .listStyle(.inset)
        }
        .padding()
    }

    private var resolvedType: String {
        selectedType == "custom" ? customType : selectedType
    }

    private var canAddEntry: Bool {
        !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(selectedType == "custom" && customType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func addEntryIfValid() {
        guard canAddEntry else { return }
        store.add(type: resolvedType, surface: surface)
        surface = ""
        customType = ""
        if selectedType == "custom" {
            selectedType = DictionaryEntry.suggestedTypes.first ?? "person"
        }
    }
}

// MARK: - Bridge

struct BridgeSettingsView: View {
    @AppStorage(AppSettings.Keys.bridgeEnabled) private var enabled = false
    @AppStorage(AppSettings.Keys.bridgeLANEnabled) private var lanEnabled = false
    @AppStorage(AppSettings.Keys.bridgeLANAdapter) private var lanAdapter = BridgePairingPayload.allLANAdaptersID
    @AppStorage(AppSettings.Keys.bridgePublicEnabled) private var publicEnabled = false
    @AppStorage(AppSettings.Keys.bridgePort) private var port = 18081
    @AppStorage(AppSettings.Keys.bridgeHostname) private var hostname = ""
    @State private var authToken = ""
    @State private var showToken = false
    @State private var showingPairingQR = false
    @State private var showingRotateConfirm = false
    @State private var copiedMessage = ""
    @ObservedObject private var connectionStore = BridgeConnectionStore.shared
    @ObservedObject private var serverStatus = BridgeServerStatusStore.shared

    var body: some View {
        Form {
            Section("Bridge server") {
                Toggle("Enable Bridge", isOn: $enabled)
                HStack {
                    Text("Status")
                    Spacer()
                    Text(listenerStatusText)
                        .foregroundStyle(listenerStatusColor)
                }
                if case .failed(let message) = serverStatus.status, enabled {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                IntegerSettingField(title: "Port", value: $port, range: 1024...65535, suffix: "")
                Toggle("Allow LAN access", isOn: $lanEnabled)
                Picker("LAN adapter", selection: $lanAdapter) {
                    Text("All adapters").tag(BridgePairingPayload.allLANAdaptersID)
                    ForEach(availableLANAdapters) { adapter in
                        Text(adapter.displayName).tag(adapter.id)
                    }
                    if selectedAdapterMissing {
                        Text("Unavailable (\(lanAdapter))").tag(lanAdapter)
                    }
                }
                .disabled(!lanEnabled)
                HStack {
                    Text("Listening URL")
                    Spacer()
                    Text(verbatim: displayedBridgeURL)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Bridge accepts requests from Typeforme clients and returns refined text. It listens on 127.0.0.1 unless LAN access is enabled. The adapter setting controls which LAN URLs are included in pairing JSON.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Pair Clients") {
                HStack {
                    Text("Token")
                    Spacer()
                    Text(showToken ? currentToken : maskedToken)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showToken ? "Hide token" : "Show token")
                }
                HStack {
                    Button {
                        copyPairingJSON()
                    } label: {
                        Label("Copy Pairing JSON", systemImage: "doc.on.doc")
                    }
                    Button {
                        showingPairingQR = true
                    } label: {
                        Label("Show QR", systemImage: "qrcode")
                    }
                    .help("Display a QR for the iOS app to scan")
                    Button {
                        copyToken()
                    } label: {
                        Label("Copy Token", systemImage: "key")
                    }
                    Button(role: .destructive) {
                        showingRotateConfirm = true
                    } label: {
                        Label("Rotate Token", systemImage: "arrow.clockwise")
                    }
                    .confirmationDialog(
                        "Rotate the pairing token?",
                        isPresented: $showingRotateConfirm
                    ) {
                        Button("Rotate Token", role: .destructive) {
                            authToken = AppSettings.rotateBridgeAuthToken()
                            showToken = false
                            copiedMessage = "Token rotated"
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every paired client (including your iPhone) loses access until it re-pairs with the new token.")
                    }
                    Spacer()
                    if !copiedMessage.isEmpty {
                        Text(copiedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Mac stores this token in Keychain. Other clients cannot read it automatically, so pair by copying the token or JSON into the client. Pairing JSON contains the token plus enabled client URLs: lan_bridge_urls when LAN access is on, and public_bridge_url when Public Bridge URL is on. Clients pull languages and defaults from the server settings endpoint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            clientActivitySection
            Section("Public Bridge URL") {
                Toggle("Enable Public Bridge URL", isOn: $publicEnabled)
                TextField("Public bridge URL", text: $hostname, prompt: Text("https://voice.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!publicEnabled)
                Text("Optional. Use this when clients reach Bridge through a public URL. Cloudflare Tunnel, SSH tunnel, VPN, reverse proxy, or port forwarding are deployment choices outside Typeforme; configure them separately, then paste the client-facing URL here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Endpoints") {
                Text("GET  /v1/health\nGET  /v1/pairing\nGET  /v1/settings\nWS   /v1/jobs/:jobID/events\nWS   /v1/live-preview/:sessionID/socket\nPOST /v1/settings\nPOST /v1/dictate\nPOST /v1/live-preview/start\nPOST /v1/live-preview/:sessionID/finish\nPOST /v1/refine\nPOST /v1/edit-text")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("All endpoints require the bearer token. Missing or wrong tokens return an empty not-found response. /v1/pairing returns token plus enabled LAN/public URLs for first setup; clients pull languages and defaults from /v1/settings. /v1/jobs/:jobID/events is the WebSocket job event stream for transcript and refine status. /v1/live-preview/:sessionID/socket accepts one Opus 16 kHz mono 20 ms packet per binary frame and returns live preview partial/final JSON frames on the same WebSocket. /v1/dictate uses multipart FLAC audio file upload, requires audio_extension before the audio file part, and returns refined text. /v1/refine reuses text from a recent session or submitted text so mode switching does not require another recording. /v1/edit-text edits a selected or targeted text span from a spoken repair or command.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            authToken = AppSettings.ensureBridgeAuthToken()
        }
        .sheet(isPresented: $showingPairingQR) {
            PairingQRSheetView(payloadJSON: pairingPayloadJSONString())
        }
    }

    @ViewBuilder
    private var clientActivitySection: some View {
        let snapshot = connectionStore.snapshot
        Section("Client Activity") {
            BridgeActivityOverview(snapshot: snapshot)
            BridgeActivityMetrics(snapshot: snapshot)
            BridgeClientActivityTable(snapshot: snapshot)

            HStack {
                Text("Only authorized Bridge requests are counted. Raw dictation text, edit context, and tokens are never shown here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    connectionStore.reset()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(snapshot.totalRequests == 0)
            }
        }
    }

    private var portString: String {
        String(port)
    }

    /// The toggle records intent; the status row shows what the socket
    /// actually did. "Starting…" covers the brief window between the toggle
    /// flipping and BridgeHTTPServer publishing a result.
    private var listenerStatusText: String {
        guard enabled else { return "Off" }
        switch serverStatus.status {
        case .running(_, let activePort): return "Listening on port \(activePort)"
        case .failed: return "Failed"
        case .stopped: return "Starting…"
        }
    }

    private var listenerStatusColor: Color {
        guard enabled else { return .secondary }
        switch serverStatus.status {
        case .running: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    private var availableLANAdapters: [BridgeLANAdapter] {
        BridgePairingPayload.availableLANAdapters()
    }

    private var selectedAdapterMissing: Bool {
        lanAdapter != BridgePairingPayload.allLANAdaptersID
            && !availableLANAdapters.contains(where: { $0.id == lanAdapter })
    }

    private var displayedBridgeURL: String {
        if lanEnabled {
            let urls = BridgePairingPayload.lanBridgeURLs(port: port, adapterID: lanAdapter)
            guard let first = urls.first else { return "No LAN IP found" }
            if urls.count > 1 {
                return "\(first) (+\(urls.count - 1))"
            }
            return first
        }
        return BridgePairingPayload.localBridgeURL(port: port)
    }

    private var currentToken: String {
        authToken.isEmpty ? AppSettings.ensureBridgeAuthToken() : authToken
    }

    private var maskedToken: String {
        let token = currentToken
        guard token.count > 10 else { return "••••••" }
        return "••••••" + token.suffix(6)
    }

    private func copyToken() {
        copyToClipboard(currentToken)
        copiedMessage = "Token copied"
    }

    private func copyPairingJSON() {
        copyToClipboard(pairingPayloadJSONString())
        copiedMessage = "JSON copied"
    }

    /// Shared encoder for clipboard + QR consumers. Compact (no
    /// `.prettyPrinted`) so the QR is denser; iOS parser tolerates both.
    private func pairingPayloadJSONString() -> String {
        let payload = BridgePairingPayload.current()
        let data: Data
        do {
            data = try BridgeJSON.encodeSorted(payload)
        } catch {
            preconditionFailure("Could not encode pairing payload: \(error)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("Pairing payload JSON was not UTF-8")
        }
        return text
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct BridgeActivityOverview: View {
    let snapshot: BridgeConnectionSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            BridgeActivityStatusBadge(label: statusLabel, color: tint)
        }
        .padding(.vertical, 4)
    }

    private var latestClient: BridgeClientActivityRecord? {
        snapshot.clients.first
    }

    private var title: String {
        guard !snapshot.clients.isEmpty else { return "Waiting for clients" }
        if snapshot.clients.count == 1 {
            return "1 client seen"
        }
        return "\(snapshot.clients.count) clients seen"
    }

    private var detail: String {
        guard let latestClient else {
            return "Pair an iPhone or refresh a paired client to confirm the Bridge connection."
        }
        return "Latest: \(latestClient.host) used \(latestClient.lastEndpoint.displayName.lowercased()) at \(Self.timeFormatter.string(from: latestClient.lastSeenAt))."
    }

    private var statusLabel: String {
        guard let latestClient else { return "Idle" }
        return latestClient.lastStatusCode < 400 ? "OK" : "Issue"
    }

    private var iconName: String {
        guard let latestClient else { return "antenna.radiowaves.left.and.right" }
        return latestClient.lastStatusCode < 400 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        guard let latestClient else { return .secondary }
        return latestClient.lastStatusCode < 400 ? .green : .orange
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct BridgeActivityMetrics: View {
    let snapshot: BridgeConnectionSnapshot

    var body: some View {
        HStack(spacing: 0) {
            BridgeActivityMetricCell(
                title: "Clients",
                value: "\(snapshot.clients.count)",
                detail: latestClientLabel
            )
            Divider()
            BridgeActivityMetricCell(
                title: "Requests",
                value: "\(snapshot.totalRequests)",
                detail: "\(snapshot.successfulRequests) ok / \(snapshot.failedRequests) failed"
            )
            Divider()
            BridgeActivityMetricCell(
                title: "Success",
                value: successRateLabel,
                detail: successDetail
            )
            Divider()
            BridgeActivityMetricCell(
                title: "Work",
                value: "\(workRequestCount)",
                detail: "\(snapshot.count(for: .dictate)) dictate / \(snapshot.count(for: .refine)) refine / \(snapshot.count(for: .editText)) edit"
            )
        }
        .frame(minHeight: 58)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var latestClientLabel: String {
        snapshot.clients.first?.host ?? "none"
    }

    private var successRateLabel: String {
        guard snapshot.totalRequests > 0 else { return "--" }
        let rate = Double(snapshot.successfulRequests) / Double(snapshot.totalRequests)
        return "\(Int((rate * 100).rounded()))%"
    }

    private var successDetail: String {
        guard let lastRequestAt = snapshot.lastRequestAt else { return "no requests yet" }
        return "last at \(Self.timeFormatter.string(from: lastRequestAt))"
    }

    private var workRequestCount: Int {
        snapshot.count(for: .dictate) + snapshot.count(for: .refine) + snapshot.count(for: .editText)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct BridgeActivityMetricCell: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct BridgeClientActivityTable: View {
    let snapshot: BridgeConnectionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent Clients")
                    .font(.callout.weight(.semibold))
                Spacer()
                if !snapshot.clients.isEmpty {
                    Text("\(snapshot.clients.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot.clients.isEmpty {
                BridgeActivityEmptyState()
            } else {
                VStack(spacing: 0) {
                    BridgeClientActivityHeader()
                    Divider()
                    ForEach(snapshot.clients) { client in
                        BridgeClientActivityRow(client: client)
                        if client.id != snapshot.clients.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                )
            }
        }
        .padding(.top, 2)
    }
}

private struct BridgeActivityEmptyState: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("No client activity yet")
                    .font(.callout.weight(.medium))
                Text("Show the pairing QR, then scan or refresh from iOS. The first authorized request appears here automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct BridgeClientActivityHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Client")
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text("Last Request")
                .frame(width: 116, alignment: .leading)
            Text("Requests")
                .frame(width: 104, alignment: .trailing)
            Text("State")
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct BridgeClientActivityRow: View {
    let client: BridgeClientActivityRecord

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(client.lastEndpoint.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(client.lastSeenAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 116, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(client.requestCount)")
                    .font(.caption.monospacedDigit().weight(.medium))
                Text("Handled in \(client.lastLatencyMs) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104, alignment: .trailing)

            BridgeActivityStatusBadge(label: statusLabel, color: statusColor)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var title: String {
        if let name = client.clientDisplayName, !name.isEmpty {
            return name
        }
        if let platform = client.clientPlatform, !platform.isEmpty {
            return "Typeforme \(platform)"
        }
        return client.host
    }

    private var subtitle: String {
        if client.usesCloudflare, let forwardedClientIP = client.forwardedClientIP {
            return "Cloudflare - \(forwardedClientIP)"
        }
        if let bundleID = client.clientBundleID, !bundleID.isEmpty {
            return bundleID
        }
        if !client.clientIdentityID.isEmpty {
            return client.clientIdentityID
        }
        if let userAgent = client.userAgent, !userAgent.isEmpty {
            return userAgent
        }
        return client.host
    }

    private var statusLabel: String {
        client.lastStatusCode < 400 ? "OK" : "\(client.lastStatusCode)"
    }

    private var statusColor: Color {
        client.lastStatusCode < 400 ? .green : .orange
    }
}

private struct BridgeActivityStatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Pairing QR sheet

/// Renders the pairing payload as a Core Image QR code. The iOS host's
/// PairingQRScannerView feeds the decoded string back into the same JSON
/// parser the clipboard path uses, so the two flows produce identical
/// `PairingConfig`s.
private struct PairingQRSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let payloadJSON: String?
    @State private var startedAt = Date()
    @State private var pairingCompleted = false
    @State private var closeScheduled = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Pairing QR")
                .font(.title3.weight(.semibold))
            Text(pairingCompleted
                 ? "Pairing complete. Client list refreshed."
                 : "Open Typeforme on iOS → Pairing → Scan QR from Mac, then point the camera at this window.")
                .font(.footnote)
                .foregroundStyle(pairingCompleted ? .green : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)

            qrImage
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 320, height: 320)
                .background(Color.white)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

            if payloadJSON == nil {
                Text("Could not build pairing payload — verify Bridge settings.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if pairingCompleted {
                Label("Pairing complete", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            }

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 480)
        .onAppear {
            startedAt = Date()
            pairingCompleted = false
            closeScheduled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: BridgeConnectionStore.clientRequestNotification)) { notification in
            handleClientRequest(notification)
        }
    }

    private var qrImage: Image {
        if let json = payloadJSON, let nsImage = Self.makeQR(from: json) {
            return Image(nsImage: nsImage)
        }
        // Fallback placeholder so the view still lays out gracefully.
        return Image(systemName: "qrcode")
    }

    private static func makeQR(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Bump up the resolution so the QR doesn't render fuzzy on Retina.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private func handleClientRequest(_ notification: Notification) {
        guard payloadJSON != nil,
              let activity = notification.object as? BridgeClientRequestActivity,
              activity.succeeded,
              activity.occurredAt >= startedAt
        else { return }

        pairingCompleted = true
        guard !closeScheduled else { return }
        closeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsView: View {
    @AppStorage(AppSettings.Keys.diagnosticsDebugMode) private var debugMode = false
    @AppStorage(AppSettings.Keys.diagnosticsDebugCaptureLimit) private var debugCaptureLimit = 10
    @State private var debugCaptureCount = 0
    @ObservedObject private var errorLog = DictationErrorLog.shared

    var body: some View {
        Form {
            Section("Recent errors") {
                if errorLog.entries.isEmpty {
                    Text("No dictation errors this session.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(errorLog.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.at, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Text("The HUD error capsule auto-dismisses; the last \(errorLog.entries.count) error\(errorLog.entries.count == 1 ? "" : "s") stay here until quit.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { errorLog.clear() }
                    }
                }
            }
            Section("Debug capture") {
                Toggle("Debug mode", isOn: $debugMode)
                Text("When enabled, Typeforme keeps the latest \(AppSettings.diagnosticsDebugCaptureLimit) captures: received audio, ASR transcript, and the selected correction request/result.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                IntegerSettingField(
                    title: "Keep captures",
                    value: $debugCaptureLimit,
                    range: 1...200,
                    suffix: "items"
                )
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(AppPaths.debugCapturesDir.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Stored captures")
                    Spacer()
                    Text("\(debugCaptureCount)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal in Finder") {
                        try? AppPaths.ensureDirectories()
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.debugCapturesDir])
                        refreshDebugCaptureCount()
                    }
                    Button("Refresh") {
                        refreshDebugCaptureCount()
                    }
                    Button("Clear") {
                        DebugLogStore.clear()
                        refreshDebugCaptureCount()
                    }
                    .disabled(debugCaptureCount == 0)
                }
            }
            Section("Live logs") {
                HStack {
                    Text("Subsystem")
                    Spacer()
                    Text(BundleIdentity.mainBundleIdentifier).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Open Console.app and filter by Subsystem to see categorized live logs (audio, asr, llm, hotkey, coordinator, …).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Crash reports") {
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Library/Logs/DiagnosticReports")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Text("If Typeforme ever crashes, look for a Typeforme-*.ips file in ~/Library/Logs/DiagnosticReports. The first 30 lines (Exception Type / Termination Reason / Thread 0 backtrace) are usually enough to diagnose.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Link(destination: typeformePrivacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Text(debugMode ? "Debug mode stores raw audio and text locally in the debug capture folder. Turn it off when you are done." : "Normal live logs use provider / latency / length / hash / error-code only. They do not include raw user text.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDebugCaptureCount() }
        .onChange(of: debugMode) { _, _ in refreshDebugCaptureCount() }
        .onChange(of: debugCaptureLimit) { _, _ in
            DebugLogStore.prune()
            refreshDebugCaptureCount()
        }
    }

    private func refreshDebugCaptureCount() {
        debugCaptureCount = DebugLogStore.recentCount()
    }
}
