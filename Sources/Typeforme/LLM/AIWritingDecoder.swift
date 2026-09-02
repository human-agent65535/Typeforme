import Darwin
import Foundation

enum AIWritingBackend: String, CaseIterable, Identifiable, Sendable {
    case languageModel
    case pinyinDecoder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .languageModel: return "Language model prompt"
        case .pinyinDecoder: return "Pinyin decoder (Rime + Qwen)"
        }
    }
}

/// The installer owns native dependencies and model selection. A request keeps
/// this snapshot even if the runtime manifest or Settings change mid-flight.
struct AIWritingDecoderConfiguration: Codable, Equatable, Sendable {
    let version: Int
    let python: String
    let script: String
    let tools: String
    let rimeData: String
    let grammar: String
    let plugin: String
    let model: String
    let backendDirectory: String

    static func load(from url: URL = AppPaths.aiWritingRuntimeFile) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else {
            throw AIWritingDecoderError.unavailable
        }
        return value
    }

    func validate() throws {
        let fm = FileManager.default
        let files = [python, script, model, grammar, plugin,
                     tools + "/rime_analysis", tools + "/rime_sentences",
                     tools + "/llama_score", tools + "/layout",
                     rimeData + "/build/typeforme_pinyin.table.bin",
                     rimeData + "/build/typeforme_pinyin.prism.bin"]
        guard version == 1,
              files.allSatisfy({ $0.hasPrefix("/") && fm.isReadableFile(atPath: $0) }),
              fm.isExecutableFile(atPath: python)
        else { throw AIWritingDecoderError.unavailable }
    }

    var arguments: [String] {
        [script, "--tools-directory", tools, "--rime-data", rimeData,
         "--grammar-file", grammar, "--rime-plugin", plugin,
         "--model-path", model, "--backend-directory", backendDirectory,
         "--service-parent-pid", String(getpid())]
    }
}

enum AIWritingSessionConfiguration: Sendable {
    case languageModel
    case pinyinDecoder(AIWritingDecoderConfiguration?)

    static func capture() -> Self {
        switch AppSettings.aiWritingBackend {
        case .languageModel: return .languageModel
        case .pinyinDecoder: return .pinyinDecoder(try? AIWritingDecoderConfiguration.load())
        }
    }
}

enum AIWritingDecoderError: LocalizedError, Equatable {
    case unavailable, busy, timedOut, invalidResponse, failed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return NSLocalizedString("The AI Writing decoder runtime is missing or incomplete. Install the decoder runtime on this Mac before converting.", comment: "")
        case .busy:
            return NSLocalizedString("AI Writing is already converting a draft. Please try again when it finishes.", comment: "")
        case .timedOut:
            return NSLocalizedString("AI Writing timed out. Your draft has not been replaced.", comment: "")
        case .invalidResponse, .failed:
            return NSLocalizedString("AI Writing could not safely decode this draft. Your input has not been replaced.", comment: "")
        }
    }
}

protocol AIWritingDecoding: Sendable {
    func decode(_ request: TextEditRequest, configuration: AIWritingDecoderConfiguration) async throws -> [String]
}

