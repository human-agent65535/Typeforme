import AVFoundation
import Foundation
import os.lock

enum AudioRecorderError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case engineFailedToStart(String)
    case fileSetupFailed(String)
    case invalidInputFormat(String)
    case captureBufferOverflow(capacity: Int)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Grant access in System Settings → Privacy → Microphone."
        case .engineFailedToStart(let why):
            return "AudioEngine failed to start: \(why)"
        case .fileSetupFailed(let why):
            return "Couldn't open audio file for writing: \(why)"
        case .invalidInputFormat(let why):
            return "The selected microphone has an invalid audio format: \(why)"
        case .captureBufferOverflow(let capacity):
            return "Audio capture couldn't keep up and filled its \(capacity)-buffer queue. The recording was stopped to avoid losing audio."
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
    private let levelThrottler = LevelUpdateThrottler(interval: 1.0 / 20.0)
    private var pipeline: AudioCapturePipeline?
    private var currentURL: URL?
    private var configChangeObserver: NSObjectProtocol?
    private var isRunning = false
    private var tapInstalled = false

    /// Called on the main thread with normalized [0..1] RMS values.
    var onLevel: (@MainActor (Float) -> Void)?
    /// Called on the main thread if the audio config changes mid-recording.
    var onConfigurationChanged: (@MainActor () -> Void)?
    /// Called after capture has been stopped because a bounded pipeline error
    /// made the recording incomplete. Incomplete audio is never returned.
    var onCaptureFailure: (@MainActor (AudioRecorderError) -> Void)?

    func start(pcmHandler: ((AVAudioPCMBuffer) -> Void)? = nil) async throws -> URL {
        guard await Self.ensureMicrophonePermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        try AudioInputFormatValidator.validate(format)

        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-\(UUID().uuidString).flac")
        let fileWriter = MonoFLACBufferWriter()
        try fileWriter.begin(url: audioURL)

        let levelHandler: (@MainActor (Float) -> Void)?
        if onLevel == nil {
            levelHandler = nil
        } else {
            levelHandler = { [weak self] level in
                guard let self, self.isRunning else { return }
                self.onLevel?(level)
            }
        }
        let levelThrottler = levelThrottler
        levelThrottler.reset()
        let pipeline: AudioCapturePipeline
        do {
            pipeline = try AudioCapturePipeline(
                inputFormat: format,
                writer: fileWriter,
                pcmHandler: pcmHandler,
                levelHandler: levelHandler,
                levelThrottler: levelThrottler,
                failureHandler: { [weak self] error in
                    Task { @MainActor [weak self] in
                        await self?.stopAfterCaptureFailure(error)
                    }
                }
            )
        } catch {
            fileWriter.cancel()
            throw error
        }
        self.pipeline = pipeline
        currentURL = audioURL
        pipeline.start()
        let tapHandler = makeAudioRecorderTapHandler(
            pipeline: pipeline
        )
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: tapHandler
        )
        tapInstalled = true

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
                    await self.discard()
                }
            }
        }

        do {
            try engine.start()
        } catch {
            await discard()
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

        isRunning = true
        return audioURL
    }

    @discardableResult
    func stop() async throws -> URL? {
        guard let pipeline else { return nil }
        stopCaptureDevice()
        let url = currentURL
        do {
            try await pipeline.finish()
            guard self.pipeline === pipeline else { return nil }
            self.pipeline = nil
            currentURL = nil
            guard let url else { return nil }
            return url
        } catch {
            if self.pipeline === pipeline {
                self.pipeline = nil
                currentURL = nil
            }
            Log.audio.notice("Mac recorder FLAC write failed: \(error.localizedDescription, privacy: .public)")
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Abandons the current recording. Unlike `stop()`, this never drains
    /// queued PCM into FLAC or live-preview consumers. It can also upgrade a
    /// normal stop that is already waiting for its pipeline to finish.
    func discard() async {
        stopCaptureDevice()
        let pipeline = pipeline
        let url = currentURL
        self.pipeline = nil
        currentURL = nil
        await pipeline?.cancel()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stopAfterCaptureFailure(_ error: AudioRecorderError) async {
        guard isRunning else { return }
        await discard()
        onCaptureFailure?(error)
    }

    private func stopCaptureDevice() {
        isRunning = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        removeObserver()
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
    pipeline: AudioCapturePipeline
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        pipeline.appendFromAudioTap(buffer)
    }
}

enum AudioInputFormatValidator {
    static func validate(_ format: AVAudioFormat) throws {
        try validate(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            commonFormat: format.commonFormat
        )
    }

    static func validate(
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        commonFormat: AVAudioCommonFormat
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat("sample rate is zero or non-finite")
        }
        guard channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat("no input channels are available")
        }
        guard commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatInt16 else {
            throw AudioRecorderError.invalidInputFormat("unsupported PCM format \(commonFormat.rawValue)")
        }
    }
}

