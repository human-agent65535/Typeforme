import UIKit
import QuartzCore
import AudioToolbox

/// UIKit's playInputClick() cannot select a key category. These built-in
/// keyboard sound IDs have no public symbolic constants, so keep their
/// mapping in one place and verify the sounds on new major iOS versions.
enum KeyboardKeySound: SystemSoundID {
    case input = 1104
    case delete = 1155
    case modifier = 1156
}

@MainActor
final class KeyboardHaptics {
    private static let textKeyCooldown: CFTimeInterval = 0.035

    /// Mirrors Typeforme's Keyboard Settings → Feedback toggles. System
    /// Sound Services owns sound playback; no recording session is changed.
    var clickSoundsEnabled = true
    var hapticsEnabled = true

    // .rigid, not .light: light is a low-sharpness, slow-decay thump that
    // reads as soft and laggy under fast typing. Rigid is the short,
    // high-sharpness tick that matches the native keyboard's key click.
    private let textKeyImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let controlImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private var lastTextKeyFeedbackAt: CFTimeInterval = 0

    func prepareForKeyboardReady() {
        textKeyImpactGenerator.prepare()
        controlImpactGenerator.prepare()
        selectionGenerator.prepare()
    }

    func prepareForTextInput() {
        textKeyImpactGenerator.prepare()
    }

    func playTextKeyPress(sound: KeyboardKeySound) {
        if clickSoundsEnabled {
            AudioServicesPlaySystemSoundWithCompletion(sound.rawValue, nil)
        }
        guard hapticsEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTextKeyFeedbackAt > Self.textKeyCooldown else { return }
        lastTextKeyFeedbackAt = now
        textKeyImpactGenerator.impactOccurred(intensity: 1.0)
        textKeyImpactGenerator.prepare()
    }

    func playControlTap() {
        guard hapticsEnabled else { return }
        controlImpactGenerator.impactOccurred(intensity: 0.8)
        controlImpactGenerator.prepare()
        textKeyImpactGenerator.prepare()
    }

    func playSelectionChanged() {
        guard hapticsEnabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
        textKeyImpactGenerator.prepare()
    }
}
