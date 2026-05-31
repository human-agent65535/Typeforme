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
/// Marked `@unchecked Sendable` — `isRunning` / `currentURL` / observer are
/// only mutated from the main-actor coordinator's call sites. The tap closure
/// writes through a captured writer and only weakly checks `self.isRunning`
/// before delivering UI level updates after stop.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let fileWriter = MonoM4ABufferWriter()
    private var currentURL: URL?
    private var configChangeObserver: NSObjectProtocol?
    private var isRunning = false

    /// Called on the main thread with normalized [0..1] RMS values.
    var onLevel: (@MainActor (Float) -> Void)?
    /// Called on the main thread if the audio config changes mid-recording.
    var onConfigurationChanged: (@MainActor () -> Void)?
    func start(pcmHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) async throws -> URL {
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Tap closure runs on the audio thread; it only touches its own
            // buffer writer and snapshotted handlers.
            writer.write(buffer)
            // Fan the same buffer out to any live-preview consumer (e.g.
            // SFSpeechRecognizer). Snapshotted at install-time so a late
            // attach is intentionally a no-op for the current recording.
            pcmHandler?(buffer)
            let rms = Self.rms(buffer)
            if let levelHandler {
                Task { @MainActor [weak self] in
                    guard self?.isRunning == true else { return }
                    levelHandler(rms)
                }
            }
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.audio.notice("AVAudioEngineConfigurationChange — requesting recording stop")
            if let h = self.onConfigurationChanged {
                Task { @MainActor in h() }
            } else {
                _ = self.stop()
            }
        }

        do {
            try engine.start()
        } catch {
            // Clean up everything we set up before throwing — otherwise the
            // tap stays installed, the observer stays registered, and the
            // temp file leaks into NSTemporaryDirectory().
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

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
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

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

}

private final class MonoM4ABufferWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var file: AVAudioFile?
    private var writeFormat: AVAudioFormat?
    private var frameCount: Int = 0
    private var writeError: Error?

    func begin(url: URL, sampleRate: Double) throws {
        let rate = sampleRate > 0 ? sampleRate : 48_000
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
        self.writeError = nil
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0 else { return }

        lock.lock()
        guard let file, let writeFormat, url != nil, writeError == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let mono = AVAudioPCMBuffer(
            pcmFormat: writeFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ), let destination = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)

        if let data = buffer.floatChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved ? data[0][frame * channels + channel] : data[channel][frame]
                }
                destination[frame] = sum / Float(channels)
            }
        } else if let data = buffer.int16ChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum = 0
                for channel in 0..<channels {
                    let sample = interleaved ? data[0][frame * channels + channel] : data[channel][frame]
                    sum += Int(sample)
                }
                let averaged = Float(sum) / Float(channels) / Float(Int16.max)
                destination[frame] = max(-1, min(1, averaged))
            }
        } else {
            return
        }

        lock.lock()
        do {
            if url != nil, writeError == nil {
                try file.write(from: mono)
                frameCount += frames
            }
        } catch {
            writeError = error
        }
        lock.unlock()
    }

    func finish() throws {
        lock.lock()
        let outputURL = url
        let frames = frameCount
        let error = writeError
        url = nil
        file = nil
        writeFormat = nil
        frameCount = 0
        writeError = nil
        lock.unlock()

        guard let outputURL else {
            throw AudioRecorderError.fileSetupFailed("No recording file")
        }
        if let error {
            throw AudioRecorderError.fileSetupFailed(error.localizedDescription)
        }
        guard frames > 0 else {
            throw AudioRecorderError.fileSetupFailed("Recorded M4A contains no audio data")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = attributes[.size] as? NSNumber
        guard (byteCount?.intValue ?? 0) > 0 else {
            throw AudioRecorderError.fileSetupFailed("Recorded M4A contains no audio data")
        }
    }

    func cancel() {
        lock.lock()
        let outputURL = url
        url = nil
        file = nil
        writeFormat = nil
        frameCount = 0
        writeError = nil
        lock.unlock()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}
