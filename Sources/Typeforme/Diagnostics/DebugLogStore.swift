import Foundation

struct DebugLogHandle: Sendable {
    let id: String
    let directory: URL
}

private actor DebugLogDiskWriter {
    static let shared = DebugLogDiskWriter()

    private static let recordFileName = "record.json"

    func saveReceivedAudio(_ source: URL, for handle: DebugLogHandle) {
        do {
            let filename = try Self.copyAudio(source, in: handle.directory)
            update(handle) { record in
                record.audioFile = filename
                record.audioCopyError = nil
            }
        } catch {
            let message = error.localizedDescription
            update(handle) { record in
                record.audioCopyError = message
            }
        }
    }

    func recordTranscript(_ transcript: DebugLogTranscript, for handle: DebugLogHandle) {
        update(handle) { record in
            record.transcript = transcript
        }
    }

    func recordCorrection(_ correction: DebugLogCorrection, for handle: DebugLogHandle) {
        update(handle) { record in
            record.correction = correction
        }
    }

    func recordTextEdit(_ textEdit: DebugLogTextEdit, for handle: DebugLogHandle) {
        update(handle) { record in
            record.textEdit = textEdit
        }
    }

    func prune(limit: Int) {
        let items = Self.entries()
        for url in items.dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func update(
        _ handle: DebugLogHandle,
        _ body: (inout DebugLogRecord) -> Void
    ) {
        do {
            var record = try Self.read(in: handle.directory)
            body(&record)
            try Self.write(record, in: handle.directory)
        } catch {
            Log.store.error("debug capture update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func read(in directory: URL) throws -> DebugLogRecord {
        let data = try Data(contentsOf: directory.appendingPathComponent(recordFileName))
        return try BridgeJSON.decode(DebugLogRecord.self, from: data)
    }

    private static func copyAudio(_ source: URL, in directory: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let filename = "audio.\(ext)"
        let destination = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return filename
    }

    private static func write(_ record: DebugLogRecord, in directory: URL) throws {
        let data = try BridgeJSON.encodePrettySorted(record)
        try data.write(to: directory.appendingPathComponent(recordFileName), options: .atomic)
    }

    private static func entries() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.debugCapturesDir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return leftDate > rightDate
            }
    }
}

private struct DebugLogTranscript: Codable, Sendable {
    var status: String
    var text: String?
    var error: String?
    var latencyMs: Int?
    var provider: String?
    var model: String?
    var maxTokens: Int?
    var modelOutputs: [DebugLogTranscriptModelOutput]?
    /// Supplementary transcripts sent to the corrector alongside `text`.
    /// This can include additional recognition source output and live preview text.
    var alternateTranscripts: [String]?

    enum CodingKeys: String, CodingKey {
        case status
        case text
        case error
        case latencyMs = "latency_ms"
        case provider
        case model
        case maxTokens = "max_tokens"
        case modelOutputs = "model_outputs"
        case alternateTranscripts = "alternate_transcripts"
    }
}

private struct DebugLogTranscriptModelOutput: Codable, Sendable {
    var role: String
    var provider: String
    var model: String
    var status: String
    var text: String?
    var error: String?
}

private struct DebugLogCorrection: Codable, Sendable {
    var correctionMode: String
    var backend: String
    var model: String
    var maxTokens: Int
    var timeoutMs: Int?
    var status: String
    var text: String?
    var error: String?
    var latencyMs: Int?
    var input: DebugLogCorrectionInput?

    enum CodingKeys: String, CodingKey {
        case correctionMode = "correction_mode"
        case backend
        case model
        case maxTokens = "max_tokens"
        case timeoutMs = "timeout_ms"
        case status
        case text
        case error
        case latencyMs = "latency_ms"
        case input
    }
}

private struct DebugLogCorrectionInput: Codable, Sendable {
    var rawTranscript: String
    var contextBefore: String
    var contextAfter: String
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var appCategory: String
    var languageIDs: [String]
    var numberOutputPreference: String
    var punctuationPreference: String
    var userDictionaryCount: Int
    var rawTranscriptChars: Int
    var contextBeforeChars: Int
    var contextAfterChars: Int

    enum CodingKeys: String, CodingKey {
        case rawTranscript = "raw_transcript"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case frontmostAppName = "frontmost_app_name"
        case frontmostBundleID = "frontmost_bundle_id"
        case appCategory = "app_category"
        case languageIDs = "language_ids"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case userDictionaryCount = "user_dictionary_count"
        case rawTranscriptChars = "raw_transcript_chars"
        case contextBeforeChars = "context_before_chars"
        case contextAfterChars = "context_after_chars"
    }
}

private struct DebugLogTextEdit: Codable, Sendable {
    var intent: String
    var backend: String
    var model: String
    var maxTokens: Int
    var timeoutMs: Int?
    var status: String
    var text: String?
    var error: String?
    var latencyMs: Int?
    var input: DebugLogTextEditInput?

    enum CodingKeys: String, CodingKey {
        case intent
        case backend
        case model
        case maxTokens = "max_tokens"
        case timeoutMs = "timeout_ms"
        case status
        case text
        case error
        case latencyMs = "latency_ms"
        case input
    }
}

private struct DebugLogTextEditInput: Codable, Sendable {
    var intent: String
    var contextBefore: String
    var targetText: String
    var contextAfter: String
    var spokenInstruction: String
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var appCategory: String
    var languageIDs: [String]
    var numberOutputPreference: String
    var punctuationPreference: String
    var userDictionaryCount: Int
    var contextBeforeChars: Int
    var targetTextChars: Int
    var contextAfterChars: Int
    var spokenInstructionChars: Int

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
        case frontmostAppName = "frontmost_app_name"
        case frontmostBundleID = "frontmost_bundle_id"
        case appCategory = "app_category"
        case languageIDs = "language_ids"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case userDictionaryCount = "user_dictionary_count"
        case contextBeforeChars = "context_before_chars"
        case targetTextChars = "target_text_chars"
        case contextAfterChars = "context_after_chars"
        case spokenInstructionChars = "spoken_instruction_chars"
    }
}

