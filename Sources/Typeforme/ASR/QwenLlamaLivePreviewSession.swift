@preconcurrency import AVFoundation
import Foundation

actor QwenLlamaLivePreviewTaskRegistry {
    static let shared = QwenLlamaLivePreviewTaskRegistry()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func register(_ task: Task<Void, Never>, id: UUID) {
        tasks[id] = task
    }

    func unregister(id: UUID) {
        tasks.removeValue(forKey: id)
    }

    func cancelAll() -> Bool {
        let hadTasks = !tasks.isEmpty
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        return hadTasks
    }
}

final class QwenLlamaLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    static let providerID = RecognitionSource.qwen.rawValue
    private static let outputSampleRate = 16_000.0
    private static let minimumPreviewSamples = 24_000
    private static let requestStrideSamples = 16_000
    private static let rollingWindowSamples = 8 * 16_000
    private static let requestTimeout: TimeInterval = 12
    private static let requestMaxTokens = 256
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let service: QwenLlamaASRService
    private let languageIDs: [String]
    private var diagnosticID: String
    private var onTranscript: (String) -> Void
    private let queue = DispatchQueue(label: "typeforme.qwen3-asr.live-preview")
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var startedAt = Date()
    private var inputClosed = false
    private var terminated = false
    private var pcmWindow = Data()
    private var totalSampleCount = 0
    private var lastRequestedSampleCount = 0
    private var inFlightTask: Task<Void, Never>?
    private var inFlightTaskID: UUID?
    private var lastTranscript: String?
    private var converter: AVAudioConverter?
    private var converterInputSampleRate = 0.0
    private var firstRequestLogged = false

    var provider: String { Self.providerID }

    static func start(
        service: QwenLlamaASRService,
        languageIDs: [String],
        diagnosticID: String = UUID().uuidString,
        onTranscript: @escaping (String) -> Void
    ) throws -> QwenLlamaLivePreviewSession {
        let supportedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        guard !supportedLanguageIDs.isEmpty else {
            throw ASRAudioSupportError.httpStatus(
                422,
                "Qwen3-ASR does not support the selected live preview languages"
            )
        }
        guard FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaModelPath),
              FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaMMProjPath)
        else {
            throw ASRAudioSupportError.httpStatus(503, "Qwen3-ASR model files are not installed")
        }
        let session = QwenLlamaLivePreviewSession(
            service: service,
            languageIDs: supportedLanguageIDs,
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
        Log.asr.notice(
            "Qwen3-ASR live preview session started session=\(session.logID, privacy: .public) languages=\(supportedLanguageIDs.joined(separator: ","), privacy: .public)"
        )
        return session
    }

    private init(
        service: QwenLlamaASRService,
        languageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) {
        self.service = service
        self.languageIDs = languageIDs
        self.diagnosticID = diagnosticID
        self.onTranscript = onTranscript
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        terminate(reason: "deinit")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = Self.copyBuffer(buffer) else { return }
        let item = QwenLivePreviewSendablePCMBuffer(copied)
        queue.async { [weak self, item] in
            self?.appendOnQueue(item.buffer)
        }
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {
        guard !data.isEmpty else { return }
        let copied = Data(data)
        queue.async { [weak self, copied] in
            self?.appendPCM16kMonoFloat32DataOnQueue(copied)
        }
    }

    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool {
        terminateOnQueue(reason: "finish")
        return true
    }

    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool {
        terminateOnQueue(reason: "cancel")
        return true
    }

    func currentTranscript() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTranscript
    }

    func terminate(reason: String = "terminate") {
        terminateOnQueue(reason: reason)
    }

    static func rollingWindowStartSample(totalSamples: Int) -> Int {
        max(0, totalSamples - rollingWindowSamples)
    }

    static func shouldRequestPreview(
        totalSamples: Int,
        lastRequestedSamples: Int
    ) -> Bool {
        guard totalSamples >= minimumPreviewSamples else { return false }
        return totalSamples - lastRequestedSamples >= requestStrideSamples
    }

    private var logID: String {
        String(diagnosticID.prefix(8))
    }

    private func appendOnQueue(_ buffer: AVAudioPCMBuffer) {
        guard !isClosedOnQueue,
              let mono = Self.makeMonoBuffer(from: buffer),
              let output = resample(mono),
              let samples = output.floatChannelData?[0]
        else { return }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }
        appendPCM16kMonoFloat32DataOnQueue(Self.littleEndianFloatData(samples: samples, count: frameCount))
    }

    private func appendPCM16kMonoFloat32DataOnQueue(_ data: Data) {
        guard !isClosedOnQueue,
              data.count % MemoryLayout<Float>.size == 0
        else { return }
        let sampleCount = data.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        pcmWindow.append(data)
        totalSampleCount += sampleCount
        let maxWindowBytes = Self.rollingWindowSamples * MemoryLayout<Float>.size
        if pcmWindow.count > maxWindowBytes {
            pcmWindow.removeFirst(pcmWindow.count - maxWindowBytes)
        }
        schedulePreviewIfNeededOnQueue()
    }

    private var isClosedOnQueue: Bool {
        inputClosed || terminated
    }

    private func schedulePreviewIfNeededOnQueue() {
        guard inFlightTask == nil,
              !isClosedOnQueue,
              Self.shouldRequestPreview(
                  totalSamples: totalSampleCount,
                  lastRequestedSamples: lastRequestedSampleCount
              )
        else { return }

        let requestID = UUID()
        let audio = Data(pcmWindow)
        let totalSamples = totalSampleCount
        let windowStart = Self.rollingWindowStartSample(totalSamples: totalSamples)
        let languageIDs = self.languageIDs
        let service = self.service
        let logID = self.logID
        let startedAt = self.startedAt
        let isFirst = !firstRequestLogged
        firstRequestLogged = true
        lastRequestedSampleCount = totalSamples

        let task = Task(priority: .utility) { [weak self, audio, languageIDs, service, logID, startedAt] in
            defer {
                Task {
                    await QwenLlamaLivePreviewTaskRegistry.shared.unregister(id: requestID)
                }
            }
            do {
                guard !Task.isCancelled else { return }
                let text = try await service.transcribeLivePreviewPCM16kMonoFloat32Data(
                    audio,
                    languageIDs: languageIDs,
                    timeout: Self.requestTimeout,
                    maxTokens: Self.requestMaxTokens
                )
                guard !Task.isCancelled else { return }
                self?.handlePreviewResult(
                    text,
                    requestID: requestID,
                    totalSamples: totalSamples,
                    windowStart: windowStart
                )
            } catch is CancellationError {
                self?.handlePreviewCompletion(requestID: requestID)
            } catch {
                Log.asr.notice(
                    "Qwen3-ASR live preview request failed session=\(logID, privacy: .public) first=\(isFirst, privacy: .public) input_audio_ms=\(totalSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: startedAt), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                self?.handlePreviewCompletion(requestID: requestID)
            }
        }
        inFlightTask = task
        inFlightTaskID = requestID
        Task {
            await QwenLlamaLivePreviewTaskRegistry.shared.register(task, id: requestID)
        }
        Log.asr.debug(
            "Qwen3-ASR live preview request session=\(logID, privacy: .public) first=\(isFirst, privacy: .public) window_start_ms=\(windowStart * 1_000 / 16_000, privacy: .public) input_audio_ms=\(totalSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: startedAt), privacy: .public)"
        )
    }

    private func handlePreviewResult(
        _ rawText: String,
        requestID: UUID,
        totalSamples: Int,
        windowStart: Int
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async { [weak self] in
            guard let self,
                  self.inFlightTaskID == requestID,
                  !self.terminated
            else { return }
            self.inFlightTask = nil
            self.inFlightTaskID = nil
            if !text.isEmpty {
                self.lock.lock()
                self.lastTranscript = text
                let handler = self.onTranscript
                self.lock.unlock()
                Log.asr.debug(
                    "Qwen3-ASR live preview result session=\(self.logID, privacy: .public) text_chars=\(text.count, privacy: .public) window_start_ms=\(windowStart * 1_000 / 16_000, privacy: .public) input_audio_ms=\(totalSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: self.startedAt), privacy: .public)"
                )
                handler(text)
            }
            self.schedulePreviewIfNeededOnQueue()
        }
    }

    private func handlePreviewCompletion(requestID: UUID) {
        queue.async { [weak self] in
            guard let self,
                  self.inFlightTaskID == requestID
            else { return }
            self.inFlightTask = nil
            self.inFlightTaskID = nil
            self.schedulePreviewIfNeededOnQueue()
        }
    }

    private func terminateOnQueue(reason: String) {
        syncOnQueue {
            guard !terminated else { return }
            self.inputClosed = true
            self.terminated = true
            self.inFlightTask?.cancel()
            if let inFlightTaskID = self.inFlightTaskID {
                Task {
                    await QwenLlamaLivePreviewTaskRegistry.shared.unregister(id: inFlightTaskID)
                }
            }
            self.inFlightTask = nil
            self.inFlightTaskID = nil
            self.pcmWindow.removeAll(keepingCapacity: false)
            self.converter = nil
            Log.asr.notice(
                "Qwen3-ASR live preview terminate session=\(self.logID, privacy: .public) reason=\(reason, privacy: .public) input_audio_ms=\(self.totalSampleCount * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: self.startedAt), privacy: .public)"
            )
        }
    }

    private func syncOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func resample(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if abs(mono.format.sampleRate - Self.outputSampleRate) < 0.5 {
            return mono
        }

        if converter == nil || abs(converterInputSampleRate - mono.format.sampleRate) >= 0.5 {
            converter = AVAudioConverter(from: mono.format, to: Self.outputFormat)
            converterInputSampleRate = mono.format.sampleRate
        }
        guard let converter else { return nil }

        let ratio = Self.outputSampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(mono.frameLength) * ratio)) + 256))
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return mono
        }

        if let conversionError {
            Log.asr.notice("Qwen3-ASR live preview resample failed: \(conversionError.localizedDescription, privacy: .public)")
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output
        case .error:
            return nil
        @unknown default:
            return output
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0,
              let copy = AVAudioPCMBuffer(
                  pcmFormat: buffer.format,
                  frameCapacity: AVAudioFrameCount(frames)
              )
        else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)

        if let source = buffer.floatChannelData,
           let destination = copy.floatChannelData {
            let samplesPerChannel = buffer.format.isInterleaved ? frames * channels : frames
            let planeCount = buffer.format.isInterleaved ? 1 : channels
            for plane in 0..<planeCount {
                destination[plane].update(from: source[plane], count: samplesPerChannel)
            }
            return copy
        }

        if let source = buffer.int16ChannelData,
           let destination = copy.int16ChannelData {
            let samplesPerChannel = buffer.format.isInterleaved ? frames * channels : frames
            let planeCount = buffer.format.isInterleaved ? 1 : channels
            for plane in 0..<planeCount {
                destination[plane].update(from: source[plane], count: samplesPerChannel)
            }
            return copy
        }

        return nil
    }

    private static func makeMonoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let destination = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)

        if let source = buffer.floatChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = interleaved
                        ? source[0][frame * channels + channel]
                        : source[channel][frame]
                    sum += value
                }
                destination[frame] = max(-1, min(1, sum / Float(channels)))
            }
            return mono
        }

        if let source = buffer.int16ChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum = 0
                for channel in 0..<channels {
                    let sample = interleaved
                        ? source[0][frame * channels + channel]
                        : source[channel][frame]
                    sum += Int(sample)
                }
                destination[frame] = max(-1, min(1, Float(sum) / Float(channels) / Float(Int16.max)))
            }
            return mono
        }

        return nil
    }

    private static func littleEndianFloatData(samples: UnsafePointer<Float>, count: Int) -> Data {
        var data = Data(count: count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: UInt32.self)
            for index in 0..<count {
                output[index] = samples[index].bitPattern.littleEndian
            }
        }
        return data
    }

    private static func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}

private final class QwenLivePreviewSendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
