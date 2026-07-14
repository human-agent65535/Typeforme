@preconcurrency import AVFoundation
import Darwin
import Foundation

enum ASRAudioSupportError: LocalizedError {
    case audioConversionFailed(String)
    case requestBodyFailed(String)
    case invalidResponse(String)
    case httpStatus(Int, String)
    case timeout(seconds: TimeInterval)
    case emptyTranscript
    case unsupportedBridgeAudioExtension(String)

    var errorDescription: String? {
        switch self {
        case .audioConversionFailed(let detail):
            return "Could not convert audio for ASR upload: \(detail)"
        case .requestBodyFailed(let detail):
            return "Could not build ASR request body: \(detail)"
        case .invalidResponse(let detail):
            return "ASR server returned an invalid response: \(detail)"
        case .httpStatus(let code, let body):
            return "ASR server returned HTTP \(code): \(body)"
        case .timeout(let seconds):
            return "ASR timed out after \(Int(seconds))s"
        case .emptyTranscript:
            return "ASR server returned an empty transcript"
        case .unsupportedBridgeAudioExtension(let ext):
            return "Bridge upload audio must be FLAC; got \(ext)"
        }
    }
}

enum ASRAudioSupport {
    static let conversionTimeoutSeconds: TimeInterval = 30
    static let maximumCanonicalWAVBytes = Int(
        BridgeAudioRecordingContract.maximumFrameCount
            * UInt64(BridgeAudioRecordingContract.channelCount)
            * UInt64(MemoryLayout<Int16>.size)
    ) + 4_096
    private static let conversionLimiter = ASRAudioConversionLimiter(maxConcurrentConversions: 2)

    static func audioDurationMilliseconds(for url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return max(0, Int((Double(file.length) / sampleRate * 1_000).rounded()))
    }

