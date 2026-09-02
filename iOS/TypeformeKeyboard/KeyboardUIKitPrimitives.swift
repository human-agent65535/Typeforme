import UIKit

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
