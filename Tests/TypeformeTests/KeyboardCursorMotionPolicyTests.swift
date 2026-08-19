import Testing
@testable import Typeforme

@Suite("Keyboard cursor motion")
struct KeyboardCursorMotionPolicyTests {
    @Test("Slow travel accumulates into stable character steps")
    func accumulatesTravel() {
        var state = KeyboardCursorMotionPolicy.State()

        #expect(state.cursorStep(forTranslationX: 7) == 0)
        #expect(state.cursorStep(forTranslationX: 13.9) == 0)
        #expect(state.cursorStep(forTranslationX: 14) == 1)
        #expect(state.cursorStep(forTranslationX: 21) == 0)
        #expect(state.cursorStep(forTranslationX: 28) == 1)
    }

    @Test("A dropped frame never emits a multi-character jump")
    func capsBurstMovement() {
        var state = KeyboardCursorMotionPolicy.State()

        #expect(state.cursorStep(forTranslationX: 70) == 1)
        #expect(state.cursorStep(forTranslationX: 70) == 0)
        #expect(state.cursorStep(forTranslationX: 84) == 1)
    }

    @Test("Direction reversal requires fresh deliberate travel")
    func reversalHasHysteresis() {
        var state = KeyboardCursorMotionPolicy.State()

        #expect(state.cursorStep(forTranslationX: 14) == 1)
        #expect(state.cursorStep(forTranslationX: 13) == 0)
        #expect(state.cursorStep(forTranslationX: 0) == -1)
    }

    @Test("The hold location becomes the new movement origin")
    func resetStartsAtHoldLocation() {
        var state = KeyboardCursorMotionPolicy.State()

        #expect(state.cursorStep(forTranslationX: 13) == 0)
        state.reset(at: 120)
        #expect(state.cursorStep(forTranslationX: 121) == 0)
        #expect(state.cursorStep(forTranslationX: 134) == 1)
    }
}