struct AudioCaptureQueuePlan: Equatable, Sendable {
    static let maximumQueuedPCMBytes = 16 * 1_024 * 1_024
    static let maximumBufferedDuration: TimeInterval = 3
    static let maximumBufferCount = 256
    private static let preferredBufferDuration: TimeInterval = 0.1
    private static let minimumFrameCapacity = 4_096

    let frameCapacity: AVAudioFrameCount
    let bufferCount: Int
    let bytesPerBuffer: Int
    let totalBytes: Int
    let bufferedDuration: TimeInterval

    static func make(
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        commonFormat: AVAudioCommonFormat
    ) throws -> AudioCaptureQueuePlan {
        try AudioInputFormatValidator.validate(
            sampleRate: sampleRate,
            channelCount: channelCount,
            commonFormat: commonFormat
        )

        let bytesPerSample: Int
        switch commonFormat {
        case .pcmFormatFloat32:
            bytesPerSample = MemoryLayout<Float>.size
        case .pcmFormatInt16:
            bytesPerSample = MemoryLayout<Int16>.size
        default:
            throw AudioRecorderError.invalidInputFormat("unsupported PCM format \(commonFormat.rawValue)")
        }

        let requestedFrames = max(
            Double(Self.minimumFrameCapacity),
            ceil(sampleRate * Self.preferredBufferDuration)
        )
        guard requestedFrames <= Double(AVAudioFrameCount.max) else {
            throw AudioRecorderError.invalidInputFormat("sample rate is too large for the capture queue")
        }
        let frameCapacity = Int(requestedFrames)
        let (bytesPerFrame, frameByteOverflow) = Int(channelCount)
            .multipliedReportingOverflow(by: bytesPerSample)
        let (bytesPerBuffer, bufferByteOverflow) = frameCapacity
            .multipliedReportingOverflow(by: bytesPerFrame)
        guard !frameByteOverflow,
              !bufferByteOverflow,
              bytesPerBuffer > 0,
              bytesPerBuffer <= Self.maximumQueuedPCMBytes
        else {
            throw AudioRecorderError.invalidInputFormat("one capture buffer exceeds the PCM memory budget")
        }

        let byteBound = Self.maximumQueuedPCMBytes / bytesPerBuffer
        let durationBound = Int(floor(
            Self.maximumBufferedDuration * sampleRate / Double(frameCapacity)
        ))
        let bufferCount = min(Self.maximumBufferCount, byteBound, durationBound)
        guard bufferCount > 0 else {
            throw AudioRecorderError.invalidInputFormat("one capture buffer exceeds the queue duration budget")
        }
        let totalBytes = bytesPerBuffer * bufferCount
        let bufferedDuration = Double(frameCapacity * bufferCount) / sampleRate
        return AudioCaptureQueuePlan(
            frameCapacity: AVAudioFrameCount(frameCapacity),
            bufferCount: bufferCount,
            bytesPerBuffer: bytesPerBuffer,
            totalBytes: totalBytes,
            bufferedDuration: bufferedDuration
        )
    }
}

struct AudioCapturePipelineState {
    var readIndex = 0
    var writeIndex = 0
    var queuedCount = 0
    var workerOwnsReadBuffer = false
    var accepting = true
    var cancelRequested = false
    var terminalError: AudioRecorderError?
    var failureReported = false
    var completion: Result<Void, AudioRecorderError>?
    var waiters: [CheckedContinuation<Void, any Error>] = []

    var isReadyToTerminate: Bool {
        !accepting && queuedCount == 0 && !workerOwnsReadBuffer
    }

    @discardableResult
    mutating func requestDiscard() -> Int {
        accepting = false
        cancelRequested = true
        return discardPendingBuffers()
    }

    @discardableResult
    mutating func discardPendingBuffers() -> Int {
        let retainedBufferCount = workerOwnsReadBuffer && queuedCount > 0 ? 1 : 0
        let discardedBufferCount = max(0, queuedCount - retainedBufferCount)
        queuedCount = retainedBufferCount
        if !workerOwnsReadBuffer {
            readIndex = writeIndex
        }
        return discardedBufferCount
    }

    mutating func releaseReadBuffer(bufferCount: Int) {
        guard workerOwnsReadBuffer else { return }
        workerOwnsReadBuffer = false
        if cancelRequested || terminalError != nil {
            queuedCount = 0
            readIndex = writeIndex
        } else {
            readIndex = (readIndex + 1) % bufferCount
            queuedCount = max(0, queuedCount - 1)
        }
    }
}

func normalizedAudioRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameCount > 0, channelCount > 0 else { return 0 }

    let sampleCount = frameCount * channelCount
    var sumSquares: Double = 0

    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
        guard let channelData = buffer.floatChannelData else { return 0 }
        if buffer.format.isInterleaved {
            for index in 0..<sampleCount {
                let sample = Double(channelData[0][index])
                sumSquares += sample * sample
            }
        } else {
            for channelIndex in 0..<channelCount {
                for frameIndex in 0..<frameCount {
                    let sample = Double(channelData[channelIndex][frameIndex])
                    sumSquares += sample * sample
                }
            }
        }
    case .pcmFormatInt16:
        guard let channelData = buffer.int16ChannelData else { return 0 }
        let scale = 1.0 / Double(Int16.max)
        if buffer.format.isInterleaved {
            for index in 0..<sampleCount {
                let sample = Double(channelData[0][index]) * scale
                sumSquares += sample * sample
            }
        } else {
            for channelIndex in 0..<channelCount {
                for frameIndex in 0..<frameCount {
                    let sample = Double(channelData[channelIndex][frameIndex]) * scale
                    sumSquares += sample * sample
                }
            }
        }
    default:
        return 0
    }

    let rms = Float(sqrt(sumSquares / Double(sampleCount)))
    // Square-root compression + scale; clamps loud speech to ~1.0.
    return min(1, sqrt(rms) * 2.5)
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

