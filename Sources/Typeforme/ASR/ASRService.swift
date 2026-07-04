import Foundation

struct ASRTranscription: Sendable {
    /// Representative transcript for UI display and raw-commit recovery.
    /// Correction uses `hypotheses` so no ASR source is treated as primary.
    let text: String
    let hypotheses: [String]
    let sourceHypotheses: [ASRSourceHypothesis]
    let alternateTranscripts: [String]
    let modelOutputs: [ASRTranscriptModelOutput]
    let warnings: [String]

    init(
        text: String,
        hypotheses: [String] = [],
        alternateTranscripts: [String] = [],
        modelOutputs: [ASRTranscriptModelOutput] = [],
        warnings: [String] = []
    ) {
        self.text = text
        self.hypotheses = CorrectionRequest.normalizedASRHypotheses(
            candidates: hypotheses.map(Optional.some)
                + [Optional.some(text)]
                + alternateTranscripts.map(Optional.some)
        )
        self.sourceHypotheses = ASRSourceHypothesis.fromModelOutputs(
            modelOutputs,
            fallbackTexts: self.hypotheses.map(Optional.some)
        )
        self.alternateTranscripts = alternateTranscripts
        self.modelOutputs = modelOutputs
        self.warnings = warnings
    }

    var warningText: String? {
        let cleaned = warnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !ASRAudioSupport.isBenignEmptyTranscriptMessage($0) }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }
}

struct ASRTranscriptionProgress: Sendable, Equatable {
    let completedSources: Int
    let totalSources: Int
    let source: RecognitionSource?

    var isMultiSource: Bool {
        totalSources > 1
    }
}

struct ASRTranscriptionSeed: Sendable, Equatable {
    let source: RecognitionSource
    let text: String

    var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUsable: Bool {
        !normalizedText.isEmpty
    }
}

typealias ASRTranscriptionProgressHandler = @Sendable (ASRTranscriptionProgress) async -> Void

struct ASRTranscriptModelOutput: Sendable {
    let role: String
    let provider: String
    let model: String
    let status: String
    let text: String?
    let error: String?
    let latencyMs: Int?

    init(
        role: String,
        provider: String,
        model: String,
        status: String,
        text: String?,
        error: String?,
        latencyMs: Int? = nil
    ) {
        self.role = role
        self.provider = provider
        self.model = model
        self.status = status
        self.text = text
        self.error = error
        self.latencyMs = latencyMs
    }
}

/// Recognition sources return final text for an audio file. Live partial preview is
/// handled outside this protocol.
protocol ASRService: Sendable {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String
    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription
    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription
}

extension ASRService {
    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        try await transcribeResult(audioFileURL: audioFileURL, languageIDs: languageIDs, progress: nil)
    }

    func transcribeResult(
        audioFileURL: URL,
        languageIDs: [String],
        progress: ASRTranscriptionProgressHandler?
    ) async throws -> ASRTranscription {
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 0, totalSources: 1, source: nil))
        }
        let text = try await transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        if let progress {
            await progress(ASRTranscriptionProgress(completedSources: 1, totalSources: 1, source: nil))
        }
        return ASRTranscription(
            text: text
        )
    }
}
