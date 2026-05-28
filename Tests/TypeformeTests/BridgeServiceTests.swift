import Testing
@testable import Typeforme

@Suite("BridgeService")
struct BridgeServiceTests {
    @Test @MainActor func resultReadyMessageSurfacesDegradedCorrection() {
        #expect(BridgeService.resultReadyMessage(correctionStatus: "ok", okMessage: "Refine complete") == "Refine complete")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "timeout", okMessage: "Refine complete") == "Without refine")
        #expect(BridgeService.resultReadyMessage(correctionStatus: "fallback", okMessage: "Refine complete") == "Without refine")
    }
}
