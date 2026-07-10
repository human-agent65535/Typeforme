@preconcurrency import AVFoundation
import Darwin
import Foundation

final class NvidiaNemotronLivePreviewSession: ASRLivePreviewSession, @unchecked Sendable {
    static let providerID = "nvidia-nemotron-asr"
    private static let outputSampleRate = 16_000.0
    private static let stdinChunkSampleCount = 8_960
    private static let finishMarkerBits: UInt32 = 0x7FC0_1001
    private static let cancelMarkerBits: UInt32 = 0x7FC0_1002
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
    private var diagnosticID: String
    private var onTranscript: (String) -> Void
    private let audioQueue = DispatchQueue(label: "typeforme.nvidia-nemotron.live-preview.audio")
    private let lock = NSLock()
    private var startedAt = Date()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var inputClosed = false
    private var cleanedUp = false
    private var processTerminated = false
    private var ready = false
    private var finalEventReceived = false
    private var resetEventReceived = false
    private var terminationContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var finalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var resetContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var decodedChunkContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var lastTranscript: String?
    private var converter: AVAudioConverter?
    private var converterInputSampleRate = 0.0
    private var inputSampleCount = 0
    private var nextInputLogSampleCount = 16_000
    private var firstInputWriteLogged = false
    private var stdoutEventCount = 0
    private var firstStdoutEventLogged = false

    var provider: String { Self.providerID }

    private struct SessionLogSnapshot {
        let logID: String
        let inputAudioMS: Int
        let startedAt: Date
    }

    static func start(
        languageIDs: [String],
        diagnosticID: String = UUID().uuidString,
        onTranscript: @escaping (String) -> Void
    ) throws -> NvidiaNemotronLivePreviewSession {
        let supportedLanguageIDs = ASRLanguageSelection.effectiveIDs(languageIDs, for: .nvidiaNemotron)
        guard !supportedLanguageIDs.isEmpty else {
            throw ASRAudioSupportError.httpStatus(
                422,
                "NVIDIA Nemotron ASR does not support the selected live preview languages"
            )
        }
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
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
        do {
            try process.run()
            let snapshot = session.sessionLogSnapshot()
            Log.asr.notice(
                "Nemotron live preview process started session=\(snapshot.logID, privacy: .public) languages=\(supportedLanguageIDs.joined(separator: ","), privacy: .public)"
            )
            return session
        } catch {
            session.terminate(reason: "start_failed")
            throw error
        }
    }

    private init(
        process: Process,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        modelDirURL: URL,
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.modelDirURL = modelDirURL
        self.diagnosticID = diagnosticID
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
        closeInputImmediately()
        if process.isRunning {
            process.terminate()
        } else {
            drainRemainingOutput()
        }
        resumeTerminationWaiters()
        cleanup()
    }

    var isRunning: Bool {
        lock.lock()
        let wasCleanedUp = cleanedUp
        lock.unlock()
        return process.isRunning && !wasCleanedUp
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    static func isDecodedChunkLog(_ message: String) -> Bool {
        message.hasPrefix("typeforme-nemotron-asr stream chunk=")
    }

    func warmUpWithDecodedSilence(timeout: TimeInterval) async -> Bool {
        let snapshot = sessionLogSnapshot()
        Log.asr.notice(
            "Nemotron live preview warmup start session=\(snapshot.logID, privacy: .public)"
        )
        let decoded = await waitForNextDecodedChunk(timeout: timeout) {
            self.writeSilenceChunkForWarmup()
        }
        guard decoded else {
            Log.asr.notice(
                "Nemotron live preview warmup decode timeout session=\(snapshot.logID, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
            )
            return false
        }
        let reset = await cancelInputAndWaitForReset(timeout: timeout)
        let completed = decoded && reset
        Log.asr.notice(
            "Nemotron live preview warmup finished session=\(snapshot.logID, privacy: .public) reset=\(reset, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
        )
        return completed
    }

    func prepareForUse(
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) {
        audioQueue.sync {
            resetConverterOnAudioQueue()
        }
        lock.lock()
        self.diagnosticID = diagnosticID
        self.onTranscript = onTranscript
        startedAt = Date()
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)
        inputClosed = false
        finalEventReceived = false
        resetEventReceived = false
        lastTranscript = nil
        inputSampleCount = 0
        nextInputLogSampleCount = 16_000
        firstInputWriteLogged = false
        stdoutEventCount = 0
        firstStdoutEventLogged = false
        lock.unlock()
    }

