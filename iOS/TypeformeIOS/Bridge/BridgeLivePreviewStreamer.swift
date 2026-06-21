import AVFoundation
import Foundation
import OSLog

private let bridgeLivePreviewLog = Logger(
    subsystem: TypeformeBundleConfiguration.hostBundleIdentifier,
    category: "bridge-live-preview"
)

final class BridgeLivePreviewStreamer: @unchecked Sendable {
    private static let outputSampleRate = 16_000.0
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!
    private static let flushByteCount = 8_192
    private static let maxPendingByteCount = 512 * 1024

    private let client: BridgeClient
    private let languageIDs: [String]
    private let onTranscript: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let audioQueue = DispatchQueue(label: "typeforme.ios.bridge-live-preview.audio")
    private var sessionID: String?
    private var pendingData = Data()
    private var uploadInFlight = false
    private var startInFlight = false
    private var finished = false
    private var finishPendingAfterUpload = false
    private var cancelPendingAfterUpload = false
    private var converter: AVAudioConverter?
    private var converterInputSampleRate = 0.0
    private var lastTranscript = ""
    private var eventTask: Task<Void, Never>?

    init(
        client: BridgeClient,
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.client = client
        self.languageIDs = languageIDs
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    deinit {
        eventTask?.cancel()
    }

    func start() {
        audioQueue.async { [weak self] in
            self?.startOnAudioQueue()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = Self.copyBuffer(buffer) else { return }
        let item = SendableLivePreviewPCMBuffer(copied)
        audioQueue.async { [weak self, item] in
            self?.appendOnAudioQueue(item.buffer)
        }
    }

    func finish() {
        audioQueue.async {
            self.finishOnAudioQueue()
        }
    }

    func cancel() {
        audioQueue.async {
            self.cancelOnAudioQueue()
        }
    }

    private func startOnAudioQueue() {
        guard !startInFlight, sessionID == nil, !finished else { return }
        startInFlight = true
        let client = self.client
        let languageIDs = self.languageIDs
        Task {
            do {
                let response = try await client.startLivePreview(languageIDs: languageIDs)
                self.audioQueue.async {
                    self.handleStartResponseOnAudioQueue(response)
                }
            } catch {
                let message = error.localizedDescription
                self.audioQueue.async {
                    self.handleFailureOnAudioQueue(message: message)
                }
            }
        }
    }

    private func handleStartResponseOnAudioQueue(_ response: BridgeLivePreviewStartResponse) {
        startInFlight = false
        guard !finished else {
            sendFinishRequest(
                sessionID: response.sessionID,
                trailingData: pendingData
            )
            pendingData.removeAll(keepingCapacity: false)
            return
        }
        sessionID = response.sessionID
        startEventStreamOnAudioQueue(sessionID: response.sessionID)
        flushOnAudioQueue(force: true)
    }

    private func appendOnAudioQueue(_ buffer: AVAudioPCMBuffer) {
        guard !finished else { return }
        guard let mono = Self.makeMonoBuffer(from: buffer),
              let output = resample(mono),
              let samples = output.floatChannelData?[0]
        else { return }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }
        pendingData.append(Self.littleEndianFloatData(samples: samples, count: frameCount))
        if pendingData.count > Self.maxPendingByteCount {
            pendingData.removeFirst(pendingData.count - Self.maxPendingByteCount)
        }
        flushOnAudioQueue(force: pendingData.count >= Self.flushByteCount)
    }

    private func flushOnAudioQueue(force: Bool) {
        guard force, !uploadInFlight, !finished, let sessionID, !pendingData.isEmpty else { return }
        let chunk = pendingData
        pendingData.removeAll(keepingCapacity: true)
        uploadInFlight = true
        let client = self.client
        Task {
            do {
                let response = try await client.appendLivePreviewAudio(sessionID: sessionID, audioData: chunk)
                self.audioQueue.async {
                    self.handleAppendResponseOnAudioQueue(response)
                }
            } catch {
                let message = error.localizedDescription
                self.audioQueue.async {
                    self.handleFailureOnAudioQueue(message: message)
                }
            }
        }
    }

    private func handleAppendResponseOnAudioQueue(_ response: BridgeLivePreviewAudioAppendResponse) {
        uploadInFlight = false
        if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           text != lastTranscript {
            lastTranscript = text
            onTranscript(text)
        }
        if finishPendingAfterUpload {
            finishPendingAfterUpload = false
            sendFinishOnAudioQueue()
            return
        }
        if cancelPendingAfterUpload {
            cancelPendingAfterUpload = false
            stopEventStreamOnAudioQueue()
            sendCancelOnAudioQueue()
            return
        }
        flushOnAudioQueue(force: pendingData.count >= Self.flushByteCount)
    }

    private func finishOnAudioQueue() {
        guard !finished else { return }
        finished = true
        if uploadInFlight {
            finishPendingAfterUpload = true
            return
        }
        sendFinishOnAudioQueue()
    }

    private func cancelOnAudioQueue() {
        guard !finished else { return }
        finished = true
        pendingData.removeAll(keepingCapacity: false)
        if uploadInFlight {
            cancelPendingAfterUpload = true
            return
        }
        stopEventStreamOnAudioQueue()
        sendCancelOnAudioQueue()
    }

    private func handleFailureOnAudioQueue(message: String) {
        if finished {
            if finishPendingAfterUpload || cancelPendingAfterUpload {
                finishPendingAfterUpload = false
                cancelPendingAfterUpload = false
                sendCancelOnAudioQueue()
            }
            return
        }
        guard !finished else { return }
        finished = true
        pendingData.removeAll(keepingCapacity: false)
        uploadInFlight = false
        startInFlight = false
        stopEventStreamOnAudioQueue()
        sendCancelOnAudioQueue()
        bridgeLivePreviewLog.notice("server live preview stopped: \(message, privacy: .public)")
        onFailure(message)
    }

    private func sendFinishOnAudioQueue() {
        let sessionID = self.sessionID
        let trailingData = pendingData
        pendingData.removeAll(keepingCapacity: false)
        guard let sessionID else { return }
        sendFinishRequest(sessionID: sessionID, trailingData: trailingData)
    }

    private func sendFinishRequest(sessionID: String, trailingData: Data) {
        let client = self.client
        Task {
            if !trailingData.isEmpty {
                _ = try? await client.appendLivePreviewAudio(sessionID: sessionID, audioData: trailingData)
            }
            if let response = try? await client.finishLivePreview(sessionID: sessionID),
               let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                self.onTranscript(text)
            }
            self.audioQueue.async {
                self.stopEventStreamOnAudioQueue()
            }
        }
    }

