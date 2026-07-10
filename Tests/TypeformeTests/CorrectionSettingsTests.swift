import Testing
@testable import Typeforme

@Suite("Correction settings")
struct CorrectionSettingsTests {
    @Test func contextSizeHasEnoughRoomForCorrectionPrompt() {
        #expect(AppSettings.normalizedCorrectionContextSize(0) == 2_048)
        #expect(AppSettings.normalizedCorrectionContextSize(1_024) == 2_048)
        #expect(AppSettings.normalizedCorrectionContextSize(2_048) == 2_048)
        #expect(AppSettings.normalizedCorrectionContextSize(4_096) == 4_096)
    }
}
