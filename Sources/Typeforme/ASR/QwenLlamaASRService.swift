import Foundation

final class QwenLlamaASRService: ASRService {
    static let maxTransientASRAttempts = 2
    private static let requestBodyAudioChunkSize = 48 * 1024
    private static let warmupSampleRate = 16_000
    private static let warmupMaxTokens = 8
    private static let warmupTimeout: TimeInterval = 20

    private let server: LlamaCppServerManager
    private let warmupState = QwenLlamaWarmupState()

    init(server: LlamaCppServerManager) {
        self.server = server
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        let supportedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        let port: Int
        do {
            port = try await server.ensureRunning()
        } catch {
            throw ASRAudioSupportError.httpStatus(503, error.localizedDescription)
        }
        return try await runUserRequest {
            try await Self.transcribeViaLlamaChatWithRetry(
                audioFileURL: audioFileURL,
                languageIDs: supportedLanguageIDs,
                port: port,
                timeout: AppSettings.asrQwenLlamaTimeoutSeconds,
                maxTokens: AppSettings.asrQwenLlamaMaxTokens,
                model: (AppSettings.asrQwenLlamaModelPath as NSString).lastPathComponent
            )
        }
    }

    static func shouldRetryTransientASRError(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maxTransientASRAttempts else { return false }
        if let asrError = error as? ASRAudioSupportError {
            switch asrError {
            case .emptyTranscript:
                return true
            case .httpStatus(let code, _):
                return code >= 500 && code < 600
            case .audioConversionFailed, .requestBodyFailed, .timeout, .unsupportedBridgeAudioExtension:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return true
            default:
                return false
            }
        }
        return false
    }

