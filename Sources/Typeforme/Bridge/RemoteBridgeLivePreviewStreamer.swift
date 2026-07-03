import AVFoundation
import Foundation

final class RemoteBridgeLivePreviewStreamer: @unchecked Sendable {
    private static let outputSampleRate = 16_000.0
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!
    private static let maxPendingByteCount = 512 * 1024
    private static let finishRequestTimeout: TimeInterval = BridgeSettingsNormalization.asrTimeoutSecondsRange.upperBound + 5

    private let client: RemoteBridgeClient
    private let languageIDs: [String]
    private let correctionMode: CorrectionMode
    private let livePreviewSource: VoiceLivePreviewSource
    private let appSnapshot: FrontmostAppSnapshot?
    private let appCategory: AppCategory
    private let clientJobID: String?
    private let onTranscript: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let audioQueue = DispatchQueue(label: "typeforme.mac-client.live-preview.audio")

    private var sessionID: String?
    private var pendingPackets: [RemoteLivePreviewOpusPacket] = []
    private var pendingPacketHeadIndex = 0
    private var pendingPacketBytes = 0
    private var startInFlight = false
    private var finished = false
    private var suppressSocketResult = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendInFlight = false
    private var pendingControl: BridgeLivePreviewSocketControl.ControlType?
    private var converter: AVAudioConverter?
    private var opusEncoder = RemoteLivePreviewOpusEncoder()
    private var converterInputSampleRate = 0.0
    private var lastTranscript = ""
    private var startedAt: Date?
    private var startRequestStartedAt: Date?
    private var queuedSampleCount = 0
    private var sentSampleCount = 0
    private var nextQueueLogSampleCount = 16_000
    private var nextSendLogSampleCount = 16_000
    private var firstQueueLogged = false
    private var firstSendLogged = false
    private var eventCount = 0
    private var finishWaiters: [CheckedContinuation<String?, Never>] = []
    private var finishResultText: String?
    private var finishDidResolve = false

