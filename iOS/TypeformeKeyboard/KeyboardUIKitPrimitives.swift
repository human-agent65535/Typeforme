import UIKit

/// UIInputView subclass opting into system keyboard clicks —
/// UIDevice.playInputClick() is a no-op unless the active input view conforms
/// to UIInputViewAudioFeedback. The system additionally gates the sound on
/// the user's keyboard-click setting, matching the native keyboard.
final class ClickFeedbackInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Backing surface for blank keyboard hit regions. The owning controller paints
/// it with `keyboardTouchableBackgroundColor` (0.01 alpha) and masks it to the
/// active touch geometry. iOS custom keyboards also consider rendered pixel
/// alpha for hit-test eligibility, so `point(inside:)` alone is not enough to
/// stop gap touches from leaking to the host app.
final class KeyboardSurfaceView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.contains(point)
    }
}

/// UIButton whose direct control target can extend beyond its visible bounds.
/// Character keys do not use this; their gaps and row margins are owned by
/// KeyboardTouchOverlayView so there is only one text-key routing path.
final class HitInsetButton: UIButton {
    var hitInsets: UIEdgeInsets = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.inset(by: hitInsets).contains(point)
    }
}
