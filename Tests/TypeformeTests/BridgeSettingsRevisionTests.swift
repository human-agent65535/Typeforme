import Foundation
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

    @Test func revisionIgnoresDerivedAndServerLocalFields() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.settingsRevision = "server-sent-revision"
        payload.rimeUserPhrases = ["derived phrase"]
        payload.debugMode.toggle()

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) == revision)
    }

    @Test func revisionChangesWhenConfigChanges() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.correctionTimeoutMs += 1

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) != revision)
    }

    @Test func revisionChangesWhenASRModelChanges() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.asrModelIDsByRecognitionSource[RecognitionSource.qwen.rawValue] = "qwen3-asr-1.7b-q8_0"

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) != revision)
    }

    @Test func revisionChangesWhenLivePreviewSourceChanges() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.livePreviewSource = VoiceLivePreviewSource.off.rawValue
        if BridgeSettingsPayload.settingsRevision(for: payload) == revision {
            payload.livePreviewSource = VoiceLivePreviewSource.appleSpeech.rawValue
        }

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) != revision)
    }

    @Test func revisionChangesWhenUserDictionaryChanges() {
        var payload = BridgeSettingsPayload.current()
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.userDictionary = [
            DictionaryEntry(type: "person", surface: "样例用户"),
        ]

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) != revision)
    }

    @Test func revisionChangesWhenUserDictionaryTypeChanges() {
        let entryID = UUID()
        var payload = BridgeSettingsPayload.current(
            userDictionary: [DictionaryEntry(id: entryID, type: "person", surface: "样例用户")]
        )
        let revision = BridgeSettingsPayload.settingsRevision(for: payload)

        payload.userDictionary = [
            DictionaryEntry(id: entryID, type: "project", surface: "样例用户"),
        ]

        #expect(BridgeSettingsPayload.settingsRevision(for: payload) != revision)
    }
}