    func preload() async throws {
        let port = try await server.ensureRunning()
        let model = (AppSettings.asrQwenLlamaModelPath as NSString).lastPathComponent
        let languageIDs = ASRLanguageSelection.validatedIDs(
            AppSettings.asrLanguageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        let key = Self.warmupKey(port: port, languageIDs: languageIDs)
        switch await warmupState.beginWarmup(key: key) {
        case .started(let ticket):
            let task = Task(priority: .utility) {
                await Self.warmUpLlamaChat(
                    port: port,
                    model: model.isEmpty ? "qwen3-asr" : model,
                    languageIDs: languageIDs
                )
            }
            guard await warmupState.installWarmupTask(task, ticket: ticket) else {
                task.cancel()
                _ = await task.value
                throw QwenLlamaWarmupError.skipped("user transcription is active")
            }
            let outcome = await task.value
            await warmupState.finishWarmup(ticket: ticket)
            try Self.validateWarmupOutcome(outcome)
        case .wait(let task):
            try Self.validateWarmupOutcome(await task.value)
        case .skipped(let reason):
            throw QwenLlamaWarmupError.skipped(reason)
        }
    }

    func stop() async {
        await server.stop()
    }

    func transcribeLivePreviewPCM16kMonoFloat32Data(
        _ pcmData: Data,
        languageIDs: [String],
        timeout: TimeInterval,
        maxTokens: Int
    ) async throws -> String {
        guard !Task.isCancelled else { throw CancellationError() }
        let supportedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        let port: Int
        do {
            port = try await server.ensureRunning()
        } catch {
            throw ASRAudioSupportError.httpStatus(503, error.localizedDescription)
        }
        let model = (AppSettings.asrQwenLlamaModelPath as NSString).lastPathComponent
        return try await runPreviewRequest {
            let audioURL = try Self.writePCM16kMonoFloat32WAVFile(pcmData)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            guard !Task.isCancelled else { throw CancellationError() }
            return try await Self.llamaChat(
                audioFileURL: audioURL,
                languageIDs: supportedLanguageIDs,
                port: port,
                timeout: timeout,
                maxTokens: maxTokens,
                model: model.isEmpty ? "qwen3-asr" : model,
                allowEmptyTranscript: true
            )
        }
    }

    static func chatCompletionsEndpoint(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    }

    private static func warmupKey(port: Int, languageIDs: [String]) -> String {
        [
            "port=\(port)",
            "model=\(AppSettings.asrQwenLlamaModelPath)",
            "mmproj=\(AppSettings.asrQwenLlamaMMProjPath)",
            "languages=\(languageIDs.joined(separator: ","))",
        ].joined(separator: "|")
    }

    static func languageAssistantPrefix(languageIDs: [String]) -> String? {
        let ids = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        var seen = Set<String>()
        let names = qwenASRPrefixOrderedLanguageIDs(ids).compactMap { id -> String? in
            guard let name = qwenASRLanguageName(for: id),
                  !seen.contains(name)
            else { return nil }
            seen.insert(name)
            return name
        }
        guard !names.isEmpty else { return nil }
        return "language \(names.joined(separator: ", "))<asr_text>"
    }

    private static func qwenASRPrefixOrderedLanguageIDs(_ ids: [String]) -> [String] {
        let defaultIDs = Set(ASRLanguageSelection.defaultIDs)
        return ids.enumerated().sorted { lhs, rhs in
            let lhsIsDefault = defaultIDs.contains(lhs.element)
            let rhsIsDefault = defaultIDs.contains(rhs.element)
            if lhsIsDefault != rhsIsDefault {
                return !lhsIsDefault
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func qwenASRLanguageName(for id: String) -> String? {
        switch id {
        case "zh-CN", "zh-TW":
            return "Chinese"
        case "tl":
            return "Filipino"
        default:
            guard let option = ASRLanguageSelection.option(for: id) else { return nil }
            return option.displayName
                .components(separatedBy: " / ")
                .first?
                .components(separatedBy: " (")
                .first
        }
    }

    static func parseChatTranscript(data: Data) throws -> String {
        guard let response = try? BridgeJSON.decode(QwenASRChatResponse.self, from: data) else {
            return ASRAudioSupport.cleanTranscriptText(
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        if let text = response.extractedText {
            return ASRAudioSupport.cleanTranscriptText(text)
        }
        return ""
    }

    private static func responseSummary(data: Data) -> String {
        guard let response = try? BridgeJSON.decode(QwenASRChatResponse.self, from: data) else {
            return "non_json bytes=\(data.count)"
        }

        var parts = ["bytes=\(data.count)"]
        if let choices = response.choices {
            parts.append("choices=\(choices.count)")
            if let first = choices.first, let finishReason = first.finishReason {
                parts.append("finish_reason=\(finishReason)")
            }
            if let content = choices.first?.message?.content {
                parts.append("message_content=\(content.summary)")
            }
        } else {
            parts.append("choices=nil")
        }
        if let message = response.error?.message.prefix(160) {
            parts.append("error=\(message)")
        }
        return parts.joined(separator: " ")
    }

    private static func transcribeViaLlamaChat(
        audioFileURL: URL,
        languageIDs: [String],
        port: Int,
        timeout: TimeInterval,
        maxTokens: Int,
        model: String
    ) async throws -> String {
        try await llamaChat(
            audioFileURL: audioFileURL,
            languageIDs: languageIDs,
            port: port,
            timeout: timeout,
            maxTokens: maxTokens,
            model: model,
            allowEmptyTranscript: false
        )
    }

    private static func llamaChat(
        audioFileURL: URL,
        languageIDs: [String],
        port: Int,
        timeout: TimeInterval,
        maxTokens: Int,
        model: String,
        allowEmptyTranscript: Bool
    ) async throws -> String {
        let uploadURL = try await ASRAudioSupport.llamaUploadableAudioURL(for: audioFileURL)
        defer {
            if uploadURL != audioFileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }

        let endpoint = chatCompletionsEndpoint(port: port)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyFile: QwenASRChatBodyFile
        do {
            bodyFile = try await writeChatRequestBodyFile(
                uploadURL: uploadURL,
                languageIDs: languageIDs,
                maxTokens: maxTokens,
                model: model.isEmpty ? "qwen3-asr" : model
            )
        } catch {
            throw ASRAudioSupportError.requestBodyFailed(error.localizedDescription)
        }
        defer {
            try? FileManager.default.removeItem(at: bodyFile.url)
        }
        guard let bodyStream = InputStream(url: bodyFile.url) else {
            throw ASRAudioSupportError.requestBodyFailed("Could not open Qwen ASR request body")
        }
        request.httpBodyStream = bodyStream
        request.setValue(String(bodyFile.byteCount), forHTTPHeaderField: "Content-Length")

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        try ASRAudioSupport.validateHTTPResponse(response, data: data)
        let text = try parseChatTranscript(data: data)
        guard allowEmptyTranscript || !text.isEmpty else {
            Log.asr.notice("qwen3-asr empty transcript response: \(responseSummary(data: data), privacy: .public)")
            throw ASRAudioSupportError.emptyTranscript
        }
        return LocaleTextNormalizer.normalize(text, languageIDs: languageIDs)
    }

    private static func writeChatRequestBodyFile(
        uploadURL: URL,
        languageIDs: [String],
        maxTokens: Int,
        model: String
    ) async throws -> QwenASRChatBodyFile {
        try await Task.detached(priority: .utility) {
            let bodyURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("typeforme-qwen-asr-\(UUID().uuidString).json")
            _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }

            func write(_ string: String) throws {
                try output.write(contentsOf: Data(string.utf8))
            }
            func write(_ data: Data) throws {
                try output.write(contentsOf: data)
            }
            func writeJSONString(_ string: String) throws {
                try write(BridgeJSON.encode(string))
            }

            let languagePrefix = languageAssistantPrefix(languageIDs: languageIDs)

            try write(#"{"model":"#)
            try writeJSONString(model)
            try write(#","messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":""#)
            try writeBase64Audio(uploadURL, to: output)
            try write(#"","format":"wav"}}]}"#)
            if let languagePrefix {
                try write(#",{"role":"assistant","content":"#)
                try writeJSONString(languagePrefix)
                try write(#"}"#)
            }
            try write(#"],"temperature":0,"max_tokens":"#)
            try write(String(maxTokens))
            if languagePrefix != nil {
                try write(#","continue_final_message":true,"add_generation_prompt":false"#)
            }
            try write(#","stream":false,"cache_prompt":true}"#)

            let byteCount = try FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber
            return QwenASRChatBodyFile(url: bodyURL, byteCount: byteCount?.uint64Value ?? 0)
        }.value
    }

    private static func warmUpLlamaChat(
        port: Int,
        model: String,
        languageIDs: [String]
    ) async -> QwenLlamaWarmupOutcome {
        let started = Date()
        do {
            let audioURL = try writeWarmupSilenceWAVFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            _ = try await llamaChat(
                audioFileURL: audioURL,
                languageIDs: languageIDs,
                port: port,
                timeout: warmupTimeout,
                maxTokens: warmupMaxTokens,
                model: model,
                allowEmptyTranscript: true
            )
            Log.asr.info(
                "Qwen3-ASR GGUF audio warmup finished elapsed_ms=\(Self.elapsedMS(since: started), privacy: .public)"
            )
            return .warmed
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                Log.asr.notice("Qwen3-ASR GGUF audio warmup cancelled")
                return .cancelled("user transcription interrupted warmup")
            }
            Log.asr.notice(
                "Qwen3-ASR GGUF audio warmup failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }

    private func runUserRequest<T>(_ operation: () async throws -> T) async throws -> T {
        let requestStart = await warmupState.beginUserRequest()
        let cancelledPreview = await QwenLlamaLivePreviewTaskRegistry.shared.cancelAll()
        let waitedForPreview: Bool
        do {
            waitedForPreview = try await warmupState.waitForPreviewRequestsToFinish()
        } catch {
            await warmupState.finishUserRequest()
            throw error
        }
        if cancelledPreview {
            Log.asr.notice("Qwen3-ASR live preview cancelled for user transcription")
        }
        if waitedForPreview {
            Log.asr.notice("Qwen3-ASR user transcription waited for live preview to stop")
        }
        if requestStart.cancelledWarmup {
            Log.asr.notice("Qwen3-ASR GGUF audio warmup cancelled for user transcription")
        }
        do {
            let result = try await operation()
            await warmupState.finishUserRequest()
            return result
        } catch {
            await warmupState.finishUserRequest()
            throw error
        }
    }

    private func runPreviewRequest<T>(_ operation: () async throws -> T) async throws -> T {
        guard await warmupState.beginPreviewRequest() else {
            throw CancellationError()
        }
        do {
            let result = try await operation()
            await warmupState.finishPreviewRequest()
            return result
        } catch {
            await warmupState.finishPreviewRequest()
            throw error
        }
    }

    private static func validateWarmupOutcome(_ outcome: QwenLlamaWarmupOutcome) throws {
        switch outcome {
        case .warmed:
            return
        case .cancelled(let reason):
            throw QwenLlamaWarmupError.skipped(reason)
        case .failed(let message):
            throw QwenLlamaWarmupError.failed(message)
        }
    }

    static func writeWarmupSilenceWAVFile(sampleCount: Int = 16_000) throws -> URL {
        let clampedSampleCount = max(1, sampleCount)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-qwen-asr-warmup-\(UUID().uuidString).wav")
        let samples = Data(count: clampedSampleCount * MemoryLayout<Int16>.size)
        try writePCM16kMonoInt16WAVFile(samples, sampleCount: clampedSampleCount, to: url)
        return url
    }

    static func writePCM16kMonoFloat32WAVFile(_ pcmData: Data) throws -> URL {
        guard !pcmData.isEmpty,
              pcmData.count % MemoryLayout<Float>.size == 0
        else {
            throw ASRAudioSupportError.audioConversionFailed("Qwen preview PCM must be non-empty Float32 samples")
        }
        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        var int16Data = Data(count: sampleCount * MemoryLayout<Int16>.size)
        pcmData.withUnsafeBytes { inputBuffer in
            int16Data.withUnsafeMutableBytes { outputBuffer in
                let input = inputBuffer.bindMemory(to: UInt32.self)
                let output = outputBuffer.bindMemory(to: Int16.self)
                for index in 0..<sampleCount {
                    let value = Float(bitPattern: UInt32(littleEndian: input[index]))
                    let clamped = max(-1, min(1, value))
                    output[index] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
                }
            }
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-qwen-asr-preview-\(UUID().uuidString).wav")
        try writePCM16kMonoInt16WAVFile(int16Data, sampleCount: sampleCount, to: url)
        return url
    }

    private static func writePCM16kMonoInt16WAVFile(
        _ pcmData: Data,
        sampleCount: Int,
        to url: URL
    ) throws {
        let clampedSampleCount = max(1, sampleCount)
        var data = Data()

        func appendASCII(_ value: String) {
            data.append(Data(value.utf8))
        }

        func appendUInt16LE(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32LE(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        let bytesPerSample = 2
        let audioByteCount = clampedSampleCount * bytesPerSample
        appendASCII("RIFF")
        appendUInt32LE(UInt32(36 + audioByteCount))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32LE(16)
        appendUInt16LE(1)
        appendUInt16LE(1)
        appendUInt32LE(UInt32(warmupSampleRate))
        appendUInt32LE(UInt32(warmupSampleRate * bytesPerSample))
        appendUInt16LE(UInt16(bytesPerSample))
        appendUInt16LE(16)
        appendASCII("data")
        appendUInt32LE(UInt32(audioByteCount))
        if pcmData.count >= audioByteCount {
            data.append(pcmData.prefix(audioByteCount))
        } else {
            data.append(pcmData)
            data.append(Data(count: audioByteCount - pcmData.count))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private static func writeBase64Audio(_ audioURL: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }

        while true {
            let chunk = try input.read(upToCount: requestBodyAudioChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk.base64EncodedData())
        }
    }

    private struct QwenASRChatBodyFile {
        let url: URL
        let byteCount: UInt64
    }

    private static func transcribeViaLlamaChatWithRetry(
        audioFileURL: URL,
        languageIDs: [String],
        port: Int,
        timeout: TimeInterval,
        maxTokens: Int,
        model: String
    ) async throws -> String {
        var lastError: Error?
        for attempt in 1...maxTransientASRAttempts {
            do {
                return try await transcribeViaLlamaChat(
                    audioFileURL: audioFileURL,
                    languageIDs: languageIDs,
                    port: port,
                    timeout: timeout,
                    maxTokens: maxTokens,
                    model: model
                )
            } catch {
                lastError = error
                guard shouldRetryTransientASRError(error, attempt: attempt) else {
                    throw error
                }
                Log.asr.notice("qwen3-asr transient failure on attempt \(attempt, privacy: .public); retrying: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        throw lastError ?? ASRAudioSupportError.emptyTranscript
    }
}

enum QwenLlamaWarmupError: LocalizedError {
    case skipped(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .skipped(let reason):
            return "Qwen3-ASR GGUF audio warmup skipped: \(reason)"
        case .failed(let message):
            return "Qwen3-ASR GGUF audio warmup failed: \(message)"
        }
    }
}

private struct QwenLlamaWarmupTicket: Sendable {
    let id = UUID()
    let key: String
}

private enum QwenLlamaWarmupStart: Sendable {
    case started(QwenLlamaWarmupTicket)
    case wait(Task<QwenLlamaWarmupOutcome, Never>)
    case skipped(String)
}

private enum QwenLlamaWarmupOutcome: Sendable {
    case warmed
    case cancelled(String)
    case failed(String)
}

private struct QwenLlamaUserRequestStart: Sendable {
    let cancelledWarmup: Bool
}

private actor QwenLlamaWarmupState {
    private var warmingKey: String?
    private var warmingID: UUID?
    private var warmingTask: Task<QwenLlamaWarmupOutcome, Never>?
    private var userRequestCount = 0
    private var previewRequestCount = 0

    func beginWarmup(key: String) -> QwenLlamaWarmupStart {
        guard userRequestCount == 0, previewRequestCount == 0 else {
            return .skipped("user transcription or live preview is active")
        }
        if warmingKey == key {
            if let warmingTask {
                return .wait(warmingTask)
            }
            return .skipped("matching warmup is already starting")
        }
        warmingTask?.cancel()
        let ticket = QwenLlamaWarmupTicket(key: key)
        warmingKey = key
        warmingID = ticket.id
        warmingTask = nil
        return .started(ticket)
    }

    func installWarmupTask(
        _ task: Task<QwenLlamaWarmupOutcome, Never>,
        ticket: QwenLlamaWarmupTicket
    ) -> Bool {
        guard warmingKey == ticket.key,
              warmingID == ticket.id,
              userRequestCount == 0,
              previewRequestCount == 0
        else {
            task.cancel()
            return false
        }
        warmingTask = task
        return true
    }

    func finishWarmup(ticket: QwenLlamaWarmupTicket) {
        guard warmingKey == ticket.key, warmingID == ticket.id else { return }
        warmingKey = nil
        warmingID = nil
        warmingTask = nil
    }

    func beginUserRequest() -> QwenLlamaUserRequestStart {
        userRequestCount += 1
        let cancelled = warmingKey != nil || warmingTask != nil
        warmingTask?.cancel()
        warmingKey = nil
        warmingID = nil
        warmingTask = nil
        return QwenLlamaUserRequestStart(cancelledWarmup: cancelled)
    }

    func waitForPreviewRequestsToFinish() async throws -> Bool {
        let waitedForPreview = previewRequestCount > 0
        do {
            while previewRequestCount > 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            throw error
        }
        return waitedForPreview
    }

    func finishUserRequest() {
        userRequestCount = max(0, userRequestCount - 1)
    }

    func beginPreviewRequest() -> Bool {
        guard userRequestCount == 0 else { return false }
        warmingTask?.cancel()
        warmingKey = nil
        warmingID = nil
        warmingTask = nil
        previewRequestCount += 1
        return true
    }

    func finishPreviewRequest() {
        previewRequestCount = max(0, previewRequestCount - 1)
    }
}

private struct QwenASRChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: ResponseContent?
        }

        let message: Message?
        let text: String?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case text
            case finishReason = "finish_reason"
        }
    }

    struct ErrorPayload: Decodable {
        let message: String
    }

    let choices: [Choice]?
    let text: String?
    let content: ResponseContent?
    let error: ErrorPayload?

    var extractedText: String? {
        if let choices, let first = choices.first {
            if let text = first.message?.content?.text { return text }
            if let text = first.text { return text }
        }
        if let text { return text }
        return content?.text
    }
}

private enum ResponseContent: Decodable {
    case string(String)
    case object(ResponseContentItem)
    case array([ResponseContentItem])

    var text: String? {
        switch self {
        case .string(let text):
            return text
        case .object(let item):
            return item.textValue
        case .array(let items):
            let text = items.compactMap(\.textValue).joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }

    var summary: String {
        switch self {
        case .string(let text):
            return "string(\(text.count))"
        case .object:
            return "object"
        case .array(let items):
            return "array(\(items.count))"
        }
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let text = try? singleValue.decode(String.self) {
            self = .string(text)
            return
        }
        if let items = try? singleValue.decode([ResponseContentItem].self) {
            self = .array(items)
            return
        }
        self = .object(try singleValue.decode(ResponseContentItem.self))
    }
}

private struct ResponseContentItem: Decodable {
    let text: String?
    let content: String?
    let inputText: String?

    enum CodingKeys: String, CodingKey {
        case text
        case content
        case inputText = "input_text"
    }

    var textValue: String? {
        if let text { return text }
        if let content { return content }
        return inputText
    }
}
