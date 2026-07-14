import AppKit
import SwiftUI

private enum SetupGuidePage: String, CaseIterable, Identifiable {
    case role
    case permissions
    case bridge
    case asr
    case refine

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .role: return "Role"
        case .permissions: return "Access"
        case .bridge: return "Bridge"
        case .asr: return "ASR"
        case .refine: return "Refine"
        }
    }

    var title: String {
        switch self {
        case .role: return "Choose how this Mac works"
        case .permissions: return "Grant required access"
        case .bridge: return "Pair with Typeforme Bridge"
        case .asr: return "Choose recognition sources"
        case .refine: return "Choose the refine model"
        }
    }

    var subtitle: String {
        switch self {
        case .role:
            return "Pick Server if this Mac should run local models. Pick Client if another Mac will do the model work."
        case .permissions:
            return "Typeforme needs only the permissions that match the selected role."
        case .bridge:
            return "Paste the pairing JSON from the server Mac, then verify that a route is reachable."
        case .asr:
            return "Choose the ASR sources this Mac may use. Apple Speech and local ASR models are optional."
        case .refine:
            return "Use an installed local model or a verified external compatible API. Done starts a background warm-up."
        }
    }

    var systemImage: String {
        switch self {
        case .role: return "macbook"
        case .permissions: return "lock.shield"
        case .bridge: return "network"
        case .asr: return "waveform"
        case .refine: return "text.bubble"
        }
    }
}

private struct SetupExternalLLMConfig: Equatable {
    let backendRaw: String
    let baseURL: String
    let apiKey: String
    let model: String
}

struct SetupGuideWizardView: View {
    var onClose: () -> Void = {}

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue
    @AppStorage(AppSettings.Keys.asrQwenEnabled) private var qwenEnabled = false
    @AppStorage(AppSettings.Keys.asrNvidiaNemotronEnabled) private var nvidiaEnabled = false
    @AppStorage(AppSettings.Keys.asrAppleSpeechEnabled) private var appleSpeechEnabled = false
    @AppStorage(AppSettings.Keys.asrQwenLlamaModelID) private var qwenModelID = QwenASRModelCatalog.defaultID
    @AppStorage(AppSettings.Keys.asrNvidiaNemotronModelID) private var nvidiaModelID = NvidiaNemotronASRModelCatalog.defaultID
    @AppStorage(AppSettings.Keys.correctionBackend) private var backendRaw = CorrectionBackendKind.qwen35_4B.rawValue
    @AppStorage(AppSettings.Keys.externalLLMBaseURL) private var externalLLMBaseURL = "http://127.0.0.1:1234"
    @AppStorage(AppSettings.Keys.externalLLMModel) private var externalLLMModel = ""
    @AppStorage(AppSettings.Keys.clientLocalBridgeURLs) private var clientLocalBridgeURLsRaw = ""
    @AppStorage(AppSettings.Keys.clientCloudBridgeURL) private var clientCloudBridgeURL = ""

    @State private var page: SetupGuidePage = .role
    @State private var axTrusted = AppPermissions.accessibilityTrusted
    @State private var microphoneStatus = AppPermissions.microphoneStatus
    @State private var speechStatus = AppPermissions.speechRecognitionStatus
    @State private var clientBridgeToken = AppSettings.clientBridgeToken
    @State private var routeStatus = BridgeRouteResolutionStatus()
    @State private var checkedClientConfig: ClientBridgeConfiguration?
    @State private var bridgeStatus: String?
    @State private var bridgeIsError = false
    @State private var bridgeOperationState = LatestDraftOperationState<ClientBridgeConfiguration>()
    @State private var externalLLMAPIKey = AppSettings.externalLLMAPIKey
    @State private var externalLLMStatus = "Not checked"
    @State private var externalLLMDetail = "Refresh models before using an external refine backend."
    @State private var externalLLMModels: [String] = []
    @State private var checkedExternalLLMConfig: SetupExternalLLMConfig?
    @State private var isCheckingExternalLLM = false
    @State private var externalLLMCheckTask: Task<Void, Never>?
    @State private var externalLLMCheckID = UUID()
    @State private var suppressNextExternalLLMModelReset = false