actor AIWritingDecoderService: AIWritingDecoding {
    static let shared = AIWritingDecoderService()
    private var worker: AIWritingLineWorker?
    private var configuration: AIWritingDecoderConfiguration?
    private var activeRequest: UUID?
    private var releaseAfterRequest = false

    func decode(_ request: TextEditRequest, configuration: AIWritingDecoderConfiguration) async throws -> [String] {
        try Task.checkCancellation()
        guard activeRequest == nil else { throw AIWritingDecoderError.busy }
        try configuration.validate()
        let id = UUID()
        activeRequest = id
        defer {
            activeRequest = nil
            if releaseAfterRequest { shutdown() }
        }
        let cold = worker == nil || self.configuration != configuration || worker?.isClosed == true
        if cold {
            worker?.stop()
            worker = try AIWritingLineWorker(executable: configuration.python, arguments: configuration.arguments)
            self.configuration = configuration
        }
        guard let worker else { throw AIWritingDecoderError.unavailable }
        do {
            let input = DecoderInput(
                id: id.uuidString,
                input: request.targetText,
                contextBefore: String(request.contextBefore.suffix(160)),
                vocabularyCandidates: Array(TextEditPromptBuilder.vocabularyCandidates(for: request).compactMap { hint in
                    guard let matched = hint.matchedSpan, !matched.isEmpty,
                          !hint.speechHint.isEmpty,
                          [hint.surface, hint.speechHint, matched].allSatisfy({ $0.count <= 100 })
                    else { return nil }
                    return ["surface": hint.surface, "speech_hint": hint.speechHint,
                            "matched_span": matched, "type": hint.type]
                }.prefix(32))
            )
            let response = try await worker.query(
                JSONEncoder().encode(input),
                timeout: cold ? 60 : 30
            )
            try Task.checkCancellation()
            let result = try JSONDecoder().decode(DecoderOutput.self, from: response)
            guard result.id == id.uuidString else { throw AIWritingDecoderError.invalidResponse }
            guard result.error == nil, result.structureValid == true,
                  let segments = result.convertedSegments,
                  segments.count == PinyinDraftLayout(request.targetText).segments.count
            else { throw AIWritingDecoderError.failed }
            return segments
        } catch {
            // A cancelled or failed request never leaves unread output for the
            // next draft, and never silently switches to a different backend.
            worker.stop()
            if self.worker === worker {
                self.worker = nil
                self.configuration = nil
            }
            throw error
        }
    }

    func shutdown() {
        worker?.stop()
        worker = nil
        configuration = nil
        releaseAfterRequest = false
    }

    func releaseWhenIdle() {
        if activeRequest == nil { shutdown() }
        else { releaseAfterRequest = true }
    }

    private struct DecoderInput: Encodable {
        let id: String
        let input: String
        let contextBefore: String
        let vocabularyCandidates: [[String: String]]
        enum CodingKeys: String, CodingKey {
            case id, input
            case contextBefore = "context_before"
            case vocabularyCandidates = "vocabulary_candidates"
        }
    }

    private struct DecoderOutput: Decodable {
        let id: String?
        let convertedSegments: [String]?
        let structureValid: Bool?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case id, error
            case convertedSegments = "converted_segments"
            case structureValid = "structure_valid"
        }
    }
}

/// One owned JSON-lines process. Only the lock protects mutable I/O state;
/// Foundation callbacks never touch actor-isolated request state.
final class AIWritingLineWorker: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<Data, any Error>?
    private var deadline: DispatchWorkItem?
    private var closed = false

    var isClosed: Bool { lock.withLock { closed } }

    init(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        // Native diagnostics can include input/model paths. Normal app logs
        // retain only the request status; opt-in debug capture owns user text.
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.stop(error: AIWritingDecoderError.failed)
        }
        do { try process.run() }
        catch {
            stop(error: AIWritingDecoderError.unavailable)
            throw AIWritingDecoderError.unavailable
        }
    }

    func query(_ data: Data, timeout: TimeInterval) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let failure: AIWritingDecoderError? = lock.withLock {
                    guard !closed else { return .failed }
                    guard pending == nil else { return .busy }
                    pending = continuation
                    let work = DispatchWorkItem { [weak self] in
                        self?.stop(error: AIWritingDecoderError.timedOut)
                    }
                    deadline = work
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
                    return nil
                }
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
                catch { stop(error: AIWritingDecoderError.failed) }
            }
        } onCancel: {
            self.stop(error: CancellationError())
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { stop(error: AIWritingDecoderError.failed); return }
        var reply: (CheckedContinuation<Data, any Error>, Data)?
        let invalid = lock.withLock {
            guard !closed else { return false }
            buffer.append(data)
            guard buffer.count <= 1_048_576 else { return true }
            guard let end = buffer.firstIndex(of: 10) else { return false }
            guard let continuation = pending, end == buffer.index(before: buffer.endIndex) else { return true }
            reply = (continuation, Data(buffer[..<end]))
            pending = nil
            buffer.removeAll(keepingCapacity: true)
            deadline?.cancel()
            deadline = nil
            return false
        }
        if invalid { stop(error: AIWritingDecoderError.invalidResponse) }
        if let (continuation, line) = reply { continuation.resume(returning: line) }
    }

    func stop(error: any Error = CancellationError()) {
        let state: (Bool, CheckedContinuation<Data, any Error>?) = lock.withLock {
            guard !closed else { return (false, nil) }
            closed = true
            let continuation = pending
            pending = nil
            deadline?.cancel()
            deadline = nil
            return (true, continuation)
        }
        guard state.0 else { return }
        output.fileHandleForReading.readabilityHandler = nil
        let pid = process.processIdentifier
        // Service mode establishes a private process group before creating any
        // native helpers. Check ownership before addressing the whole group.
        if pid > 0, getpgid(pid) == pid {
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            }
        } else if process.isRunning {
            process.terminate()
        }
        try? input.fileHandleForWriting.close()
        state.1?.resume(throwing: error)
    }

    deinit { stop() }
}
