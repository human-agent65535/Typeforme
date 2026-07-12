import XCTest
@testable import Typeforme

final class VoiceOrbVisualPolicyTests: XCTestCase {
    func testHighlightStaysInsideOrb() {
        let halfWidth = VoiceOrbVisualPolicy.highlightWidthRatio / 2
        let halfHeight = VoiceOrbVisualPolicy.highlightHeightRatio / 2

        XCTAssertGreaterThanOrEqual(VoiceOrbVisualPolicy.highlightCenterXRatio - halfWidth, 0)
        XCTAssertLessThanOrEqual(VoiceOrbVisualPolicy.highlightCenterXRatio + halfWidth, 1)
        XCTAssertGreaterThanOrEqual(VoiceOrbVisualPolicy.highlightCenterYRatio - halfHeight, 0)
        XCTAssertLessThanOrEqual(VoiceOrbVisualPolicy.highlightCenterYRatio + halfHeight, 1)
    }

    func testCenterContentFitsInsideOrb() {
        XCTAssertLessThan(VoiceOrbVisualPolicy.voiceprintWidthRatio, 1)
        XCTAssertLessThan(VoiceOrbVisualPolicy.voiceprintHeightRatio, 1)
        XCTAssertLessThan(VoiceOrbVisualPolicy.iconFrameRatio, 1)
        XCTAssertLessThanOrEqual(
            VoiceOrbVisualPolicy.idleIconPointSizeRatio,
            VoiceOrbVisualPolicy.iconFrameRatio
        )
    }

    func testPulseAnimationHasThreeStaggeredRings() {
        XCTAssertEqual(VoiceOrbVisualPolicy.pulseRingCount, 3)
        XCTAssertGreaterThan(VoiceOrbVisualPolicy.pulseMaximumScale, 1)
        XCTAssertGreaterThan(VoiceOrbVisualPolicy.pulseDuration, VoiceOrbVisualPolicy.pulsePhaseOffset)
        XCTAssertGreaterThan(VoiceOrbVisualPolicy.pulsePeakOpacity, 0)
        XCTAssertLessThanOrEqual(VoiceOrbVisualPolicy.pulsePeakOpacity, 1)
    }

    func testAudioSmoothingWeightsRemainNormalized() {
        XCTAssertEqual(
            VoiceOrbVisualPolicy.pulseAudioPreviousLevelWeight
                + VoiceOrbVisualPolicy.pulseAudioNewLevelWeight,
            1,
            accuracy: 0.000_001
        )
        XCTAssertLessThanOrEqual(
            VoiceOrbVisualPolicy.pulseAudioBaselineOpacity
                + VoiceOrbVisualPolicy.pulseAudioLevelContribution,
            VoiceOrbVisualPolicy.pulseAudioMaximumOpacity
        )
    }
}
