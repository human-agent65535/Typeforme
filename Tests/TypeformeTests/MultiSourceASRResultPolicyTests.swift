import Foundation
import Testing
@testable import Typeforme

@Suite("Multi-source ASR result policy")
struct MultiSourceASRResultPolicyTests {
    @Test func sourceCancellationCancelsTheCombinedRequest() async throws {
        let audioURL = try TestAudioFixtures.makeWAVFile(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let service = MultiSourceASRService(
            bindings: [
                ASRSourceBinding(
                    source: .qwen,
                    modelID: "qwen-test",
                    service: CancellingASRService()
                ),
                ASRSourceBinding(
                    source: .nvidiaNemotron,
                    modelID: "nvidia-test",
                    service: CancellingASRService()
                ),
            ],
            timeoutSeconds: 1
        )

        await #expect(throws: CancellationError.self) {
            try await service.transcribe(
                audioFileURL: audioURL,
                languageIDs: ["en-US"]
            )
        }
    }

    @Test func emptyAndUnsupportedSkipRemainABenignEmptyTranscript() {
        #expect(MultiSourceASRResultPolicy.shouldReturnEmptyTranscript(
            statuses: ["empty", "skipped_unsupported_language"]
        ))
    }

    @Test func allUnsupportedSkipsRemainAConfigurationError() {
        #expect(!MultiSourceASRResultPolicy.shouldReturnEmptyTranscript(
            statuses: ["skipped_unsupported_language", "skipped_unsupported_language"]
        ))
    }

    @Test func realErrorIsNotHiddenByAnEmptyAttempt() {
        #expect(!MultiSourceASRResultPolicy.shouldReturnEmptyTranscript(
            statuses: ["empty", "error"]
        ))
    }

    @Test func multipleActualEmptyAttemptsRemainBenign() {
        #expect(MultiSourceASRResultPolicy.shouldReturnEmptyTranscript(
            statuses: ["empty", "empty"]
        ))
    }
}

private struct CancellingASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        throw CancellationError()
    }
}
