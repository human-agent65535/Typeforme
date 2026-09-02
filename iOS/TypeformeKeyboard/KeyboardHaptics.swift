import UIKit
import QuartzCore
import AudioToolbox
import AVFoundation
import OSLog

/// UIKit's playInputClick() cannot select a key category. These built-in
/// keyboard sound IDs have no public symbolic constants, so keep their
/// mapping in one place and verify the sounds on new major iOS versions.
enum KeyboardKeySound: SystemSoundID, CaseIterable {
    case input = 1104
    case delete = 1155
    case modifier = 1156

    fileprivate var resourceName: String {
        switch self {
        case .input: return "key_press_click"
        case .delete: return "key_press_delete"
        case .modifier: return "key_press_modifier"
        }
    }
}

/// System Sound Services has no per-sound volume control. Prepare louder PCM
/// copies once, keeping the system's three timbres and UI-sound playback policy.
private final class KeyboardClickSounds {
    private static let gain: Float = 2
    private static let peakLimit: Float = 0.9
    private static let log = Logger(
        subsystem: TypeformeBundleConfiguration.keyboardBundleIdentifier,
        category: "key-feedback"
    )
    private let directory: URL
    private var soundIDs: [KeyboardKeySound: SystemSoundID] = [:]

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-keyboard-clicks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for sound in KeyboardKeySound.allCases {
                do {
                    soundIDs[sound] = try prepare(sound)
                } catch {
                    // OS sound resources are not an API contract. A missing or
                    // changed file must leave the built-in category available.
                    Self.log.error("Using system key sound \(sound.rawValue): gain preparation failed")
                }
            }
        } catch {
            Self.log.error("Using system key sounds: temporary audio directory unavailable")
        }
    }

    deinit {
        for id in soundIDs.values {
            AudioServicesDisposeSystemSoundID(id)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func play(_ sound: KeyboardKeySound) {
        AudioServicesPlaySystemSoundWithCompletion(soundIDs[sound] ?? sound.rawValue, nil)
    }

    private func prepare(_ sound: KeyboardKeySound) throws -> SystemSoundID {
        #if targetEnvironment(simulator)
        let root = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"] ?? "/"
        #else
        let root = "/"
        #endif
        let source = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("System/Library/Audio/UISounds", isDirectory: true)
            .appendingPathComponent(sound.resourceName + ".caf")
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard input.length > 0, input.length <= Int64(format.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)),
              let channels = buffer.floatChannelData
        else { throw CocoaError(.fileReadCorruptFile) }
        try input.read(into: buffer)

        var peak: Float = 0
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = channels[channel][frame]
                guard sample.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                peak = max(peak, abs(sample))
            }
        }
        // Reduce the requested gain for a louder OS asset instead of clipping
        // its waveform; otherwise all three categories receive the same +6 dB.
        let gain = peak > 0 ? min(Self.gain, Self.peakLimit / peak) : 1
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] *= gain
            }
        }
        let outputURL = directory.appendingPathComponent(sound.resourceName + ".caf")
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            try output.write(from: buffer)
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(outputURL as CFURL, &id)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // IsUISound defaults to true. Retain it so Silent Mode and the user's
        // system sound policy still apply, without activating an audio session.
        return id
    }
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
    private var clickSounds: KeyboardClickSounds?

    func prepareForKeyboardReady() {
        prepareClickSoundsIfNeeded()
        textKeyImpactGenerator.prepare()
        controlImpactGenerator.prepare()
        selectionGenerator.prepare()
    }

    func prepareForTextInput() {
        textKeyImpactGenerator.prepare()
    }

    func playTextKeyPress(sound: KeyboardKeySound) {
        if clickSoundsEnabled {
            prepareClickSoundsIfNeeded()
            clickSounds?.play(sound)
        }
        guard hapticsEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTextKeyFeedbackAt > Self.textKeyCooldown else { return }
        lastTextKeyFeedbackAt = now
        textKeyImpactGenerator.impactOccurred(intensity: 1.0)
        textKeyImpactGenerator.prepare()
    }

    private func prepareClickSoundsIfNeeded() {
        guard clickSoundsEnabled, clickSounds == nil else { return }
        clickSounds = KeyboardClickSounds()
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
