import AVFoundation
import Foundation
import OSLog

private let recordingLog = Logger(subsystem: TypeformeBundleConfiguration.hostBundleIdentifier, category: "audio")

enum IOSRecordingAudioSession {
    enum Purpose: Sendable {
        case standby
        case keyboardRecording
        case recording
    }

    static let category: AVAudioSession.Category = .playAndRecord
    static let mode: AVAudioSession.Mode = .voiceChat
    static let standbyOptions: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
    static let keyboardRecordingOptions: AVAudioSession.CategoryOptions =
        [.defaultToSpeaker, .allowBluetoothHFP]
    static let recordingOptions: AVAudioSession.CategoryOptions =
        [.defaultToSpeaker, .allowBluetoothHFP]
    static let options = standbyOptions

    static func activate(reuseActiveSession: Bool = false, purpose: Purpose = .standby) throws {
        let session = AVAudioSession.sharedInstance()
        try configureActiveSessionCategory(purpose: purpose)
        do {
            try session.setActive(true)
            try? session.setPreferredInputNumberOfChannels(1)
            try requireMonoInputIfKnown()
        } catch {
            if !reuseActiveSession || purpose != .standby {
                throw error
            }
        }
    }

    static func configureActiveSessionCategory(purpose: Purpose) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options(for: purpose))
        try? session.setPreferredInputNumberOfChannels(1)
    }

    static func requireMonoInputIfKnown() throws {
        let channels = AVAudioSession.sharedInstance().inputNumberOfChannels
        guard channels <= 1 else {
            throw monoInputError(channels: channels)
        }
    }

    static func monoInputError(channels: Int) -> NSError {
        NSError(
            domain: "Typeforme",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Microphone input must be mono; got \(channels) channels"]
        )
    }

    static func configureActiveSessionCategoryEventually(purpose: Purpose) {
        Task.detached(priority: .userInitiated) {
            do {
                try configureActiveSessionCategory(purpose: purpose)
            } catch {
                NSLog("typeforme audio session category async configure failed purpose=\(purpose) error=\(error.localizedDescription)")
            }
        }
    }

    static func activateKeyboardRecording(reuseActiveSession: Bool = false) async throws {
        do {
            try activate(reuseActiveSession: reuseActiveSession, purpose: .keyboardRecording)
        } catch {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try activate(reuseActiveSession: reuseActiveSession, purpose: .keyboardRecording)
        }
    }

    static func activateRecording(reuseActiveSession: Bool = false) async throws {
        do {
            try activate(reuseActiveSession: reuseActiveSession, purpose: .recording)
        } catch {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try activate(reuseActiveSession: reuseActiveSession, purpose: .recording)
        }
    }

    static func deactivateAndNotifyOthers() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func shouldInterruptOtherAudioForKeyboardRecording() -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
    }

    static func isPriorityConflict(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == AVAudioSession.ErrorCode.insufficientPriority.rawValue {
            return true
        }
        let description = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
        return description.localizedCaseInsensitiveContains("priority")
            || description.localizedCaseInsensitiveContains("insufficient")
    }

    private static func options(for purpose: Purpose) -> AVAudioSession.CategoryOptions {
        switch purpose {
        case .standby: return standbyOptions
        case .keyboardRecording: return keyboardRecordingOptions
        case .recording: return recordingOptions
        }
    }
}

enum VoiceProcessingError: LocalizedError {
    case notEnabled

    var errorDescription: String? {
        "iOS voice processing could not be enabled"
    }
}

