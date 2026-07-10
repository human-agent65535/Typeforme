import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeService")
struct BridgeServiceTests {
    @Test @MainActor func staleSettingsRevisionRejectsBeforeMutation() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-settings-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let service = BridgeService(dictionary: UserDictionaryStore(url: dictionaryURL))
        let originalAutoCommit = AppSettings.autoCommit
        let request = BridgeSettingsUpdateRequest(
            expectedSettingsRevision: String(repeating: "0", count: 64),
            autoCommit: !originalAutoCommit
        )

        do {
            _ = try await service.updateSettings(request)
            Issue.record("Expected stale revision to be rejected")
        } catch let error as BridgeServiceError {
            guard case .settingsConflict = error else {
                Issue.record("Expected settingsConflict, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(AppSettings.autoCommit == originalAutoCommit)
    }

    @Test @MainActor func invalidLateSettingsFieldRejectsBeforeMutation() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-settings-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let dictionary = UserDictionaryStore(url: dictionaryURL)
        let service = BridgeService(dictionary: dictionary)
        let originalAutoCommit = AppSettings.autoCommit
        let request = BridgeSettingsUpdateRequest(
            expectedSettingsRevision: BridgeSettingsPayload.currentSettingsRevision(
                userDictionary: dictionary.sortedSnapshot()
            ),
            punctuationPreference: "not-a-preference",
            autoCommit: !originalAutoCommit
        )

        await #expect(throws: BridgeServiceError.self) {
            _ = try await service.updateSettings(request)
        }
        #expect(AppSettings.autoCommit == originalAutoCommit)
    }

    @Test @MainActor func resultReadyMessageSurfacesDegradedCorrection() {
        #expect(BridgeService.resultReadyMessage(correctionStatus: "ok", okMessage: "Refine complete") == "Refine complete")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "refine_timeout", okMessage: "Refine complete") == "Without refine: refine timeout")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "refine_error", okMessage: "Refine complete") == "Without refine: refine error")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "skipped_fast_mode", okMessage: "Refine complete") == "Fast transcript ready")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "empty", okMessage: "Refine complete") == "No reliable transcript")
    }

    @Test @MainActor func refineFailureStatusDistinguishesTimeoutFromOtherErrors() {
        #expect(BridgeService.refineFailureStatus(for: CorrectorError.timeout) == "refine_timeout")
        #expect(BridgeService.refineFailureStatus(for: CorrectorError.requestFailed("500")) == "refine_error")
        #expect(BridgeService.refineFailureStatus(for: CorrectorError.empty) == "refine_error")
    }

    @Test @MainActor func settingsLanguageIDsRequireExactSupportedCanonicalIDs() throws {
        let supported = ASRLanguageSelection.qwenASRSupportedLanguages

        #expect(try BridgeService.resolveSettingsLanguageIDs(["en-US", "zh-CN", "en-US"], supportedOptions: supported) == ["zh-CN", "en-US"])
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs([], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs([""], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs([" en-US "], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs(["en"], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs(["en-us"], supportedOptions: supported)
        }
        #expect(throws: BridgeServiceError.self) {
            _ = try BridgeService.resolveSettingsLanguageIDs(["af"], supportedOptions: supported)
        }
    }

    @Test @MainActor func externalCorrectionSettingsSaveDoesNotRequireReachableListedModel() throws {
        try BridgeService.validateExternalCorrectionSettingsIfNeeded(
            .externalOpenAICompatible,
            externalLLMBaseURL: "http://127.0.0.1:1234",
            externalLLMModel: "model-that-is-not-currently-listed"
        )
    }

    @Test @MainActor func externalCorrectionSettingsStillRequireModelAndHTTPURL() {
        #expect(throws: BridgeServiceError.self) {
            try BridgeService.validateExternalCorrectionSettingsIfNeeded(
                .externalOpenAICompatible,
                externalLLMBaseURL: "http://127.0.0.1:1234",
                externalLLMModel: " "
            )
        }
        #expect(throws: BridgeServiceError.self) {
            try BridgeService.validateExternalCorrectionSettingsIfNeeded(
                .externalAnthropicCompatible,
                externalLLMBaseURL: "file:///tmp/model",
                externalLLMModel: "claude-sonnet-4-5"
            )
        }
    }

    @Test @MainActor func localCorrectionSettingsSaveDoesNotRequireInstalledModel() throws {
        try BridgeService.validateExternalCorrectionSettingsIfNeeded(
            .qwen35_9B,
            externalLLMBaseURL: "",
            externalLLMModel: ""
        )
    }

    @Test func remoteClientAcceptsDegradedRefineResponsesWithText() throws {
        try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "refine_timeout", error: "Correction timed out")
        try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "refine_error", error: "Backend error")
        try RemoteBridgeClient.validateTextResponse(text: "", status: "empty", error: nil)
        #expect(throws: RemoteBridgeClientError.self) {
            try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "error", error: "Backend error")
        }
        #expect(throws: RemoteBridgeClientError.self) {
            try RemoteBridgeClient.validateTextResponse(text: "", status: "refine_error", error: "Backend error")
        }
    }
}
