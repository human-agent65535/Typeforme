struct KeyboardTouchGapPolicy {
    enum Side: String, Equatable {
        case left
        case right
    }

    struct KeyStats: Equatable {
        let sampleCount: Double
        let meanX: Double
    }

    struct Decision: Equatable {
        let side: Side
        let leftSamples: Double
        let rightSamples: Double
        let leftBias: Double
        let rightBias: Double
        let margin: Double
    }

    static let fullConfidenceSamples = 24.0
    static let minimumDecisionSamples = 5.0
    static let gapBiasMargin = 0.05
    static let maxMeanX = 0.34

    static func decide(left: KeyStats?, right: KeyStats?) -> Decision? {
        let leftSamples = left?.sampleCount ?? 0
        let rightSamples = right?.sampleCount ?? 0
        guard max(leftSamples, rightSamples) >= minimumDecisionSamples else { return nil }

        let leftBias = max(0, effectiveMeanX(left))
        let rightBias = max(0, -effectiveMeanX(right))
        let difference = leftBias - rightBias
        guard abs(difference) >= gapBiasMargin else { return nil }

        return Decision(
            side: difference > 0 ? .left : .right,
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            leftBias: leftBias,
            rightBias: rightBias,
            margin: abs(difference)
        )
    }

    static func effectiveMeanX(_ stats: KeyStats?) -> Double {
        let confidence = min(1, (stats?.sampleCount ?? 0) / fullConfidenceSamples)
        return clamp((stats?.meanX ?? 0) * confidence, min: -maxMeanX, max: maxMeanX)
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }
}
