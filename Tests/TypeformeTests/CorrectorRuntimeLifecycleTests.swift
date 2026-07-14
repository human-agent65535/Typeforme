import Foundation
import Darwin
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

private actor RuntimeTeardownScopeGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            if entered {
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class RuntimePIDCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPID: Int32?

    func store(_ pid: Int32) {
        lock.withLock { storedPID = pid }
    }

    var pid: Int32? {
        lock.withLock { storedPID }
    }
}

private struct InjectedPIDWriteError: LocalizedError {
    var errorDescription: String? { "injected PID write failure" }
}

@Suite("Corrector runtime lifecycle")
struct CorrectorRuntimeLifecycleTests {
    @Test func activationWaitDeadlineDoesNotCancelSharedRetirementBarrier() async {
        let gate = RuntimeActivationGate()
        let barrier = Task {
            await gate.wait()
        }
        let startedAt = Date()
        do {
            try await CorrectorLlamaActivationDeadline.wait(
                for: barrier,
                timeoutMilliseconds: 40
            )
            Issue.record("A closed activation barrier unexpectedly opened")
        } catch let error as CorrectorError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Expected CorrectorError.timeout, got \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.5)

        let laterWaiter = Task {
            try await CorrectorLlamaActivationDeadline.wait(
                for: barrier,
                timeoutMilliseconds: 1_000
            )
        }
        await gate.open()
        do {
            try await laterWaiter.value
        } catch {
            Issue.record("Timing out one waiter cancelled the shared barrier: \(error)")
        }
    }

    @Test @MainActor func sameLaunchRuntimeIsSharedAcrossRequestOnlyMaxTokenChanges() async throws {
        let fixture = try CorrectorFactoryFixture()
        defer { fixture.cleanup() }
        let capture = CorrectorFactoryManagerCapture(pidFile: fixture.pidFile)
        let factory = CorrectorFactory(
            bundledLlamaServerProvider: { fixture.missingBinary },
            llamaServerBuilder: capture.build
        )
        let first = factory.make(configuration: .embedded(fixture.configuration(maxTokens: 128)))
        let second = factory.make(configuration: .embedded(fixture.configuration(maxTokens: 512)))

        #expect(first.kind == second.kind)
        #expect(capture.managers.count == 1)

        await factory.shutdownAll()
        let manager = try #require(capture.managers.first)
        do {
            _ = try await manager.ensureRunning()
            Issue.record("Force shutdown left its embedded runtime restartable")
        } catch let error as LlamaServerError {
            guard case .retired = error else {
                Issue.record("Expected retired runtime, got \(error)")
                return
            }
        }
        _ = first
        _ = second
    }

    @Test @MainActor func replacementRuntimeWaitIsBoundedUntilPriorSessionLeaseDrains() async throws {
        let fixture = try CorrectorFactoryFixture()
        defer { fixture.cleanup() }
        let secondModel = fixture.root.appendingPathComponent("second.gguf")
        try Data().write(to: secondModel)
        let capture = CorrectorFactoryManagerCapture(pidFile: fixture.pidFile)
        let factory = CorrectorFactory(
            bundledLlamaServerProvider: { fixture.missingBinary },
            llamaServerBuilder: capture.build
        )
        var priorService: (any CorrectorService)? = factory.make(
            configuration: .embedded(fixture.configuration(maxTokens: 128))
        )
        #expect(priorService != nil)
        let replacementConfiguration = EmbeddedCorrectorConfiguration(
            kind: .qwen35_9B,
            modelPath: secondModel.path,
            contextSize: 512,
            maxTokens: 128,
            useFlashAttention: false,
            coldTimeoutMilliseconds: 40
        )
        let replacementService = factory.make(
            configuration: .embedded(replacementConfiguration)
        )
        #expect(capture.managers.count == 2)

        do {
            _ = try await replacementService.complete(
                system: "system",
                messages: [.user("hello")],
                timeoutMs: 100
            )
            Issue.record("Replacement runtime started while its predecessor lease was held")
        } catch let error as CorrectorError {
            #expect(error == .timeout)
        }
        // The non-main-actor deadline test above owns the wall-clock bound.
        // This integration test checks the timeout and lease lifecycle because
        // MainActor contention can delay observation after the timer fires.

        priorService = nil
        await Task.yield()
        let priorManager = try #require(capture.managers.first)
        var priorRetired = false
        for _ in 0..<100 {
            do {
                _ = try await priorManager.ensureRunning()
            } catch let error as LlamaServerError {
                if case .retired = error {
                    priorRetired = true
                    break
                }
            } catch {}
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(priorRetired)
        await factory.shutdownAll()
        _ = replacementService
    }

    @Test @MainActor func modelDeletionWaitsForMatchingCorrectionSessionLease() async throws {
        let fixture = try CorrectorFactoryFixture()
        defer { fixture.cleanup() }
        let capture = CorrectorFactoryManagerCapture(pidFile: fixture.pidFile)
        let factory = CorrectorFactory(
            bundledLlamaServerProvider: { fixture.missingBinary },
            llamaServerBuilder: capture.build
        )
        var service: (any CorrectorService)? = factory.make(
            configuration: .embedded(fixture.configuration(maxTokens: 128))
        )
        #expect(service != nil)
        let deletion = Task { @MainActor in
            try await factory.withDrainedModelRuntime(atPath: fixture.model.path) {
                try FileManager.default.removeItem(at: fixture.model)
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(FileManager.default.fileExists(atPath: fixture.model.path))

        service = nil
        try await deletion.value
        #expect(!FileManager.default.fileExists(atPath: fixture.model.path))
    }

    @Test @MainActor func concurrentRuntimeTeardownsRemainClosedUntilBothFinish() async throws {
        let fixture = try CorrectorFactoryFixture()
        defer { fixture.cleanup() }
        let secondModel = fixture.root.appendingPathComponent("second.gguf")
        try Data().write(to: secondModel)
        let capture = CorrectorFactoryManagerCapture(pidFile: fixture.pidFile)
        let factory = CorrectorFactory(
            bundledLlamaServerProvider: { fixture.missingBinary },
            llamaServerBuilder: capture.build
        )
        let firstGate = RuntimeTeardownScopeGate()
        let secondGate = RuntimeTeardownScopeGate()

        let firstModelDrain = Task { @MainActor in
            await factory.withRuntimeTeardownScope {
                await firstGate.wait()
            }
        }
        await firstGate.waitUntilEntered()
        let secondModelDrain = Task { @MainActor in
            await factory.withRuntimeTeardownScope {
                await secondGate.wait()
            }
        }
        await secondGate.waitUntilEntered()

        await firstGate.open()
        await firstModelDrain.value
        _ = factory.make(configuration: .embedded(fixture.configuration(maxTokens: 128)))
        #expect(capture.managers.isEmpty)

        await secondGate.open()
        await secondModelDrain.value
        let secondConfiguration = EmbeddedCorrectorConfiguration(
            kind: .qwen35_9B,
            modelPath: secondModel.path,
            contextSize: 512,
            maxTokens: 128,
            useFlashAttention: false,
            coldTimeoutMilliseconds: 40
        )
        var service: (any CorrectorService)? = factory.make(
            configuration: .embedded(secondConfiguration)
        )
        #expect(capture.managers.count == 1)
        service = nil
        await factory.shutdownAll()
    }

    @Test func pidPersistenceFailureTerminatesOwnedChildAndFailsLaunch() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-llama-pid-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("model.gguf")
        let managerPIDFile = root.appendingPathComponent("manager.pid")
        try Data().write(to: model)
        let script = """
        $SIG{TERM} = 'IGNORE';
        while (1) { sleep 1; }
        """

        let capturedPID = RuntimePIDCapture()
        let manager = LlamaCppServerManager(
            modelPath: model.path,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: perl,
            pidFile: managerPIDFile,
            executableArgumentPrefix: ["-e", script, "--"],
            coldTimeoutSec: 5,
            pidFileWriter: { pid, _ in
                capturedPID.store(pid)
                throw InjectedPIDWriteError()
            }
        )

        do {
            _ = try await manager.ensureRunning()
            Issue.record("A launch without persisted process ownership unexpectedly succeeded")
        } catch let error as LlamaServerError {
            guard case .ownershipPersistenceFailed = error else {
                Issue.record("Expected ownershipPersistenceFailed, got \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Expected LlamaServerError, got \(error)")
        }

        let pid = try #require(capturedPID.pid)
        defer {
            if Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        #expect(Darwin.kill(pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: managerPIDFile.path))
    }

    @Test func failedColdStartForceStopsHelperAndCleansPIDFile() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-llama-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("model.gguf")
        let childPIDFile = root.appendingPathComponent("child.pid")
        let managerPIDFile = root.appendingPathComponent("manager.pid")
        try Data().write(to: model)
        let script = """
        open(my $handle, '>', '\(childPIDFile.path)') or die $!;
        print $handle $$;
        close($handle);
        $SIG{TERM} = 'IGNORE';
        while (1) { sleep 1; }
        """

        let manager = LlamaCppServerManager(
            modelPath: model.path,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: perl,
            pidFile: managerPIDFile,
            executableArgumentPrefix: ["-e", script, "--"],
            coldTimeoutSec: 0.05
        )
        let startedAt = Date()
        do {
            _ = try await manager.ensureRunning()
            await manager.stop()
            Issue.record("A helper without a health endpoint unexpectedly became ready")
        } catch {
            // Expected: startup timeout owns and tears down the launched child.
        }

        #expect(Date().timeIntervalSince(startedAt) < 4)
        #expect(!FileManager.default.fileExists(atPath: managerPIDFile.path))
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(childPIDText))
        #expect(Darwin.kill(childPID, 0) != 0)
    }

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

    @Test func correctionRuntimeKeyChangesWhenModelIsReplacedAtTheSamePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-corrector-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("model.gguf")
        let binary = root.appendingPathComponent("llama-server")
        try Data("model-a".utf8).write(to: model)
        try Data("binary".utf8).write(to: binary)

        func configuration() -> CorrectorLlamaRuntimeConfiguration {
            CorrectorLlamaRuntimeConfiguration(
                kind: .qwen35_4B,
                modelPath: model.path,
                binaryPath: binary.path,
                pidFilePath: root.appendingPathComponent("llama.pid").path,
                contextSize: 4_096,
                useFlashAttention: true,
                coldTimeoutMilliseconds: 30_000
            )
        }

        let original = configuration()
        try FileManager.default.removeItem(at: model)
        try Data("model-b-with-a-different-size".utf8).write(to: model)
        let replacement = configuration()

        #expect(original.modelPath == replacement.modelPath)
        #expect(original != replacement)
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

    @Test func stopInvalidatesAColdStartWaitingBeforeLaunch() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-llama-stop-before-launch-\(UUID().uuidString)", isDirectory: true)
        let gate = RuntimeActivationGate()
        let barrier = Task { await gate.wait() }
        let manager = LlamaCppServerManager(
            modelPath: root.appendingPathComponent("missing-model.gguf").path,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            pidFile: root.appendingPathComponent("llama.pid"),
            activationBarrier: barrier
        )
        let attempt = Task { () -> Bool in
            do {
                _ = try await manager.ensureRunning()
                return true
            } catch {
                return false
            }
        }

        for _ in 0..<4 { await Task.yield() }
        await manager.stop()
        await gate.open()

        #expect(!(await attempt.value))
        #expect(await manager.status == .stopped)
    }

    @Test func stopDoesNotClearAProcessStartedByALaterEnsure() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-llama-stop-epoch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("model.gguf")
        let helper = root.appendingPathComponent("health-server.py")
        let pidFile = root.appendingPathComponent("llama.pid")
        try Data().write(to: model)
        let script = """
        import signal
        import sys
        import time
        from http.server import BaseHTTPRequestHandler, HTTPServer

        port = int(sys.argv[sys.argv.index("--port") + 1])

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
            def log_message(self, format, *args):
                pass

        def terminate(signum, frame):
            time.sleep(0.2)
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, terminate)
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        try Data(script.utf8).write(to: helper)

        let manager = LlamaCppServerManager(
            modelPath: model.path,
            contextSize: 512,
            useFlashAttn: false,
            binaryURL: python,
            pidFile: pidFile,
            executableArgumentPrefix: [helper.path],
            coldTimeoutSec: 3
        )
        _ = try await manager.ensureRunning()
        guard case .running(_, let firstPID) = await manager.status else {
            Issue.record("Initial helper was not running")
            return
        }

        let stopTask = Task { await manager.stop() }
        let stoppingDeadline = Date().addingTimeInterval(1)
        while Date() < stoppingDeadline {
            if await manager.status == .stopping { break }
            await Task.yield()
        }
        #expect(await manager.status == .stopping)

        let laterEnsure = Task { try await manager.ensureRunning() }
        await stopTask.value
        _ = try await laterEnsure.value

        guard case .running(_, let secondPID) = await manager.status else {
            Issue.record("Later ensure did not leave its helper running")
            return
        }
        #expect(secondPID != firstPID)
        #expect(Darwin.kill(firstPID, 0) != 0)
        #expect(Darwin.kill(secondPID, 0) == 0)
        await manager.stop()
    }
}

private final class CorrectorFactoryManagerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let pidFile: URL
    private var storedManagers: [LlamaCppServerManager] = []

    init(pidFile: URL) {
        self.pidFile = pidFile
    }

    var managers: [LlamaCppServerManager] {
        lock.withLock { storedManagers }
    }

    func build(
        configuration: CorrectorLlamaRuntimeConfiguration,
        activationBarrier: Task<Void, Never>?
    ) -> LlamaCppServerManager {
        let manager = LlamaCppServerManager(
            modelPath: configuration.modelPath,
            contextSize: configuration.contextSize,
            useFlashAttn: configuration.useFlashAttention,
            binaryURL: URL(fileURLWithPath: configuration.binaryPath),
            pidFile: pidFile,
            coldTimeoutSec: TimeInterval(configuration.coldTimeoutMilliseconds) / 1_000,
            activationBarrier: activationBarrier
        )
        lock.withLock { storedManagers.append(manager) }
        return manager
    }
}

private struct CorrectorFactoryFixture {
    let root: URL
    let model: URL
    let missingBinary: URL
    let pidFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-corrector-factory-\(UUID().uuidString)", isDirectory: true)
        model = root.appendingPathComponent("first.gguf")
        missingBinary = root.appendingPathComponent("missing-llama-server")
        pidFile = root.appendingPathComponent("llama.pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: model)
    }

    func configuration(maxTokens: Int) -> EmbeddedCorrectorConfiguration {
        EmbeddedCorrectorConfiguration(
            kind: .qwen35_4B,
            modelPath: model.path,
            contextSize: 512,
            maxTokens: maxTokens,
            useFlashAttention: false,
            coldTimeoutMilliseconds: 40
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
