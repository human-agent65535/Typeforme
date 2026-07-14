import Foundation
import Testing
@testable import Typeforme

@Suite("DictationSessionSettings")
struct DictationSessionSettingsTests {
    @Test func canonicalRouteComesOnlyFromTheCapturedSessionRoleAndSources() {
        let base = DictationSessionSettings(
            processingMode: .server,
            correctionMode: .clean,
            recognitionSources: [.qwen, .appleSpeech],
            transcriptionLanguageIDs: ["en-US"],
            fastASRSource: nil,
            configuredFastASRSource: .qwen,
            numberOutputPreference: .digits,
            punctuationPreference: .english,
            correctionTimeoutMs: 1_500,
            voiceLivePreviewEnabled: true,
            voiceLivePreviewSource: .appleSpeech,
            clientBridgeRecognitionSources: [.qwen],
            clientBridgeConfiguration: ClientBridgeConfiguration(
                localBridgeURLs: ["http://192.168.1.2:18081"],
                cloudBridgeURL: "",
                token: "token"
            ),
            maxRecordingDuration: 300
        )
        #expect(!base.usesRemoteBridge)
        #expect(base.canonicalRecognitionSources == [.qwen, .appleSpeech])

        let fast = DictationSessionSettings(
            processingMode: .server,
            correctionMode: .fast,
            recognitionSources: [.qwen, .appleSpeech],
            transcriptionLanguageIDs: ["en-US"],
            fastASRSource: .appleSpeech,
            configuredFastASRSource: .qwen,
            numberOutputPreference: base.numberOutputPreference,
            punctuationPreference: base.punctuationPreference,
            correctionTimeoutMs: base.correctionTimeoutMs,
            voiceLivePreviewEnabled: base.voiceLivePreviewEnabled,
            voiceLivePreviewSource: base.voiceLivePreviewSource,
            clientBridgeRecognitionSources: base.clientBridgeRecognitionSources,
            clientBridgeConfiguration: base.clientBridgeConfiguration,
            maxRecordingDuration: base.maxRecordingDuration
        )
        #expect(fast.canonicalRecognitionSources == [.appleSpeech])

        let client = DictationSessionSettings(
            processingMode: .client,
            correctionMode: .clean,
            recognitionSources: base.recognitionSources,
            transcriptionLanguageIDs: ["ja"],
            fastASRSource: nil,
            configuredFastASRSource: .qwen,
            numberOutputPreference: base.numberOutputPreference,
            punctuationPreference: base.punctuationPreference,
            correctionTimeoutMs: base.correctionTimeoutMs,
            voiceLivePreviewEnabled: base.voiceLivePreviewEnabled,
            voiceLivePreviewSource: .qwen,
            clientBridgeRecognitionSources: [.qwen],
            clientBridgeConfiguration: base.clientBridgeConfiguration,
            maxRecordingDuration: base.maxRecordingDuration
        )
        #expect(client.usesRemoteBridge)
        #expect(client.canonicalRecognitionSources.isEmpty)
        #expect(client.transcriptionLanguageIDs == ["ja"])
    }

    @Test @MainActor func localASRInstanceIsBoundOnceWhileClientSkipsLocalFactory() throws {
        let localSettings = makeSettings(processingMode: .server)
        let firstService = TaggedASRService(id: "captured")
        let replacementService = TaggedASRService(id: "replacement")
        var selectedService = firstService
        var factoryCalls = 0

        let localSession = try DictationASRSession(settings: localSettings) { _ in
            factoryCalls += 1
            return selectedService
        }
        selectedService = replacementService

        let capturedService = try #require(localSession.localASRService as? TaggedASRService)
        #expect(capturedService === firstService)
        #expect(capturedService.id == "captured")
        #expect(factoryCalls == 1)

        let clientSession = try DictationASRSession(
            settings: makeSettings(processingMode: .client)
        ) { _ in
            factoryCalls += 1
            return replacementService
        }
        #expect(clientSession.localASRService == nil)
        #expect(factoryCalls == 1)
    }

    private func makeSettings(processingMode: ProcessingMode) -> DictationSessionSettings {
        DictationSessionSettings(
            processingMode: processingMode,
            correctionMode: .clean,
            recognitionSources: [.appleSpeech],
            transcriptionLanguageIDs: ["en-US"],
            fastASRSource: nil,
            configuredFastASRSource: .appleSpeech,
            numberOutputPreference: .digits,
            punctuationPreference: .english,
            correctionTimeoutMs: 1_500,
            voiceLivePreviewEnabled: false,
            voiceLivePreviewSource: .appleSpeech,
            clientBridgeRecognitionSources: [.appleSpeech],
            clientBridgeConfiguration: ClientBridgeConfiguration(
                localBridgeURLs: ["http://192.168.1.2:18081"],
                cloudBridgeURL: "",
                token: "token"
            ),
            maxRecordingDuration: 300
        )
    }
}

private final class TaggedASRService: ASRService, @unchecked Sendable {
    let id: String

    init(id: String) {
        self.id = id
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        id
    }
}
