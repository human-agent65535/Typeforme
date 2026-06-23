import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineFailedToStart(String)
    case fileSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Grant access in System Settings → Privacy → Microphone."
        case .engineFailedToStart(let why):
            return "AudioEngine failed to start: \(why)"
        case .fileSetupFailed(let why):
            return "Couldn't open audio file for writing: \(why)"
        }
    }
}

/// AVAudioEngine-based capture. On device-change we stop recording and surface
/// the interruption to the coordinator.
/// Main-actor isolated because recording lifecycle state is driven by the
/// coordinator and UI permission flow. The audio tap writes through captured,
/// nonisolated, lock-protected helpers and hops back to the main actor for
/// published state.
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let fileWriter = MonoM4ABufferWriter()
    private let levelThrottler = LevelUpdateThrottler(interval: 1.0 / 20.0)
    private let runningState = AudioRecorderRunningState()
    private var currentURL: URL?
    private var configChangeObserver: NSObjectProtocol?
    private var isRunning = false

    /// Called on the main thread with normalized [0..1] RMS values.
    var onLevel: (@MainActor (Float) -> Void)?
    /// Called on the main thread if the audio config changes mid-recording.
    var onConfigurationChanged: (@MainActor () -> Void)?
    func start(pcmHandler: ((AVAudioPCMBuffer) -> Void)? = nil) async throws -> URL {
        guard await Self.ensureMicrophonePermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let m4aURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-\(UUID().uuidString).m4a")
        try fileWriter.begin(url: m4aURL, sampleRate: format.sampleRate)

        let writer = fileWriter
        let levelHandler = onLevel
        let levelThrottler = levelThrottler
        levelThrottler.reset()
        runningState.setRunning(false)
        let tapHandler = makeAudioRecorderTapHandler(
            writer: writer,
            pcmHandler: pcmHandler,
            levelHandler: levelHandler,
            levelThrottler: levelThrottler,
            runningState: runningState
        )
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: tapHandler
        )

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.audio.notice("AVAudioEngineConfigurationChange — requesting recording stop")
            Task { @MainActor in
                if let h = self.onConfigurationChanged {
                    h()
                } else {
                    _ = self.stop()
                }
            }
        }

        do {
            runningState.setRunning(true)
            try engine.start()
        } catch {
            // Clean up everything we set up before throwing — otherwise the
            // tap stays installed, the observer stays registered, and the
            // temp file leaks into NSTemporaryDirectory().
            runningState.setRunning(false)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            removeObserver()
            try? FileManager.default.removeItem(at: m4aURL)
            fileWriter.cancel()
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

        currentURL = m4aURL
        isRunning = true
        return m4aURL
    }

    @discardableResult
    func stop() -> URL? {
        guard isRunning else { return nil }
        isRunning = false
        runningState.setRunning(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObserver()
        let url = currentURL
        currentURL = nil
        guard let url else { return nil }
        do {
            try fileWriter.finish()
            return url
        } catch {
            Log.audio.notice("Mac recorder M4A write failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func removeObserver() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

}

private func makeAudioRecorderTapHandler(
    writer: MonoM4ABufferWriter,
    pcmHandler: ((AVAudioPCMBuffer) -> Void)?,
    levelHandler: (@MainActor (Float) -> Void)?,
    levelThrottler: LevelUpdateThrottler,
    runningState: AudioRecorderRunningState
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        writer.write(buffer)
        // Fan the same buffer out to any live-preview consumer. The handler is
        // snapshotted at install-time so a late attach is a no-op for the
        // current recording.
        pcmHandler?(buffer)
        if let levelHandler, levelThrottler.shouldPublish() {
            let rms = normalizedAudioRMS(buffer)
            Task { @MainActor in
                guard runningState.isRunning else { return }
                levelHandler(rms)
            }
        }
    }
}

private func normalizedAudioRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let chans = buffer.floatChannelData else { return 0 }
    let frames = Int(buffer.frameLength)
    let channel = chans[0]
    var sumSq: Float = 0
    for i in 0..<frames {
        let s = channel[i]
        sumSq += s * s
    }
    let rms = sqrt(sumSq / Float(max(1, frames)))
    // Square-root compression + scale; clamps loud speech to ~1.0.
    return min(1, sqrt(rms) * 2.5)
}

private final class AudioRecorderRunningState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }
}

