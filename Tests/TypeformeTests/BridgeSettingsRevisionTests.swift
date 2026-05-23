import Testing
@testable import Typeforme

@Suite("BridgeSettingsRevision")
struct BridgeSettingsRevisionTests {
    @Test func revisionIgnoresDynamicModelStatuses() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        #expect(revision.count == 64)
        payload.modelStatuses = [
            BridgeModelStatus(
                id: "asr:test",
                kind: "asr",
                displayName: "Test",
                installed: false,
                installing: true,
                detail: "Installing"
            ),
        ]

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) == revision)
    }

    @Test func revisionChangesWhenConfigChanges() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.correctionTimeoutMs += 1

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) != revision)
    }
}