/// A single-producer/single-consumer capture pipeline. The audio tap only
/// copies into preallocated buffers and signals the worker; format conversion,
/// FLAC I/O, live-preview fan-out, and level calculation all run in order on
/// the worker queue. The queue is deliberately bounded: once it fills, the
/// recording fails instead of silently dropping or reordering audio.
private final class AudioCapturePipeline: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let buffers: [AVAudioPCMBuffer]
    private let state = OSAllocatedUnfairLock(initialState: AudioCapturePipelineState())
    private let wakeup = DispatchSemaphore(value: 0)
    private let workerQueue = DispatchQueue(
        label: "typeforme.audio.capture-writer",
        qos: .userInitiated
    )
    private let writer: MonoFLACBufferWriter
    private let pcmHandler: ((AVAudioPCMBuffer) -> Void)?
    private let levelHandler: (@MainActor (Float) -> Void)?
    private let levelThrottler: LevelUpdateThrottler
    private let failureHandler: @Sendable (AudioRecorderError) -> Void

    init(
        inputFormat: AVAudioFormat,
        writer: MonoFLACBufferWriter,
        pcmHandler: ((AVAudioPCMBuffer) -> Void)?,
        levelHandler: (@MainActor (Float) -> Void)?,
        levelThrottler: LevelUpdateThrottler,
        failureHandler: @escaping @Sendable (AudioRecorderError) -> Void
    ) throws {
        try AudioInputFormatValidator.validate(inputFormat)
        self.inputFormat = inputFormat
        self.writer = writer
        self.pcmHandler = pcmHandler
        self.levelHandler = levelHandler
        self.levelThrottler = levelThrottler
        self.failureHandler = failureHandler

        let queuePlan = try AudioCaptureQueuePlan.make(
            sampleRate: inputFormat.sampleRate,
            channelCount: inputFormat.channelCount,
            commonFormat: inputFormat.commonFormat
        )
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(queuePlan.bufferCount)
        for _ in 0..<queuePlan.bufferCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: queuePlan.frameCapacity
            ) else {
                throw AudioRecorderError.fileSetupFailed("Could not allocate the capture buffer queue")
            }
            allocated.append(buffer)
        }
        buffers = allocated
    }

    func start() {
        workerQueue.async { [self] in
            runWorker()
        }
    }

    /// Called directly by AVAudioEngine's real-time tap.
    func appendFromAudioTap(_ source: AVAudioPCMBuffer) {
        let sendableSource = UncheckedAudioPCMBuffer(source)
        let outcome = state.withLock { state -> (accepted: Bool, failure: AudioRecorderError?) in
            let source = sendableSource.value
            guard state.accepting else { return (false, nil) }
            guard source.format.isEqual(inputFormat) else {
                let failure = markFailedLocked(
                    &state,
                    error: .invalidInputFormat("input format changed while recording")
                )
                return (false, failure)
            }
            guard source.frameLength <= buffers[state.writeIndex].frameCapacity else {
                let failure = markFailedLocked(
                    &state,
                    error: .invalidInputFormat(
                        "input buffer has \(source.frameLength) frames; capacity is \(buffers[state.writeIndex].frameCapacity)"
                    )
                )
                return (false, failure)
            }
            guard state.queuedCount < buffers.count else {
                let failure = markFailedLocked(
                    &state,
                    error: .captureBufferOverflow(capacity: buffers.count)
                )
                return (false, failure)
            }

            let destination = buffers[state.writeIndex]
            guard Self.copy(source, to: destination) else {
                let failure = markFailedLocked(
                    &state,
                    error: .invalidInputFormat("could not copy the microphone buffer")
                )
                return (false, failure)
            }
            state.writeIndex = (state.writeIndex + 1) % buffers.count
            state.queuedCount += 1
            return (true, nil)
        }
        if outcome.accepted || outcome.failure != nil {
            wakeup.signal()
        }
        if let failure = outcome.failure {
            failureHandler(failure)
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { state -> Result<Void, AudioRecorderError>? in
                if let completion = state.completion {
                    return completion
                }
                state.accepting = false
                state.waiters.append(continuation)
                return nil
            }
            if let immediate {
                Self.resume(continuation, with: immediate)
            } else {
                wakeup.signal()
            }
        }
    }

    func cancel() async {
        _ = try? await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { state -> Result<Void, AudioRecorderError>? in
                if let completion = state.completion {
                    return completion
                }
                state.requestDiscard()
                state.waiters.append(continuation)
                return nil
            }
            if let immediate {
                Self.resume(continuation, with: immediate)
            } else {
                wakeup.signal()
            }
        }
    }

    private func runWorker() {
        while true {
            wakeup.wait()
            while let buffer = takeNextBuffer() {
                guard shouldProcessCurrentBuffer() else {
                    releaseReadBuffer()
                    continue
                }
                do {
                    try writer.write(buffer)
                    guard shouldProcessCurrentBuffer() else {
                        releaseReadBuffer()
                        continue
                    }
                    pcmHandler?(buffer)
                    if shouldProcessCurrentBuffer(),
                       let levelHandler,
                       levelThrottler.shouldPublish() {
                        let rms = normalizedAudioRMS(buffer)
                        Task { @MainActor in
                            levelHandler(rms)
                        }
                    }
                    releaseReadBuffer()
                } catch {
                    releaseReadBuffer()
                    recordWorkerFailure(.fileSetupFailed(error.localizedDescription))
                    break
                }
            }

            guard let terminal = terminalActionIfReady() else { continue }
            let result: Result<Void, AudioRecorderError>
            if terminal.cancelRequested {
                writer.cancel()
                result = .success(())
            } else if let error = terminal.error {
                writer.cancel()
                result = .failure(error)
            } else {
                do {
                    try writer.finish()
                    result = .success(())
                } catch {
                    result = .failure(.fileSetupFailed(error.localizedDescription))
                }
            }
            complete(with: result)
            return
        }
    }

    private func takeNextBuffer() -> AVAudioPCMBuffer? {
        let index = state.withLock { state -> Int? in
            if state.cancelRequested || state.terminalError != nil {
                state.discardPendingBuffers()
                return nil
            }
            guard state.queuedCount > 0, !state.workerOwnsReadBuffer else { return nil }
            state.workerOwnsReadBuffer = true
            return state.readIndex
        }
        return index.map { buffers[$0] }
    }

    private func releaseReadBuffer() {
        state.withLock { state in
            state.releaseReadBuffer(bufferCount: buffers.count)
        }
    }

    private func shouldProcessCurrentBuffer() -> Bool {
        state.withLock { state in
            !state.cancelRequested && state.terminalError == nil
        }
    }

    private func recordWorkerFailure(_ error: AudioRecorderError) {
        let failureToReport = state.withLock { state in
            markFailedLocked(&state, error: error)
        }
        if let failureToReport {
            failureHandler(failureToReport)
        }
        wakeup.signal()
    }

    private func markFailedLocked(
        _ state: inout AudioCapturePipelineState,
        error: AudioRecorderError
    ) -> AudioRecorderError? {
        guard state.terminalError == nil, !state.cancelRequested else { return nil }
        state.accepting = false
        state.terminalError = error
        state.discardPendingBuffers()
        guard !state.failureReported else { return nil }
        state.failureReported = true
        return error
    }

    private func terminalActionIfReady() -> (cancelRequested: Bool, error: AudioRecorderError?)? {
        state.withLock { state in
            guard !state.accepting else { return nil }
            if state.cancelRequested || state.terminalError != nil {
                state.discardPendingBuffers()
            }
            guard state.isReadyToTerminate else { return nil }
            return (state.cancelRequested, state.terminalError)
        }
    }

    private func complete(with result: Result<Void, AudioRecorderError>) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard state.completion == nil else { return [] }
            state.completion = result
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            Self.resume(waiter, with: result)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, any Error>,
        with result: Result<Void, AudioRecorderError>
    ) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) -> Bool {
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let byteCount = Int(sourceBuffer.mDataByteSize)
            guard byteCount <= Int(destinationBuffers[index].mDataByteSize),
                  let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData
            else { return false }
            memcpy(destinationData, sourceData, byteCount)
        }
        return true
    }
}