private final class LevelUpdateThrottler: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastUpdateAt: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func reset() {
        lock.lock()
        lastUpdateAt = 0
        lock.unlock()
    }

    func shouldPublish(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastUpdateAt >= interval else { return false }
        lastUpdateAt = now
        return true
    }
}

private final class MonoM4ABufferWriter: @unchecked Sendable {
    private static let minimumRecordingDuration: TimeInterval = 0.35

    private let lock = NSLock()
    private var url: URL?
    private var file: AVAudioFile?
    private var writeFormat: AVAudioFormat?
    private var frameCount: AVAudioFramePosition = 0
    private var currentSampleRate: Double = 0
    private var writeError: Error?

    func begin(url: URL, sampleRate: Double) throws {
        let rate = try validatedRecordingSampleRate(sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.fileSetupFailed("Could not create M4A writer format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        lock.lock()
        self.url = url
        self.file = file
        self.writeFormat = format
        self.frameCount = 0
        self.currentSampleRate = rate
        self.writeError = nil
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        lock.lock()
        let recordingURL = url
        let format = writeFormat
        let hasPreviousError = writeError != nil
        lock.unlock()
        guard recordingURL != nil, let format, !hasPreviousError,
              let writeBuffer = Self.makeWriteBuffer(from: buffer, format: format)
        else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            guard url == recordingURL, let file, writeError == nil else { return }
            try file.write(from: writeBuffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = error
        }
    }

    func finish() throws {
        lock.lock()
        let outputURL = url
        let sampleRate = currentSampleRate
        let frames = Int(frameCount)
        let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        let error = writeError
        url = nil
        file = nil
        writeFormat = nil
        frameCount = 0
        currentSampleRate = 0
        writeError = nil
        lock.unlock()

        guard let outputURL else {
            Log.audio.notice("Mac recorder finish: no active file")
            throw AudioRecorderError.fileSetupFailed("No recording file")
        }
        if let error {
            Log.audio.error("Mac recorder finish failed: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.fileSetupFailed(error.localizedDescription)
        }
        guard frames > 0 else {
            Log.audio.error(
                "Mac recorder finish: empty m4a duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            throw AudioRecorderError.fileSetupFailed("Recorded M4A contains no audio data")
        }
        guard duration >= Self.minimumRecordingDuration else {
            Log.audio.notice(
                "Mac recorder finish: too short duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            throw AudioRecorderError.fileSetupFailed("Recorded M4A is too short")
        }

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileBytes > 0 else {
            Log.audio.error(
                "Mac recorder finish: empty m4a duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            throw AudioRecorderError.fileSetupFailed("Recorded M4A contains no audio data")
        }
        Log.audio.debug(
            "Mac recorder finish: m4a written duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) fileBytes=\(fileBytes, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
        )
    }

    func cancel() {
        lock.lock()
        let outputURL = url
        url = nil
        file = nil
        writeFormat = nil
        frameCount = 0
        currentSampleRate = 0
        writeError = nil
        lock.unlock()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    /// Converts arbitrary input buffers to the mono float32 writer format.
    /// Multi-channel input is averaged so USB and monitor-array devices produce
    /// the same Bridge-ready M4A shape as the iOS keyboard path.
    private static func makeWriteBuffer(
        from buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(format) {
            return buffer
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameLength)
        ), let destination = output.floatChannelData?[0] else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(frameLength)

        if let data = buffer.floatChannelData {
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleaved ? data[0][frame * channelCount + channel] : data[channel][frame]
                }
                destination[frame] = sum / Float(channelCount)
            }
            return output
        }
        if let data = buffer.int16ChannelData {
            let scale = Float(Int16.max)
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let sample = interleaved ? data[0][frame * channelCount + channel] : data[channel][frame]
                    sum += Float(sample) / scale
                }
                destination[frame] = max(-1, min(1, sum / Float(channelCount)))
            }
            return output
        }
        return nil
    }
}

private func validatedRecordingSampleRate(_ sampleRate: Double) throws -> Double {
    guard sampleRate.isFinite, sampleRate > 0 else {
        Log.audio.error("Mac recorder received invalid hardware sample rate: \(sampleRate, privacy: .public)")
        throw AudioRecorderError.fileSetupFailed("Invalid input sample rate: \(sampleRate)")
    }
    return sampleRate
}
