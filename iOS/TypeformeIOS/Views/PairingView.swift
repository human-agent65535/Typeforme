import SwiftUI
import UIKit

struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: PairingConfig
    @State private var pairingJSON = ""
    @State private var parseError: String?
    @State private var parsedSuccessfully = false
    @State private var parsedSource = ""
    @State private var isPulling = false
    @State private var routeStatus: BridgeRouteStatus
    @State private var tokenVisible = false
    @State private var showingQRScanner = false
    @State private var pairingParseTask: Task<Void, Never>?

    let onSave: (PairingConfig) -> Void
    let onUnpair: () -> Void

    init(
        config: PairingConfig,
        routeStatus: BridgeRouteStatus,
        onSave: @escaping (PairingConfig) -> Void,
        onUnpair: @escaping () -> Void
    ) {
        self._config = State(initialValue: config)
        self._routeStatus = State(initialValue: routeStatus)
        self.onSave = onSave
        self.onUnpair = onUnpair
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Open the Mac app, copy the pairing JSON, then paste it here. Pairing only stores connection details. Languages are an iOS override on the main screen, and the default mode follows Dictation Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Paste Pairing JSON") {
                    Button {
                        pastePairingJSON()
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showingQRScanner = true
                    } label: {
                        Label("Scan QR from Mac", systemImage: "qrcode.viewfinder")
                    }
                    if !pairingJSON.isEmpty {
                        TextEditor(text: $pairingJSON)
                            .frame(minHeight: 100)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: pairingJSON) { _, _ in
                                schedulePairingParse(pairingJSON)
                            }
                    }
                    if parsedSuccessfully {
                        Label("Pairing JSON parsed. Tap Save to apply.", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Bridge") {
                    LabeledContent("Local URL") {
                        TextField("http://192.168.…", text: localURLBinding)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    if config.localBridgeURLCandidates.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(
                                format: NSLocalizedString("%d local candidates from the Mac", comment: "Local bridge URL candidate count"),
                                config.localBridgeURLCandidates.count
                            ))
                                .font(.footnote.weight(.medium))
                            ForEach(config.localBridgeURLCandidates, id: \.self) { url in
                                Text(url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    LabeledContent("Cloud URL") {
                        TextField("https://…", text: $config.publicBridgeURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Token") {
                        HStack(spacing: 6) {
                            // Mirror the SecureField/TextField pair Apple uses
                            // for password fields with a "reveal" eye icon —
                            // pasted tokens are easy to misread without it.
                            Group {
                                if tokenVisible {
                                    TextField("paste token", text: $config.token)
                                } else {
                                    SecureField("paste token", text: $config.token)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)

                            Button {
                                tokenVisible.toggle()
                            } label: {
                                Image(systemName: tokenVisible ? "eye.slash" : "eye")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tokenVisible ? "Hide token" : "Show token")
                        }
                    }
                    Button {
                        refreshFromMac(saveAfterRefresh: true)
                    } label: {
                        Label(
                            isPulling
                                ? NSLocalizedString("Pulling…", comment: "Pairing settings pull in progress")
                                : NSLocalizedString("Refresh Dictation Settings", comment: "Pull dictation settings button"),
                            systemImage: "arrow.down.doc"
                        )
                    }
                    .disabled(isPulling || !config.hasAnyBridgeURL || config.token.isEmpty)
                }

                if isPaired {
                    Section("Repair") {
                        Button(role: .destructive) {
                            pairingParseTask?.cancel()
                            pairingParseTask = nil
                            config = .empty
                            pairingJSON = ""
                            parseError = nil
                            parsedSuccessfully = false
                            routeStatus = BridgeRouteStatus()
                            onUnpair()
                            dismiss()
                        } label: {
                            Label("Unpair This Device", systemImage: "link.badge.minus")
                        }
                    }
                }

                Section("Routing") {
                    PairingRouteRow(
                        title: "Local",
                        endpoint: primaryLocalEndpoint,
                        state: endpointState(
                            isConfigured: !config.localBridgeURLCandidates.isEmpty,
                            isChecked: routeStatus.localChecked,
                            isOK: routeStatus.localOK
                        ),
                        latencyMs: routeStatus.localLatencyMs,
                        isActive: routeStatus.activeKind == .local,
                        tint: .green
                    )
                    PairingRouteRow(
                        title: "Cloud",
                        endpoint: serverEndpoint,
                        state: endpointState(
                            isConfigured: !config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            isChecked: routeStatus.cloudChecked,
                            isOK: routeStatus.cloudOK
                        ),
                        latencyMs: routeStatus.cloudLatencyMs,
                        isActive: routeStatus.activeKind == .cloud,
                        tint: .blue
                    )
                    Button {
                        refreshRouteStatus()
                    } label: {
                        Label(
                            isPulling
                                ? NSLocalizedString("Checking…", comment: "Route check in progress")
                                : NSLocalizedString("Check Routes", comment: "Check routes button"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isPulling || !config.hasAnyBridgeURL || config.token.isEmpty)
                    Text("When Wi-Fi is active, Typeforme tries Local first. If Local is unavailable, it falls back to Cloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pairing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(config)
                        dismiss()
                    }
                    .disabled(!config.hasAnyBridgeURL || config.token.isEmpty)
                }
            }
            .sheet(isPresented: $showingQRScanner) {
                PairingQRScannerView { payload in
                    pairingJSON = payload
                    schedulePairingParse(payload)
                }
            }
            .onDisappear {
                pairingParseTask?.cancel()
                pairingParseTask = nil
            }
        }
    }

    private var primaryLocalEndpoint: String {
        if routeStatus.activeKind == .local, let activeURL = routeStatus.activeURL?.absoluteString {
            return activeURL
        }
        return config.localBridgeURLCandidates.first ?? NSLocalizedString("Not configured", comment: "Pairing route missing endpoint")
    }

    private var serverEndpoint: String {
        let trimmed = config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSLocalizedString("Not configured", comment: "Pairing route missing endpoint") : trimmed
    }

    private var isPaired: Bool {
        config.hasAnyBridgeURL || !config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func endpointState(isConfigured: Bool, isChecked: Bool, isOK: Bool) -> String {
        if !isConfigured { return "Not configured" }
        if isOK { return "Available" }
        return isChecked ? "Unavailable" : "Not checked"
    }

    private var localURLBinding: Binding<String> {
        Binding {
            config.lanBridgeURL
        } set: { newValue in
            config.lanBridgeURL = newValue
            config.lanBridgeURLs = PairingConfig.uniqueBridgeURLs([newValue])
        }
    }

    private func refreshRouteStatus() {
        guard !isPulling else { return }
        isPulling = true
        parseError = nil
        Task {
            let route = await BridgeRouteResolver().resolve(config: config, probeAllEndpoints: true)
            await MainActor.run {
                routeStatus = route
                if route.activeKind == .local, let activeURL = route.activeURL?.absoluteString {
                    config.promoteLocalBridgeURL(activeURL)
                }
                isPulling = false
            }
        }
    }

    private func pastePairingJSON() {
        let pasted = UIPasteboard.general.string ?? ""
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parseError = NSLocalizedString("Clipboard is empty.", comment: "Pairing paste error")
            parsedSuccessfully = false
            return
        }
        if pasted == pairingJSON {
            schedulePairingParse(pasted)
        } else {
            pairingJSON = pasted
            schedulePairingParse(pasted)
        }
    }

    private func schedulePairingParse(_ rawValue: String) {
        pairingParseTask?.cancel()
        pairingParseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            parsePairingJSON(rawValue)
        }
    }

    private func parsePairingJSON(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = nil
            parsedSuccessfully = false
            return
        }
        if trimmed == parsedSource, parsedSuccessfully { return }
        parseError = nil
        parsedSuccessfully = false
        guard let data = trimmed.data(using: .utf8) else {
            parseError = NSLocalizedString("Pasted text isn't valid UTF-8.", comment: "Pairing paste error")
            return
        }
        do {
            let payload = try JSONDecoder().decode(PairingPayload.self, from: data)
            var decoded = payload.config(
                languageIDs: config.languageIDs,
                supportedLanguages: config.supportedLanguages,
                correctionMode: config.correctionMode
            )
            decoded.normalizeLanguageIDs()
            config = decoded
            parsedSuccessfully = true
            parsedSource = trimmed
            if decoded.hasAnyBridgeURL, !decoded.token.isEmpty {
                refreshFromMac(saveAfterRefresh: false)
            }
        } catch {
            parseError = String(
                format: NSLocalizedString("Couldn't parse as pairing JSON: %@", comment: "Pairing JSON parse error"),
                error.localizedDescription
            )
        }
    }

    private func refreshFromMac(saveAfterRefresh: Bool) {
        guard !isPulling else { return }
        parseError = nil
        let token = config.token
        isPulling = true
        Task {
            let route = await BridgeRouteResolver().resolve(config: config, probeAllEndpoints: true)
            guard let activeURL = route.activeURL else {
                await MainActor.run {
                    routeStatus = route
                    parseError = BridgeClientError.unauthorizedOrUnavailable.localizedDescription
                    isPulling = false
                }
                return
            }
            let client = BridgeClient(baseURL: activeURL, token: token)
            do {
                var settings = try await client.macSettings()
                settings.normalize()
                await MainActor.run {
                    routeStatus = route
                    if route.activeKind == .local {
                        config.promoteLocalBridgeURL(activeURL.absoluteString)
                    }
                    applyMacSettings(settings)
                    parsedSuccessfully = true
                    if saveAfterRefresh {
                        onSave(config)
                    }
                    isPulling = false
                }
            } catch {
                await MainActor.run {
                    parseError = error.localizedDescription
                    isPulling = false
                }
            }
        }
    }

    private func applyMacSettings(_ settings: BridgeMacSettingsPayload) {
        config.supportedLanguages = settings.supportedLanguages
        config.correctionMode = settings.correctionMode
        config.languageIDs = ASRLanguageSelection.validatedIDs(
            config.languageIDs,
            supportedOptions: config.supportedLanguageOptions
        )
        config.normalizeLanguageIDs()
    }

}

private struct PairingRouteRow: View {
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
                    Text(NSLocalizedString(title, comment: "Pairing route title"))
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
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(NSLocalizedString(state, comment: "Pairing route state"))
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
