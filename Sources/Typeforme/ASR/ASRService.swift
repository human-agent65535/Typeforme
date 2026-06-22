import Foundation

struct ASRTranscription: Sendable {
    /// Representative transcript for UI display and raw-commit recovery.
    /// Correction uses `hypotheses` so no ASR source is treated as primary.
    let text: String
    let hypotheses: [String]
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
        self.alternateTranscripts = alternateTranscripts
        self.modelOutputs = modelOutputs
        self.warnings = warnings
    }

    var warningText: String? {
        let cleaned = warnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }
}

struct ASRTranscriptModelOutput: Sendable {
    let role: String
    let provider: String
    let model: String
    let status: String
    let text: String?
    let error: String?
}

/// Recognition sources return final text for an audio file. Live partial preview is
/// handled outside this protocol.
protocol ASRService: Sendable {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String
    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription
}

extension ASRService {
    func transcribeResult(audioFileURL: URL, languageIDs: [String]) async throws -> ASRTranscription {
        ASRTranscription(
            text: try await transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
        )
    }
}
