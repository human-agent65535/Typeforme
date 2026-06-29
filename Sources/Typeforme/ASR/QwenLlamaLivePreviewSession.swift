@preconcurrency import AVFoundation
import Foundation

final class QwenLlamaLivePreviewTaskRegistry: @unchecked Sendable {
    static let shared = QwenLlamaLivePreviewTaskRegistry()

    private let lock = NSLock()
    private var reservedIDs = Set<UUID>()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledIDs = Set<UUID>()

    func reserve(id: UUID) {
        lock.lock()
        reservedIDs.insert(id)
        lock.unlock()
    }

    @discardableResult
    func install(_ task: Task<Void, Never>, id: UUID) -> Bool {
        lock.lock()
        reservedIDs.remove(id)
        if cancelledIDs.remove(id) != nil {
            lock.unlock()
            task.cancel()
            return false
        }
        tasks[id] = task
        lock.unlock()
        return true
    }

    func unregister(id: UUID) {
        lock.lock()
        reservedIDs.remove(id)
        tasks.removeValue(forKey: id)
        cancelledIDs.remove(id)
        lock.unlock()
    }

    func cancelAll() async -> Bool {
        let (hadRequests, taskList) = cancelAllSnapshot()
        for task in taskList {
            task.cancel()
        }
        for task in taskList {
            await task.value
        }
        return hadRequests
    }

    private func cancelAllSnapshot() -> (Bool, [Task<Void, Never>]) {
        lock.lock()
        let taskIDs = Set(tasks.keys)
        let taskList = Array(tasks.values)
        let hadRequests = !reservedIDs.isEmpty || !taskList.isEmpty
        cancelledIDs.formUnion(reservedIDs)
        cancelledIDs.formUnion(taskIDs)
        reservedIDs.removeAll()
        tasks.removeAll()
        lock.unlock()
        return (hadRequests, taskList)
    }
}

final class QwenLlamaLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    static let providerID = RecognitionSource.qwen.rawValue
    private static let outputSampleRate = 16_000.0
    private static let minimumPreviewSamples = 19_200
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
    private var fullPCM = Data()
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
        let snapshot = finishSnapshotOnQueue()
        await Self.waitForTaskCompletion(snapshot.inFlightTask, timeout: timeout)
        guard !snapshot.fullPCM.isEmpty else {
            return currentTranscript()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        do {
            let text = try await snapshot.service.transcribeLivePreviewPCM16kMonoFloat32Data(
                snapshot.fullPCM,
                languageIDs: snapshot.languageIDs,
                timeout: timeout,
                maxTokens: AppSettings.asrQwenLlamaMaxTokens
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return currentTranscript()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            let handler = storeTranscriptAndGetHandler(text)
            Log.asr.notice(
                "Qwen3-ASR live preview final session=\(snapshot.logID, privacy: .public) text_chars=\(text.count, privacy: .public) input_audio_ms=\(snapshot.totalSampleCount * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
            )
            handler(text)
            return true
        } catch {
            Log.asr.notice(
                "Qwen3-ASR live preview final failed session=\(snapshot.logID, privacy: .public) input_audio_ms=\(snapshot.totalSampleCount * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return currentTranscript()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool {
        let task = terminateOnQueue(reason: "cancel")
        return await Self.waitForTaskCompletion(task, timeout: timeout)
    }

    func currentTranscript() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTranscript
    }

    private func storeTranscriptAndGetHandler(_ text: String) -> (String) -> Void {
        lock.lock()
        lastTranscript = text
        let handler = onTranscript
        lock.unlock()
        return handler
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

        fullPCM.append(data)
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
        QwenLlamaLivePreviewTaskRegistry.shared.reserve(id: requestID)
        let startGate = QwenLivePreviewStartGate()

        let task = Task(priority: .utility) { [weak self, audio, languageIDs, service, logID, startedAt, startGate] in
            defer {
                QwenLlamaLivePreviewTaskRegistry.shared.unregister(id: requestID)
            }
            await startGate.wait()
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
        let installed = QwenLlamaLivePreviewTaskRegistry.shared.install(task, id: requestID)
        Task {
            await startGate.open()
        }
        if !installed {
            handlePreviewCompletion(requestID: requestID)
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

    private struct FinishSnapshot {
        let service: QwenLlamaASRService
        let languageIDs: [String]
        let logID: String
        let startedAt: Date
        let totalSampleCount: Int
        let fullPCM: Data
        let inFlightTask: Task<Void, Never>?
    }

    private func finishSnapshotOnQueue() -> FinishSnapshot {
        syncOnQueue {
            guard !terminated else {
                return FinishSnapshot(
                    service: service,
                    languageIDs: languageIDs,
                    logID: logID,
                    startedAt: startedAt,
                    totalSampleCount: totalSampleCount,
                    fullPCM: Data(),
                    inFlightTask: nil
                )
            }
            inputClosed = true
            terminated = true
            let task = inFlightTask
            task?.cancel()
            inFlightTask = nil
            inFlightTaskID = nil
            let snapshot = FinishSnapshot(
                service: service,
                languageIDs: languageIDs,
                logID: logID,
                startedAt: startedAt,
                totalSampleCount: totalSampleCount,
                fullPCM: fullPCM,
                inFlightTask: task
            )
            pcmWindow.removeAll(keepingCapacity: false)
            fullPCM.removeAll(keepingCapacity: false)
            converter = nil
            Log.asr.notice(
                "Qwen3-ASR live preview finish session=\(self.logID, privacy: .public) input_audio_ms=\(self.totalSampleCount * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: self.startedAt), privacy: .public)"
            )
            return snapshot
        }
    }

    @discardableResult
    private func terminateOnQueue(reason: String) -> Task<Void, Never>? {
        syncOnQueue {
            guard !terminated else { return nil }
            self.inputClosed = true
            self.terminated = true
            let task = self.inFlightTask
            task?.cancel()
            self.inFlightTask = nil
            self.inFlightTaskID = nil
            self.pcmWindow.removeAll(keepingCapacity: false)
            self.fullPCM.removeAll(keepingCapacity: false)
            self.converter = nil
            Log.asr.notice(
                "Qwen3-ASR live preview terminate session=\(self.logID, privacy: .public) reason=\(reason, privacy: .public) input_audio_ms=\(self.totalSampleCount * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: self.startedAt), privacy: .public)"
            )
            return task
        }
    }

    private func syncOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        } else {
            return queue.sync(execute: work)
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

        var conversionError: NSError?
        let input = ASRAudioConverterOneShotInput(buffer: mono)
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            input.provide(outStatus)
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

    private static func waitForTaskCompletion(
        _ task: Task<Void, Never>?,
        timeout: TimeInterval
    ) async -> Bool {
        guard let task else { return true }
        guard timeout > 0 else { return false }
        return await withCheckedContinuation { continuation in
            let waiter = QwenLivePreviewTaskCompletionWaiter()

            Task {
                await task.value
                waiter.resume(true, continuation: continuation)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                waiter.resume(false, continuation: continuation)
            }
        }
    }
}

private final class QwenLivePreviewSendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private actor QwenLivePreviewStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class QwenLivePreviewTaskCompletionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ value: Bool,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}
