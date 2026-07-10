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
    @State private var routeStatus: BridgeRouteResolutionStatus
    @State private var tokenVisible = false
    @State private var showingQRScanner = false
    @State private var pairingParseTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration: UInt64 = 0
    @State private var activeRefreshFingerprint: PairingRefreshFingerprint?
    @State private var isUnpairing = false

    let onSave: (PairingConfig) -> Bool
    let onSaveConnection: (BridgeEndpoints) -> Bool
    let onUnpair: () async -> Void

    init(
        config: PairingConfig,
        routeStatus: BridgeRouteResolutionStatus,
        onSave: @escaping (PairingConfig) -> Bool,
        onSaveConnection: @escaping (BridgeEndpoints) -> Bool,
        onUnpair: @escaping () async -> Void
    ) {
        self._config = State(initialValue: config)
        self._routeStatus = State(initialValue: routeStatus)
        self.onSave = onSave
        self.onSaveConnection = onSaveConnection
        self.onUnpair = onUnpair
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Open the Mac app, copy the pairing JSON, then paste it here. Pairing stores connection details. Languages and the default dictation mode are iPhone settings.")
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
                                cancelRefreshIfInputChanged()
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
                            cancelRefresh()
                            isUnpairing = true
                            Task { @MainActor in
                                await onUnpair()
                                config = .empty
                                pairingJSON = ""
                                parseError = nil
                                parsedSuccessfully = false
                                routeStatus = BridgeRouteResolutionStatus()
                                isUnpairing = false
                                dismiss()
                            }
                        } label: {
                            Label(
                                isUnpairing ? "Unpairing…" : "Unpair This Device",
                                systemImage: "link.badge.minus"
                            )
                        }
                        .disabled(isUnpairing)
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
                    Button("Cancel") {
                        cancelRefresh()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        pairingParseTask?.cancel()
                        pairingParseTask = nil
                        cancelRefresh()
                        if onSave(config) {
                            dismiss()
                        } else {
                            parseError = NSLocalizedString(
                                "Couldn't save pairing securely. Your previous pairing is unchanged.",
                                comment: "Pairing persistence failure"
                            )
                        }
                    }
                    .disabled(!config.hasAnyBridgeURL || config.token.isEmpty)
                }
            }
            .sheet(isPresented: $showingQRScanner) {
                PairingQRScannerView { payload in
                    cancelRefresh()
                    pairingJSON = payload
                    schedulePairingParse(payload)
                }
            }
            .onChange(of: config) { _, _ in
                cancelRefreshIfInputChanged()
            }
            .onDisappear {
                pairingParseTask?.cancel()
                pairingParseTask = nil
                cancelRefresh()
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
            config.primaryLANBridgeURL
        } set: { newValue in
            config.primaryLANBridgeURL = newValue
        }
    }

    private func refreshRouteStatus() {
        guard !isPulling else { return }
        isPulling = true
        parseError = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let fingerprint = currentRefreshFingerprint
        activeRefreshFingerprint = fingerprint
        refreshTask = Task { @MainActor in
            let route = await BridgeRouteResolver().resolve(
                config: fingerprint.config,
                probeAllEndpoints: true
            )
            guard refreshIsCurrent(generation, fingerprint: fingerprint) else { return }
            let refreshedConfig: PairingConfig?
            if let activeURL = route.activeURL {
                refreshedConfig = try? await BridgeClient(
                    baseURL: activeURL,
                    token: fingerprint.config.token
                ).pairing(timeout: 4)
            } else {
                refreshedConfig = nil
            }
            guard refreshIsCurrent(generation, fingerprint: fingerprint) else { return }
            var candidate = fingerprint.config
            if let refreshedConfig {
                candidate.bridgeEndpoints = refreshedConfig.bridgeEndpoints
            } else if route.activeKind == .local, let activeURL = route.activeURL?.absoluteString {
                candidate.promoteLocalBridgeURL(activeURL)
            }
            candidate.normalizeBridgeEndpoints()
            guard completeRefresh(generation, fingerprint: fingerprint) else { return }
            routeStatus = route
            if candidate.bridgeEndpoints != fingerprint.config.bridgeEndpoints {
                if !onSaveConnection(candidate.bridgeEndpoints) {
                    parseError = NSLocalizedString(
                        "Couldn't save pairing securely. Your previous pairing is unchanged.",
                        comment: "Pairing persistence failure"
                    )
                } else {
                    config = candidate
                }
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
            cancelRefresh()
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
            let payload = try JSONDecoder().decode(BridgePairingPayload.self, from: data)
            var decoded = payload.config(
                languageIDs: config.languageIDs,
                supportedLanguages: config.supportedLanguages,
                correctionMode: config.correctionMode
            )
            decoded.normalize()
            cancelRefresh()
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
        isPulling = true
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let fingerprint = currentRefreshFingerprint
        activeRefreshFingerprint = fingerprint
        refreshTask = Task { @MainActor in
            let route = await BridgeRouteResolver().resolve(
                config: fingerprint.config,
                probeAllEndpoints: true
            )
            guard refreshIsCurrent(generation, fingerprint: fingerprint) else { return }
            guard let activeURL = route.activeURL else {
                guard completeRefresh(generation, fingerprint: fingerprint) else { return }
                routeStatus = route
                parseError = BridgeClientError.unauthorizedOrUnavailable.localizedDescription
                return
            }
            let client = BridgeClient(baseURL: activeURL, token: fingerprint.config.token)
            do {
                let refreshedConfig = try? await client.pairing(timeout: 4)
                guard refreshIsCurrent(generation, fingerprint: fingerprint) else { return }
                var settings = try await client.macSettings()
                settings.normalize()
                guard refreshIsCurrent(generation, fingerprint: fingerprint) else { return }
                var candidate = fingerprint.config
                if let refreshedConfig {
                    candidate.bridgeEndpoints = refreshedConfig.bridgeEndpoints
                } else if route.activeKind == .local {
                    candidate.promoteLocalBridgeURL(activeURL.absoluteString)
                }
                applyMacSettings(settings, to: &candidate)
                guard completeRefresh(generation, fingerprint: fingerprint) else { return }
                routeStatus = route
                config = candidate
                parsedSuccessfully = true
                if saveAfterRefresh {
                    if !onSave(candidate) {
                        parseError = NSLocalizedString(
                            "Couldn't save pairing securely. Your previous pairing is unchanged.",
                            comment: "Pairing persistence failure"
                        )
                    }
                }
            } catch {
                guard completeRefresh(generation, fingerprint: fingerprint) else { return }
                parseError = error.localizedDescription
            }
        }
    }

    private var currentRefreshFingerprint: PairingRefreshFingerprint {
        PairingRefreshFingerprint(config: config, pairingJSON: pairingJSON)
    }

    private func refreshIsCurrent(
        _ generation: UInt64,
        fingerprint: PairingRefreshFingerprint
    ) -> Bool {
        guard !Task.isCancelled,
              !isUnpairing,
              refreshGeneration == generation,
              activeRefreshFingerprint == fingerprint,
              currentRefreshFingerprint == fingerprint
        else {
            if refreshGeneration == generation {
                cancelRefresh()
            }
            return false
        }
        return true
    }

    private func completeRefresh(
        _ generation: UInt64,
        fingerprint: PairingRefreshFingerprint
    ) -> Bool {
        guard refreshIsCurrent(generation, fingerprint: fingerprint) else { return false }
        refreshTask = nil
        activeRefreshFingerprint = nil
        isPulling = false
        return true
    }

    private func cancelRefreshIfInputChanged() {
        guard let activeRefreshFingerprint,
              activeRefreshFingerprint != currentRefreshFingerprint
        else { return }
        cancelRefresh()
    }

    private func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        activeRefreshFingerprint = nil
        isPulling = false
    }

    private func applyMacSettings(_ settings: BridgeMacSettingsPayload, to config: inout PairingConfig) {
        config.supportedLanguages = settings.supportedLanguages
        config.languageIDs = ASRLanguageSelection.validatedIDs(
            config.languageIDs,
            supportedOptions: config.supportedLanguageOptions
        )
        config.normalize()
    }

}

private struct PairingRefreshFingerprint: Equatable {
    let config: PairingConfig
    let pairingJSON: String
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