final class AudioTapFileWriter {
    private let lock = NSLock()
    private var audioData = Data()
    private var currentURL: URL?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var currentSampleRate: Double = 0
    private var writeError: Error?
    private var loggedFirstWrite = false

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentURL != nil
    }

    func begin(format: AVAudioFormat) throws -> URL {
        guard format.channelCount == 1 else {
            throw IOSRecordingAudioSession.monoInputError(channels: Int(format.channelCount))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-keyboard-\(UUID().uuidString).m4a")

        lock.lock()
        if let oldURL = currentURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        audioData = Data()
        currentURL = url
        recordedFrameCount = 0
        currentSampleRate = format.sampleRate
        writeError = nil
        loggedFirstWrite = false
        lock.unlock()
        NSLog("typeforme keyboard audio begin sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        return url
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0 else { return }
        guard channelCount == 1 else {
            lock.lock()
            if writeError == nil {
                writeError = IOSRecordingAudioSession.monoInputError(channels: channelCount)
            }
            lock.unlock()
            return
        }

        var chunk = Data()
        chunk.reserveCapacity(frameLength * MemoryLayout<Int16>.size)
        if let channels = buffer.floatChannelData {
            for frame in 0..<frameLength {
                chunk.appendPCM16(channels[0][frame])
            }
        } else if let channels = buffer.int16ChannelData {
            for frame in 0..<frameLength {
                chunk.appendInt16(channels[0][frame])
            }
        } else {
            return
        }

        var shouldLogFirstWrite = false
        lock.lock()
        guard currentURL != nil else {
            lock.unlock()
            return
        }
        if currentSampleRate <= 0 {
            currentSampleRate = buffer.format.sampleRate
        }
        audioData.append(chunk)
        recordedFrameCount += AVAudioFramePosition(buffer.frameLength)
        if !loggedFirstWrite {
            loggedFirstWrite = true
            shouldLogFirstWrite = true
        }
        lock.unlock()
        if shouldLogFirstWrite {
            NSLog("typeforme keyboard audio first pcm frames=\(buffer.frameLength) sampleRate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount)")
        }
    }

    func finish() -> URL? {
        lock.lock()
        let url = currentURL
        let data = audioData
        let duration = currentSampleRate > 0 ? Double(recordedFrameCount) / currentSampleRate : 0
        let sampleRate = currentSampleRate
        let frames = Int(recordedFrameCount)
        let error = writeError
        audioData = Data()
        currentURL = nil
        recordedFrameCount = 0
        currentSampleRate = 0
        writeError = nil
        loggedFirstWrite = false
        lock.unlock()
        guard let url else {
            NSLog("typeforme keyboard audio finish no_active_file")
            recordingLog.notice("keyboard audio finish: no active file")
            return nil
        }
        if let error {
            NSLog("typeforme keyboard audio finish failed error=\(error.localizedDescription)")
            recordingLog.error("keyboard audio finish failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if duration < 0.35 {
            NSLog("typeforme keyboard audio finish too_short duration=\(duration) frames=\(frames) bytes=\(data.count) sampleRate=\(sampleRate)")
            recordingLog.notice(
                "keyboard audio finish: too short duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) bytes=\(data.count, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        do {
            try Self.writeM4A(data: data, sampleRate: sampleRate, frameCount: frames, to: url)
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            NSLog("typeforme keyboard audio finish m4a_written duration=\(duration) frames=\(frames) pcmBytes=\(data.count) fileBytes=\(fileBytes) sampleRate=\(sampleRate)")
            recordingLog.notice(
                "keyboard audio finish: m4a written duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) pcmBytes=\(data.count, privacy: .public) fileBytes=\(fileBytes, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
        } catch {
            NSLog("typeforme keyboard audio finish m4a_failed duration=\(duration) frames=\(frames) pcmBytes=\(data.count) sampleRate=\(sampleRate) error=\(error.localizedDescription)")
            recordingLog.error(
                "keyboard audio finish: m4a failed duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) pcmBytes=\(data.count, privacy: .public) sampleRate=\(sampleRate, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func cancel() -> URL? {
        let url = finish()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func discard() {
        lock.lock()
        let url = currentURL
        audioData = Data()
        currentURL = nil
        recordedFrameCount = 0
        currentSampleRate = 0
        writeError = nil
        loggedFirstWrite = false
        lock.unlock()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeM4A(
        data: Data,
        sampleRate: Double,
        frameCount: Int,
        to url: URL
    ) throws {
        let sampleCount = min(frameCount, data.count / MemoryLayout<Int16>.size)
        guard sampleCount > 0 else {
            throw NSError(domain: "Typeforme", code: 6, userInfo: [NSLocalizedDescriptionKey: "Recorded M4A contains no audio data"])
        }
        let rate = max(1, sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
              )
        else {
            throw NSError(domain: "Typeforme", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not create M4A conversion buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            if let source = rawBuffer.baseAddress,
               let destination = buffer.int16ChannelData?[0] {
                UnsafeMutableRawPointer(destination).copyMemory(
                    from: source,
                    byteCount: sampleCount * MemoryLayout<Int16>.size
                )
            }
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
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

private extension Data {
    mutating func appendInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendPCM16(_ sample: Float) {
        let clamped = Swift.max(-1, Swift.min(1, sample))
        appendInt16(Int16(clamped * Float(Int16.max)))
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    /// Normalized 0...1 RMS-ish microphone level, refreshed while recording.
    /// Drives the keyboard extension's voiceprint visualization via the local
    /// status bridge. Stays at 0 when not recording.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meteringTimer: Timer?
    /// Pre-allocated recorder ready to record on first `start()`. The expensive
    /// work — permission, session config, encoder warm-up — happens once at
    /// app launch or right after the previous recording finishes, so the
    /// `record()` call from the press gesture is ~10ms instead of ~400ms.
    /// Without this the first ~1 syllable of speech is dropped because the
    /// mic isn't actually capturing yet.
    private var preparedRecorder: AVAudioRecorder?
    private var preparedURL: URL?

    var isPreWarmed: Bool {
        preparedRecorder != nil
    }

    /// Standby/pre-warm uses the same mixed session as `StandbyKeeper`.
    /// Fast-path recording intentionally reuses that hot session; changing
    /// category here costs seconds on some devices. Cold starts still switch
    /// to the dedicated recording session before capture.

    /// Prime the AVAudioRecorder so the next `start()` is instant. Safe to
    /// call multiple times; only does the work once until the prepared
    /// recorder is consumed.
    func preWarm(requestPermissionIfNeeded: Bool = false) async {
        guard preparedRecorder == nil else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            guard requestPermissionIfNeeded,
                  await requestPermission()
            else { return }
        case .denied:
            return
        @unknown default:
            return
        }

        do {
            try IOSRecordingAudioSession.activate(purpose: .standby)
        } catch {
            return
        }

        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-\(UUID().uuidString).m4a")
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        preparedRecorder = recorder
        preparedURL = url
    }

    func discardPreWarm() {
        if let preparedURL {
            try? FileManager.default.removeItem(at: preparedURL)
        }
        preparedRecorder = nil
        preparedURL = nil
    }

    func start(reuseActiveSession: Bool = false) async throws {
        // Fast path: use the pre-warmed recorder. record() is ~10ms.
        if let recorder = preparedRecorder, let url = preparedURL {
            preparedRecorder = nil
            preparedURL = nil
            guard recorder.record() else {
                try? FileManager.default.removeItem(at: url)
                // Fall through to cold path — pre-warm may have gone stale.
                try await coldStart(reuseActiveSession: reuseActiveSession)
                return
            }
            self.recorder = recorder
            self.currentURL = url
            self.isRecording = true
            startMetering()
            return
        }

        try await coldStart(reuseActiveSession: reuseActiveSession)
    }

    private func coldStart(reuseActiveSession: Bool) async throws {
        let granted = await requestPermission()
        guard granted else {
            throw NSError(domain: "Typeforme", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required"])
        }

        try await IOSRecordingAudioSession.activateRecording(reuseActiveSession: reuseActiveSession)

        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-\(UUID().uuidString).m4a")
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: "Typeforme", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start microphone recording"])
        }
        self.recorder = recorder
        self.currentURL = url
        self.isRecording = true
        startMetering()
    }

    func stop(deactivateSession: Bool = true) -> URL? {
        guard isRecording else { return nil }
        stopMetering()
        recorder?.stop()
        recorder = nil
        isRecording = false
        let url = currentURL
        currentURL = nil
        if deactivateSession {
            IOSRecordingAudioSession.deactivateAndNotifyOthers()
        }
        return url
    }

    private func startMetering() {
        stopMetering()
        level = 0
        // 20Hz sampling — fine-grained enough that the keyboard, which polls
        // ~8Hz during recording, always has a recent reading without spending
        // CPU on a CADisplayLink-rate update.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleLevel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meteringTimer = timer
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        level = 0
    }

    private func sampleLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = Self.normalizedLevel(fromDecibels: db)
    }

    /// Convert AVAudioRecorder dB into 0...1. iPhone mic typical ranges:
    /// silence -50 to -55dB, normal speech -25 to -15dB, loud -10 to 0dB.
    /// We clamp to a -45dB floor and use a `^0.55` curve to *expand* quiet
    /// signals (root-curve), the opposite of the prior `^1.6` which crushed
    /// them. Speech around -25dB now lands at ~0.66 instead of ~0.28, so the
    /// voiceprint actually moves visibly.
    private static func normalizedLevel(fromDecibels db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let floor: Float = -45
        let clamped = max(floor, min(0, db))
        let linear = (clamped - floor) / -floor
        return pow(linear, 0.55)
    }

    private func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            break
        @unknown default:
            return false
        }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
final class StandbyAudioSession: ObservableObject {
    /// Optional second consumer of the input PCM tap. Used by the live-preview
    /// SFSpeechRecognizer feed so we don't need a parallel AVAudioEngine
    /// pulling from the same mic. Cleared on stop.
    /// Read on the audio thread after recording begins. The host attaches this
    /// after the standby tap is already installed, so it intentionally remains a
    /// late-bound hook.
    nonisolated(unsafe) var onPCMBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    @Published private(set) var isActive = false
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private let fileWriter = AudioTapFileWriter()
    private let levelThrottler = LevelUpdateThrottler(interval: 1.0 / 20.0)
    private var hasInstalledTap = false
    private var currentFormat: AVAudioFormat?
    private var needsEngineRestart = false
    private var recordingDidActivateCaptureCategory = false
    private var recordingShouldYieldOtherAudio = false
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        observeAudioSessionInvalidations()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isRecording: Bool {
        fileWriter.isRecording
    }

    func start(reuseActiveSession: Bool = false) async throws {
        if fileWriter.isRecording {
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
            return
        }
        if isActive {
            if needsEngineRestart || !engine.isRunning || !hasInstalledTap {
                removeInputTap()
                engine.stop()
                currentFormat = nil
                isActive = false
                try await startEngineWithRetry(purpose: .standby, reuseActiveSession: reuseActiveSession)
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
            return
        }

        let granted = await requestPermission()
        guard granted else {
            throw NSError(domain: "Typeforme", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required"])
        }

        try await startEngineWithRetry(purpose: .standby, reuseActiveSession: reuseActiveSession)
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
    }

    private func observeAudioSessionInvalidations() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
        ]
        notificationObservers = names.map { name in
            center.addObserver(
                forName: name,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionNotification(notification)
                }
            }
        }
    }

    private func handleAudioSessionNotification(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.routeChangeNotification:
            handleRouteChange(notification)
        default:
            markEngineRestartNeeded()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else {
            markEngineRestartNeeded()
            return
        }

        switch reason {
        case .categoryChange, .override, .routeConfigurationChange, .wakeFromSleep:
            // Starting the silent keepalive or switching between standby and
            // capture can emit route-change notifications while the input
            // engine is still running with a valid tap. Treat those as hot
            // session churn; forcing a voice-processing engine restart here
            // adds multi-second "Preparing" latency on device.
            guard engine.isRunning, hasInstalledTap else {
                markEngineRestartNeeded()
                return
            }
            currentFormat = engine.inputNode.outputFormat(forBus: 0)
            needsEngineRestart = false
        case .newDeviceAvailable, .oldDeviceUnavailable, .noSuitableRouteForCategory, .unknown:
            markEngineRestartNeeded()
        @unknown default:
            markEngineRestartNeeded()
        }
    }

    private func markEngineRestartNeeded() {
        needsEngineRestart = true
        level = 0
    }

    private func startEngine(
        purpose: IOSRecordingAudioSession.Purpose,
        reuseActiveSession: Bool
    ) throws {
        try IOSRecordingAudioSession.activate(reuseActiveSession: reuseActiveSession, purpose: purpose)
        try enableVoiceProcessing()
        currentFormat = engine.inputNode.outputFormat(forBus: 0)
        if let currentFormat, currentFormat.channelCount != 1 {
            throw IOSRecordingAudioSession.monoInputError(channels: Int(currentFormat.channelCount))
        }
        installInputTapIfNeeded()
        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }
        isActive = true
        needsEngineRestart = false
    }

    private func startEngineWithRetry(
        purpose: IOSRecordingAudioSession.Purpose,
        reuseActiveSession: Bool
    ) async throws {
        var lastError: Error?
        for delay in [UInt64(0), 180_000_000, 360_000_000] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                try startEngine(purpose: purpose, reuseActiveSession: reuseActiveSession)
                return
            } catch {
                lastError = error
                removeInputTap()
                engine.stop()
                isActive = false
                currentFormat = nil
                needsEngineRestart = true
            }
        }
        throw lastError ?? NSError(
            domain: "Typeforme",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Session activation failed"]
        )
    }

    private func restartEngine(
        purpose: IOSRecordingAudioSession.Purpose,
        reuseActiveSession: Bool = true
    ) throws {
        removeInputTap()
        engine.stop()
        currentFormat = nil
        try startEngine(purpose: purpose, reuseActiveSession: reuseActiveSession)
    }

    private func installInputTapIfNeeded() {
        guard !hasInstalledTap else { return }
        let levelThrottler = levelThrottler
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self, fileWriter, levelThrottler] buffer, _ in
            guard fileWriter.isRecording else { return }
            let level = Self.normalizedLevel(from: buffer)
            fileWriter.write(buffer)
            // Fan the same buffer out to any live-preview consumer (e.g.
            // SFSpeechRecognizer). Read the handler off `self` each call so
            // late-attached handlers also receive frames.
            self?.onPCMBuffer?(buffer)
            guard levelThrottler.shouldPublish() else { return }
            Task { @MainActor [weak self] in
                self?.level = level
            }
        }
        hasInstalledTap = true
    }

    private func removeInputTap() {
        guard hasInstalledTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
    }

    private func enableVoiceProcessing() throws {
        try engine.inputNode.setVoiceProcessingEnabled(true)
        try engine.outputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.isVoiceProcessingBypassed = false
        engine.inputNode.isVoiceProcessingAGCEnabled = true
        guard engine.inputNode.isVoiceProcessingEnabled else {
            throw VoiceProcessingError.notEnabled
        }
    }

    func stop(deactivateSession: Bool = true) {
        recordingDidActivateCaptureCategory = false
        recordingShouldYieldOtherAudio = false
        onPCMBuffer = nil
        removeInputTap()
        _ = fileWriter.cancel()
        engine.stop()
        isActive = false
        level = 0
        currentFormat = nil
        if deactivateSession {
            IOSRecordingAudioSession.deactivateAndNotifyOthers()
        }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
    }

    func stopForAudioInterruption() {
        recordingDidActivateCaptureCategory = false
        recordingShouldYieldOtherAudio = false
        onPCMBuffer = nil
        removeInputTap()
        fileWriter.discard()
        if engine.isRunning {
            engine.stop()
        }
        isActive = false
        level = 0
        currentFormat = nil
        needsEngineRestart = true
    }

    func beginRecording() async throws -> URL {
        guard isActive else {
            throw NSError(domain: "Typeforme", code: 3, userInfo: [NSLocalizedDescriptionKey: "Keyboard standby is not active"])
        }
        guard !fileWriter.isRecording else {
            throw NSError(domain: "Typeforme", code: 5, userInfo: [NSLocalizedDescriptionKey: "Keyboard dictation is already recording"])
        }
        recordingDidActivateCaptureCategory = false
        recordingShouldYieldOtherAudio = false
        do {
            return try await beginRecordingNow()
        } catch {
            restoreAudioSessionAfterCapture()
            needsEngineRestart = true
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                return try await beginRecordingNow()
            } catch {
                restoreAudioSessionAfterCapture()
                throw error
            }
        }
    }

    private func beginRecordingNow() async throws -> URL {
        let needsRestart = needsEngineRestart || !engine.isRunning || !hasInstalledTap
        let shouldInterruptOtherAudio = IOSRecordingAudioSession.shouldInterruptOtherAudioForKeyboardRecording()
        if needsRestart {
            recordingDidActivateCaptureCategory = true
            recordingShouldYieldOtherAudio = shouldInterruptOtherAudio
            try await IOSRecordingAudioSession.activateKeyboardRecording(reuseActiveSession: true)
            try restartEngine(purpose: .keyboardRecording)
        } else {
            if shouldInterruptOtherAudio {
                recordingDidActivateCaptureCategory = true
                recordingShouldYieldOtherAudio = true
                IOSRecordingAudioSession.configureActiveSessionCategoryEventually(purpose: .keyboardRecording)
            }
            currentFormat = currentFormat ?? engine.inputNode.outputFormat(forBus: 0)
            if let currentFormat, currentFormat.channelCount != 1 {
                throw IOSRecordingAudioSession.monoInputError(channels: Int(currentFormat.channelCount))
            }
            needsEngineRestart = false
        }
        level = 0
        let format = currentFormat ?? engine.inputNode.outputFormat(forBus: 0)
        NSLog("typeforme keyboard audio beginRecording engineRunning=\(engine.isRunning) hasTap=\(hasInstalledTap) needsRestart=\(needsEngineRestart) sampleRate=\(format.sampleRate)")
        return try fileWriter.begin(format: format)
    }

    func finishRecording() -> URL? {
        level = 0
        let url = fileWriter.finish()
        restoreStandbyAfterRecording()
        return url
    }

    func cancelRecording() {
        let wasRecording = fileWriter.isRecording
        level = 0
        _ = fileWriter.cancel()
        if wasRecording {
            restoreStandbyAfterRecording()
        }
    }

    private func restoreStandbyAfterRecording() {
        restoreAudioSessionAfterCapture()
    }

    private func restoreAudioSessionAfterCapture() {
        let shouldYieldOtherAudio = recordingShouldYieldOtherAudio
        let shouldRestoreStandbyCategory = recordingDidActivateCaptureCategory
        recordingDidActivateCaptureCategory = false
        recordingShouldYieldOtherAudio = false
        if shouldYieldOtherAudio {
            removeInputTap()
            if engine.isRunning {
                engine.stop()
            }
            isActive = false
            level = 0
            currentFormat = nil
            needsEngineRestart = true
            IOSRecordingAudioSession.deactivateAndNotifyOthers()
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
            return
        }
        guard isActive else {
            needsEngineRestart = true
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
            return
        }
        if engine.isRunning, hasInstalledTap {
            currentFormat = currentFormat ?? engine.inputNode.outputFormat(forBus: 0)
            needsEngineRestart = false
            if shouldRestoreStandbyCategory {
                IOSRecordingAudioSession.configureActiveSessionCategoryEventually(purpose: .standby)
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
            return
        }
        needsEngineRestart = true
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
    }

    private func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            break
        @unknown default:
            return false
        }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        var sampleCount = 0
        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for frame in 0..<frameLength {
                    let sample = data[frame]
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let scale = Float(Int16.max)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for frame in 0..<frameLength {
                    let sample = Float(data[frame]) / scale
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sum / Float(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }

        // The standby keyboard path runs through iOS voice processing / AGC,
        // so raw RMS can sit near a constant "loud" value. Convert to dB and
        // apply the same floor curve as the host recorder to keep normal
        // speech below saturation and preserve visible dynamics.
        let db = 20 * log10f(max(rms, 0.00001))
        let floor: Float = -45
        let clamped = max(floor, min(0, db))
        let linear = (clamped - floor) / -floor
        return min(1, max(0, pow(linear, 0.55)))
    }
}

private final class LevelUpdateThrottler: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastUpdateAt: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldPublish(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastUpdateAt >= interval else { return false }
        lastUpdateAt = now
        return true
    }
}
