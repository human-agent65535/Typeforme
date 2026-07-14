import Foundation
import Testing
@testable import Typeforme

@Suite("ProcessingModeSettings")
struct ProcessingModeSettingsTests {
    @Test func staleClientSettingsResponseCannotApplyAfterRoleChange() {
        let configuration = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.10:18081"],
            cloudBridgeURL: "",
            token: "token-a"
        )
        #expect(ClientBridgeSettingsSync.shouldApplyResponse(
            taskIsActive: true,
            taskConfiguration: configuration,
            currentConfiguration: configuration,
            processingMode: .client,
            isCancelled: false
        ))
        #expect(!ClientBridgeSettingsSync.shouldApplyResponse(
            taskIsActive: false,
            taskConfiguration: configuration,
            currentConfiguration: configuration,
            processingMode: .client,
            isCancelled: false
        ))
        #expect(!ClientBridgeSettingsSync.shouldApplyResponse(
            taskIsActive: true,
            taskConfiguration: configuration,
            currentConfiguration: configuration,
            processingMode: .server,
            isCancelled: false
        ))
        #expect(!ClientBridgeSettingsSync.shouldApplyResponse(
            taskIsActive: true,
            taskConfiguration: configuration,
            currentConfiguration: configuration,
            processingMode: .client,
            isCancelled: true
        ))
    }

    @Test func staleClientSettingsResponseCannotApplyAfterRepairOrUnpair() {
        let original = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.10:18081"],
            cloudBridgeURL: "https://bridge-a.example.com",
            token: "token-a"
        )
        let repaired = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.20:18081"],
            cloudBridgeURL: "https://bridge-b.example.com",
            token: "token-b"
        )
        let unpaired = ClientBridgeConfiguration(
            localBridgeURLs: [],
            cloudBridgeURL: "",
            token: ""
        )

        #expect(!ClientBridgeSettingsSync.shouldApplyResponse(
            taskIsActive: true,
            taskConfiguration: original,
            currentConfiguration: repaired,
            processingMode: .client,
            isCancelled: false
        ))
        #expect(!ClientBridgeSettingsSync.shouldApplyResponse(
            taskIsActive: true,
            taskConfiguration: original,
            currentConfiguration: unpaired,
            processingMode: .client,
            isCancelled: false
        ))
    }

    @Test func settingsRevisionCannotBeReusedAcrossPairings() {
        let serverA = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.10:18081"],
            cloudBridgeURL: "",
            token: "token-a"
        )
        let serverB = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.20:18081"],
            cloudBridgeURL: "",
            token: "token-b"
        )

        #expect(ClientBridgeSettingsSync.settingsRevisionMatches(
            serverRevision: "revision-1",
            storedRevision: "revision-1",
            revisionConfiguration: serverA,
            currentConfiguration: serverA
        ))
        #expect(!ClientBridgeSettingsSync.settingsRevisionMatches(
            serverRevision: "revision-1",
            storedRevision: "revision-1",
            revisionConfiguration: serverA,
            currentConfiguration: serverB
        ))
        #expect(!ClientBridgeSettingsSync.settingsRevisionMatches(
            serverRevision: "revision-1",
            storedRevision: "revision-1",
            revisionConfiguration: nil,
            currentConfiguration: serverA
        ))
    }

    @Test func clientSettingsThrottleBelongsToItsConfiguration() {
        let serverA = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.10:18081"],
            cloudBridgeURL: "",
            token: "token-a"
        )
        let serverB = ClientBridgeConfiguration(
            localBridgeURLs: ["http://192.168.1.20:18081"],
            cloudBridgeURL: "",
            token: "token-b"
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let recentSync = now.addingTimeInterval(-10)

        #expect(ClientBridgeSettingsSync.shouldThrottle(
            now: now,
            lastSyncAt: recentSync,
            lastSyncedConfiguration: serverA,
            currentConfiguration: serverA
        ))
        #expect(!ClientBridgeSettingsSync.shouldThrottle(
            now: now,
            lastSyncAt: recentSync,
            lastSyncedConfiguration: serverA,
            currentConfiguration: serverB
        ))
        #expect(!ClientBridgeSettingsSync.shouldThrottle(
            now: now,
            lastSyncAt: recentSync,
            lastSyncedConfiguration: nil,
            currentConfiguration: serverA
        ))
    }

    @Test func switchingModesRestoresServerAndClientScopedSettings() {
        let suiteName = "TypeformeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ProcessingMode.server.rawValue, forKey: AppSettings.Keys.processingMode)
        defaults.set(CorrectionBackendKind.qwen35_9B.rawValue, forKey: AppSettings.Keys.correctionBackend)
        defaults.set(true, forKey: AppSettings.Keys.bridgeEnabled)
        defaults.set("http://192.168.1.10:18081", forKey: AppSettings.Keys.clientLocalBridgeURLs)
        defaults.set("https://old.example.com", forKey: AppSettings.Keys.clientCloudBridgeURL)
        defaults.set("old-token", forKey: AppSettings.Keys.clientBridgeToken)
        defaults.set("en,zh", forKey: AppSettings.Keys.clientLanguageIDs)
        defaults.set(RecognitionSource.qwen.rawValue, forKey: AppSettings.Keys.clientBridgeEnabledRecognitionSources)

        AppSettings.setProcessingMode(.client, defaults: defaults)
        defaults.set("http://192.168.1.20:18081", forKey: AppSettings.Keys.clientLocalBridgeURLs)
        defaults.set("https://client.example.com", forKey: AppSettings.Keys.clientCloudBridgeURL)
        defaults.set("client-token", forKey: AppSettings.Keys.clientBridgeToken)
        defaults.set("ja,vi", forKey: AppSettings.Keys.clientLanguageIDs)
        defaults.set(RecognitionSource.nvidiaNemotron.rawValue, forKey: AppSettings.Keys.clientBridgeEnabledRecognitionSources)
        defaults.set(CorrectionBackendKind.qwen35_2B.rawValue, forKey: AppSettings.Keys.correctionBackend)
        defaults.set(false, forKey: AppSettings.Keys.bridgeEnabled)

        AppSettings.setProcessingMode(.server, defaults: defaults)
        #expect(defaults.string(forKey: AppSettings.Keys.processingMode) == ProcessingMode.server.rawValue)
        #expect(defaults.string(forKey: AppSettings.Keys.correctionBackend) == CorrectionBackendKind.qwen35_9B.rawValue)
        #expect(defaults.bool(forKey: AppSettings.Keys.bridgeEnabled))
        let clientSnapshot = defaults.dictionary(forKey: AppSettings.Keys.clientSettingsSnapshot) ?? [:]
        #expect(clientSnapshot[AppSettings.Keys.clientBridgeToken] == nil)

        AppSettings.setProcessingMode(.client, defaults: defaults)
        #expect(defaults.string(forKey: AppSettings.Keys.processingMode) == ProcessingMode.client.rawValue)
        #expect(defaults.string(forKey: AppSettings.Keys.clientLocalBridgeURLs) == "http://192.168.1.20:18081")
        #expect(defaults.string(forKey: AppSettings.Keys.clientCloudBridgeURL) == "https://client.example.com")
        #expect(defaults.string(forKey: AppSettings.Keys.clientBridgeToken) == "client-token")
        #expect(defaults.string(forKey: AppSettings.Keys.clientLanguageIDs) == "ja,vi")
        #expect(defaults.string(forKey: AppSettings.Keys.clientBridgeEnabledRecognitionSources) == RecognitionSource.nvidiaNemotron.rawValue)
    }

    @Test func clientSyncPreservesCanonicalLanguagesWhileAppleSupportIsUnresolved() {
        var settings = BridgeSettingsPayload.current()
        settings.enabledRecognitionSources = [
            RecognitionSource.qwen.rawValue,
            RecognitionSource.appleSpeech.rawValue,
        ]
        settings.supportedLanguagesByRecognitionSource[RecognitionSource.appleSpeech.rawValue] = []

        let pendingValue = ClientBridgeSettingsSync.clientLanguageRawValue(
            currentLanguageIDs: ["af"],
            settings: settings
        )
        #expect(pendingValue == nil)

        settings.enabledRecognitionSources = [RecognitionSource.qwen.rawValue]
        let resolvedValue = ClientBridgeSettingsSync.clientLanguageRawValue(
            currentLanguageIDs: ["ja"],
            settings: settings
        )
        #expect(resolvedValue == "ja")
    }
}
