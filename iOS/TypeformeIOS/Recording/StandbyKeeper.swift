import AVFoundation
import Foundation

/// Keeps the host app alive in the background so the keyboard extension's
/// local bridge stream to `KeyboardLocalServer` always reaches a live process.
/// iOS keeps any app with `UIBackgroundModes = audio` alive while audio is
/// actively being routed; we feed an `AVAudioPlayerNode` a zero-filled
/// looping PCM buffer at 0.001 mixer volume.
///
/// Why `AVAudioEngine` instead of `AVAudioPlayer`:
/// `AVAudioPlayer.play()` returns `false` in practice when the session is
/// transitioning between categories (e.g., right after `AudioRecorder`
/// changed to voice-processing mode and the keeper is asked to resume).
/// `AVAudioPlayerNode` running on an engine is decoupled from session
/// category churn and reliably stays alive across recording sessions.
///
/// Why playback (silent) instead of a continuous mic engine:
/// playback keeps the app alive without lighting the red microphone status
/// indicator and without actually capturing audio. Battery cost: ~1-2%/hr.
///
/// Critical invariant: the connection format between `player` and
/// `mainMixerNode` MUST match the format of buffers scheduled on the
/// player. A mismatch raises an Obj-C exception that Swift can't catch and
/// crashes the app on launch. We pin both sides to a single static format.
@MainActor
final class StandbyKeeper {
    private struct SessionConfiguration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions

        init(session: AVAudioSession) {
            category = session.category
            mode = session.mode
            options = session.categoryOptions
        }
    }

    private enum SetupError: Error {
        case playbackBufferUnavailable
    }

    private(set) var isActive = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var hasAttached = false
    private var loopBuffer: AVAudioPCMBuffer?
    private var hasScheduledLoopBuffer = false
    private var sessionWasActivatedByKeeper = false

    /// 44.1 kHz Float32 stereo — iOS's lingua franca. `mainMixerNode`
    /// always accepts this and the hardware output node converts internally
    /// as needed.
    private static let playbackFormat: AVAudioFormat? =
        AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)

    func start(configureSession: Bool = true) {
        // A healthy keeper already owns one running graph and one scheduled
        // infinite buffer. Reconfiguring the session or scheduling another
        // buffer here would only queue unreachable work behind that loop.
        guard !(isActive && engine.isRunning && player.isPlaying && hasScheduledLoopBuffer) else {
            return
        }

        guard let format = Self.playbackFormat else {
            stopPlaybackGraph()
            isActive = false
            sessionWasActivatedByKeeper = false
            return
        }

        let session = AVAudioSession.sharedInstance()
        let previousConfiguration = configureSession
            ? SessionConfiguration(session: session)
            : nil
        let previouslyActivatedByKeeper = sessionWasActivatedByKeeper
        var didConfigureSession = false
        var didActivateSession = false

        // Recover an internally inconsistent graph before retrying. This does
        // not touch the process-wide audio session; the transaction below owns
        // any matching activation rollback.
        stopPlaybackGraph()
        isActive = false

        do {
            let buffer = try makeLoopBuffer(format: format)
            if configureSession {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
                didConfigureSession = true
                try session.setActive(true)
                didActivateSession = true
            }

            try setupAndPlay(format: format, buffer: buffer)
            isActive = true
            sessionWasActivatedByKeeper = previouslyActivatedByKeeper || didActivateSession
        } catch {
            // Audio session conflicts, hardware unavailable, etc. should not
            // surface to the user. The local bridge still works in foreground;
            // after background suspension, the next keyboard standby URL open
            // retries.
            rollbackFailedStart(
                session: session,
                previousConfiguration: previousConfiguration,
                restorePreviousConfiguration: didConfigureSession,
                deactivateSession: didActivateSession || previouslyActivatedByKeeper
            )
        }
    }

    func stop(deactivateSession: Bool = true) {
        let hadResources = isActive
            || engine.isRunning
            || player.isPlaying
            || hasScheduledLoopBuffer
            || sessionWasActivatedByKeeper
        stopPlaybackGraph()
        isActive = false
        sessionWasActivatedByKeeper = false
        if hadResources, deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func setupAndPlay(format: AVAudioFormat, buffer: AVAudioPCMBuffer) throws {
        if !hasAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.001
            hasAttached = true
        }

        if !engine.isRunning {
            try engine.start()
        }

        if !hasScheduledLoopBuffer {
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            hasScheduledLoopBuffer = true
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func makeLoopBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if let loopBuffer {
            return loopBuffer
        }

        // The retained buffer is reused across stop/start cycles. It must stay
        // in exactly the format used for the player-to-mixer connection.
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else {
            throw SetupError.playbackBufferUnavailable
        }
        buffer.frameLength = frameCount
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< Int(frameCount) {
                channels[channel][frame] = 0
            }
        }
        loopBuffer = buffer
        return buffer
    }

    private func stopPlaybackGraph() {
        // AVAudioPlayerNode.stop() clears every scheduled buffer even when the
        // node is not currently reporting isPlaying.
        player.stop()
        engine.stop()
        hasScheduledLoopBuffer = false
    }

    private func rollbackFailedStart(
        session: AVAudioSession,
        previousConfiguration: SessionConfiguration?,
        restorePreviousConfiguration: Bool,
        deactivateSession: Bool
    ) {
        stopPlaybackGraph()
        isActive = false
        sessionWasActivatedByKeeper = false
        if deactivateSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        if restorePreviousConfiguration, let previousConfiguration {
            try? session.setCategory(
                previousConfiguration.category,
                mode: previousConfiguration.mode,
                options: previousConfiguration.options
            )
        }
    }
}
