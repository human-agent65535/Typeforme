import Foundation
import Testing
@testable import Typeforme

private actor ASRSessionTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ASRSessionTestEvents {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@Suite("ASR session configuration")
struct ASRSessionConfigurationTests {
    private func qwenConfiguration(
        modelID: String = "qwen-a",
        modelPath: String = "/models/qwen-a.gguf",
        mmprojPath: String = "/models/qwen-a-mmproj.gguf",
        modelName: String = "qwen-a.gguf",
        requestTimeoutSeconds: TimeInterval = 42,
        maxTokens: Int = 1_024,
        useFlashAttention: Bool = true,
        binaryURL: URL? = URL(fileURLWithPath: "/app/llama-server"),
        warmupLanguageIDs: [String] = ["ja"],
        isInstalledAtCapture: Bool = true
    ) -> QwenLlamaASRConfiguration {
        QwenLlamaASRConfiguration(
            modelID: modelID,
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            modelName: modelName,
            requestTimeoutSeconds: requestTimeoutSeconds,
            maxTokens: maxTokens,
            useFlashAttention: useFlashAttention,
            binaryURL: binaryURL,
            warmupLanguageIDs: warmupLanguageIDs,
            modelFilesInstalledAtCapture: isInstalledAtCapture
        )
    }

    private func nvidiaConfiguration() -> NvidiaNemotronASRConfiguration {
        let spec = NvidiaNemotronASRModelCatalog
            .spec(for: NvidiaNemotronASRModelCatalog.defaultID)
        return NvidiaNemotronASRConfiguration(
            modelID: spec.id,
            requestTimeoutSeconds: 1,
            runtimeStatus: NvidiaNemotronASRRuntimeStatus(
                runnerURL: URL(fileURLWithPath: "/bin/sh"),
                runnerReady: true,
                modelFiles: spec.files.map {
                    NvidiaNemotronASRModelFileStatus(
                        spec: $0,
                        url: URL(fileURLWithPath: "/models/\($0.filename)"),
                        installed: true
                    )
                }
            )
        )
    }

    @Test @MainActor func factoryReturnsObservableSessionBoundSnapshot() throws {
        let qwen = qwenConfiguration(isInstalledAtCapture: false)
        let snapshot = ASRSessionConfiguration(
            sources: [.qwen, .appleSpeech],
            unifiedAttemptTimeoutSeconds: 42,
            appleSpeechAddsPunctuation: false,
            qwen: qwen,
            nvidiaNemotron: nil
        )

        let service = ASRFactory.shared.makeSessionService(
            configuration: snapshot,
            singleSource: false
        )
        let bound = try #require(service as? SessionBoundASRService)

        #expect(bound.configuration == snapshot)
        #expect(bound.configuration.qwen?.modelName == "qwen-a.gguf")
        #expect(bound.configuration.qwen?.requestTimeoutSeconds == 42)
        #expect(bound.configuration.qwen?.maxTokens == 1_024)
        #expect(!bound.configuration.appleSpeechAddsPunctuation)
    }

    @Test func appleSpeechPunctuationRequestBehaviorIsPureConfiguration() {
        #expect(ASRSessionConfiguration.appleSpeechAddsPunctuation(for: .normal))
        #expect(ASRSessionConfiguration.appleSpeechAddsPunctuation(for: .english))
        #expect(!ASRSessionConfiguration.appleSpeechAddsPunctuation(for: .spaces))

        let withPunctuation = AppleSpeechASRService(addsPunctuation: true)
        let withoutPunctuation = AppleSpeechASRService(addsPunctuation: false)
        #expect(withPunctuation.addsPunctuation)
        #expect(!withoutPunctuation.addsPunctuation)
    }

    @Test func qwenServerReuseSeparatesRuntimeFromSessionRequestSettings() {
        let baseline = qwenConfiguration()
        let runtimeChanges = [
            qwenConfiguration(modelID: "qwen-b"),
            qwenConfiguration(modelPath: "/models/qwen-b.gguf"),
            qwenConfiguration(mmprojPath: "/models/qwen-b-mmproj.gguf"),
            qwenConfiguration(useFlashAttention: false),
            qwenConfiguration(binaryURL: URL(fileURLWithPath: "/other/llama-server")),
        ]
        let requestChanges = [
            qwenConfiguration(modelName: "request-model-name"),
            qwenConfiguration(requestTimeoutSeconds: 84),
            qwenConfiguration(maxTokens: 2_048),
            qwenConfiguration(warmupLanguageIDs: ["en-US"]),
        ]

        for configuration in runtimeChanges {
            #expect(configuration.serverRuntimeReuseKey != baseline.serverRuntimeReuseKey)
        }
        for configuration in requestChanges {
            #expect(configuration.serverRuntimeReuseKey == baseline.serverRuntimeReuseKey)
        }
    }

    @Test func qwenRuntimeKeyChangesWhenModelIsReplacedAtTheSamePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-qwen-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("model.gguf")
        let mmproj = root.appendingPathComponent("mmproj.gguf")
        let binary = root.appendingPathComponent("llama-server")
        try Data("model-a".utf8).write(to: model)
        try Data("mmproj".utf8).write(to: mmproj)
        try Data("binary".utf8).write(to: binary)

        let original = qwenConfiguration(
            modelPath: model.path,
            mmprojPath: mmproj.path,
            binaryURL: binary,
            isInstalledAtCapture: true
        )
        try FileManager.default.removeItem(at: model)
        try Data("model-b-with-a-different-size".utf8).write(to: model)
        let replacement = qwenConfiguration(
            modelPath: model.path,
            mmprojPath: mmproj.path,
            binaryURL: binary,
            isInstalledAtCapture: true
        )

        #expect(original.modelPath == replacement.modelPath)
        #expect(original.serverRuntimeReuseKey != replacement.serverRuntimeReuseKey)
    }

    @Test @MainActor func qwenLivePreviewAcquisitionDistinguishesMissingModelAndRuntime() {
        let factory = ASRFactory()

        switch factory.qwenLlamaLivePreviewServiceLease(configuration: qwenConfiguration(
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            isInstalledAtCapture: false
        )) {
        case .acquired:
            Issue.record("Qwen live preview acquired a lease without its model files")
        case .unavailable(let reason):
            #expect(reason == .modelMissing)
            #expect(reason.message.contains("model is not installed"))
        }

        switch factory.qwenLlamaLivePreviewServiceLease(configuration: qwenConfiguration(
            binaryURL: nil,
            isInstalledAtCapture: true
        )) {
        case .acquired:
            Issue.record("Qwen live preview acquired a lease without llama-server")
        case .unavailable(let reason):
            #expect(reason == .runtimeMissing)
            #expect(reason.message.contains("llama-server binary not found"))
        }
    }

    @Test @MainActor func missingModelAtCaptureRemainsExplicitlyUnavailable() async throws {
        let qwen = qwenConfiguration(isInstalledAtCapture: false)
        let snapshot = ASRSessionConfiguration(
            sources: [.qwen],
            unifiedAttemptTimeoutSeconds: 42,
            appleSpeechAddsPunctuation: true,
            qwen: qwen,
            nvidiaNemotron: nil
        )
        let service = ASRFactory.shared.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )

        do {
            _ = try await service.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["ja"]
            )
            Issue.record("A session captured without its model unexpectedly transcribed")
        } catch let error as ASRAudioSupportError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("Expected an explicit HTTP availability error, got \(error.localizedDescription)")
                return
            }
            #expect(code == 503)
            #expect(detail.contains("not installed"))
        }
    }

    @Test @MainActor func missingNemotronRuntimeAtCaptureRemainsExplicitlyUnavailable() async {
        let spec = NvidiaNemotronASRModelCatalog
            .spec(for: NvidiaNemotronASRModelCatalog.defaultID)
            .files[0]
        let runtimeStatus = NvidiaNemotronASRRuntimeStatus(
            runnerURL: nil,
            runnerReady: false,
            modelFiles: [
                NvidiaNemotronASRModelFileStatus(
                    spec: spec,
                    url: URL(fileURLWithPath: "/missing/\(spec.filename)"),
                    installed: false
                )
            ]
        )
        let nvidia = NvidiaNemotronASRConfiguration(
            modelID: NvidiaNemotronASRModelCatalog.defaultID,
            requestTimeoutSeconds: 42,
            runtimeStatus: runtimeStatus
        )
        let snapshot = ASRSessionConfiguration(
            sources: [.nvidiaNemotron],
            unifiedAttemptTimeoutSeconds: 42,
            appleSpeechAddsPunctuation: true,
            qwen: nil,
            nvidiaNemotron: nvidia
        )
        let service = ASRFactory.shared.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )

        do {
            _ = try await service.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("A session captured without its Nemotron runtime unexpectedly transcribed")
        } catch let error as ASRAudioSupportError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("Expected an explicit HTTP availability error, got \(error.localizedDescription)")
                return
            }
            #expect(code == 503)
            #expect(detail.contains("runtime") || detail.contains("model"))
        } catch {
            Issue.record("Expected ASRAudioSupportError, got \(error)")
        }
    }

    @Test func shutdownPermanentlyRetiresQwenService() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-qwen-retired-\(UUID().uuidString)", isDirectory: true)
        let configuration = qwenConfiguration(
            modelPath: root.appendingPathComponent("missing-model.gguf").path,
            mmprojPath: root.appendingPathComponent("missing-mmproj.gguf").path,
            binaryURL: root.appendingPathComponent("missing-llama-server")
        )
        let manager = LlamaCppServerManager(
            modelPath: configuration.modelPath,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: configuration.binaryURL!,
            pidFile: root.appendingPathComponent("llama.pid")
        )
        let service = QwenLlamaASRService(server: manager, configuration: configuration)

        await service.shutdown()

        do {
            _ = try await service.transcribe(
                audioFileURL: root.appendingPathComponent("missing.wav"),
                languageIDs: ["ja"]
            )
            Issue.record("A retired Qwen service unexpectedly restarted")
        } catch let error as ASRAudioSupportError {
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("Expected retired service availability error, got \(error.localizedDescription)")
                return
            }
            #expect(code == 503)
            #expect(detail.contains("no longer active"))
        } catch {
            Issue.record("Expected ASRAudioSupportError, got \(error)")
        }
    }

    @Test @MainActor func newQwenRuntimeDoesNotRetireAnOlderSessionLease() async {
        let factory = ASRFactory()
        let firstConfiguration = qwenConfiguration(
            modelID: "leased-a",
            modelPath: "/missing/leased-a.gguf",
            mmprojPath: "/missing/leased-a-mmproj.gguf",
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            isInstalledAtCapture: true
        )
        let secondConfiguration = qwenConfiguration(
            modelID: "queued-b",
            modelPath: "/missing/queued-b.gguf",
            mmprojPath: "/missing/queued-b-mmproj.gguf",
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            isInstalledAtCapture: true
        )
        var firstService: (any ASRService)? = factory.makeSessionService(
            configuration: ASRSessionConfiguration(
                sources: [.qwen],
                unifiedAttemptTimeoutSeconds: 1,
                appleSpeechAddsPunctuation: true,
                qwen: firstConfiguration,
                nvidiaNemotron: nil
            ),
            singleSource: true
        )
        let secondService = factory.makeSessionService(
            configuration: ASRSessionConfiguration(
                sources: [.qwen],
                unifiedAttemptTimeoutSeconds: 1,
                appleSpeechAddsPunctuation: true,
                qwen: secondConfiguration,
                nvidiaNemotron: nil
            ),
            singleSource: true
        )

        do {
            _ = try await firstService?.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("The fixture unexpectedly transcribed")
        } catch let error as ASRAudioSupportError {
            #expect(!error.localizedDescription.contains("no longer active"))
            #expect(error.localizedDescription.contains("model not found"))
        } catch {
            Issue.record("Expected ASRAudioSupportError, got \(error)")
        }

        let startedAt = Date()
        do {
            _ = try await ASRStringOperationTimeout.run(timeoutSeconds: 0.05) {
                try await secondService.transcribe(
                    audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                    languageIDs: ["en-US"]
                )
            }
            Issue.record("A queued backend unexpectedly bypassed its active predecessor")
        } catch let error as ASRAudioSupportError {
            guard case .timeout = error else {
                Issue.record("Expected queued backend timeout, got \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Expected ASRAudioSupportError.timeout, got \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)

        await factory.stopQwenLlama()
        do {
            _ = try await firstService?.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("Global shutdown left a retained backend active")
        } catch let error as ASRAudioSupportError {
            #expect(error.localizedDescription.contains("no longer active"))
        } catch {
            Issue.record("Expected ASRAudioSupportError, got \(error)")
        }
        firstService = nil
    }

    @Test @MainActor func maintenanceRejectsNewQwenLeasesUntilFinished() async throws {
        let factory = ASRFactory()
        let maintenance = try await factory.beginQwenLlamaMaintenance()
        let configuration = qwenConfiguration(
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            isInstalledAtCapture: true
        )
        let service = factory.makeSessionService(
            configuration: ASRSessionConfiguration(
                sources: [.qwen],
                unifiedAttemptTimeoutSeconds: 1,
                appleSpeechAddsPunctuation: true,
                qwen: configuration,
                nvidiaNemotron: nil
            ),
            singleSource: true
        )

        switch factory.qwenLlamaLivePreviewServiceLease(configuration: configuration) {
        case .acquired:
            Issue.record("Model maintenance unexpectedly admitted Qwen live preview")
        case .unavailable(let reason):
            #expect(reason == .maintenance)
            #expect(reason.message.contains("model maintenance"))
        }

        do {
            _ = try await service.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("Model maintenance unexpectedly admitted a new Qwen lease")
        } catch let error as ASRAudioSupportError {
            #expect(error.localizedDescription.contains("maintenance"))
        } catch {
            Issue.record("Expected ASRAudioSupportError, got \(error)")
        }

        maintenance.finish()
        await Task.yield()
    }

    @Test @MainActor func cancelledQwenMaintenanceWaiterRestoresSessionAdmission() async {
        let factory = ASRFactory()
        let configuration = qwenConfiguration(
            modelPath: "/missing/cancelled-qwen.gguf",
            mmprojPath: "/missing/cancelled-mmproj.gguf",
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            isInstalledAtCapture: true
        )
        let snapshot = ASRSessionConfiguration(
            sources: [.qwen],
            unifiedAttemptTimeoutSeconds: 1,
            appleSpeechAddsPunctuation: true,
            qwen: configuration,
            nvidiaNemotron: nil
        )
        var capturedSession: (any ASRService)? = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        let maintenanceTask = Task { @MainActor in
            try await factory.beginQwenLlamaMaintenance()
        }

        for _ in 0..<10 { await Task.yield() }
        let blockedSession = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        do {
            _ = try await blockedSession.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("Qwen maintenance waiter did not close session admission")
        } catch {
            #expect(error.localizedDescription.contains("maintenance"))
        }

        maintenanceTask.cancel()
        switch await maintenanceTask.result {
        case .success:
            Issue.record("Cancelled Qwen maintenance unexpectedly acquired a lease")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        let reopenedSession = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        do {
            _ = try await reopenedSession.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("The missing Qwen fixture unexpectedly transcribed")
        } catch {
            #expect(!error.localizedDescription.contains("maintenance"))
        }
        capturedSession = nil
        _ = capturedSession
    }

    @Test @MainActor func nvidiaMaintenanceWaitsForLivePreviewAndThenReopensProvider() async throws {
        let factory = ASRFactory()
        let previewLease = try #require(factory.nvidiaNemotronRuntimeLease())
        let events = ASRSessionTestEvents()
        let maintenanceTask = Task { @MainActor in
            let maintenance = try await factory.beginNvidiaNemotronMaintenance()
            await events.append("maintenance-entered")
            return maintenance
        }

        for _ in 0..<10 { await Task.yield() }
        #expect(!(await events.snapshot().contains("maintenance-entered")))
        #expect(factory.nvidiaNemotronRuntimeLease() == nil)
        await factory.preloadNvidiaNemotron {
            await events.append("preload-started")
        }
        #expect(!(await events.snapshot().contains("preload-started")))

        previewLease.release()
        let maintenance = try await maintenanceTask.value
        #expect(await events.snapshot().contains("maintenance-entered"))
        #expect(factory.nvidiaNemotronRuntimeLease() == nil)
        await factory.preloadNvidiaNemotron {
            await events.append("preload-started")
        }
        #expect(!(await events.snapshot().contains("preload-started")))

        maintenance.finish()
        var reopenedPreviewLease: NvidiaNemotronRuntimeLease?
        for _ in 0..<20 where reopenedPreviewLease == nil {
            await Task.yield()
            reopenedPreviewLease = factory.nvidiaNemotronRuntimeLease()
        }
        #expect(reopenedPreviewLease != nil)
        reopenedPreviewLease?.release()
        await factory.preloadNvidiaNemotron {
            await events.append("preload-started")
        }
        #expect(await events.snapshot().filter { $0 == "preload-started" }.count == 1)
    }

    @Test @MainActor func cancelledNvidiaMaintenanceWaiterRestoresSessionAdmission() async {
        let factory = ASRFactory()
        let configuration = nvidiaConfiguration()
        let snapshot = ASRSessionConfiguration(
            sources: [.nvidiaNemotron],
            unifiedAttemptTimeoutSeconds: 1,
            appleSpeechAddsPunctuation: true,
            qwen: nil,
            nvidiaNemotron: configuration
        )
        var capturedSession: (any ASRService)? = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        let maintenanceTask = Task { @MainActor in
            try await factory.beginNvidiaNemotronMaintenance()
        }

        for _ in 0..<10 { await Task.yield() }
        let blockedSession = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        do {
            _ = try await blockedSession.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("NVIDIA maintenance waiter did not close session admission")
        } catch {
            #expect(error.localizedDescription.contains("maintenance"))
        }

        maintenanceTask.cancel()
        switch await maintenanceTask.result {
        case .success:
            Issue.record("Cancelled NVIDIA maintenance unexpectedly acquired a lease")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        let reopenedSession = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        do {
            _ = try await reopenedSession.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("The missing NVIDIA fixture unexpectedly transcribed")
        } catch {
            #expect(!error.localizedDescription.contains("maintenance"))
        }
        capturedSession = nil
        _ = capturedSession
    }

    @Test @MainActor func nvidiaMaintenanceWaitsForCapturedSessionAndThenReopens() async throws {
        let factory = ASRFactory()
        let configuration = nvidiaConfiguration()
        let snapshot = ASRSessionConfiguration(
            sources: [.nvidiaNemotron],
            unifiedAttemptTimeoutSeconds: 1,
            appleSpeechAddsPunctuation: true,
            qwen: nil,
            nvidiaNemotron: configuration
        )
        var capturedSession: (any ASRService)? = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        let events = ASRSessionTestEvents()
        let maintenanceTask = Task { @MainActor in
            let lease = try await factory.beginNvidiaNemotronMaintenance()
            await events.append("maintenance-entered")
            return lease
        }

        for _ in 0..<10 { await Task.yield() }
        #expect(!(await events.snapshot().contains("maintenance-entered")))

        let blockedSession = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        do {
            _ = try await blockedSession.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("NVIDIA maintenance admitted a new session")
        } catch {
            #expect(error.localizedDescription.contains("maintenance"))
        }

        capturedSession = nil
        let maintenance = try await maintenanceTask.value
        #expect(await events.snapshot().contains("maintenance-entered"))
        maintenance.finish()
        for _ in 0..<10 { await Task.yield() }

        let reopenedSession = factory.makeSessionService(
            configuration: snapshot,
            singleSource: true
        )
        do {
            _ = try await reopenedSession.transcribe(
                audioFileURL: URL(fileURLWithPath: "/missing/audio.wav"),
                languageIDs: ["en-US"]
            )
            Issue.record("The missing fixture unexpectedly transcribed")
        } catch {
            #expect(!error.localizedDescription.contains("maintenance"))
        }
        _ = capturedSession
    }

    @Test @MainActor func nvidiaTerminationQueueDrainsTerminationsAddedDuringAWait() async {
        let queue = SerialMainActorTaskQueue()
        let firstGate = ASRSessionTestGate()
        let secondGate = ASRSessionTestGate()
        let events = ASRSessionTestEvents()

        queue.enqueue {
            await events.append("first-started")
            await firstGate.wait()
            await events.append("first-finished")
        }
        let waiter = Task { @MainActor in
            await queue.waitForAll()
            await events.append("wait-finished")
        }
        for _ in 0..<10 { await Task.yield() }
        queue.enqueue {
            await events.append("second-started")
            await secondGate.wait()
            await events.append("second-finished")
        }

        await firstGate.open()
        for _ in 0..<20 { await Task.yield() }
        let beforeSecondFinishes = await events.snapshot()
        #expect(beforeSecondFinishes.contains("second-started"))
        #expect(!beforeSecondFinishes.contains("wait-finished"))

        await secondGate.open()
        await waiter.value
        #expect(await events.snapshot() == [
            "first-started",
            "first-finished",
            "second-started",
            "second-finished",
            "wait-finished",
        ])
    }
}