private struct DebugLogRecord: Codable, Sendable {
    var id: String
    var createdAt: String
    var source: String
    var audioFile: String?
    var audioCopyError: String?
    var recognitionSources: [String]
    var asrModel: String
    var asrMaxTokens: Int?
    var correctionBackend: String
    var correctionModel: String
    var correctionMaxTokens: Int
    var selectedCorrectionMode: String
    var languageIDs: [String]
    var transcript: DebugLogTranscript?
    var correction: DebugLogCorrection?
    var textEdit: DebugLogTextEdit?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case source
        case audioFile = "audio_file"
        case audioCopyError = "audio_copy_error"
        case recognitionSources = "recognition_sources"
        case asrModel = "asr_model"
        case asrMaxTokens = "asr_max_tokens"
        case correctionBackend = "correction_backend"
        case correctionModel = "correction_model"
        case correctionMaxTokens = "correction_max_tokens"
        case selectedCorrectionMode = "selected_correction_mode"
        case languageIDs = "language_ids"
        case transcript
        case correction
        case textEdit = "text_edit"
    }
}

@MainActor
enum DebugLogStore {
    private static let recordFileName = "record.json"
    private static let isoFormatter = ISO8601DateFormatter()

    static var isEnabled: Bool {
        AppSettings.diagnosticsDebugMode
    }

    static func begin(
        source: String,
        audioURL: URL?,
        selectedCorrectionMode: CorrectionMode,
        languageIDs: [String],
        appName _: String?,
        bundleID _: String?,
        appCategory _: AppCategory
    ) -> DebugLogHandle? {
        createCapture(
            source: source,
            audioURL: audioURL,
            selectedCorrectionMode: selectedCorrectionMode.rawValue,
            languageIDs: languageIDs,
            logLabel: "debug capture"
        )
    }

    static func beginTextEdit(
        source: String,
        intent: TextEditIntent,
        languageIDs: [String]
    ) -> DebugLogHandle? {
        createCapture(
            source: source,
            audioURL: nil,
            selectedCorrectionMode: "text_edit:\(intent.rawValue)",
            languageIDs: languageIDs,
            logLabel: "debug text edit capture"
        )
    }

