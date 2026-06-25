import Testing
@testable import Typeforme

@Suite("BridgeService")
struct BridgeServiceTests {
    @Test @MainActor func resultReadyMessageSurfacesDegradedCorrection() {
        #expect(BridgeService.resultReadyMessage(correctionStatus: "ok", okMessage: "Refine complete") == "Refine complete")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "refine_timeout", okMessage: "Refine complete") == "Without refine: refine timeout")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "refine_error", okMessage: "Refine complete") == "Without refine: refine error")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "skipped_fast_mode", okMessage: "Refine complete") == "Fast transcript ready")
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

    @Test func remoteClientAcceptsDegradedRefineResponsesWithText() throws {
        try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "refine_timeout", error: "Correction timed out")
        try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "refine_error", error: "Backend error")
        #expect(throws: RemoteBridgeClientError.self) {
            try RemoteBridgeClient.validateTextResponse(text: "raw transcript", status: "error", error: "Backend error")
        }
        #expect(throws: RemoteBridgeClientError.self) {
            try RemoteBridgeClient.validateTextResponse(text: "", status: "refine_error", error: "Backend error")
        }
    }
}
