import Foundation
import Testing
@testable import Typeforme

@Suite("CommandLineHandler")
@MainActor
struct CommandLineHandlerTests {
    @Test func debugTranscribeCleansHelpersAfterSuccess() async throws {
        let request = try #require(DebugTranscribeCommand(arguments: [
            "--debug-transcribe", "/tmp/input.wav",
        ]))
        let probe = DebugTranscribeLifecycleProbe()

        let execution = await CommandLineHandler.executeDebugTranscribe(
            request,
            provider: "qwen3-asr-llama",
            languageIDs: ["en-US"],
            transcribe: { _, _ in
                await probe.record("transcribe")
                return "hello"
            },
            cleanup: {
                await probe.record("cleanup")
            }
        )

        #expect(execution.exitCode == 0)
        #expect(!execution.writesToStandardError)
        #expect(execution.payload.ok)
        #expect(execution.payload.transcript == "hello")
        #expect(await probe.snapshot() == ["transcribe", "cleanup"])
    }

    @Test func debugTranscribeCleansHelpersAfterFailure() async throws {
        let request = try #require(DebugTranscribeCommand(arguments: [
            "--debug-transcribe", "/tmp/input.wav",
        ]))
        let probe = DebugTranscribeLifecycleProbe()

        let execution = await CommandLineHandler.executeDebugTranscribe(
            request,
            provider: "nvidia-nemotron-asr",
            languageIDs: ["en-US"],
            transcribe: { _, _ in
                await probe.record("transcribe")
                throw DebugTranscribeStubError()
            },
            cleanup: {
                await probe.record("cleanup")
            }
        )

        #expect(execution.exitCode == 2)
        #expect(execution.writesToStandardError)
        #expect(!execution.payload.ok)
        #expect(execution.payload.error == "stub failure")
        #expect(await probe.snapshot() == ["transcribe", "cleanup"])
    }
}

private actor DebugTranscribeLifecycleProbe {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private struct DebugTranscribeStubError: LocalizedError {
    var errorDescription: String? { "stub failure" }
}