    init(
        client: RemoteBridgeClient,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        livePreviewSource: VoiceLivePreviewSource,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        clientJobID: String? = nil,
        onTranscript: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.client = client
        self.languageIDs = languageIDs
        self.correctionMode = correctionMode
        self.livePreviewSource = livePreviewSource
        self.appSnapshot = appSnapshot
        self.appCategory = appCategory
        self.clientJobID = clientJobID
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    deinit {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        receiveTask?.cancel()
    }

    func start() {
        audioQueue.async {
            self.startOnAudioQueue()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = Self.copyBuffer(buffer) else { return }
        let item = SendableRemotePreviewPCMBuffer(copied)
        audioQueue.async { [item] in
            self.appendOnAudioQueue(item.buffer)
        }
    }

    func finish() {
        audioQueue.async {
            self.finishOnAudioQueue()
        }
    }

    func finishAndWait(timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: FinishWaitResult.self) { group in
            group.addTask {
                let text = await withCheckedContinuation { continuation in
                    self.audioQueue.async {
                        self.finishOnAudioQueue(waiter: continuation)
                    }
                }
                return .completed(text)
            }
            if timeout > 0 {
                group.addTask {
                    try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds(timeout))
                    return .timedOut
                }
            }
            let result = await group.next() ?? .timedOut
            group.cancelAll()
            switch result {
            case .completed(let text):
                return text
            case .timedOut:
                self.audioQueue.async {
                    self.resolveFinishWaitersOnAudioQueue(text: nil)
                }
                return nil
            }
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
        startedAt = Date()
        startRequestStartedAt = startedAt
        Log.bridge.notice("Mac client live preview start request")
        let client = self.client
        let languageIDs = self.languageIDs
        let correctionMode = self.correctionMode
        let livePreviewSource = self.livePreviewSource
        let appSnapshot = self.appSnapshot
        let appCategory = self.appCategory
        let clientJobID = self.clientJobID
        Task {
            do {
                let response = try await client.startLivePreview(
                    languageIDs: languageIDs,
                    correctionMode: correctionMode,
                    livePreviewSource: livePreviewSource,
                    appSnapshot: appSnapshot,
                    appCategory: appCategory,
                    clientJobID: clientJobID
                )
                self.audioQueue.async {
                    self.handleStartResponseOnAudioQueue(response)
                }
            } catch {
                self.audioQueue.async {
                    self.handleFailureOnAudioQueue(message: error.localizedDescription)
                }
            }
        }
    }

    private func handleStartResponseOnAudioQueue(_ response: BridgeLivePreviewStartResponse) {
        startInFlight = false
        sessionID = response.sessionID
        guard response.audioFormat == BridgeLivePreviewStartResponse.audioFormat else {
            handleFailureOnAudioQueue(message: "Remote live preview audio format mismatch: \(response.audioFormat)")
            return
        }
        Log.bridge.notice(
            "Mac client live preview start response session=\(self.logSessionID, privacy: .public) start_ms=\(Self.elapsedMS(since: self.startRequestStartedAt), privacy: .public) queued_audio_ms=\(self.queuedAudioMS, privacy: .public)"
        )
        guard !finished else {
            if suppressSocketResult {
                clearPendingPackets(keepingCapacity: false)
                let client = self.client
                Task { try? await client.finishLivePreview(sessionID: response.sessionID) }
                return
            }
            startWebSocketOnAudioQueue(sessionID: response.sessionID, allowAfterFinish: true)
            queueControlOnAudioQueue(.finish)
            return
        }
        startWebSocketOnAudioQueue(sessionID: response.sessionID)
        flushWebSocketOnAudioQueue()
    }

    private func appendOnAudioQueue(_ buffer: AVAudioPCMBuffer) {
        guard !finished else { return }
        guard let mono = Self.makeMonoBuffer(from: buffer),
              let output = resample(mono),
              let samples = output.floatChannelData?[0]
        else { return }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }
        do {
            let packets = try opusEncoder.append(samples: samples, count: frameCount)
            queuePacketsOnAudioQueue(packets)
        } catch {
            handleFailureOnAudioQueue(message: error.localizedDescription)
            return
        }
        queuedSampleCount += frameCount
        logQueuedAudioIfNeeded(frameCount: frameCount, sourceSampleRate: mono.format.sampleRate)
        flushWebSocketOnAudioQueue()
    }

    private func finishOnAudioQueue(waiter: CheckedContinuation<String?, Never>? = nil) {
        if let waiter {
            if finishDidResolve {
                waiter.resume(returning: finishResultText)
            } else {
                finishWaiters.append(waiter)
            }
        }
        guard !finished else { return }
        do {
            queuePacketsOnAudioQueue(try opusEncoder.finish())
        } catch {
            handleFailureOnAudioQueue(message: error.localizedDescription)
            return
        }
        finished = true
        Log.bridge.notice(
            "Mac client live preview finish requested session=\(self.logSessionID, privacy: .public) queued_audio_ms=\(self.queuedAudioMS, privacy: .public) sent_audio_ms=\(self.sentAudioMS, privacy: .public) pending_bytes=\(self.pendingPacketBytes, privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
        )
        if webSocketTask != nil {
            queueControlOnAudioQueue(.finish)
        } else if !startInFlight {
            sendFinishRequestOnAudioQueue()
        }
    }

    private func cancelOnAudioQueue() {
        guard !finished else { return }
        finished = true
        suppressSocketResult = true
        clearPendingPackets(keepingCapacity: false)
        if webSocketTask != nil {
            queueControlOnAudioQueue(.cancel)
        } else {
            sendCancelOnAudioQueue()
        }
    }

    private func queuePacketsOnAudioQueue(_ packets: [RemoteLivePreviewOpusPacket]) {
        guard !packets.isEmpty else { return }
        pendingPackets.append(contentsOf: packets)
        pendingPacketBytes += packets.reduce(0) { $0 + $1.data.count }
        trimPendingPacketsToLimit()
    }