    private static func createCapture(
        source: String,
        audioURL: URL?,
        selectedCorrectionMode: String,
        languageIDs: [String],
        logLabel: String
    ) -> DebugLogHandle? {
        guard isEnabled else { return nil }
        do {
            try AppPaths.ensureDirectories()
            let createdAt = isoFormatter.string(from: Date())
            let id = safeID(createdAt)
            let directory = AppPaths.debugCapturesDir.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let record = DebugLogRecord(
                id: id,
                createdAt: createdAt,
                source: source,
                audioFile: nil,
                audioCopyError: nil,
                recognitionSources: AppSettings.enabledRecognitionSources.map(\.rawValue),
                asrModel: activeASRModelDescription(),
                asrMaxTokens: activeASRMaxTokens(),
                correctionBackend: AppSettings.correctionBackend.rawValue,
                correctionModel: activeCorrectionModelDescription(),
                correctionMaxTokens: AppSettings.correctionMaxTokens,
                selectedCorrectionMode: selectedCorrectionMode,
                languageIDs: languageIDs,
                transcript: nil,
                correction: nil,
                textEdit: nil
            )
            try write(record, in: directory)
            if let audioURL {
                Task {
                    await DebugLogDiskWriter.shared.saveReceivedAudio(audioURL, for: DebugLogHandle(id: id, directory: directory))
                }
            }
            let captureLimit = AppSettings.diagnosticsDebugCaptureLimit
            Task {
                await DebugLogDiskWriter.shared.prune(limit: captureLimit)
            }
            Log.store.info("\(logLabel) started: \(id, privacy: .public)")
            return DebugLogHandle(id: id, directory: directory)
        } catch {
            Log.store.error("\(logLabel) start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func recordASR(
        _ handle: DebugLogHandle?,
        text: String?,
        status: String,
        error: String? = nil,
        latencyMs: Int? = nil,
        alternateTranscripts: [String] = [],
        modelOutputs: [ASRTranscriptModelOutput] = []
    ) {
        guard let handle else { return }
        let cleanedAlternates = normalizedTranscripts(alternateTranscripts)
        let cleanedModelOutputs = normalizedModelOutputs(modelOutputs)
        let transcript = DebugLogTranscript(
            status: status,
            text: text,
            error: error,
            latencyMs: latencyMs,
            provider: activeRecognitionSourceDescription(),
            model: activeASRModelDescription(),
            maxTokens: activeASRMaxTokens(),
            modelOutputs: cleanedModelOutputs.isEmpty ? nil : cleanedModelOutputs,
            alternateTranscripts: cleanedAlternates.isEmpty ? nil : cleanedAlternates
        )
        Task {
            await DebugLogDiskWriter.shared.recordTranscript(transcript, for: handle)
        }
    }

    static func recordCorrection(
        _ handle: DebugLogHandle?,
        mode: CorrectionMode,
        text: String?,
        status: String,
        error: String? = nil,
        latencyMs: Int? = nil,
        request: CorrectionRequest? = nil,
        timeoutMs: Int? = nil
    ) {
        guard let handle else { return }
        let correction = DebugLogCorrection(
            correctionMode: mode.rawValue,
            backend: AppSettings.correctionBackend.rawValue,
            model: activeCorrectionModelDescription(),
            maxTokens: AppSettings.correctionMaxTokens,
            timeoutMs: timeoutMs,
            status: status,
            text: text,
            error: error,
            latencyMs: latencyMs,
            input: request.map(correctionInput)
        )
        Task {
            await DebugLogDiskWriter.shared.recordCorrection(correction, for: handle)
        }
    }

    static func recordTextEdit(
        _ handle: DebugLogHandle?,
        intent: TextEditIntent,
        text: String?,
        status: String,
        error: String? = nil,
        latencyMs: Int? = nil,
        request: TextEditRequest? = nil,
        timeoutMs: Int? = nil
    ) {
        guard let handle else { return }
        let textEdit = DebugLogTextEdit(
            intent: intent.rawValue,
            backend: AppSettings.correctionBackend.rawValue,
            model: activeCorrectionModelDescription(),
            maxTokens: AppSettings.correctionMaxTokens,
            timeoutMs: timeoutMs,
            status: status,
            text: text,
            error: error,
            latencyMs: latencyMs,
            input: request.map(textEditInput)
        )
        Task {
            await DebugLogDiskWriter.shared.recordTextEdit(textEdit, for: handle)
        }
    }

    static func recentCount() -> Int {
        entries().count
    }

    static func clear() {
        do {
            if FileManager.default.fileExists(atPath: AppPaths.debugCapturesDir.path) {
                try FileManager.default.removeItem(at: AppPaths.debugCapturesDir)
            }
            try AppPaths.ensureDirectories()
        } catch {
            Log.store.error("debug capture clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func prune() {
        let items = entries()
        for url in items.dropFirst(AppSettings.diagnosticsDebugCaptureLimit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func correctionInput(_ request: CorrectionRequest) -> DebugLogCorrectionInput {
        DebugLogCorrectionInput(
            rawTranscript: request.rawTranscript,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            frontmostAppName: request.frontmostAppName,
            frontmostBundleID: request.frontmostBundleID,
            appCategory: request.appCategory.rawValue,
            languageIDs: request.languageIDs,
            numberOutputPreference: request.numberOutputPreference.rawValue,
            punctuationPreference: request.punctuationPreference.rawValue,
            userDictionaryCount: request.userDictionary.count,
            rawTranscriptChars: request.rawTranscript.count,
            contextBeforeChars: request.contextBefore.count,
            contextAfterChars: request.contextAfter.count
        )
    }

    private static func textEditInput(_ request: TextEditRequest) -> DebugLogTextEditInput {
        DebugLogTextEditInput(
            intent: request.intent.rawValue,
            contextBefore: request.contextBefore,
            targetText: request.targetText,
            contextAfter: request.contextAfter,
            spokenInstruction: request.spokenInstruction,
            frontmostAppName: request.frontmostAppName,
            frontmostBundleID: request.frontmostBundleID,
            appCategory: request.appCategory.rawValue,
            languageIDs: request.languageIDs,
            numberOutputPreference: request.numberOutputPreference.rawValue,
            punctuationPreference: request.punctuationPreference.rawValue,
            userDictionaryCount: request.userDictionary.count,
            contextBeforeChars: request.contextBefore.count,
            targetTextChars: request.targetText.count,
            contextAfterChars: request.contextAfter.count,
            spokenInstructionChars: request.spokenInstruction.count
        )
    }

    private static func normalizedTranscripts(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func normalizedModelOutputs(
        _ outputs: [ASRTranscriptModelOutput]
    ) -> [DebugLogTranscriptModelOutput] {
        outputs.compactMap { output in
            let text = cleanedOptionalText(output.text)
            let error = cleanedOptionalText(output.error)
            guard text != nil || error != nil else { return nil }
            return DebugLogTranscriptModelOutput(
                role: output.role,
                provider: output.provider,
                model: output.model,
                status: output.status,
                text: text,
                error: error
            )
        }
    }

    private static func cleanedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func write(_ record: DebugLogRecord, in directory: URL) throws {
        let data = try BridgeJSON.encodePrettySorted(record)
        try data.write(to: directory.appendingPathComponent(recordFileName), options: .atomic)
    }

    private static func entries() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.debugCapturesDir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return leftDate > rightDate
            }
    }

    private static func safeID(_ value: String) -> String {
        value
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .appending("-\(UUID().uuidString.prefix(8))")
    }

    private static func activeASRModelDescription() -> String {
        AppSettings.enabledRecognitionSources.map { source in
            switch source {
            case .qwen:
                return "qwen:\(AppSettings.asrQwenLlamaModelID)"
            case .nvidiaNemotron:
                return "nemotron:\(AppSettings.asrNvidiaNemotronModelID)"
            case .appleSpeech:
                return "apple-speech:on-device"
            }
        }
        .joined(separator: ", ")
    }

    private static func activeASRMaxTokens() -> Int? {
        AppSettings.enabledRecognitionSources.contains(.qwen) ? AppSettings.asrQwenLlamaMaxTokens : nil
    }

    private static func activeRecognitionSourceDescription() -> String {
        AppSettings.enabledRecognitionSources.map(\.rawValue).joined(separator: ",")
    }

    private static func activeCorrectionModelDescription() -> String {
        switch AppSettings.correctionBackend {
        case .qwen35_2B:
            return URL(fileURLWithPath: AppSettings.llama2BPath).lastPathComponent
        case .qwen35_4B:
            return URL(fileURLWithPath: AppSettings.llama4BPath).lastPathComponent
        case .qwen35_9B:
            return URL(fileURLWithPath: AppSettings.llama9BPath).lastPathComponent
        case .externalOpenAICompatible, .externalAnthropicCompatible:
            return AppSettings.externalLLMModel
        }
    }

}
