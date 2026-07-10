import Foundation
import Testing
@testable import Typeforme

private actor RuntimeActivationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeCompletionCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@Suite("Corrector runtime lifecycle")
struct CorrectorRuntimeLifecycleTests {
    @Test func everyLaunchSettingParticipatesInRuntimeReuse() {
        func configuration(
            kind: CorrectionBackendKind = .qwen35_4B,
            modelPath: String = "/models/qwen-4b.gguf",
            binaryPath: String = "/app/llama-server",
            pidFilePath: String = "/tmp/typeforme-llama.pid",
            contextSize: Int = 4_096,
            useFlashAttention: Bool = true,
            coldTimeoutMilliseconds: Int = 30_000
        ) -> CorrectorLlamaRuntimeConfiguration {
            CorrectorLlamaRuntimeConfiguration(
                kind: kind,
                modelPath: modelPath,
                binaryPath: binaryPath,
                pidFilePath: pidFilePath,
                contextSize: contextSize,
                useFlashAttention: useFlashAttention,
                coldTimeoutMilliseconds: coldTimeoutMilliseconds
            )
        }

        let baseline = configuration()
        #expect(baseline == configuration())
        let changedConfigurations = [
            configuration(kind: .qwen35_9B),
            configuration(modelPath: "/models/qwen-9b.gguf"),
            configuration(binaryPath: "/other/llama-server"),
            configuration(pidFilePath: "/tmp/other.pid"),
            configuration(contextSize: 8_192),
            configuration(useFlashAttention: false),
            configuration(coldTimeoutMilliseconds: 60_000),
        ]
        for changed in changedConfigurations {
            #expect(changed != baseline)
        }
    }

    @Test func retiredManagerCannotBeRestartedByStaleService() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = LlamaCppServerManager(
            modelPath: root.appendingPathComponent("missing-model.gguf").path,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: root.appendingPathComponent("missing-llama-server"),
            pidFile: root.appendingPathComponent("llama.pid")
        )

        await manager.retire()
        do {
            _ = try await manager.ensureRunning()
            Issue.record("A retired manager unexpectedly restarted")
        } catch let error as LlamaServerError {
            guard case .retired = error else {
                Issue.record("Expected retired error, got \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Expected LlamaServerError.retired, got \(error)")
        }
    }

    @Test func concurrentStartsShareActivationBarrier() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = RuntimeActivationGate()
        let barrier = Task {
            await gate.wait()
        }
        let manager = LlamaCppServerManager(
            modelPath: root.appendingPathComponent("missing-model.gguf").path,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: root.appendingPathComponent("missing-llama-server"),
            pidFile: root.appendingPathComponent("llama.pid"),
            activationBarrier: barrier
        )
        let completions = RuntimeCompletionCounter()
        let attempts = (0..<8).map { _ in
            Task {
                do {
                    _ = try await manager.ensureRunning()
                } catch {
                    // The fixture intentionally has no binary. Completion is
                    // expected only after the activation barrier opens.
                }
                await completions.record()
            }
        }

        for _ in 0..<4 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let completedBeforeBarrier = await completions.value()
        #expect(completedBeforeBarrier == 0)

        await gate.open()
        for attempt in attempts {
            await attempt.value
        }
        let completedAfterBarrier = await completions.value()
        #expect(completedAfterBarrier == attempts.count)
    }
}