    private func popPendingPacketOnAudioQueue() -> RemoteLivePreviewOpusPacket? {
        guard pendingPacketHeadIndex < pendingPackets.count else {
            compactPendingPacketsIfNeeded(force: true, keepingCapacity: true)
            return nil
        }
        let packet = pendingPackets[pendingPacketHeadIndex]
        pendingPacketHeadIndex += 1
        pendingPacketBytes -= packet.data.count
        compactPendingPacketsIfNeeded(force: false, keepingCapacity: true)
        return packet
    }

    private func trimPendingPacketsToLimit() {
        while pendingPacketBytes > Self.maxPendingByteCount,
              pendingPacketHeadIndex < pendingPackets.count {
            let removed = pendingPackets[pendingPacketHeadIndex]
            pendingPacketHeadIndex += 1
            pendingPacketBytes -= removed.data.count
        }
        compactPendingPacketsIfNeeded(force: false, keepingCapacity: true)
    }

    private func clearPendingPackets(keepingCapacity: Bool) {
        pendingPackets.removeAll(keepingCapacity: keepingCapacity)
        pendingPacketHeadIndex = 0
        pendingPacketBytes = 0
    }

    private func compactPendingPacketsIfNeeded(force: Bool, keepingCapacity: Bool) {
        guard pendingPacketHeadIndex > 0 else { return }
        if pendingPacketHeadIndex >= pendingPackets.count {
            pendingPackets.removeAll(keepingCapacity: keepingCapacity)
            pendingPacketHeadIndex = 0
            return
        }
        guard force || (pendingPacketHeadIndex >= 64 && pendingPacketHeadIndex * 2 >= pendingPackets.count) else {
            return
        }
        pendingPackets.removeFirst(pendingPacketHeadIndex)
        pendingPacketHeadIndex = 0
    }

    private func handleFailureOnAudioQueue(message: String) {
        if finished {
            resolveFinishWaitersOnAudioQueue(text: nil)
            return
        }
        finished = true
        suppressSocketResult = true
        clearPendingPackets(keepingCapacity: false)
        startInFlight = false
        closeWebSocketOnAudioQueue()
        sendCancelOnAudioQueue()
        Log.bridge.notice("Mac client live preview stopped: \(message, privacy: .public)")
        onFailure(message)
    }

    private func startWebSocketOnAudioQueue(sessionID: String, allowAfterFinish: Bool = false) {
        guard webSocketTask == nil,
              !finished || allowAfterFinish
        else { return }
        do {
            let task = try client.livePreviewWebSocketTask(sessionID: sessionID)
            webSocketTask = task
            Log.bridge.notice(
                "Mac client live preview websocket resume session=\(self.logSessionID, privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
            )
            task.resume()
            startReceiveLoopOnAudioQueue(task: task)
        } catch {
            handleFailureOnAudioQueue(message: error.localizedDescription)
        }
    }

    private func startReceiveLoopOnAudioQueue(task: URLSessionWebSocketTask) {
        receiveTask = Task { [task] in
            do {
                while !Task.isCancelled {
                    let event = try Self.decodeLivePreviewEvent(try await task.receive())
                    self.handleLivePreviewEvent(event)
                    if event.isFinal { return }
                }
            } catch is CancellationError {
                return
            } catch {
                self.audioQueue.async {
                    self.handleWebSocketReceiveFailureOnAudioQueue(message: error.localizedDescription)
                }
            }
        }
    }

    private func queueControlOnAudioQueue(_ type: BridgeLivePreviewSocketControl.ControlType) {
        pendingControl = type
        flushWebSocketOnAudioQueue()
    }