    private func sendCancelOnAudioQueue() {
        guard let sessionID else { return }
        let client = self.client
        Task { try? await client.finishLivePreview(sessionID: sessionID) }
    }

    private func startEventStreamOnAudioQueue(sessionID: String) {
        guard eventTask == nil else { return }
        let client = self.client
        eventTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    let completed = try await client.streamLivePreviewEvents(sessionID: sessionID) { [weak self] event in
                        self?.handleLivePreviewEvent(event)
                    }
                    if completed {
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    bridgeLivePreviewLog.notice("server live preview event stream failed: \(error.localizedDescription, privacy: .public)")
                }
                attempt += 1
                let delayMs = min(1_000, 120 * attempt)
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
        }
    }

    private func handleLivePreviewEvent(_ event: BridgeLivePreviewEvent) {
        audioQueue.async {
            self.handleLivePreviewEventOnAudioQueue(event)
        }
    }

    private func handleLivePreviewEventOnAudioQueue(_ event: BridgeLivePreviewEvent) {
        guard event.sessionID == sessionID else { return }
        if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           text != lastTranscript {
            lastTranscript = text
            onTranscript(text)
        }
        if event.isFinal {
            eventTask = nil
        }
    }

    private func stopEventStreamOnAudioQueue() {
        eventTask?.cancel()
        eventTask = nil
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
            bridgeLivePreviewLog.notice("server live preview resample failed: \(conversionError.localizedDescription, privacy: .public)")
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
}

private final class SendableLivePreviewPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
