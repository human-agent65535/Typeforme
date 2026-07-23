import Testing
@testable import Typeforme

@Suite("KeyboardTouchGapPolicy")
struct KeyboardTouchGapPolicyTests {
    @Test func coldStartKeepsTheGeometricBoundary() {
        #expect(KeyboardTouchGapPolicy.decide(left: nil, right: nil) == nil)
    }

    @Test func assignsWholeGapToLeftWhenLeftInwardBiasWins() {
        let decision = KeyboardTouchGapPolicy.decide(
            left: .init(sampleCount: 24, meanX: 0.18),
            right: .init(sampleCount: 24, meanX: -0.04)
        )

        #expect(decision?.side == .left)
        #expect(abs((decision?.leftBias ?? .nan) - 0.18) < 0.000_001)
        #expect(abs((decision?.rightBias ?? .nan) - 0.04) < 0.000_001)
    }

    @Test func assignsWholeGapToRightWhenRightInwardBiasWins() {
        let decision = KeyboardTouchGapPolicy.decide(
            left: .init(sampleCount: 24, meanX: 0.02),
            right: .init(sampleCount: 24, meanX: -0.16)
        )

        #expect(decision?.side == .right)
        #expect(abs((decision?.leftBias ?? .nan) - 0.02) < 0.000_001)
        #expect(abs((decision?.rightBias ?? .nan) - 0.16) < 0.000_001)
    }

    @Test func requiresEnoughSamplesBeforeMovingGapBoundary() {
        let decision = KeyboardTouchGapPolicy.decide(
            left: .init(sampleCount: 4, meanX: 0.34),
            right: nil
        )

        #expect(decision == nil)
    }

    @Test func requiresMarginAfterConfidenceWeighting() {
        let decision = KeyboardTouchGapPolicy.decide(
            left: .init(sampleCount: 12, meanX: 0.18),
            right: .init(sampleCount: 24, meanX: -0.05)
        )

        #expect(decision == nil)
    }

    @Test func acceptsBoundaryWhenMarginReachesThreshold() {
        let decision = KeyboardTouchGapPolicy.decide(
            left: .init(sampleCount: 24, meanX: 0.05),
            right: nil
        )

        #expect(decision?.side == .left)
        #expect(abs((decision?.margin ?? .nan) - KeyboardTouchGapPolicy.gapBiasMargin) < 0.000_001)
    }

    @Test func clampsEffectiveMeanBeforeComparingBias() {
        let decision = KeyboardTouchGapPolicy.decide(
            left: .init(sampleCount: 24, meanX: 0.80),
            right: nil
        )

        #expect(abs((decision?.leftBias ?? .nan) - KeyboardTouchGapPolicy.maxMeanX) < 0.000_001)
    }
}
