struct KeyboardCursorMotionPolicy {
    static let minimumHorizontalIntentDistance = 8.0
    static let horizontalIntentDominance = 1.35
    static let pointsPerCharacter = 14.0

    static func isHorizontalIntent(translationX: Double, translationY: Double) -> Bool {
        let horizontalDistance = abs(translationX)
        return horizontalDistance >= minimumHorizontalIntentDistance
            && horizontalDistance >= abs(translationY) * horizontalIntentDominance
    }

    struct State {
        private(set) var previousTranslationX = 0.0
        private(set) var residualX = 0.0
        private var direction = 0

        mutating func reset(at translationX: Double = 0) {
            previousTranslationX = translationX
            residualX = 0
            direction = 0
        }

        /// Converts incremental finger travel into at most one cursor step.
        /// A direction change clears partial travel so small hand jitter cannot
        /// oscillate the insertion point across a character boundary.
        mutating func cursorStep(forTranslationX translationX: Double) -> Int {
            let delta = translationX - previousTranslationX
            previousTranslationX = translationX
            guard delta != 0 else { return 0 }

            let nextDirection = delta > 0 ? 1 : -1
            if direction != 0, nextDirection != direction {
                residualX = 0
            }
            direction = nextDirection
            residualX += delta

            let rawStep = Int(residualX / KeyboardCursorMotionPolicy.pointsPerCharacter)
            guard rawStep != 0 else { return 0 }

            // Do not replay a burst of stale movement after a dropped UI
            // frame. The next visible callback starts from the remaining
            // sub-character travel instead of jumping several characters.
            residualX = residualX.truncatingRemainder(
                dividingBy: KeyboardCursorMotionPolicy.pointsPerCharacter
            )
            return rawStep > 0 ? 1 : -1
        }
    }
}
