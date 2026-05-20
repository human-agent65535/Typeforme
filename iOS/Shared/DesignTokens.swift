import SwiftUI
import UIKit

/// Single source of truth for orb gradient colors used by both the iOS host
/// app (SwiftUI) and the keyboard extension (UIKit). Previously each side
/// hardcoded the same RGB values; tweaking the brand required two edits.
enum OrbGradient {
    /// Default standby — cool brighter top, deeper cooler bottom. Reads as
    /// "Typeforme is listening" without competing with the keyboard chrome.
    case idle
    /// Live recording. Red, the universal "we're capturing" signal.
    case recording
    /// Transcribing / restyling / opening host. Purple-indigo, distinct from
    /// the red of recording so users see when their voice is being processed
    /// rather than captured.
    case sending
    /// Capability gate (Full Access not granted, bridge unavailable, error
    /// with bridge still awake). Orange = "fixable, your attention needed".
    case blocked
    /// Final confirmation flash after a successful insert.
    case success

    var stops: (top: UIColor, bottom: UIColor) {
        switch self {
        case .idle:
            return (
                UIColor(red: 0.34, green: 0.66, blue: 1.00, alpha: 1),
                UIColor(red: 0.10, green: 0.40, blue: 0.92, alpha: 1)
            )
        case .recording:
            return (
                UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1),
                UIColor(red: 0.86, green: 0.18, blue: 0.20, alpha: 1)
            )
        case .sending:
            return (
                UIColor(red: 0.60, green: 0.50, blue: 0.96, alpha: 1),
                UIColor(red: 0.36, green: 0.28, blue: 0.80, alpha: 1)
            )
        case .blocked:
            return (
                UIColor(red: 1.00, green: 0.66, blue: 0.30, alpha: 1),
                UIColor(red: 0.95, green: 0.50, blue: 0.18, alpha: 1)
            )
        case .success:
            return (
                UIColor(red: 0.36, green: 0.84, blue: 0.50, alpha: 1),
                UIColor(red: 0.15, green: 0.62, blue: 0.30, alpha: 1)
            )
        }
    }

    /// UIKit consumers (keyboard extension): top + bottom UIColor.
    var top: UIColor { stops.top }
    var bottom: UIColor { stops.bottom }

    /// SwiftUI consumers (iOS host orb): `[top, bottom]` ready for
    /// `LinearGradient(colors:)`.
    var swiftUIColors: [Color] {
        [Color(uiColor: stops.top), Color(uiColor: stops.bottom)]
    }
}