    private func flushWebSocketOnAudioQueue() {
        guard !sendInFlight, let task = webSocketTask else { return }
        if let packet = popPendingPacketOnAudioQueue() {
            let data = packet.data
            let byteCount = data.count
            let sampleCount = packet.sampleCount
            let sendStartedAt = Date()
            sendInFlight = true
            Task {
                do {
                    try await task.send(.data(data))
                    self.audioQueue.async {
                        self.handleWebSocketSendCompletionOnAudioQueue(
                            sentControl: nil,
                            sentAudioSamples: sampleCount,
                            sentBytes: byteCount,
                            sendMS: Self.elapsedMS(since: sendStartedAt)
                        )
                    }
                } catch {
                    self.audioQueue.async {
                        self.handleWebSocketSendFailureOnAudioQueue(message: error.localizedDescription)
                    }
                }
            }
            return
        }
        guard let control = pendingControl else { return }
        pendingControl = nil
        sendInFlight = true
        let payload = BridgeLivePreviewSocketControl(type: control)
        let sendStartedAt = Date()
        Task {
            do {
                let data = try JSONEncoder().encode(payload)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw RemoteBridgeClientError.invalidResponse
                }
                try await task.send(.string(text))
                self.audioQueue.async {
                    self.handleWebSocketSendCompletionOnAudioQueue(
                        sentControl: control,
                        sentAudioSamples: 0,
                        sentBytes: data.count,
                        sendMS: Self.elapsedMS(since: sendStartedAt)
                    )
                }
            } catch {
                self.audioQueue.async {
                    self.handleWebSocketSendFailureOnAudioQueue(message: error.localizedDescription)
                }
            }
        }
    }

    private func handleWebSocketSendCompletionOnAudioQueue(
        sentControl: BridgeLivePreviewSocketControl.ControlType?,
        sentAudioSamples: Int,
        sentBytes: Int,
        sendMS: Int
    ) {
        sendInFlight = false
        if sentAudioSamples > 0 {
            sentSampleCount += sentAudioSamples
            logSentAudioIfNeeded(byteCount: sentBytes, sendMS: sendMS)
        } else if let sentControl {
            Log.bridge.notice(
                "Mac client live preview websocket control sent session=\(self.logSessionID, privacy: .public) type=\(sentControl.rawValue, privacy: .public) bytes=\(sentBytes, privacy: .public) send_ms=\(sendMS, privacy: .public) sent_audio_ms=\(self.sentAudioMS, privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
            )
        }
        if sentControl == .cancel {
            closeWebSocketOnAudioQueue()
            return
        }
        flushWebSocketOnAudioQueue()
    }

    private func handleWebSocketSendFailureOnAudioQueue(message: String) {
        sendInFlight = false
        if finished {
            resolveFinishWaitersOnAudioQueue(text: nil)
            closeWebSocketOnAudioQueue()
            return
        }
        handleFailureOnAudioQueue(message: message)
    }

    private func handleWebSocketReceiveFailureOnAudioQueue(message: String) {
        if finished {
            resolveFinishWaitersOnAudioQueue(text: nil)
            closeWebSocketOnAudioQueue()
            return
        }
        handleFailureOnAudioQueue(message: message)
    }

    private func sendFinishRequestOnAudioQueue() {
        clearPendingPackets(keepingCapacity: false)
        guard let sessionID else {
            resolveFinishWaitersOnAudioQueue(text: nil)
            return
        }
        let client = self.client
        Task {
            var finalText: String?
            if let response = try? await client.finishLivePreview(
                sessionID: sessionID,
                timeout: Self.finishRequestTimeout
            ) {
                let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    finalText = text
                    self.onTranscript(text)
                }
            }
            self.audioQueue.async {
                self.resolveFinishWaitersOnAudioQueue(text: finalText)
                self.closeWebSocketOnAudioQueue()
            }
        }
    }

    private func sendCancelOnAudioQueue() {
        guard let sessionID else { return }
        let client = self.client
        Task { try? await client.finishLivePreview(sessionID: sessionID) }
    }

    private func handleLivePreviewEvent(_ event: BridgeLivePreviewEvent) {
        audioQueue.async {
            self.handleLivePreviewEventOnAudioQueue(event)
        }
    }

    private func handleLivePreviewEventOnAudioQueue(_ event: BridgeLivePreviewEvent) {
        guard event.sessionID == sessionID else { return }
        eventCount += 1
        Log.bridge.debug(
            "Mac client live preview event session=\(self.logSessionID, privacy: .public) final=\(event.isFinal, privacy: .public) event_count=\(self.eventCount, privacy: .public) text_chars=\(event.text?.count ?? 0, privacy: .public) sent_audio_ms=\(self.sentAudioMS, privacy: .public) server_age_ms=\(Self.serverAgeMS(event.updatedAt), privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
        )
        if !suppressSocketResult,
           let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           event.isFinal || text != lastTranscript {
            lastTranscript = text
            onTranscript(text)
        }
        if event.isFinal {
            resolveFinishWaitersOnAudioQueue(text: event.text)
            closeWebSocketOnAudioQueue()
        }
    }

    private func resolveFinishWaitersOnAudioQueue(text: String?) {
        guard !finishDidResolve else { return }
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        finishResultText = cleaned.isEmpty ? nil : cleaned
        finishDidResolve = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: finishResultText)
        }
    }

    private func closeWebSocketOnAudioQueue() {
        if webSocketTask != nil {
            Log.bridge.notice(
                "Mac client live preview websocket closed session=\(self.logSessionID, privacy: .public) sent_audio_ms=\(self.sentAudioMS, privacy: .public) events=\(self.eventCount, privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
            )
        }
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        sendInFlight = false
        pendingControl = nil
    }

    private static func decodeLivePreviewEvent(_ message: URLSessionWebSocketTask.Message) throws -> BridgeLivePreviewEvent {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw RemoteBridgeClientError.invalidResponse
        }
        return try JSONDecoder().decode(BridgeLivePreviewEvent.self, from: data)
    }

    private enum FinishWaitResult: Sendable {
        case completed(String?)
        case timedOut
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        UInt64(max(0, timeout) * 1_000_000_000)
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
            Log.bridge.notice("Mac client live preview resample failed: \(conversionError.localizedDescription, privacy: .public)")
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

    private func logQueuedAudioIfNeeded(frameCount: Int, sourceSampleRate: Double) {
        let shouldLog = !firstQueueLogged || queuedSampleCount >= nextQueueLogSampleCount
        guard shouldLog else { return }
        let isFirst = !firstQueueLogged
        firstQueueLogged = true
        while queuedSampleCount >= nextQueueLogSampleCount {
            nextQueueLogSampleCount += 16_000
        }
        Log.bridge.debug(
            "Mac client live preview audio queued session=\(self.logSessionID, privacy: .public) first=\(isFirst, privacy: .public) frames=\(frameCount, privacy: .public) source_hz=\(Int(sourceSampleRate.rounded()), privacy: .public) queued_audio_ms=\(self.queuedAudioMS, privacy: .public) pending_bytes=\(self.pendingPacketBytes, privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
        )
    }

    private func logSentAudioIfNeeded(byteCount: Int, sendMS: Int) {
        let shouldLog = !firstSendLogged || sentSampleCount >= nextSendLogSampleCount || sendMS >= 100
        guard shouldLog else { return }
        let isFirst = !firstSendLogged
        firstSendLogged = true
        while sentSampleCount >= nextSendLogSampleCount {
            nextSendLogSampleCount += 16_000
        }
        Log.bridge.debug(
            "Mac client live preview audio sent session=\(self.logSessionID, privacy: .public) first=\(isFirst, privacy: .public) bytes=\(byteCount, privacy: .public) sent_audio_ms=\(self.sentAudioMS, privacy: .public) send_ms=\(sendMS, privacy: .public) elapsed_ms=\(self.elapsedMS, privacy: .public)"
        )
    }

    private var logSessionID: String {
        guard let sessionID else { return "pending" }
        return String(sessionID.prefix(8))
    }

    private var queuedAudioMS: Int {
        queuedSampleCount * 1_000 / 16_000
    }

    private var sentAudioMS: Int {
        sentSampleCount * 1_000 / 16_000
    }

    private var elapsedMS: Int {
        Self.elapsedMS(since: startedAt)
    }

    private static func elapsedMS(since date: Date?) -> Int {
        guard let date else { return 0 }
        return elapsedMS(since: date)
    }

    private static func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private static func serverAgeMS(_ timestamp: TimeInterval) -> Int {
        Int((Date().timeIntervalSince1970 - timestamp) * 1_000)
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
}

private struct RemoteLivePreviewOpusPacket {
    let data: Data
    let sampleCount: Int
}

private enum RemoteLivePreviewOpusCodecError: LocalizedError {
    case unavailable
    case encodeFailed(String)
    case emptyPacket

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Opus live preview codec is unavailable"
        case .encodeFailed(let detail):
            return "Opus live preview encode failed: \(detail)"
        case .emptyPacket:
            return "Opus live preview encoder produced no packet"
        }
    }
}

