@preconcurrency import AVFoundation
import Foundation

final class NvidiaNemotronLivePreviewSession: @unchecked Sendable {
    private static let outputSampleRate = 16_000.0
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let modelDirURL: URL
    private let onTranscript: (String) -> Void
    private let audioQueue = DispatchQueue(label: "typeforme.nvidia-nemotron.live-preview.audio")
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var inputClosed = false
    private var cleanedUp = false
    private var processTerminated = false
    private var terminationContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var lastTranscript: String?
    private var converter: AVAudioConverter?
    private var converterInputSampleRate = 0.0

    static func start(
        languageIDs: [String],
        onTranscript: @escaping (String) -> Void
    ) throws -> NvidiaNemotronLivePreviewSession {
        let supportedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.nvidiaNemotronASRSupportedLanguages
        )
        let runtimeStatus = NvidiaNemotronASRService.bundledRuntimeStatus()
        guard runtimeStatus.isReady,
              let runnerURL = runtimeStatus.runnerURL
        else {
            throw ASRAudioSupportError.httpStatus(503, runtimeStatus.errorDetail)
        }

        let modelDirURL = try NvidiaNemotronASRService.stageModelDirectory(runtimeStatus)
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = runnerURL
        process.arguments = [
            "--model-dir",
            modelDirURL.path,
            "--target-lang",
            NvidiaNemotronASRService.targetLanguage(for: supportedLanguageIDs),
            "--stream-stdin-f32",
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let session = NvidiaNemotronLivePreviewSession(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            modelDirURL: modelDirURL,
            onTranscript: onTranscript
        )
        do {
            try process.run()
            return session
        } catch {
            session.cancel()
            throw error
        }
    }

    private init(
        process: Process,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        modelDirURL: URL,
        onTranscript: @escaping (String) -> Void
    ) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.modelDirURL = modelDirURL
        self.onTranscript = onTranscript

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStderr(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.handleProcessTermination()
        }
    }

    deinit {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        resumeTerminationWaiters()
        cleanup()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = Self.copyBuffer(buffer) else { return }
        let item = SendablePCMBuffer(copied)
        audioQueue.async { [weak self, item] in
            self?.appendOnAudioQueue(item.buffer)
        }
    }

    func appendPCM16kMonoFloat32Data(_ data: Data) {
        guard !data.isEmpty else { return }
        let copied = Data(data)
        audioQueue.async { [weak self, copied] in
            self?.appendPCM16kMonoFloat32DataOnAudioQueue(copied)
        }
    }

    func finishInput() {
        audioQueue.async {
            self.closeInputOnAudioQueue()
        }
    }

    func finishInputAndWaitForTermination(timeout: TimeInterval) async -> Bool {
        finishInput()
        return await waitForTermination(timeout: timeout)
    }

    func currentTranscript() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTranscript
    }

    func cancel() {
        audioQueue.async {
            self.closeInputOnAudioQueue()
            if self.process.isRunning {
                self.process.terminate()
            }
        }
    }

    private func appendOnAudioQueue(_ buffer: AVAudioPCMBuffer) {
        guard !inputClosed, process.isRunning else { return }
        guard let mono = Self.makeMonoBuffer(from: buffer),
              let output = resample(mono),
              let samples = output.floatChannelData?[0]
        else { return }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }

        let data = Self.littleEndianFloatData(samples: samples, count: frameCount)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            inputClosed = true
            Log.asr.notice("Nemotron live preview stdin write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendPCM16kMonoFloat32DataOnAudioQueue(_ data: Data) {
        guard !inputClosed, process.isRunning else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            inputClosed = true
            Log.asr.notice("Nemotron live preview stdin write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeInputOnAudioQueue() {
        guard !inputClosed else { return }
        inputClosed = true
        try? stdinPipe.fileHandleForWriting.close()
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
            Log.asr.notice("Nemotron live preview resample failed: \(conversionError.localizedDescription, privacy: .public)")
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

    private func handleStdout(_ data: Data) {
        let lines = appendAndExtractLines(data, into: &stdoutBuffer)
        for line in lines {
            guard let text = Self.parseTranscriptLine(line) else { continue }
            recordTranscript(text)
            onTranscript(text)
        }
    }

    private func handleStderr(_ data: Data) {
        let lines = appendAndExtractLines(data, into: &stderrBuffer)
        for line in lines {
            guard let message = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty
            else { continue }
            Log.asr.notice("Nemotron live preview: \(message, privacy: .public)")
        }
    }

    private func appendAndExtractLines(_ data: Data, into buffer: inout Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var lines: [Data] = []
        let newline = Data([0x0A])
        while let range = buffer.firstRange(of: newline) {
            let line = Data(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            lines.append(line)
        }
        return lines
    }

    private func waitForTermination(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterID = UUID()
            var shouldResumeImmediately = false
            lock.lock()
            if processTerminated || !process.isRunning {
                shouldResumeImmediately = true
            } else {
                terminationContinuations[waiterID] = continuation
            }
            lock.unlock()

            if shouldResumeImmediately {
                continuation.resume(returning: true)
                return
            }

            let timeoutMilliseconds = Int((max(0, timeout) * 1_000).rounded(.up))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak self] in
                guard let self else { return }
                let timedOutContinuation: CheckedContinuation<Bool, Never>?
                self.lock.lock()
                timedOutContinuation = self.terminationContinuations.removeValue(forKey: waiterID)
                self.lock.unlock()
                timedOutContinuation?.resume(returning: false)
            }
        }
    }

    private func recordTranscript(_ text: String) {
        lock.lock()
        lastTranscript = text
        lock.unlock()
    }

    private func handleProcessTermination() {
        resumeTerminationWaiters()
        cleanup()
    }

    private func resumeTerminationWaiters() {
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        if processTerminated {
            continuations = []
        } else {
            processTerminated = true
            continuations = Array(terminationContinuations.values)
            terminationContinuations.removeAll()
        }
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    private func cleanup() {
        lock.lock()
        guard !cleanedUp else {
            lock.unlock()
            return
        }
        cleanedUp = true
        lock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: modelDirURL)
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
                    sum += interleaved ? source[0][frame * channels + channel] : source[channel][frame]
                }
                destination[frame] = sum / Float(channels)
            }
            return mono
        }

        if let source = buffer.int16ChannelData {
            let interleaved = buffer.format.isInterleaved
            for frame in 0..<frames {
                var sum = 0
                for channel in 0..<channels {
                    let sample = interleaved ? source[0][frame * channels + channel] : source[channel][frame]
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

    private static func parseTranscriptLine(_ line: Data) -> String? {
        guard !line.isEmpty,
              let payload = try? BridgeJSON.decode(NvidiaNemotronLivePreviewPayload.self, from: line),
              let text = payload.textValue
        else { return nil }
        let cleaned = ASRAudioSupport.cleanTranscriptText(text)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private final class SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct NvidiaNemotronLivePreviewPayload: Decodable {
    let text: String?
    let transcript: String?
    let transcription: String?

    var textValue: String? {
        text ?? transcript ?? transcription
    }
}
