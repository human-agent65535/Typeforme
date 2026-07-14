import Foundation

@MainActor
final class ClientBridgeSettingsSync {
    private nonisolated static let minimumSyncInterval: TimeInterval = 60

    private var lastSyncAt: Date?
    private var lastSyncedConfiguration: ClientBridgeConfiguration?
    private var syncTask: Task<Void, Never>?
    private var activeConfiguration: ClientBridgeConfiguration?
    private var activeSyncID: UUID?

    func syncIfNeeded(force: Bool = false) {
        guard AppSettings.processingMode == .client else {
            cancel()
            return
        }
        let configuration = ClientBridgeConfiguration.current
        guard configuration.isConfigured else {
            cancel()
            return
        }
        if syncTask != nil, activeConfiguration != configuration {
            cancel()
        }
        if !force, Self.shouldThrottle(
            now: Date(),
            lastSyncAt: lastSyncAt,
            lastSyncedConfiguration: lastSyncedConfiguration,
            currentConfiguration: configuration
        ) {
            return
        }
        guard syncTask == nil else { return }

        let syncID = UUID()
        activeConfiguration = configuration
        activeSyncID = syncID
        syncTask = Task { [weak self] in
            await self?.sync(
                force: force,
                syncID: syncID,
                configuration: configuration
            )
        }
    }

    func cancel() {
        activeSyncID = nil
        syncTask?.cancel()
        syncTask = nil
        activeConfiguration = nil
        lastSyncAt = nil
        lastSyncedConfiguration = nil
    }

    func configurationDidChange() {
        cancel()
    }

    static func applyServerDefaults(_ settings: BridgeSettingsPayload) {
        let sources = settings.enabledSources
        AppSettings.setClientBridgeEnabledRecognitionSources(sources)
        AppSettings.setClientSettingsRevision(settings.settingsRevision)
        UserDefaults.standard.set(settings.fastASRSource, forKey: AppSettings.Keys.fastASRSource)

        if let languageRawValue = clientLanguageRawValue(
            currentLanguageIDs: AppSettings.clientLanguageIDs,
            settings: settings
        ) {
            UserDefaults.standard.set(
                languageRawValue,
                forKey: AppSettings.Keys.clientLanguageIDs
            )
        }
    }

    /// `supported_languages_by_recognition_source.apple-speech == []` is the
    /// Bridge's explicit cold-cache state. Until it becomes authoritative, do
    /// not reinterpret an empty or partial union as a reason to overwrite the
    /// client's canonical selection.
    nonisolated static func clientLanguageRawValue(
        currentLanguageIDs: [String],
        settings: BridgeSettingsPayload
    ) -> String? {
        let sources = settings.enabledSources
        if sources.contains(.appleSpeech),
           settings.supportedLanguageOptions(for: RecognitionSource.appleSpeech.rawValue).isEmpty {
            return nil
        }
        let supported = settings.supportedLanguageOptionsForEnabledSources()
        guard !supported.isEmpty else { return nil }
        let validated = ASRLanguageSelection.validatedIDs(
            currentLanguageIDs,
            supportedOptions: supported
        )
        return ASRLanguageSelection.rawValue(
            for: validated,
            supportedOptions: supported
        )
    }

    nonisolated static func shouldApplyResponse(
        taskIsActive: Bool,
        taskConfiguration: ClientBridgeConfiguration,
        currentConfiguration: ClientBridgeConfiguration,
        processingMode: ProcessingMode,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && taskIsActive
            && taskConfiguration == currentConfiguration
            && processingMode == .client
    }

    nonisolated static func shouldThrottle(
        now: Date,
        lastSyncAt: Date?,
        lastSyncedConfiguration: ClientBridgeConfiguration?,
        currentConfiguration: ClientBridgeConfiguration
    ) -> Bool {
        guard lastSyncedConfiguration == currentConfiguration,
              let lastSyncAt
        else { return false }
        return now.timeIntervalSince(lastSyncAt) < minimumSyncInterval
    }

    nonisolated static func settingsRevisionMatches(
        serverRevision: String?,
        storedRevision: String,
        revisionConfiguration: ClientBridgeConfiguration?,
        currentConfiguration: ClientBridgeConfiguration
    ) -> Bool {
        guard revisionConfiguration == currentConfiguration else { return false }
        let normalizedServerRevision = serverRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !normalizedServerRevision.isEmpty
            && normalizedServerRevision == storedRevision
    }

    private func sync(
        force: Bool,
        syncID: UUID,
        configuration: ClientBridgeConfiguration
    ) async {
        defer {
            if activeSyncID == syncID {
                syncTask = nil
                activeConfiguration = nil
                activeSyncID = nil
            }
        }

        do {
            let resolved = try await RemoteBridgeClient.resolved(
                config: configuration,
                probeAllEndpoints: true
            )
            guard isCurrentClientSync(syncID, configuration: configuration) else { return }
            if !force {
                let health = try await resolved.client.health(timeout: 4)
                guard isCurrentClientSync(syncID, configuration: configuration) else { return }
                if Self.settingsRevisionMatches(
                    serverRevision: health.settingsRevision,
                    storedRevision: AppSettings.clientSettingsRevision,
                    revisionConfiguration: lastSyncedConfiguration,
                    currentConfiguration: configuration
                ) {
                    lastSyncAt = Date()
                    lastSyncedConfiguration = configuration
                    Log.bridge.debug("Client bridge settings unchanged via \(resolved.routeStatus.activeKind.rawValue, privacy: .public)")
                    return
                }
            }
            var settings = try await resolved.client.settings(timeout: 6)
            settings.normalize()
            guard isCurrentClientSync(syncID, configuration: configuration) else { return }
            Self.applyServerDefaults(settings)
            lastSyncAt = Date()
            lastSyncedConfiguration = configuration
            Log.bridge.info("Client bridge settings synced via \(resolved.routeStatus.activeKind.rawValue, privacy: .public)")
        } catch {
            if !Task.isCancelled {
                Log.bridge.debug("Client bridge settings sync skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func isCurrentClientSync(
        _ syncID: UUID,
        configuration: ClientBridgeConfiguration
    ) -> Bool {
        Self.shouldApplyResponse(
            taskIsActive: activeSyncID == syncID,
            taskConfiguration: configuration,
            currentConfiguration: ClientBridgeConfiguration.current,
            processingMode: AppSettings.processingMode,
            isCancelled: Task.isCancelled
        )
    }
}
