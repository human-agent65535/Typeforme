import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeWireModels")
struct BridgeWireModelsTests {
    @Test func bridgeEndpointContractListsClientRoutes() {
        #expect(BridgeAPIEndpoint.health.methodAndPath == "GET /v1/health")
        #expect(BridgeAPIEndpoint.settingsWrite.methodAndPath == "POST /v1/settings")
        #expect(BridgeAPIEndpoint.dictate.methodAndPath == "POST /v1/dictate")
        #expect(BridgeAPIEndpoint.restyle.methodAndPath == "POST /v1/restyle")
        #expect(BridgeAPIEndpoint.editText.methodAndPath == "POST /v1/edit-text")
        #expect(BridgeAPIEndpoint.jobEvents(jobID: "ios_1").path == "/v1/jobs/ios_1/events")
        #expect(BridgeRequestEndpoint.livePreviewSocket.methodAndPath == "WS /v1/live-preview/:sessionID/socket")
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

    @Test func restyleRequestEncodesSharedBridgeKeys() throws {
        let request = BridgeRestyleRequest(
            sessionID: "session-1",
            rawTranscript: "hello",
            clientJobID: "ios_job_1",
            languageIDs: ["en-US"],
            correctionMode: CorrectionMode.polish.rawValue,
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
        #expect(object["correction_mode"] as? String == CorrectionMode.polish.rawValue)
        #expect(object["app_name"] as? String == "Notes")
        #expect(object["bundle_id"] as? String == "com.apple.Notes")
        #expect(object["app_category"] as? String == "chat")
        #expect(object["context_before"] as? String == "before")
        #expect(object["context_after"] as? String == "after")
    }

    @Test func settingsUpdateRequestEncodesSharedBridgeKeys() throws {
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let request = BridgeSettingsUpdateRequest(
            enabledRecognitionSources: [RecognitionSource.qwen.rawValue],
            asrModelIDsByRecognitionSource: [RecognitionSource.qwen.rawValue: QwenASRModelCatalog.defaultID],
            languageIDs: ["en-US"],
            asrTimeoutSecByRecognitionSource: [RecognitionSource.qwen.rawValue: 120],
            correctionBackend: CorrectionBackendKind.qwen35_2B.rawValue,
            correctionTimeoutMs: 1500,
            correctionColdTimeoutMs: 8000,
            externalLLMBaseURL: "http://127.0.0.1:1234",
            externalLLMModel: "qwen",
            livePreviewSource: VoiceLivePreviewSource.off.rawValue,
            correctionMode: CorrectionMode.polish.rawValue,
            numberOutputPreference: NumberOutputPreference.automatic.rawValue,
            punctuationPreference: PunctuationOutputPreference.normal.rawValue,
            autoCommit: true,
            debugMode: false,
            userDictionary: [
                DictionaryEntry(id: entryID, type: "person", surface: " Alice "),
            ]
        )

        let object = try encodedJSONObject(request)
        #expect(object["enabled_recognition_sources"] as? [String] == [RecognitionSource.qwen.rawValue])
        #expect((object["asr_model_ids_by_recognition_source"] as? [String: String])?[RecognitionSource.qwen.rawValue] == QwenASRModelCatalog.defaultID)
        #expect(object["language_ids"] as? [String] == ["en-US"])
        #expect((object["asr_timeout_sec_by_recognition_source"] as? [String: Double])?[RecognitionSource.qwen.rawValue] == 120)
        #expect(object["correction_backend"] as? String == CorrectionBackendKind.qwen35_2B.rawValue)
        #expect(object["correction_timeout_ms"] as? Int == 1500)
        #expect(object["correction_cold_timeout_ms"] as? Int == 8000)
        #expect(object["external_llm_base_url"] as? String == "http://127.0.0.1:1234")
        #expect(object["external_llm_model"] as? String == "qwen")
        #expect(object["live_preview_source"] as? String == VoiceLivePreviewSource.off.rawValue)
        #expect(object["correction_mode"] as? String == CorrectionMode.polish.rawValue)
        #expect(object["number_output_preference"] as? String == NumberOutputPreference.automatic.rawValue)
        #expect(object["punctuation_preference"] as? String == PunctuationOutputPreference.normal.rawValue)
        #expect(object["auto_commit"] as? Bool == true)
        #expect(object["debug_mode"] as? Bool == false)
        let entries = try #require(object["user_dictionary"] as? [[String: Any]])
        #expect(entries.first?["surface"] as? String == "Alice")
    }

    @Test func settingsUpdateRequestDecodesPartialWrites() throws {
        let data = Data(#"{"correction_timeout_ms":2000,"auto_commit":false}"#.utf8)

        let request = try JSONDecoder().decode(BridgeSettingsUpdateRequest.self, from: data)

        #expect(request.enabledRecognitionSources == nil)
        #expect(request.correctionTimeoutMs == 2000)
        #expect(request.autoCommit == false)
        #expect(request.debugMode == nil)
        #expect(request.userDictionary == nil)
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
