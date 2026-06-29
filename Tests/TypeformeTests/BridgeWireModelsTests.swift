import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeWireModels")
struct BridgeWireModelsTests {
    @Test func bridgeEndpointContractListsClientRoutes() {
        #expect(BridgeAPIEndpoint.health.methodAndPath == "GET /v1/health")
        #expect(BridgeAPIEndpoint.settingsWrite.methodAndPath == "POST /v1/settings")
        #expect(BridgeAPIEndpoint.dictate.methodAndPath == "POST /v1/dictate")
        #expect(BridgeAPIEndpoint.refine.methodAndPath == "POST /v1/refine")
        #expect(BridgeAPIEndpoint.editText.methodAndPath == "POST /v1/edit-text")
        #expect(BridgeRequestEndpoint.jobEvents.methodAndPath == "WS /v1/jobs/:jobID/events")
        #expect(BridgeAPIEndpoint.jobEvents(jobID: "ios_1").methodAndPath == "WS /v1/jobs/ios_1/events")
        #expect(BridgeRequestEndpoint.livePreviewSocket.methodAndPath == "WS /v1/live-preview/:sessionID/socket")
        #expect(BridgeAPIEndpoint.livePreviewSocket(sessionID: "preview_1").methodAndPath == "WS /v1/live-preview/preview_1/socket")
    }

    @Test func bridgeClientIdentityHeadersUseSharedNames() {
        #expect(BridgeClientIdentityHeaders.id == "X-Typeforme-Client-ID")
        #expect(BridgeClientIdentityHeaders.name == "X-Typeforme-Client-Name")
        #expect(BridgeClientIdentityHeaders.platform == "X-Typeforme-Client-Platform")
        #expect(BridgeClientIdentityHeaders.bundleID == "X-Typeforme-Client-Bundle-ID")
    }

