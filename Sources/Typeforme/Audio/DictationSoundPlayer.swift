import AppKit

/// Audible start / stop / error cues. While dictating the user is usually
/// looking at their text, not the HUD, so recording state changes need a
/// signal that works without eyes on the capsule — same contract as the
/// system dictation sounds.
@MainActor
enum DictationSoundPlayer {
    static func playStart() { play("Tink", volume: 0.45) }
    static func playStop()  { play("Pop", volume: 0.5) }
    static func playError() { play("Basso", volume: 0.6) }

    private static func play(_ name: String, volume: Float) {
        guard AppSettings.soundFeedback else { return }
        // NSSound(named:) returns a shared cached instance; copy before
        // mutating volume so we don't change the system-wide cached sound.
        guard let cached = NSSound(named: name) else { return }
        let sound = (cached.copy() as? NSSound) ?? cached
        sound.volume = volume
        sound.play()
    }
}
