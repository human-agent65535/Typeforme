import Foundation
import Testing
@testable import Typeforme

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
}