    func prepareForIdle(diagnosticID: String) {
        lock.lock()
        inputClosed = true
        lock.unlock()

        audioQueue.sync {
            resetConverterOnAudioQueue()
        }

        lock.lock()
        self.diagnosticID = diagnosticID
        self.onTranscript = { _ in }
        startedAt = Date()
        finalEventReceived = false
        resetEventReceived = false
        lastTranscript = nil
        inputSampleCount = 0
        nextInputLogSampleCount = 16_000
        firstInputWriteLogged = false
        stdoutEventCount = 0
        firstStdoutEventLogged = false
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = Self.copyBuffer(buffer) else { return }
        let item = SendablePCMBuffer(copied)
        audioQueue.async { [weak self, item] in
            self?.appendOnAudioQueue(item.buffer)
        }
    }

    func appendAudioFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let framesPerRead: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: framesPerRead
            ) else {
                throw ASRAudioSupportError.audioConversionFailed("Could not allocate Nemotron audio buffer")
            }
            let remaining = AVAudioFrameCount(min(Int64(framesPerRead), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            append(buffer)
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
            guard self.markInputClosed() else { return }
            let snapshot = self.sessionLogSnapshot()
            Log.asr.notice(
                "Nemotron live preview finish requested session=\(snapshot.logID, privacy: .public) input_audio_ms=\(snapshot.inputAudioMS, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
            )
            self.writeControlMarker(Self.finishMarkerBits)
        }
    }

    func finishInputAndWaitForFinal(timeout: TimeInterval) async -> Bool {
        finishInput()
        return await withTaskCancellationHandler {
            await waitForFinal(timeout: timeout)
        } onCancel: {
            self.terminate(reason: "asr_task_cancelled")
        }
    }

    func currentTranscript() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTranscript
    }

    func cancel() {
        terminate(reason: "cancel")
    }

    func cancelInputAndWaitForReset(timeout: TimeInterval) async -> Bool {
        audioQueue.async {
            guard self.markInputClosed() else { return }
            let snapshot = self.sessionLogSnapshot()
            Log.asr.notice(
                "Nemotron live preview reset requested session=\(snapshot.logID, privacy: .public) input_audio_ms=\(snapshot.inputAudioMS, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
            )
            self.writeControlMarker(Self.cancelMarkerBits)
        }
        return await waitForReset(timeout: timeout)
    }

    func terminate(reason: String = "terminate") {
        let snapshot = sessionLogSnapshot()
        Log.asr.notice(
            "Nemotron live preview terminate session=\(snapshot.logID, privacy: .public) reason=\(reason, privacy: .public) input_audio_ms=\(snapshot.inputAudioMS, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
        )
        closeInputImmediately()
        if process.isRunning {
            process.terminate()
        }
        // Termination means no future final/reset event can be consumed. Wake
        // callers immediately instead of making a cancelled task wait for the
        // helper or its full ASR timeout.
        resumeFinalWaiters(success: false)
        resumeResetWaiters(success: false)
        resumeDecodedChunkWaiters(success: false)
    }

    /// Terminates an owned helper and waits for it to exit. The SIGKILL
    /// escalation is reserved for process-wide teardown, where returning while
    /// the helper is still alive would orphan it after Typeforme exits.
    func terminateAndWait(reason: String, timeout: TimeInterval = 2) async {
        terminate(reason: reason)
        let terminated = await waitForTermination(timeout: timeout)
        guard !terminated else { return }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        Log.asr.notice("Nemotron helper didn't exit on SIGTERM; SIGKILL pid=\(pid)")
        _ = kill(pid, SIGKILL)
        _ = await waitForTermination(timeout: 1)
    }

    private func appendOnAudioQueue(_ buffer: AVAudioPCMBuffer) {
        guard isInputOpen, process.isRunning else { return }
        guard let mono = Self.makeMonoBuffer(from: buffer),
              let output = resample(mono),
              let samples = output.floatChannelData?[0]
        else { return }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }

        let data = Self.littleEndianFloatData(samples: samples, count: frameCount)
        writePCMDataToStdin(data, sampleCount: frameCount)
    }

    private func appendPCM16kMonoFloat32DataOnAudioQueue(_ data: Data) {
        guard isInputOpen, process.isRunning else { return }
        writePCMDataToStdin(data, sampleCount: data.count / MemoryLayout<Float>.size)
    }

    private func writeSilenceChunkForWarmup() {
        let data = Data(count: Self.stdinChunkSampleCount * MemoryLayout<Float>.size)
        audioQueue.async { [weak self, data] in
            guard let self, self.isInputOpen, self.process.isRunning else { return }
            self.writePCMDataToStdin(data, sampleCount: Self.stdinChunkSampleCount)
        }
    }

    private func writePCMDataToStdin(_ data: Data, sampleCount: Int) {
        let writeStartedAt = Date()
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            recordInputWrite(byteCount: data.count, sampleCount: sampleCount, writeMS: Self.elapsedMS(since: writeStartedAt))
        } catch {
            closeInputImmediately()
            Log.asr.notice("Nemotron live preview stdin write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordInputWrite(byteCount: Int, sampleCount: Int, writeMS: Int) {
        let log: (snapshot: SessionLogSnapshot, isFirst: Bool)?
        lock.lock()
        inputSampleCount += sampleCount
        let shouldLog = !firstInputWriteLogged
            || inputSampleCount >= nextInputLogSampleCount
            || writeMS >= 100
        if shouldLog {
            let isFirst = !firstInputWriteLogged
            firstInputWriteLogged = true
            while inputSampleCount >= nextInputLogSampleCount {
                nextInputLogSampleCount += 16_000
            }
            log = (currentSessionLogSnapshotLocked(), isFirst)
        } else {
            log = nil
        }
        lock.unlock()
        guard let log else { return }
        Log.asr.debug(
            "Nemotron live preview stdin write session=\(log.snapshot.logID, privacy: .public) first=\(log.isFirst, privacy: .public) bytes=\(byteCount, privacy: .public) input_audio_ms=\(log.snapshot.inputAudioMS, privacy: .public) write_ms=\(writeMS, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: log.snapshot.startedAt), privacy: .public)"
        )
    }

    private var isInputOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !inputClosed
    }

    private func markInputClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inputClosed else { return false }
        inputClosed = true
        return true
    }

    private func closeInputImmediately() {
        var shouldClose = false
        lock.lock()
        if !inputClosed {
            inputClosed = true
            shouldClose = true
        }
        lock.unlock()
        if shouldClose {
            try? stdinPipe.fileHandleForWriting.close()
        }
    }

    private func writeControlMarker(_ bits: UInt32) {
        var littleEndian = bits.littleEndian
        let data = Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            closeInputImmediately()
            Log.asr.notice("Nemotron live preview control write failed: \(error.localizedDescription, privacy: .public)")
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
            guard let payload = Self.parseTranscriptEvent(line) else { continue }
            let snapshot: SessionLogSnapshot
            let eventCount: Int
            let isFirst: Bool
            lock.lock()
            stdoutEventCount += 1
            eventCount = stdoutEventCount
            isFirst = !firstStdoutEventLogged
            firstStdoutEventLogged = true
            snapshot = currentSessionLogSnapshotLocked()
            lock.unlock()
            Log.asr.debug(
                "Nemotron live preview stdout session=\(snapshot.logID, privacy: .public) event=\(payload.event ?? "unknown", privacy: .public) first=\(isFirst, privacy: .public) event_count=\(eventCount, privacy: .public) text_chars=\(payload.text?.count ?? 0, privacy: .public) input_audio_ms=\(snapshot.inputAudioMS, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
            )
            if let text = payload.text, !text.isEmpty {
                recordTranscript(text)
                transcriptHandler()(text)
            }
            switch payload.event {
            case "final":
                resumeFinalWaiters(success: true)
            case "cancelled":
                resumeResetWaiters(success: true)
            default:
                break
            }
        }
    }

    private func handleStderr(_ data: Data) {
        let lines = appendAndExtractLines(data, into: &stderrBuffer)
        for line in lines {
            guard let message = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty
            else { continue }
            Log.asr.notice(
                "Nemotron live preview stderr \(NvidiaNemotronHelperLogSanitizer.publicStderrLineSummary(message), privacy: .public)"
            )
            if message.hasPrefix("typeforme-nemotron-asr ready ") {
                lock.lock()
                ready = true
                lock.unlock()
            }
            if Self.isDecodedChunkLog(message) {
                resumeDecodedChunkWaiters(success: true)
            }
        }
    }

    private func waitForNextDecodedChunk(
        timeout: TimeInterval,
        afterRegistering action: @escaping () -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterID = UUID()
            var shouldResumeImmediately = false
            lock.lock()
            if processTerminated || !process.isRunning {
                shouldResumeImmediately = true
            } else {
                decodedChunkContinuations[waiterID] = continuation
            }
            lock.unlock()

            if shouldResumeImmediately {
                continuation.resume(returning: false)
                return
            }

            action()

            let timeoutMilliseconds = Int((max(0, timeout) * 1_000).rounded(.up))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak self] in
                guard let self else { return }
                let timedOutContinuation: CheckedContinuation<Bool, Never>?
                self.lock.lock()
                timedOutContinuation = self.decodedChunkContinuations.removeValue(forKey: waiterID)
                self.lock.unlock()
                timedOutContinuation?.resume(returning: false)
            }
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
            if processTerminated {
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

    private func waitForFinal(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterID = UUID()
            var immediateResult: Bool?
            lock.lock()
            if finalEventReceived {
                immediateResult = true
            } else if processTerminated || !process.isRunning {
                immediateResult = false
            } else {
                finalContinuations[waiterID] = continuation
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(returning: immediateResult)
                return
            }

            let timeoutMilliseconds = Int((max(0, timeout) * 1_000).rounded(.up))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak self] in
                guard let self else { return }
                let timedOutContinuation: CheckedContinuation<Bool, Never>?
                self.lock.lock()
                timedOutContinuation = self.finalContinuations.removeValue(forKey: waiterID)
                self.lock.unlock()
                timedOutContinuation?.resume(returning: false)
            }
        }
    }

    private func waitForReset(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterID = UUID()
            var immediateResult: Bool?
            lock.lock()
            if resetEventReceived {
                immediateResult = true
            } else if processTerminated || !process.isRunning {
                immediateResult = false
            } else {
                resetContinuations[waiterID] = continuation
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(returning: immediateResult)
                return
            }

            let timeoutMilliseconds = Int((max(0, timeout) * 1_000).rounded(.up))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak self] in
                guard let self else { return }
                let timedOutContinuation: CheckedContinuation<Bool, Never>?
                self.lock.lock()
                timedOutContinuation = self.resetContinuations.removeValue(forKey: waiterID)
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

    private func transcriptHandler() -> (String) -> Void {
        lock.lock()
        let handler = onTranscript
        lock.unlock()
        return handler
    }

    private func handleProcessTermination() {
        let snapshot = sessionLogSnapshot()
        Log.asr.notice(
            "Nemotron live preview process terminated session=\(snapshot.logID, privacy: .public) input_audio_ms=\(snapshot.inputAudioMS, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: snapshot.startedAt), privacy: .public)"
        )
        drainRemainingOutput()
        resumeFinalWaiters(success: false)
        resumeResetWaiters(success: false)
        resumeDecodedChunkWaiters(success: false)
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

    private func resumeFinalWaiters(success: Bool) {
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        if success {
            finalEventReceived = true
        }
        continuations = Array(finalContinuations.values)
        finalContinuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: success)
        }
    }

    private func resumeResetWaiters(success: Bool) {
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        if success {
            resetEventReceived = true
        }
        continuations = Array(resetContinuations.values)
        resetContinuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: success)
        }
    }

    private func resumeDecodedChunkWaiters(success: Bool) {
        let continuations: [CheckedContinuation<Bool, Never>]
        lock.lock()
        continuations = Array(decodedChunkContinuations.values)
        decodedChunkContinuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: success)
        }
    }

    private func drainRemainingOutput() {
        lock.lock()
        let shouldDrain = !cleanedUp
        lock.unlock()
        guard shouldDrain else { return }

        drainAvailableData(from: stdoutPipe.fileHandleForReading, handler: handleStdout)
        drainAvailableData(from: stderrPipe.fileHandleForReading, handler: handleStderr)
    }

    private func drainAvailableData(from handle: FileHandle, handler: (Data) -> Void) {
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { return }
            handler(data)
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

    private func resetConverterOnAudioQueue() {
        converter = nil
        converterInputSampleRate = 0
    }

    private func sessionLogSnapshot() -> SessionLogSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSessionLogSnapshotLocked()
    }

    private func currentSessionLogSnapshotLocked() -> SessionLogSnapshot {
        SessionLogSnapshot(
            logID: String(diagnosticID.prefix(8)),
            inputAudioMS: inputSampleCount * 1_000 / 16_000,
            startedAt: startedAt
        )
    }

    private static func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private static func parseTranscriptEvent(_ line: Data) -> ParsedLivePreviewEvent? {
        guard !line.isEmpty,
              let payload = try? BridgeJSON.decode(NvidiaNemotronLivePreviewPayload.self, from: line)
        else { return nil }
        let cleaned = payload.textValue.map(ASRAudioSupport.cleanTranscriptText)
        guard payload.event != nil || cleaned?.isEmpty == false else { return nil }
        return ParsedLivePreviewEvent(
            text: cleaned?.isEmpty == true ? nil : cleaned,
            event: payload.event
        )
    }
}

private final class SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct NvidiaNemotronLivePreviewPayload: Decodable {
    let event: String?
    let text: String?
    let transcript: String?
    let transcription: String?

    var textValue: String? {
        text ?? transcript ?? transcription
    }
}

private struct ParsedLivePreviewEvent {
    let text: String?
    let event: String?
}