private final class RemoteLivePreviewOpusEncoder {
    private static let sampleRate = 16_000.0
    private static let channelCount: AVAudioChannelCount = 1
    private static let frameSampleCount = 320
    private static let maxPacketBytes = 4_096
    private static let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
    private static let opusFormat = AVAudioFormat(settings: [
        AVFormatIDKey: Int(kAudioFormatOpus),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(channelCount),
        AVEncoderBitRateKey: 24_000,
    ])!

    private let converter: AVAudioConverter?
    private var pendingSamples: [Float] = []

    init() {
        converter = AVAudioConverter(from: Self.pcmFormat, to: Self.opusFormat)
    }

    func append(samples: UnsafePointer<Float>, count: Int) throws -> [RemoteLivePreviewOpusPacket] {
        guard count > 0 else { return [] }
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        return try drainCompleteFrames()
    }

    func finish() throws -> [RemoteLivePreviewOpusPacket] {
        guard !pendingSamples.isEmpty else { return [] }
        let missing = Self.frameSampleCount - pendingSamples.count
        if missing > 0 {
            pendingSamples.append(contentsOf: repeatElement(Float(0), count: missing))
        }
        return try drainCompleteFrames()
    }

    private func drainCompleteFrames() throws -> [RemoteLivePreviewOpusPacket] {
        var packets: [RemoteLivePreviewOpusPacket] = []
        while pendingSamples.count >= Self.frameSampleCount {
            let frame = Array(pendingSamples.prefix(Self.frameSampleCount))
            pendingSamples.removeFirst(Self.frameSampleCount)
            packets.append(try encodeFrame(frame))
        }
        return packets
    }

