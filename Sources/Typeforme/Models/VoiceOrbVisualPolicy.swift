import Foundation

/// Geometry and animation values shared by Voice Orb renderers. The policy is
/// deliberately presentation-only: recording, Bridge, and Refine state remain
/// owned by their callers.
enum VoiceOrbVisualPolicy {
    static let pressedScale = 0.92
    static let borderWidth = 0.75
    static let shadowRadiusRatio = 18.0 / 132.0
    static let shadowOffsetYRatio = 9.0 / 132.0

    static let highlightWidthRatio = 0.55
    static let highlightHeightRatio = 0.32
    static let highlightCenterXRatio = 0.34
    static let highlightCenterYRatio = 0.28

    static let voiceprintWidthRatio = 80.0 / 132.0
    static let voiceprintHeightRatio = 50.0 / 132.0
    static let iconFrameRatio = 56.0 / 132.0
    static let idleIconPointSizeRatio = 52.0 / 132.0
    static let processingActionIconPointSizeRatio = 42.0 / 132.0

    static let pulseRingCount = 3
    static let pulseRingLineWidth = 1.5
    static let pulseMaximumScale = 1.7
    static let pulseDuration = 1.8
    static let pulsePhaseOffset = 0.6
    static let pulsePeakOpacity = 0.55
    static let pulseAudioBaselineOpacity = 0.30
    static let pulseAudioMaximumOpacity = 0.95
    static let pulseAudioLevelContribution = 0.65
    static let pulseAudioPreviousLevelWeight = 0.7
    static let pulseAudioNewLevelWeight = 0.3
}