    @Test func recognitionSourceContractNormalizesSharedMetadata() {
        #expect(RecognitionSource.allCases.map(\.rawValue) == [
            "qwen3-asr-llama",
            "nvidia-nemotron-asr",
            "apple-speech",
        ])
        #expect(RecognitionSource.qwen.displayName == "Qwen3-ASR")
        #expect(RecognitionSource.nvidiaNemotron.displayName == "NVIDIA Nemotron 3.5 ASR")
        #expect(RecognitionSource.appleSpeech.displayName == "Apple Speech")
        #expect(RecognitionSource.defaultEnabled == [.appleSpeech])
        #expect(
            RecognitionSource.normalizedSources([
                " NVIDIA-NEMOTRON-ASR ",
                "qwen3-asr-llama",
                "nvidia-nemotron-asr",
                "unknown",
            ]) == [.nvidiaNemotron, .qwen]
        )
        #expect(RecognitionSource.recognizedSources([]) == [])
        #expect(RecognitionSource.recognizedSources(["unknown"]) == [])
        #expect(RecognitionSource.normalizedSources([]) == [.appleSpeech])
        #expect(RecognitionSource.rawValue(for: [.qwen, .appleSpeech]) == "qwen3-asr-llama,apple-speech")
        #expect(RecognitionSource.qwen.hasModelConfiguration)
        #expect(!RecognitionSource.appleSpeech.hasModelConfiguration)
    }

    @Test func languageOptionContractUsesSharedBridgeKeys() throws {
        let option = BridgeLanguageOption(id: "zz", displayName: "Zulu Custom")

        let object = try encodedJSONObject(option)

        #expect(object["id"] as? String == "zz")
        #expect(object["display_name"] as? String == "Zulu Custom")
        #expect(BridgeLanguageOption.allLanguages.count >= 95)
        #expect(BridgeLanguageOption.asASROptions([option]).first?.id == "zz")
        #expect(BridgeLanguageOption.asASROptions([option]).first?.displayName == "Zulu Custom")
    }

    @Test func healthResponseUsesSharedBridgeKeys() throws {
        let response = BridgeHealthResponse(
            ok: true,
            service: "Typeforme Bridge",
            version: "0.1.0 (1)",
            bridgePort: 18081,
            settingsRevision: "abc"
        )

        let object = try encodedJSONObject(response)
        #expect(object["ok"] as? Bool == true)
        #expect(object["service"] as? String == "Typeforme Bridge")
        #expect(object["version"] as? String == "0.1.0 (1)")
        #expect(object["bridge_port"] as? Int == 18081)
        #expect(object["settings_revision"] as? String == "abc")
    }

    @Test func jobStatusEventCarriesOptionalTranscriptionProgress() throws {
        let event = BridgeJobStatusEvent(
            jobID: "job-1",
            stage: .transcribing,
            message: "Transcribing audio (2/3)",
            transcriptionCompletedSources: 2,
            transcriptionTotalSources: 3
        )

        let object = try encodedJSONObject(event)
        #expect(object["transcription_completed_sources"] as? Int == 2)
        #expect(object["transcription_total_sources"] as? Int == 3)

        let legacyPayload = Data(#"{"job_id":"job-1","stage":"transcribing","message":"Transcribing audio","updated_at":1}"#.utf8)
        let decoded = try JSONDecoder().decode(BridgeJobStatusEvent.self, from: legacyPayload)
        #expect(decoded.transcriptionCompletedSources == nil)
        #expect(decoded.transcriptionTotalSources == nil)
    }

    @Test func jobStatusEventMarksTranscriptionReadyForRefineOnlyWhenASRIsComplete() {
        let inProgress = BridgeJobStatusEvent(
            jobID: "job-1",
            stage: .transcribing,
            message: "Transcribing audio (2/3)",
            transcriptionCompletedSources: 2,
            transcriptionTotalSources: 3
        )
        let allAttemptsFinished = BridgeJobStatusEvent(
            jobID: "job-1",
            stage: .transcribing,
            message: "Transcribing audio (3/3)",
            transcriptionCompletedSources: 3,
            transcriptionTotalSources: 3
        )
        let partialTranscriptReady = BridgeJobStatusEvent(
            jobID: "job-1",
            stage: .transcriptReady,
            message: "Transcript ready",
            transcriptionCompletedSources: 1,
            transcriptionTotalSources: 3
        )
        let finalTranscriptReady = BridgeJobStatusEvent(
            jobID: "job-1",
            stage: .transcriptReady,
            message: "Transcript ready",
            transcriptionCompletedSources: 3,
            transcriptionTotalSources: 3
        )
        let legacyTranscriptReady = BridgeJobStatusEvent(
            jobID: "job-1",
            stage: .transcriptReady,
            message: "Transcript ready"
        )

        #expect(inProgress.transcriptionReadyForRefine == false)
        #expect(allAttemptsFinished.transcriptionReadyForRefine == true)
        #expect(partialTranscriptReady.transcriptionReadyForRefine == false)
        #expect(finalTranscriptReady.transcriptionReadyForRefine == true)
        #expect(legacyTranscriptReady.transcriptionReadyForRefine == true)
    }

    @Test func refineRequestEncodesSharedBridgeKeys() throws {
        let request = BridgeRefineRequest(
            sessionID: "session-1",
            rawTranscript: "hello",
            clientJobID: "ios_job_1",
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "before",
            contextAfter: "after"
        )

        let object = try encodedJSONObject(request)
        #expect(object["session_id"] as? String == "session-1")
        #expect(object["raw_transcript"] as? String == "hello")
        #expect(object["client_job_id"] as? String == "ios_job_1")
        #expect(object["language_ids"] as? [String] == ["en-US"])
        #expect(object["correction_mode"] as? String == CorrectionMode.polishPlus.rawValue)
        #expect(object["app_name"] as? String == "Notes")
        #expect(object["bundle_id"] as? String == "com.apple.Notes")
        #expect(object["app_category"] as? String == "chat")
        #expect(object["context_before"] as? String == "before")
        #expect(object["context_after"] as? String == "after")
    }

    @Test func livePreviewStartRequestEncodesCorrectionMode() throws {
        let request = BridgeLivePreviewStartRequest(
            clientJobID: "ios_preview_1",
            languageIDs: ["en-US"],
            languageMode: "custom",
            correctionMode: CorrectionMode.polishPlus.rawValue,
            livePreviewSource: VoiceLivePreviewSource.qwen.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat"
        )

        let object = try encodedJSONObject(request)
        #expect(object["client_job_id"] as? String == "ios_preview_1")
        #expect(object["language_ids"] as? [String] == ["en-US"])
        #expect(object["language_mode"] as? String == "custom")
        #expect(object["correction_mode"] as? String == CorrectionMode.polishPlus.rawValue)
        #expect(object["live_preview_source"] as? String == VoiceLivePreviewSource.qwen.rawValue)
        #expect(object["app_name"] as? String == "Notes")
        #expect(object["bundle_id"] as? String == "com.apple.Notes")
        #expect(object["app_category"] as? String == "chat")
    }

    @Test func livePreviewStartResponseCarriesAudioFormat() throws {
        let response = BridgeLivePreviewStartResponse(
            sessionID: "preview-1",
            provider: RecognitionSource.qwen.rawValue,
            languageIDs: ["en-US"],
            audioFormat: BridgeLivePreviewStartResponse.audioFormat,
            startedAt: 122.0
        )

        let object = try encodedJSONObject(response)
        #expect(object["session_id"] as? String == "preview-1")
        #expect(object["provider"] as? String == RecognitionSource.qwen.rawValue)
        #expect(object["language_ids"] as? [String] == ["en-US"])
        #expect(object["audio_format"] as? String == "opus_16k_mono_20ms")
        #expect(object["started_at"] as? Double == 122.0)
    }

    @Test func livePreviewStartResponseRejectsLegacyPayloadWithoutAudioFormat() {
        let legacyPayload = Data(
            #"{"session_id":"preview-1","provider":"qwen3-asr-llama","language_ids":["en-US"],"started_at":122.0}"#
                .utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BridgeLivePreviewStartResponse.self, from: legacyPayload)
        }
    }

    @Test func livePreviewFinishResponseCarriesProvider() throws {
        let response = BridgeLivePreviewFinishResponse(
            sessionID: "preview-1",
            provider: RecognitionSource.qwen.rawValue,
            text: "hello",
            finishedAt: 123.0
        )

        let object = try encodedJSONObject(response)
        #expect(object["session_id"] as? String == "preview-1")
        #expect(object["provider"] as? String == RecognitionSource.qwen.rawValue)
        #expect(object["text"] as? String == "hello")
        #expect(object["finished_at"] as? Double == 123.0)
    }

    @Test func settingsUpdateRequestEncodesSharedBridgeKeys() throws {
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let snapshot = BridgeSettingsEditableSnapshot(
            enabledRecognitionSources: [RecognitionSource.qwen.rawValue],
            asrModelIDsByRecognitionSource: [RecognitionSource.qwen.rawValue: QwenASRModelCatalog.defaultID],
            languageIDs: ["en-US"],
            asrTimeoutSec: 40,
            correctionBackend: CorrectionBackendKind.qwen35_2B.rawValue,
            correctionTimeoutMs: 1500,
            correctionColdTimeoutMs: 8000,
            externalLLMBaseURL: "http://127.0.0.1:1234",
            externalLLMModel: "qwen",
            livePreviewSource: VoiceLivePreviewSource.off.rawValue,
            correctionMode: CorrectionMode.polishPlus.rawValue,
            numberOutputPreference: NumberOutputPreference.automatic.rawValue,
            punctuationPreference: PunctuationOutputPreference.normal.rawValue,
            autoCommit: true,
            userDictionary: [
                DictionaryEntry(id: entryID, type: "person", surface: " Alice "),
            ]
        )
        let request = BridgeSettingsUpdateRequest(editableSnapshot: snapshot)

        let object = try encodedJSONObject(request)
        #expect(object["enabled_recognition_sources"] as? [String] == [RecognitionSource.qwen.rawValue])
        #expect((object["asr_model_ids_by_recognition_source"] as? [String: String])?[RecognitionSource.qwen.rawValue] == QwenASRModelCatalog.defaultID)
        #expect(object["language_ids"] as? [String] == ["en-US"])
        #expect(object["asr_timeout_sec"] as? Double == 40)
        #expect(object["correction_backend"] as? String == CorrectionBackendKind.qwen35_2B.rawValue)
        #expect(object["correction_timeout_ms"] as? Int == 1500)
        #expect(object["correction_cold_timeout_ms"] as? Int == 8000)
        #expect(object["external_llm_base_url"] as? String == "http://127.0.0.1:1234")
        #expect(object["external_llm_model"] as? String == "qwen")
        #expect(object["live_preview_source"] as? String == VoiceLivePreviewSource.off.rawValue)
        #expect(object["correction_mode"] as? String == CorrectionMode.polishPlus.rawValue)
        #expect(object["number_output_preference"] as? String == NumberOutputPreference.automatic.rawValue)
        #expect(object["punctuation_preference"] as? String == PunctuationOutputPreference.normal.rawValue)
        #expect(object["auto_commit"] as? Bool == true)
        #expect(object["debug_mode"] == nil)
        let entries = try #require(object["user_dictionary"] as? [[String: Any]])
        #expect(entries.first?["surface"] as? String == "Alice")
    }

    @Test func settingsUpdateRequestDecodesPartialWrites() throws {
        let data = Data(#"{"correction_timeout_ms":2000,"auto_commit":false,"debug_mode":true}"#.utf8)

        let request = try JSONDecoder().decode(BridgeSettingsUpdateRequest.self, from: data)

        #expect(request.enabledRecognitionSources == nil)
        #expect(request.correctionTimeoutMs == 2000)
        #expect(request.autoCommit == false)
        #expect(request.userDictionary == nil)
    }

    @Test func bridgeSettingsPayloadNormalizesEmptySourcesToAppleSpeech() {
        var payload = BridgeSettingsPayload.current()
        payload.enabledRecognitionSources = []
        payload.normalize()

        #expect(payload.enabledSources == [.appleSpeech])
    }

    @Test func bridgeSettingsPayloadKeepsFastWithAppleSpeechOnly() {
        var payload = BridgeSettingsPayload.current()
        payload.enabledRecognitionSources = [RecognitionSource.appleSpeech.rawValue]
        payload.correctionMode = CorrectionMode.fast.rawValue
        payload.normalize()

        #expect(payload.enabledSources == [.appleSpeech])
        #expect(payload.correctionMode == CorrectionMode.fast.rawValue)
    }

    @Test func bridgeSettingsPayloadReportsServerASRPreviewForQwenAndNemotron() {
        var payload = BridgeSettingsPayload.current()

        payload.enabledRecognitionSources = [RecognitionSource.qwen.rawValue]
        payload.livePreviewSource = VoiceLivePreviewSource.qwen.rawValue
        #expect(payload.supportsServerASRPreview)

        payload.enabledRecognitionSources = [RecognitionSource.nvidiaNemotron.rawValue]
        payload.livePreviewSource = VoiceLivePreviewSource.nvidiaNemotron.rawValue
        #expect(payload.supportsServerASRPreview)

        payload.enabledRecognitionSources = [RecognitionSource.qwen.rawValue, RecognitionSource.nvidiaNemotron.rawValue]
        payload.livePreviewSource = VoiceLivePreviewSource.appleSpeech.rawValue
        #expect(!payload.supportsServerASRPreview)

        payload.livePreviewSource = VoiceLivePreviewSource.off.rawValue
        #expect(!payload.supportsServerASRPreview)

        payload.enabledRecognitionSources = [RecognitionSource.appleSpeech.rawValue]
        payload.livePreviewSource = VoiceLivePreviewSource.qwen.rawValue
        #expect(!payload.supportsServerASRPreview)
    }

    @Test func editableSnapshotNormalizesUserDictionaryForComparison() {
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        let snapshot = BridgeSettingsEditableSnapshot(
            enabledRecognitionSources: [RecognitionSource.qwen.rawValue],
            asrModelIDsByRecognitionSource: [:],
            languageIDs: ["en-US"],
            asrTimeoutSec: 40,
            correctionBackend: CorrectionBackendKind.qwen35_2B.rawValue,
            correctionTimeoutMs: 1500,
            correctionColdTimeoutMs: 8000,
            externalLLMBaseURL: nil,
            externalLLMModel: nil,
            livePreviewSource: VoiceLivePreviewSource.off.rawValue,
            correctionMode: CorrectionMode.polishPlus.rawValue,
            numberOutputPreference: NumberOutputPreference.automatic.rawValue,
            punctuationPreference: PunctuationOutputPreference.normal.rawValue,
            autoCommit: true,
            userDictionary: [
                DictionaryEntry(id: entryID, type: " Person ", surface: "  Alice\tSmith  "),
                DictionaryEntry(id: entryID, type: "other", surface: "duplicate"),
                DictionaryEntry(type: "phrase", surface: " "),
            ]
        )

        #expect(snapshot.userDictionary == [
            DictionaryEntry(id: entryID, type: "person", surface: "Alice Smith"),
        ])
    }

    @Test func dictateResponseKeepsClientCompatibleOptionalFields() throws {
        let data = Data(#"{"session_id":"session-1","text":"hello","language_ids":["en-US"]}"#.utf8)

        let response = try JSONDecoder().decode(BridgeDictateResponse.self, from: data)
        #expect(response.sessionID == "session-1")
        #expect(response.text == "hello")
        #expect(response.languageIDs == ["en-US"])
        #expect(response.correctionMode == nil)
        #expect(response.latencyMs == nil)
        #expect(response.correctionStatus == nil)
    }

    private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