    private func encodeFrame(_ samples: [Float]) throws -> RemoteLivePreviewOpusPacket {
        guard let converter,
              let input = AVAudioPCMBuffer(
                  pcmFormat: Self.pcmFormat,
                  frameCapacity: AVAudioFrameCount(Self.frameSampleCount)
              ),
              let channel = input.floatChannelData?[0]
        else {
            throw RemoteLivePreviewOpusCodecError.unavailable
        }
        input.frameLength = AVAudioFrameCount(Self.frameSampleCount)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: Self.frameSampleCount)
        }

        let output = AVAudioCompressedBuffer(
            format: Self.opusFormat,
            packetCapacity: 1,
            maximumPacketSize: Self.maxPacketBytes
        )
        let inputSource = RemoteLivePreviewOpusEncoderInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            inputSource.next(outStatus)
        }
        if let conversionError {
            throw RemoteLivePreviewOpusCodecError.encodeFailed(conversionError.localizedDescription)
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw RemoteLivePreviewOpusCodecError.encodeFailed("converter returned error")
        @unknown default:
            break
        }
        guard output.byteLength > 0, output.packetCount > 0 else {
            throw RemoteLivePreviewOpusCodecError.emptyPacket
        }
        let offset: Int
        let byteCount: Int
        if let description = output.packetDescriptions?.pointee {
            offset = Int(description.mStartOffset)
            byteCount = Int(description.mDataByteSize)
        } else {
            offset = 0
            byteCount = Int(output.byteLength)
        }
        guard byteCount > 0 else {
            throw RemoteLivePreviewOpusCodecError.emptyPacket
        }
        return RemoteLivePreviewOpusPacket(
            data: Data(bytes: output.data.advanced(by: offset), count: byteCount),
            sampleCount: Self.frameSampleCount
        )
    }
}

private final class RemoteLivePreviewOpusEncoderInput: @unchecked Sendable {
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

private final class SendableRemotePreviewPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
