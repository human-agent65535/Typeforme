import Foundation

/// ASR providers return final text for an audio file. Live partial preview is
/// handled outside this protocol.
/// Conforming types are used only from the main actor (coordinator), so this
/// protocol doesn't require Sendable conformance.
protocol ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String
}