    var body: some View {
        let _ = modelDownloads
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            pageBody
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            clientBridgeToken = AppSettings.clientBridgeToken
            externalLLMAPIKey = AppSettings.externalLLMAPIKey
            refreshPermissions()
            normalizeBackendSelection()
            normalizePage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onChange(of: processingModeRaw) { _, _ in
            normalizePage()
            resetClientBridgeCheck()
        }
        .onChange(of: backendRaw) { _, _ in
            normalizeBackendSelection()
            if selectedBackendKind?.isExternalCompatible == true {
                resetExternalLLMCheck(detail: "Refresh models before using this external backend.")
            }
        }
        .onChange(of: externalLLMBaseURL) { _, _ in
            resetExternalLLMCheck(detail: "Refresh models after changing the server URL.")
        }
        .onChange(of: externalLLMModel) { _, _ in
            if suppressNextExternalLLMModelReset {
                suppressNextExternalLLMModelReset = false
                return
            }
            handleExternalLLMModelSelectionChange()
        }
        .onChange(of: externalLLMAPIKey) { _, _ in
            resetExternalLLMCheck(detail: "Refresh models after changing the API key.")
        }
        .onDisappear {
            cancelExternalLLMCheck()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup Guide")
                        .font(.title2.weight(.semibold))
                    Text("Step \(currentIndex + 1) of \(visiblePages.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(Array(visiblePages.enumerated()), id: \.element) { index, step in
                    WizardStepPill(
                        title: step.shortTitle,
                        number: index + 1,
                        isCurrent: step == page,
                        isComplete: index < currentIndex && pageComplete(step)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentPageTitle)
                    .font(.title3.weight(.semibold))
                Text(currentPageSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch page {
            case .role:
                rolePage
            case .permissions:
                permissionsPage
            case .bridge:
                bridgePage
            case .asr:
                asrPage
            case .refine:
                refinePage
            }
        }
    }

    private var rolePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Role", selection: processingModeBinding) {
                Text("Server: run local models here").tag(ProcessingMode.server.rawValue)
                Text("Client: send work to another Mac").tag(ProcessingMode.client.rawValue)
            }
            .pickerStyle(.radioGroup)

            WizardStatusLine(
                title: processingMode == .server ? "Local setup required" : "Pairing setup required",
                detail: processingMode == .server
                    ? "The next pages will install ASR and refine models on this Mac."
                    : "Local model pages are skipped. The next pages grant access and pair this Mac with Bridge.",
                systemImage: processingMode == .server ? "internaldrive" : "network",
                tint: processingMode == .server ? .blue : .secondary
            )
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            WizardPermissionRow(
                title: "Microphone",
                detail: "Records dictation audio on this Mac.",
                status: microphoneStatusText,
                isReady: microphoneStatus == .granted,
                actionTitle: microphoneActionTitle,
                action: requestMicrophone
            )
            WizardPermissionRow(
                title: "Accessibility",
                detail: "Inserts accepted text into the focused app.",
                status: axTrusted ? "Granted" : "Not granted",
                isReady: axTrusted,
                actionTitle: axTrusted ? "Refresh" : "Open Settings",
                action: requestAccessibility,
                secondaryActionTitle: "Reimport",
                secondaryAction: reimportAccessibility
            )
            if processingMode == .server, appleSpeechEnabled {
                WizardPermissionRow(
                    title: "Speech Recognition",
                    detail: "Required for the built-in Apple Speech source.",
                    status: speechStatusText,
                    isReady: speechStatus == .granted,
                    actionTitle: speechActionTitle,
                    action: requestSpeechRecognition
                )
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var bridgePage: some View {
        VStack(alignment: .leading, spacing: 13) {
            WizardStatusLine(
                title: clientConfig.isConfigured ? "Pairing JSON applied" : "Pairing required",
                detail: clientConfig.isConfigured
                    ? "Endpoint and token are saved locally. Check Bridge before continuing."
                    : "Copy Pairing JSON on the server Mac, then paste it here.",
                systemImage: clientConfig.isConfigured ? "link.circle.fill" : "link.badge.plus",
                tint: clientConfig.isConfigured ? .blue : .orange
            )

            HStack(spacing: 10) {
                Button {
                    pasteClientPairingJSON()
                } label: {
                    Label("Paste Pairing JSON", systemImage: "doc.on.clipboard")
                }
                Button {
                    Task { await checkClientBridge(pullServerDefaults: true) }
                } label: {
                    Label(isCheckingBridge ? "Checking..." : "Check Bridge", systemImage: "network")
                }
                .disabled(isCheckingBridge || !clientConfig.isConfigured)
                if isCheckingBridge {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if clientConfig.isConfigured {
                    Button("Clear", action: clearClientPairing)
                }
            }

            WizardBridgeRouteRow(
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
            WizardBridgeRouteRow(
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

            if let bridgeStatus {
                Text(bridgeStatus)
                    .font(.caption)
                    .foregroundStyle(bridgeIsError ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var asrPage: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $appleSpeechEnabled) {
                    WizardToggleLabel(
                        title: "Apple Speech",
                        detail: "Built in. No model download."
                    )
                }
                .toggleStyle(.switch)
                .disabled(!appleSpeechEnabled && !appleSpeechCanEnable)
                if let reason = appleSpeechIssue {
                    WizardStatusLine(
                        title: "Apple Speech unavailable",
                        detail: reason,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
                if appleSpeechEnabled, appleSpeechAvailability.status == "needs_permission" {
                    Button {
                        requestSpeechRecognition()
                    } label: {
                        Label("Request Speech Recognition", systemImage: "waveform")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $qwenEnabled) {
                        WizardToggleLabel(
                            title: "Qwen3-ASR",
                            detail: "Local GGUF ASR model."
                        )
                    }
                    .toggleStyle(.switch)
                    if qwenEnabled {
                        SetupModelPickerRow(title: "Model") {
                            Picker("Qwen3-ASR model", selection: $qwenModelID) {
                                ForEach(QwenASRModelCatalog.all) { spec in
                                    Text(spec.label).tag(spec.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $nvidiaEnabled) {
                        WizardToggleLabel(
                            title: "NVIDIA Nemotron",
                            detail: "Local ONNX streaming ASR model."
                        )
                    }
                    .toggleStyle(.switch)
                    if nvidiaEnabled {
                        SetupModelPickerRow(title: "Model") {
                            Picker("NVIDIA Nemotron model", selection: $nvidiaModelID) {
                                ForEach(NvidiaNemotronASRModelCatalog.all) { spec in
                                    Text(spec.label).tag(spec.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
            .frame(width: 300, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 14) {
                if !appleSpeechEnabled && !qwenEnabled && !nvidiaEnabled {
                    WizardStatusLine(
                        title: "No ASR source enabled",
                        detail: "Dictation will be unavailable until at least one source is enabled.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
                if qwenEnabled {
                    SetupQwenASRInstallRow(spec: selectedQwenModel)
                        .id(selectedQwenModel.id)
                }
                if nvidiaEnabled {
                    SetupNvidiaNemotronInstallRow(spec: selectedNvidiaModel)
                        .id(selectedNvidiaModel.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var refinePage: some View {
        HStack(alignment: .top, spacing: 24) {
            Picker("Engine", selection: correctionBackendBinding) {
                ForEach(refineBackendOptions, id: \.rawValue) { kind in
                    Text(refineBackendTitle(kind)).tag(kind.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .frame(width: 300, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 14) {
                if selectedBackendKind?.isExternalCompatible == true {
                    externalRefineSetup
                } else {
                    Text(selectedLlamaModel.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SetupLocalLlamaInstallRow(spec: selectedLlamaModel)
                        .id(selectedLlamaModel.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var externalRefineSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a compatible refine server and choose a listed model.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Base URL", text: $externalLLMBaseURL)
                .textFieldStyle(.roundedBorder)

            if externalLLMPickerModels.isEmpty {
                TextField("Model ID", text: $externalLLMModel)
                    .textFieldStyle(.roundedBorder)
            } else {
                SetupModelPickerRow(title: "Model") {
                    Picker("External model", selection: $externalLLMModel) {
                        if externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Select a model").tag("")
                        }
                        ForEach(externalLLMPickerModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            SecureField("API key (optional)", text: $externalLLMAPIKey)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Circle()
                    .fill(externalLLMColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(externalLLMStatus)
                        .font(.body.weight(.medium))
                    Text(externalLLMDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    startExternalLLMCheck(selectFirstModel: externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } label: {
                    Label(isCheckingExternalLLM ? "Checking" : "Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(isCheckingExternalLLM)
                if isCheckingExternalLLM {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") {
                moveBack()
            }
            .disabled(currentIndex == 0)

            Spacer()

            Button("Cancel") {
                onClose()
            }
            Button(isLastPage ? "Done" : "Next") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvanceCurrentPage)
        }
    }

    private var visiblePages: [SetupGuidePage] {
        processingMode == .client
            ? [.role, .permissions, .bridge]
            : [.role, .permissions, .asr, .refine]
    }

    private var currentIndex: Int {
        visiblePages.firstIndex(of: page) ?? 0
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    private var isLastPage: Bool {
        currentIndex == visiblePages.count - 1
    }

    private var currentPageTitle: String {
        return page.title
    }

    private var currentPageSubtitle: String {
        return page.subtitle
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

    private var selectedQwenModel: QwenASRModelSpec {
        QwenASRModelCatalog.spec(for: qwenModelID)
    }

    private var selectedNvidiaModel: NvidiaNemotronASRModelSpec {
        NvidiaNemotronASRModelCatalog.spec(for: nvidiaModelID)
    }

    private var selectedLlamaModel: LocalLlamaModelSpec {
        localLlamaModels.first { $0.backendKind.rawValue == backendRaw } ?? localLlamaModels[0]
    }

    private var selectedBackendKind: CorrectionBackendKind? {
        CorrectionBackendKind(rawValue: backendRaw)
    }

    private var refineBackendOptions: [CorrectionBackendKind] {
        localLlamaModels.map(\.backendKind) + [
            .externalOpenAICompatible,
            .externalAnthropicCompatible,
        ]
    }

    private var correctionBackendBinding: Binding<String> {
        Binding {
            selectedBackendKind?.rawValue ?? CorrectionBackendKind.qwen35_4B.rawValue
        } set: { raw in
            guard let kind = CorrectionBackendKind(rawValue: raw),
                  refineBackendOptions.contains(kind)
            else { return }
            backendRaw = raw
        }
    }

    private func refineBackendTitle(_ kind: CorrectionBackendKind) -> String {
        if let spec = localLlamaModels.first(where: { $0.backendKind == kind }) {
            return spec.label
        }
        return kind.displayName
    }

    private var currentExternalLLMConfig: SetupExternalLLMConfig {
        SetupExternalLLMConfig(
            backendRaw: backendRaw,
            baseURL: externalLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: externalLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var externalRefineReady: Bool {
        let selectedModel = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { return false }
        guard checkedExternalLLMConfig == currentExternalLLMConfig,
              externalLLMStatus == "Ready"
        else { return false }
        return externalLLMModels.isEmpty || externalLLMModels.contains(selectedModel)
    }

    private var externalLLMPickerModels: [String] {
        var models = externalLLMModels
        let selected = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty && !models.contains(selected) {
            models.insert(selected, at: 0)
        }
        return models
    }

    private var externalLLMColor: Color {
        if isCheckingExternalLLM { return .orange }
        if externalLLMStatus == "Ready" { return .green }
        if externalLLMStatus == "Failed" { return .red }
        return .secondary
    }

    private var permissionsReady: Bool {
        axTrusted
            && microphoneStatus == .granted
            && (processingMode != .server || !appleSpeechEnabled || speechStatus == .granted)
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

    private var clientBridgeReady: Bool {
        clientConfig.isConfigured && checkedClientConfig == clientConfig && routeStatus.activeURL != nil
    }

    private var isCheckingBridge: Bool {
        bridgeOperationState.isActive
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

    private var asrReady: Bool {
        Self.isASRConfigurationReady(
            appleSpeechEnabled: appleSpeechEnabled,
            appleSpeechReady: appleSpeechAvailability.ready,
            qwenEnabled: qwenEnabled,
            qwenInstalled: qwenModelInstalled,
            nvidiaEnabled: nvidiaEnabled,
            nvidiaInstalled: nvidiaModelInstalled
        )
    }

    nonisolated static func isASRConfigurationReady(
        appleSpeechEnabled: Bool,
        appleSpeechReady: Bool,
        qwenEnabled: Bool,
        qwenInstalled: Bool,
        nvidiaEnabled: Bool,
        nvidiaInstalled: Bool
    ) -> Bool {
        (appleSpeechEnabled || qwenEnabled || nvidiaEnabled)
            && (!appleSpeechEnabled || appleSpeechReady)
            && (!qwenEnabled || qwenInstalled)
            && (!nvidiaEnabled || nvidiaInstalled)
    }

    private var appleSpeechAvailability: AppleSpeechAvailabilityReport {
        AppleSpeechAvailability.report(languageIDs: AppSettings.asrCanonicalLanguageIDs)
    }

    private var appleSpeechCanEnable: Bool {
        appleSpeechAvailability.canEnable
    }

    private var appleSpeechIssue: String? {
        let report = appleSpeechAvailability
        if appleSpeechEnabled || !report.canEnable {
            return report.ready ? nil : report.reason
        }
        return nil
    }

    private var refineReady: Bool {
        if selectedBackendKind?.isExternalCompatible == true {
            return externalRefineReady
        }
        return FileManager.default.fileExists(atPath: effectivePath(forKey: selectedLlamaModel.pathKey, fallback: selectedLlamaModel.defaultPath))
    }

    private var canAdvanceCurrentPage: Bool {
        switch page {
        case .role:
            return true
        case .permissions:
            return permissionsReady
        case .bridge:
            return clientBridgeReady
        case .asr:
            return asrReady
        case .refine:
            return refineReady && !isCheckingExternalLLM
        }
    }

    private func pageComplete(_ step: SetupGuidePage) -> Bool {
        switch step {
        case .role:
            return true
        case .permissions:
            return permissionsReady
        case .bridge:
            return processingMode != .client || clientBridgeReady
        case .asr:
            return processingMode == .client || asrReady
        case .refine:
            return processingMode == .client || refineReady
        }
    }

    private var qwenModelInstalled: Bool {
        FileManager.default.fileExists(atPath: effectivePath(forKey: selectedQwenModel.modelPathKey, fallback: selectedQwenModel.defaultModelPath))
            && FileManager.default.fileExists(atPath: effectivePath(forKey: selectedQwenModel.mmprojPathKey, fallback: selectedQwenModel.defaultMMProjPath))
    }

    private var nvidiaModelInstalled: Bool {
        selectedNvidiaModel.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: effectivePath(forKey: file.pathKey, fallback: file.defaultPath))
        }
    }

    private func effectivePath(forKey key: String, fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    private func advance() {
        if isLastPage {
            do {
                try persistExternalRefineCredentialsIfNeeded()
            } catch {
                externalLLMStatus = "Failed"
                externalLLMDetail = error.localizedDescription
                return
            }
            AppSettings.setSetupGuideCompleted(true)
            AppSettings.setSetupGuideHasShown(true)
            warmSelectedModelsAfterDone()
            onClose()
            return
        }
        let pages = visiblePages
        guard let index = pages.firstIndex(of: page), index + 1 < pages.count else { return }
        page = pages[index + 1]
    }

    private func moveBack() {
        let pages = visiblePages
        guard let index = pages.firstIndex(of: page), index > 0 else { return }
        page = pages[index - 1]
    }

    private func normalizePage() {
        if !visiblePages.contains(page) {
            page = visiblePages.first ?? .role
        }
    }

    private func resetClientBridgeCheck() {
        bridgeOperationState.invalidate()
        routeStatus = BridgeRouteResolutionStatus()
        checkedClientConfig = nil
        bridgeStatus = nil
        bridgeIsError = false
    }

    @MainActor
    private func checkClientBridge(pullServerDefaults: Bool) async {
        let config = clientConfig
        let operation = bridgeOperationState.begin(snapshot: config)
        bridgeStatus = nil
        bridgeIsError = false
        defer { bridgeOperationState.finish(operation) }

        let resolvedStatus = await ClientBridgeRouteResolver().resolve(
            config: config,
            probeAllEndpoints: true
        )
        guard bridgeOperationState.canApply(operation, to: clientConfig) else { return }
        routeStatus = resolvedStatus
        checkedClientConfig = config

        guard routeStatus.activeURL != nil else {
            bridgeStatus = "Bridge unavailable. Check that the server Mac is running and the pairing JSON is current."
            bridgeIsError = true
            return
        }

        bridgeStatus = "\(routeStatus.activeKind.rawValue) route active."
        bridgeIsError = false

        guard pullServerDefaults else { return }
        do {
            guard let activeURL = resolvedStatus.activeURL else { return }
            let client = try RemoteBridgeClient(
                baseURLString: activeURL.absoluteString,
                token: config.token
            )
            let settings = try await client.settings()
            guard bridgeOperationState.canApply(operation, to: clientConfig) else { return }
            ClientBridgeSettingsSync.applyServerDefaults(settings)
            bridgeStatus = "Connected. Server defaults pulled from \(resolvedStatus.activeKind.rawValue)."
        } catch {
            guard bridgeOperationState.canApply(operation, to: clientConfig) else { return }
            bridgeStatus = "Connected, but server settings could not be pulled: \(error.localizedDescription)"
            bridgeIsError = false
        }
    }

    private func pasteClientPairingJSON() {
        let trimmed = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            bridgeStatus = "Clipboard is empty."
            bridgeIsError = true
            return
        }

        do {
            let payload = try BridgeJSON.decode(BridgePairingPayload.self, from: data)
            let config = ClientBridgeConfiguration.fromPairingPayload(payload)
            let persistedToken = try AppSettings.setClientBridgeToken(config.token)
            clientLocalBridgeURLsRaw = ClientBridgeConfiguration.rawValue(for: config.localBridgeURLs)
            clientCloudBridgeURL = config.cloudBridgeURL
            clientBridgeToken = persistedToken
            resetClientBridgeCheck()
            bridgeStatus = "Pairing JSON applied. Checking Bridge..."
            bridgeIsError = false
            Task { await checkClientBridge(pullServerDefaults: true) }
        } catch {
            bridgeStatus = error is SecureSettingError
                ? "Pairing could not be saved: \(error.localizedDescription)"
                : "Couldn't parse pairing JSON."
            bridgeIsError = true
        }
    }

    private func clearClientPairing() {
        do {
            let persistedToken = try AppSettings.setClientBridgeToken("")
            clientLocalBridgeURLsRaw = ""
            clientCloudBridgeURL = ""
            clientBridgeToken = persistedToken
            resetClientBridgeCheck()
            bridgeStatus = "Pairing cleared."
            bridgeIsError = false
        } catch {
            bridgeStatus = "Could not clear pairing: \(error.localizedDescription)"
            bridgeIsError = true
        }
    }

    private func endpointState(isConfigured: Bool, isChecked: Bool, isOK: Bool) -> String {
        if !isConfigured { return "Not configured" }
        if isOK { return "Available" }
        return isChecked ? "Unavailable" : "Not checked"
    }

    private func normalizeBackendSelection() {
        guard let kind = CorrectionBackendKind(rawValue: backendRaw),
              refineBackendOptions.contains(kind)
        else {
            backendRaw = CorrectionBackendKind.qwen35_4B.rawValue
            return
        }
    }

    private func persistExternalRefineCredentialsIfNeeded() throws {
        guard processingMode == .server,
              selectedBackendKind?.isExternalCompatible == true
        else { return }
        let normalizedAPIKey = externalLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedAPIKey: String
        if normalizedAPIKey == AppSettings.externalLLMAPIKey {
            persistedAPIKey = normalizedAPIKey
        } else {
            persistedAPIKey = try AppSettings.setExternalLLMAPIKey(normalizedAPIKey)
        }
        externalLLMBaseURL = externalLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        externalLLMModel = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        externalLLMAPIKey = persistedAPIKey
    }

    private func warmSelectedModelsAfterDone() {
        guard processingMode == .server else { return }
        Task { @MainActor in
            await ASRFactory.shared.preloadCachedActiveModel()
            _ = await CorrectorFactory.shared.preloadActiveModels()
        }
    }

    @MainActor
    private func startExternalLLMCheck(selectFirstModel: Bool) {
        externalLLMCheckTask?.cancel()
        guard let kind = selectedBackendKind,
              let apiKind = try? ExternalCompatibleCorrectorService.apiKind(for: kind)
        else { return }
        let checkID = UUID()
        let baseURL = externalLLMBaseURL
        let apiKey = externalLLMAPIKey
        let model = externalLLMModel
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
        let selected = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, externalLLMModels.contains(selected) {
            checkedExternalLLMConfig = currentExternalLLMConfig
            externalLLMStatus = "Ready"
            externalLLMDetail = "Selected \(selected)."
            return
        }
        if selectedBackendKind?.isExternalCompatible == true {
            resetExternalLLMCheck(detail: "Refresh models after changing the selected model.")
        }
    }

    private func applyExternalLLMReport(_ report: ExternalLLMCheckReport, selectFirstModel: Bool) {
        externalLLMStatus = report.status
        externalLLMDetail = report.detail
        externalLLMModels = report.modelIDs
        guard report.ok else { return }

        let previousModel = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshedModel = ExternalCompatibleCorrectorService.modelSelectionAfterRefresh(
            current: externalLLMModel,
            available: report.modelIDs,
            selectFirstModel: selectFirstModel
        )
        if refreshedModel != externalLLMModel {
            suppressNextExternalLLMModelReset = true
            externalLLMModel = refreshedModel
            if previousModel.isEmpty {
                externalLLMDetail = "Selected \(refreshedModel). \(report.detail)"
            } else {
                externalLLMDetail = "Previous model \(previousModel) is not listed. Switched to \(refreshedModel)."
            }
        }
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

    private var speechStatusText: String {
        switch speechStatus {
        case .granted: return "Granted"
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }

    private var microphoneActionTitle: String {
        microphoneStatus == .notDetermined ? "Request" : (microphoneStatus == .granted ? "Refresh" : "Open Settings")
    }

    private var speechActionTitle: String {
        speechStatus == .notDetermined ? "Request" : (speechStatus == .granted ? "Refresh" : "Open Settings")
    }

    private func requestMicrophone() {
        Task { @MainActor in
            if microphoneStatus == .notDetermined {
                microphoneStatus = await AppPermissions.requestMicrophone()
            } else if microphoneStatus != .granted {
                AppPermissions.openMicrophoneSettings()
            } else {
                microphoneStatus = AppPermissions.microphoneStatus
            }
        }
    }

    private func requestAccessibility() {
        if !axTrusted {
            AppPermissions.requestAccessibility()
            AppPermissions.openAccessibilitySettings()
        }
        axTrusted = AppPermissions.accessibilityTrusted
    }

    private func reimportAccessibility() {
        _ = AppPermissions.resetAccessibilityGrant()
        AppPermissions.requestAccessibility()
        AppPermissions.openAccessibilitySettings()
        axTrusted = AppPermissions.accessibilityTrusted
    }

    private func requestSpeechRecognition() {
        Task { @MainActor in
            if speechStatus == .notDetermined {
                speechStatus = await AppPermissions.requestSpeechRecognition()
            } else if speechStatus != .granted {
                AppPermissions.openSpeechRecognitionSettings()
            } else {
                speechStatus = AppPermissions.speechRecognitionStatus
            }
        }
    }

    private func refreshPermissions() {
        axTrusted = AppPermissions.accessibilityTrusted
        microphoneStatus = AppPermissions.microphoneStatus
        speechStatus = AppPermissions.speechRecognitionStatus
    }
}

private struct WizardStepPill: View {
    let title: String
    let number: Int
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(circleColor.opacity(isCurrent || isComplete ? 1 : 0.16))
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.caption.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: Capsule())
    }

    private var circleColor: Color {
        isComplete ? .green : (isCurrent ? .accentColor : .secondary)
    }
}

private struct WizardToggleLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WizardStatusLine: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct WizardPermissionRow: View {
    let title: String
    let detail: String
    let status: String
    let isReady: Bool
    let actionTitle: String
    let action: () -> Void
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?

    init(
        title: String,
        detail: String,
        status: String,
        isReady: Bool,
        actionTitle: String,
        action: @escaping () -> Void,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.isReady = isReady
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? .green : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(isReady ? .green : .orange)
            Button(actionTitle, action: action)
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct SetupModelPickerRow<Content: View>: View {
    let title: String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WizardBridgeRouteRow: View {
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
                        .font(.subheadline.weight(.medium))
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.16)))
                            .foregroundStyle(tint)
                    }
                }
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
        .padding(.vertical, 4)
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

private struct SetupQwenASRInstallRow: View {
    let spec: QwenASRModelSpec

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @AppStorage private var modelPath: String
    @AppStorage private var mmprojPath: String
    @AppStorage private var modelURL: String
    @AppStorage private var mmprojURL: String
    @StateObject private var manualOperation = ModelManualOperationController()

    init(spec: QwenASRModelSpec) {
        self.spec = spec
        self._modelPath = AppStorage(wrappedValue: spec.defaultModelPath, spec.modelPathKey)
        self._mmprojPath = AppStorage(wrappedValue: spec.defaultMMProjPath, spec.mmprojPathKey)
        self._modelURL = AppStorage(wrappedValue: spec.defaultModelURL, spec.modelURLKey)
        self._mmprojURL = AppStorage(wrappedValue: spec.defaultMMProjURL, spec.mmprojURLKey)
    }

    var body: some View {
        SetupInstallShell(
            title: spec.label,
            detail: spec.note,
            isInstalled: isInstalled,
            isDownloading: isDownloading || manualOperation.isPending,
            failureText: failureText,
            progress: progress,
            installAction: startDownloads,
            cancelAction: {
                manualOperation.cancel()
                cancelDownloads()
            }
        )
        .onDisappear {
            manualOperation.cancel()
        }
    }

    private func startDownloads() {
        guard let modelDownloadURL = URL(string: effectiveModelURLString),
              let mmprojDownloadURL = URL(string: effectiveMMProjURLString),
              let modelChecksumPolicy = setupChecksumPolicy(
                for: modelDownloadURL,
                label: "Qwen3-ASR model",
                downloader: modelDownloader
              ),
              let mmprojChecksumPolicy = setupChecksumPolicy(
                for: mmprojDownloadURL,
                label: "Qwen3-ASR mmproj",
                downloader: mmprojDownloader
              )
        else { return }
        let modelPath = effectiveModelPath
        let mmprojPath = effectiveMMProjPath
        manualOperation.start {
            do {
                try AppPaths.ensureDirectories()
                let paths = [modelPath, mmprojPath]
                let maintenanceLease = try await ModelManualMaintenance.begin(atPaths: paths) {
                    try await ASRFactory.shared.beginQwenLlamaMaintenance()
                }
                modelDownloader.start(
                    from: modelDownloadURL,
                    to: URL(fileURLWithPath: modelPath),
                    checksumPolicy: modelChecksumPolicy,
                    operationOwner: maintenanceLease
                )
                mmprojDownloader.start(
                    from: mmprojDownloadURL,
                    to: URL(fileURLWithPath: mmprojPath),
                    checksumPolicy: mmprojChecksumPolicy,
                    operationOwner: maintenanceLease
                )
            } catch is CancellationError {
                return
            } catch {
                modelDownloader.fail(error.localizedDescription)
            }
        }
    }

    private func cancelDownloads() {
        modelDownloader.cancel()
        mmprojDownloader.cancel()
    }

    private var effectiveModelPath: String { modelPath.isEmpty ? spec.defaultModelPath : modelPath }
    private var effectiveMMProjPath: String { mmprojPath.isEmpty ? spec.defaultMMProjPath : mmprojPath }
    private var effectiveModelURLString: String {
        let trimmed = modelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultModelURL : trimmed
    }
    private var effectiveMMProjURLString: String {
        let trimmed = mmprojURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultMMProjURL : trimmed
    }
    private var modelDownloader: ModelDownloader {
        modelDownloads.downloader(for: SetupWizardDownloadKey.qwenModel(spec))
    }
    private var mmprojDownloader: ModelDownloader {
        modelDownloads.downloader(for: SetupWizardDownloadKey.qwenMMProj(spec))
    }
    private var isInstalled: Bool {
        FileManager.default.fileExists(atPath: effectiveModelPath)
            && FileManager.default.fileExists(atPath: effectiveMMProjPath)
    }
    private var isDownloading: Bool {
        if case .downloading = modelDownloader.state { return true }
        if case .downloading = mmprojDownloader.state { return true }
        return false
    }
    private var failureText: String? {
        if case .failed(let why) = modelDownloader.state { return "Model: \(why)" }
        if case .failed(let why) = mmprojDownloader.state { return "mmproj: \(why)" }
        return nil
    }
    private var progress: SetupInstallProgress {
        SetupInstallProgress(
            received: setupDownloaderReceivedBytes(modelDownloader, fallbackPath: effectiveModelPath)
                + setupDownloaderReceivedBytes(mmprojDownloader, fallbackPath: effectiveMMProjPath),
            total: setupDownloaderTotalBytes(modelDownloader) + setupDownloaderTotalBytes(mmprojDownloader)
        )
    }
}

private struct SetupNvidiaNemotronInstallRow: View {
    let spec: NvidiaNemotronASRModelSpec
    let files: [NvidiaNemotronASRFileSpec]

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @AppStorage private var encoderPath: String
    @AppStorage private var encoderDataPath: String
    @AppStorage private var decoderJointPath: String
    @AppStorage private var tokenizerPath: String
    @AppStorage private var encoderURL: String
    @AppStorage private var encoderDataURL: String
    @AppStorage private var decoderJointURL: String
    @AppStorage private var tokenizerURL: String
    @StateObject private var manualOperation = ModelManualOperationController()

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
        SetupInstallShell(
            title: spec.label,
            detail: spec.note,
            isInstalled: isInstalled,
            isDownloading: isDownloading || manualOperation.isPending,
            failureText: failureText,
            progress: progress,
            installAction: startDownloads,
            cancelAction: {
                manualOperation.cancel()
                cancelDownloads()
            }
        )
        .onDisappear {
            manualOperation.cancel()
        }
    }

    private func startDownloads() {
        let paths = effectivePaths
        let urlStrings = [encoderURL, encoderDataURL, decoderJointURL, tokenizerURL]
        let downloaders = [encoderDownloader, encoderDataDownloader, decoderJointDownloader, tokenizerDownloader]
        var prepared: [(URL, String, ModelDownloader, ModelDownloadChecksumPolicy, Int64)] = []
        for index in files.indices {
            let trimmed = urlStrings[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let downloadURL = URL(string: trimmed.isEmpty ? files[index].defaultURL : trimmed),
                  let checksumPolicy = setupChecksumPolicy(
                    for: downloadURL,
                    label: files[index].label,
                    downloader: downloaders[index]
                  )
            else { return }
            prepared.append((
                downloadURL,
                paths[index],
                downloaders[index],
                checksumPolicy,
                files[index].expectedBytes
            ))
        }
        manualOperation.start {
            do {
                try AppPaths.ensureDirectories()
                let maintenanceLease = try await ModelManualMaintenance.begin(atPaths: paths) {
                    try await ASRFactory.shared.beginNvidiaNemotronMaintenance()
                }
                for request in prepared {
                    request.2.start(
                        from: request.0,
                        to: URL(fileURLWithPath: request.1),
                        checksumPolicy: request.3,
                        expectedBytes: request.4,
                        operationOwner: maintenanceLease
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                encoderDownloader.fail(error.localizedDescription)
            }
        }
    }

    private func cancelDownloads() {
        encoderDownloader.cancel()
        encoderDataDownloader.cancel()
        decoderJointDownloader.cancel()
        tokenizerDownloader.cancel()
    }

    private var effectiveEncoderPath: String { setupEffectivePath(encoderPath, fallback: files[0].defaultPath) }
    private var effectiveEncoderDataPath: String { setupEffectivePath(encoderDataPath, fallback: files[1].defaultPath) }
    private var effectiveDecoderJointPath: String { setupEffectivePath(decoderJointPath, fallback: files[2].defaultPath) }
    private var effectiveTokenizerPath: String { setupEffectivePath(tokenizerPath, fallback: files[3].defaultPath) }
    private var effectivePaths: [String] {
        [effectiveEncoderPath, effectiveEncoderDataPath, effectiveDecoderJointPath, effectiveTokenizerPath]
    }
    private var encoderDownloader: ModelDownloader { downloader(for: files[0]) }
    private var encoderDataDownloader: ModelDownloader { downloader(for: files[1]) }
    private var decoderJointDownloader: ModelDownloader { downloader(for: files[2]) }
    private var tokenizerDownloader: ModelDownloader { downloader(for: files[3]) }
    private func downloader(for file: NvidiaNemotronASRFileSpec) -> ModelDownloader {
        modelDownloads.downloader(for: SetupWizardDownloadKey.nvidiaNemotronFile(model: spec, file: file))
    }
    private var isInstalled: Bool {
        effectivePaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
    private var isDownloading: Bool {
        [encoderDownloader, encoderDataDownloader, decoderJointDownloader, tokenizerDownloader].contains { downloader in
            if case .downloading = downloader.state { return true }
            return false
        }
    }
    private var failureText: String? {
        for downloader in [encoderDownloader, encoderDataDownloader, decoderJointDownloader, tokenizerDownloader] {
            if case .failed(let why) = downloader.state { return why }
        }
        return nil
    }
    private var progress: SetupInstallProgress {
        let received = zip(files, [encoderDownloader, encoderDataDownloader, decoderJointDownloader, tokenizerDownloader])
            .map { file, downloader in
                switch downloader.state {
                case .completed:
                    return file.expectedBytes
                case .downloading(let received, _):
                    return received
                default:
                    return setupExistingByteCount(atPath: effectivePathForFile(file))
                }
            }
            .reduce(0, +)
        return SetupInstallProgress(received: received, total: files.map(\.expectedBytes).reduce(0, +))
    }
    private func effectivePathForFile(_ file: NvidiaNemotronASRFileSpec) -> String {
        if file.id == files[0].id { return effectiveEncoderPath }
        if file.id == files[1].id { return effectiveEncoderDataPath }
        if file.id == files[2].id { return effectiveDecoderJointPath }
        return effectiveTokenizerPath
    }
}

private struct SetupLocalLlamaInstallRow: View {
    let spec: LocalLlamaModelSpec

    @EnvironmentObject private var modelDownloads: ModelDownloadRegistry
    @AppStorage private var path: String
    @AppStorage private var url: String
    @StateObject private var manualOperation = ModelManualOperationController()

    init(spec: LocalLlamaModelSpec) {
        self.spec = spec
        self._path = AppStorage(wrappedValue: spec.defaultPath, spec.pathKey)
        self._url = AppStorage(wrappedValue: "", spec.urlKey)
    }

    var body: some View {
        SetupInstallShell(
            title: spec.label,
            detail: spec.note,
            isInstalled: isInstalled,
            isDownloading: isDownloading || manualOperation.isPending,
            failureText: failureText,
            progress: progress,
            installAction: startDownload,
            cancelAction: {
                manualOperation.cancel()
                downloader.cancel()
            }
        )
        .onDisappear {
            manualOperation.cancel()
        }
    }

    private func startDownload() {
        guard let downloadURL = URL(string: effectiveURLString) else { return }
        let destination = URL(fileURLWithPath: effectivePath)
        manualOperation.start {
            do {
                try AppPaths.ensureDirectories()
                let autoInstallLease = try await ModelAutoInstaller.shared.beginMaintenance(
                    atPaths: [destination.path]
                )
                guard !Task.isCancelled else {
                    await autoInstallLease.finishAndWait()
                    return
                }
                await CorrectorFactory.shared.drainAndShutdownAll()
                guard !Task.isCancelled else {
                    await autoInstallLease.finishAndWait()
                    return
                }
                guard let checksumPolicy = setupChecksumPolicy(
                    for: downloadURL,
                    label: spec.label,
                    downloader: downloader
                ) else {
                    await autoInstallLease.finishAndWait()
                    return
                }
                downloader.start(
                    from: downloadURL,
                    to: destination,
                    checksumPolicy: checksumPolicy,
                    operationOwner: autoInstallLease
                )
            } catch is CancellationError {
                return
            } catch {
                downloader.fail(error.localizedDescription)
            }
        }
    }

    private var effectivePath: String { setupEffectivePath(path, fallback: spec.defaultPath) }
    private var effectiveURLString: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var downloader: ModelDownloader {
        modelDownloads.downloader(for: SetupWizardDownloadKey.localLlama(spec))
    }
    private var isInstalled: Bool {
        FileManager.default.fileExists(atPath: effectivePath)
    }
    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        return false
    }
    private var failureText: String? {
        if effectiveURLString.isEmpty {
            return "Download URL is missing."
        }
        if case .failed(let why) = downloader.state {
            return why
        }
        return nil
    }
    private var progress: SetupInstallProgress {
        SetupInstallProgress(
            received: setupDownloaderReceivedBytes(downloader, fallbackPath: effectivePath),
            total: setupDownloaderTotalBytes(downloader)
        )
    }
}

private struct SetupInstallShell: View {
    let title: String
    let detail: String
    let isInstalled: Bool
    let isDownloading: Bool
    let failureText: String?
    let progress: SetupInstallProgress
    let installAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(isInstalled ? .green : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isInstalled {
                    Text("Installed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else if !isDownloading {
                    Button("Install", action: installAction)
                        .disabled(failureText == "Download URL is missing.")
                }
            }
            if isDownloading {
                ProgressView(value: progress.total > 0 ? Double(progress.received) / Double(progress.total) : nil)
                HStack {
                    Text("\(setupFormatBytes(progress.received)) / \(setupFormatBytes(progress.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: cancelAction)
                        .controlSize(.small)
                }
            }
            if let failureText, !isInstalled {
                Text(failureText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SetupInstallProgress {
    let received: Int64
    let total: Int64
}

private enum SetupWizardDownloadKey {
    static func qwenModel(_ spec: QwenASRModelSpec) -> String {
        "setup.asr.qwen.\(spec.id).model"
    }

    static func qwenMMProj(_ spec: QwenASRModelSpec) -> String {
        "setup.asr.qwen.\(spec.id).mmproj"
    }

    static func nvidiaNemotronFile(model: NvidiaNemotronASRModelSpec, file: NvidiaNemotronASRFileSpec) -> String {
        "setup.asr.nvidia-nemotron.\(model.id).\(file.id)"
    }

    static func localLlama(_ spec: LocalLlamaModelSpec) -> String {
        "setup.correction.local-llama.\(spec.id)"
    }
}

@MainActor
private func setupChecksumPolicy(
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

private func setupEffectivePath(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
}

private func setupFormatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func setupExistingByteCount(atPath path: String) -> Int64 {
    (try? ModelDownloadIntegrity.byteCount(of: URL(fileURLWithPath: path))) ?? 0
}

@MainActor
private func setupDownloaderReceivedBytes(_ downloader: ModelDownloader, fallbackPath: String) -> Int64 {
    switch downloader.state {
    case .completed:
        return setupExistingByteCount(atPath: fallbackPath)
    case .downloading(let received, _):
        return received
    default:
        return setupExistingByteCount(atPath: fallbackPath)
    }
}

@MainActor
private func setupDownloaderTotalBytes(_ downloader: ModelDownloader) -> Int64 {
    switch downloader.state {
    case .downloading(let received, let total):
        return max(received, total)
    default:
        return 0
    }
}