private struct UncheckedAudioPCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private final class MonoFLACBufferWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var file: AVAudioFile?
    private var writeFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var frameCount: AVAudioFramePosition = 0
    private var currentSampleRate: Double = 0
    private var writeError: Error?

    func begin(url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: BridgeAudioRecordingContract.sampleRate,
            channels: AVAudioChannelCount(BridgeAudioRecordingContract.channelCount),
            interleaved: false
        ) else {
            throw AudioRecorderError.fileSetupFailed("Could not create FLAC writer format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatFLAC),
            AVSampleRateKey: BridgeAudioRecordingContract.sampleRate,
            AVNumberOfChannelsKey: BridgeAudioRecordingContract.channelCount,
            AVEncoderBitDepthHintKey: BridgeAudioRecordingContract.flacBitDepth,
            AVLinearPCMBitDepthKey: BridgeAudioRecordingContract.flacBitDepth,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )

        lock.lock()
        self.url = url
        self.file = file
        self.writeFormat = format
        self.converter = nil
        self.converterInputFormat = nil
        self.frameCount = 0
        self.currentSampleRate = BridgeAudioRecordingContract.sampleRate
        self.writeError = nil
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        guard let inputBuffer = Self.makeMonoFloatBuffer(from: buffer) else {
            throw AudioRecorderError.fileSetupFailed("Could not downmix the microphone buffer")
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            guard let file, let format = writeFormat, writeError == nil else { return }
            if converter == nil || converterInputFormat?.isEqual(inputBuffer.format) != true {
                converter = AVAudioConverter(from: inputBuffer.format, to: format)
                converterInputFormat = inputBuffer.format
            }
            guard let converter,
                  let writeBuffer = try Self.makeWriteBuffer(
                      from: inputBuffer,
                      outputFormat: format,
                      converter: converter
                  )
            else {
                throw AudioRecorderError.fileSetupFailed("Could not convert recording buffer to FLAC format")
            }
            try file.write(from: writeBuffer)
            frameCount += AVAudioFramePosition(writeBuffer.frameLength)
        } catch {
            writeError = error
            throw error
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
        converter = nil
        converterInputFormat = nil
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
                "Mac recorder finish: empty flac duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            throw AudioRecorderError.fileSetupFailed("Recorded FLAC contains no audio data")
        }
        guard duration >= BridgeAudioRecordingContract.minimumDurationSeconds else {
            Log.audio.notice(
                "Mac recorder finish: too short duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            throw AudioRecorderError.fileSetupFailed("Recorded FLAC is too short")
        }

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileBytes > 0 else {
            Log.audio.error(
                "Mac recorder finish: empty flac duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
            )
            throw AudioRecorderError.fileSetupFailed("Recorded FLAC contains no audio data")
        }
        Log.audio.debug(
            "Mac recorder finish: flac written duration=\(duration, privacy: .public) frames=\(frames, privacy: .public) fileBytes=\(fileBytes, privacy: .public) sampleRate=\(sampleRate, privacy: .public)"
        )
    }

    func cancel() {
        lock.lock()
        let outputURL = url
        url = nil
        file = nil
        writeFormat = nil
        converter = nil
        converterInputFormat = nil
        frameCount = 0
        currentSampleRate = 0
        writeError = nil
        lock.unlock()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    /// Downmixes arbitrary input buffers before the stateful converter resamples
    /// them to the Bridge upload contract: 16 kHz mono FLAC.
    private static func makeMonoFloatBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else {
            return nil
        }
        let channelCount = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
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

    private static func makeWriteBuffer(
        from inputBuffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = max(1, Int(ceil(Double(inputBuffer.frameLength) * ratio)) + 128)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(capacity)
        ) else {
            return nil
        }
        let inputSource = SinglePCMBufferInput(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            inputSource.next(outStatus)
        }
        if let conversionError {
            throw conversionError
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        case .error:
            throw AudioRecorderError.fileSetupFailed("Audio converter returned an error")
        @unknown default:
            return output.frameLength > 0 ? output : nil
        }
    }
}

private final class SinglePCMBufferInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