    static func cleanTranscriptText(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let markerRange = value.range(of: "<asr_text>") {
            value = String(value[markerRange.upperBound...])
        }
        value = value
            .replacingOccurrences(of: "</asr_text>", with: "")
            .replacingOccurrences(
                of: #"(?i)^\s*language\s+(english|chinese|cantonese|japanese|korean|french|german|spanish|portuguese|indonesian|italian|russian|thai|vietnamese|turkish|hindi|malay|dutch|swedish|danish|finnish|polish|czech|tagalog|filipino|persian|greek|hungarian|macedonian|romanian)\s*[:：,-]?\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s*<[a-z]{2}(?:-[a-z]{2})?>\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    static func wavUploadableAudioURL(for url: URL) async throws -> URL {
        if isASRReadyWAV(url) {
            return url
        }

        let output = AppPaths.asrWorkDir
            .appendingPathComponent("typeforme-asr-\(UUID().uuidString).wav")
        do {
            try AppPaths.ensureDirectories()
            try await conversionLimiter.acquire()
            do {
                try await writeWAV(input: url, output: output)
                await conversionLimiter.release()
            } catch {
                await conversionLimiter.release()
                throw error
            }
            return output
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        } catch let error as ASRAudioSupportError {
            try? FileManager.default.removeItem(at: output)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ASRAudioSupportError.audioConversionFailed(error.localizedDescription)
        }
    }

    static func llamaUploadableAudioURL(for url: URL) async throws -> URL {
        try await wavUploadableAudioURL(for: url)
    }

    static func bridgeUploadAudioURL(for url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard BridgeAudioFormat.isAllowedExtension(ext) else {
            throw ASRAudioSupportError.unsupportedBridgeAudioExtension(ext.isEmpty ? "missing extension" : ext)
        }
        return url
    }

    static func isBenignEmptyTranscript(_ error: Error) -> Bool {
        if let asrError = error as? ASRAudioSupportError {
            switch asrError {
            case .emptyTranscript:
                return true
            default:
                break
            }
        }
        return isBenignEmptyTranscriptMessage(error.localizedDescription)
    }

    static func isBenignEmptyTranscriptMessage(_ message: String) -> Bool {
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("empty transcript")
            || lower.contains("no speech detected")
    }

    static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = data.isEmpty ? "empty response body" : "response body omitted (\(data.count) bytes)"
            throw ASRAudioSupportError.httpStatus(http.statusCode, detail)
        }
    }

    private static func writeWAV(input: URL, output: URL) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "--mix",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            "-r", "127",
            input.path,
            output.path
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let processState = ASRAudioConversionProcessState()
        try process.run()
        processState.install(process)

        let terminationStatus: Int32
        do {
            terminationStatus = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Int32.self) { group in
                    group.addTask(priority: .utility) {
                        processState.waitUntilExit()
                    }
                    group.addTask {
                        try await Task.sleep(
                            nanoseconds: UInt64(conversionTimeoutSeconds * 1_000_000_000)
                        )
                        processState.terminate()
                        throw ASRAudioSupportError.timeout(seconds: conversionTimeoutSeconds)
                    }
                    group.addTask(priority: .utility) {
                        while true {
                            try await Task.sleep(nanoseconds: 50_000_000)
                            let byteCount = Self.fileByteCount(output)
                            guard byteCount <= maximumCanonicalWAVBytes else {
                                processState.terminate()
                                throw ASRAudioSupportError.audioConversionFailed(
                                    "Converted WAV exceeds the \(maximumCanonicalWAVBytes)-byte limit"
                                )
                            }
                        }
                    }
                    guard let status = try await group.next() else {
                        throw ASRAudioSupportError.audioConversionFailed("afconvert did not return a status")
                    }
                    group.cancelAll()
                    return status
                }
            } onCancel: {
                processState.terminate()
            }
        } catch {
            processState.terminate()
            throw error
        }

        guard terminationStatus == 0 else {
            throw ASRAudioSupportError.audioConversionFailed("afconvert exited with \(terminationStatus)")
        }

        let byteCount = fileByteCount(output)
        guard byteCount > 44 else {
            throw ASRAudioSupportError.audioConversionFailed("Converted WAV contains no audio data")
        }
        guard byteCount <= maximumCanonicalWAVBytes else {
            throw ASRAudioSupportError.audioConversionFailed(
                "Converted WAV exceeds the \(maximumCanonicalWAVBytes)-byte limit"
            )
        }
    }

    private static func fileByteCount(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func isASRReadyWAV(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "wav",
              let file = try? AVAudioFile(forReading: url)
        else { return false }
        let format = file.fileFormat
        return format.channelCount == 1 && abs(format.sampleRate - 16_000) < 1
    }
}

private actor ASRAudioConversionLimiter {
    private let maximumPermits: Int
    private var availablePermits: Int

    init(maxConcurrentConversions: Int) {
        let limit = max(1, maxConcurrentConversions)
        maximumPermits = limit
        availablePermits = limit
    }

    func acquire() async throws {
        while availablePermits == 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        availablePermits -= 1
    }

    func release() {
        availablePermits = min(maximumPermits, availablePermits + 1)
    }
}

private final class ASRAudioConversionProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func waitUntilExit() -> Int32 {
        lock.lock()
        let current = process
        lock.unlock()
        guard let current else { return -1 }
        current.waitUntilExit()
        let status = current.terminationStatus
        lock.lock()
        if process === current {
            process = nil
        }
        lock.unlock()
        return status
    }

    func terminate() {
        lock.lock()
        guard let current = process, current.isRunning else {
            lock.unlock()
            return
        }
        let processID = current.processIdentifier
        current.terminate()
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.forceTerminateIfStillRunning(processID: processID)
        }
    }

    private func forceTerminateIfStillRunning(processID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = process,
              current.processIdentifier == processID,
              current.isRunning
        else { return }
        Darwin.kill(processID, SIGKILL)
    }
}
