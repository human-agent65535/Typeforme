import Foundation

struct ASRTranscription: Sendable {
    let text: String
    let alternateTranscripts: [String]
    let warnings: [String]

    init(
        text: String,
        alternateTranscripts: [String] = [],
        warnings: [String] = []
    ) {
        self.text = text
        self.alternateTranscripts = alternateTranscripts
        self.warnings = warnings
    }

    var warningText: String? {
        let cleaned = warnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }
}

/// ASR providers return final text for an audio file. Live partial preview is
/// handled outside this protocol.
/// Conforming types are used only from the main actor (coordinator), so this
/// protocol doesn't require Sendable conformance.
protocol ASRService {
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
