import Foundation
import Darwin

enum LlamaServerError: LocalizedError {
    case binaryMissing(URL)
    case modelMissing(String)
    case launchFailed(String)
    case ownershipPersistenceFailed(String)
    case warmupTimeout(seconds: TimeInterval)
    case retired

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let url): return "llama-server binary not found at \(url.path)"
        case .modelMissing(let path): return "model not found at \(path)"
        case .launchFailed(let why): return "llama-server launch failed: \(why)"
        case .ownershipPersistenceFailed(let why): return "llama-server ownership persistence failed: \(why)"
        case .warmupTimeout(let s): return "llama-server didn't become healthy in \(Int(s))s"
        case .retired: return "llama-server configuration is no longer active"
        }
    }
}

/// Launches the bundled llama-server helper on a free localhost port, using
/// the configured context size and GPU settings.
actor LlamaCppServerManager {
    enum Status: Equatable {
        case stopped
        case starting
        case stopping
        case running(port: Int, pid: Int32)
        case failed(String)
    }

    private enum PIDMatchResult {
        case matches
        case different
        case unknown
    }

    private(set) var status: Status = .stopped

    private let modelPath: String
    private let contextSize: Int
    private let useFlashAttn: Bool
    private let binaryURL: URL
    private let pidFile: URL
    private let requiredFiles: [String]
    private let executableArgumentPrefix: [String]
    private let extraArguments: [String]
    private let pidFileWriter: @Sendable (Int32, URL) throws -> Void
    /// Per-request override is also possible by passing a different timeout
    /// at call time, but the default tracks AppSettings.correctionColdTimeoutMs.
    private let coldTimeoutSec: TimeInterval
    /// A replacement manager waits for the previous configuration to finish
    /// shutting down before it may launch. This keeps model switches exclusive
    /// even when settings change several times in quick succession.
    private var activationBarrier: Task<Void, Never>?
    /// Unlike `stop()`, retirement is permanent. Services retained by an older
    /// request must not be able to restart a superseded model configuration.
    private var isRetired = false
    /// Every stop invalidates starts that entered the actor before that stop.
    /// Callers arriving while `.stopping` wait and may start only afterwards.
    private var lifecycleEpoch: UInt64 = 0
    private var process: Process?

    private static let maxLaunchPortAttempts = 3
    private static let terminationGraceSeconds: TimeInterval = 2
    private static let forcedTerminationWaitSeconds: TimeInterval = 1

    init(modelPath: String,
         contextSize: Int,
         useFlashAttn: Bool,
         binaryURL: URL,
         pidFile: URL = AppPaths.llamaPidFile,
         requiredFiles: [String] = [],
         executableArgumentPrefix: [String] = [],
         extraArguments: [String] = [],
         coldTimeoutSec: TimeInterval = 30,
         activationBarrier: Task<Void, Never>? = nil,
         pidFileWriter: @escaping @Sendable (Int32, URL) throws -> Void = { pid, url in
             try String(pid).write(to: url, atomically: true, encoding: .utf8)
         }) {
        self.modelPath = modelPath
        self.contextSize = contextSize
        self.useFlashAttn = useFlashAttn
        self.binaryURL = binaryURL
        self.pidFile = pidFile
        self.requiredFiles = requiredFiles
        self.executableArgumentPrefix = executableArgumentPrefix
        self.extraArguments = extraArguments
        self.coldTimeoutSec = coldTimeoutSec
        self.activationBarrier = activationBarrier
        self.pidFileWriter = pidFileWriter
    }

    /// Bring the server up if not already running. Returns the port.
    func ensureRunning() async throws -> Int {
        let invocationEpoch = lifecycleEpoch
        if let activationBarrier {
            try await AsyncTaskBarrier.wait(for: activationBarrier)
            try validateStart(epoch: invocationEpoch)
            self.activationBarrier = nil
        }
        try Task.checkCancellation()
        guard !isRetired else { throw LlamaServerError.retired }

        // Self-heal: if we *think* we're running but the process died (crash,
        // OOM, user-killed via Activity Monitor), drop the stale state so the
        // next request starts a fresh server.
        if case .running = status, let p = process, !p.isRunning {
            Log.llm.notice("llama-server died externally; will restart on next request")
            process = nil
            status = .stopped
            try? FileManager.default.removeItem(at: pidFile)
        }

        switch status {
        case .running(let port, _):
            return port
        case .starting:
            let waitingEpoch = lifecycleEpoch
            while case .starting = status {
                if let p = process, !p.isRunning {
                    let reason = "llama-server exited during startup"
                    Log.llm.notice("\(reason, privacy: .public)")
                    if lifecycleEpoch == waitingEpoch, process === p {
                        process = nil
                        status = .failed(reason)
                    }
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                try validateStart(epoch: waitingEpoch)
            }
            try validateStart(epoch: waitingEpoch)
            return try await ensureRunning()
        case .stopping:
            while case .stopping = status {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return try await ensureRunning()
        case .stopped, .failed:
            let startEpoch = lifecycleEpoch
            do {
                return try await start(epoch: startEpoch)
            } catch {
                if lifecycleEpoch == startEpoch,
                   !isRetired,
                   case .starting = status {
                    status = .failed(error.localizedDescription)
                }
                throw error
            }
        }
    }

    func stop() async {
        if case .stopping = status {
            while case .stopping = status {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return
        }

        lifecycleEpoch &+= 1
        let stopEpoch = lifecycleEpoch
        let ownedProcess = process
        status = .stopping
        if let ownedProcess {
            let terminated: Bool
            if ownedProcess.isRunning {
                terminated = await Self.terminateOwnedProcess(
                    ownedProcess,
                    expectedBinary: binaryURL,
                    reason: "stop"
                )
            } else {
                terminated = true
            }
            guard lifecycleEpoch == stopEpoch, process === ownedProcess else { return }
            if terminated {
                process = nil
                status = .stopped
                removePIDFile(ifOwnedBy: ownedProcess.processIdentifier)
                Log.llm.info("llama-server stopped")
            } else {
                // Keep both the Process reference and PID file. Losing either
                // would make a surviving child invisible to the next stop or
                // stale-process cleanup pass.
                process = ownedProcess
                status = .failed("llama-server did not terminate")
            }
            return
        }
        let staleTerminated = await terminateStaleServer()
        guard lifecycleEpoch == stopEpoch, process == nil else { return }
        status = staleTerminated ? .stopped : .failed("stale llama-server did not terminate")
    }

    /// Permanently disables this manager, then stops its helper. A normal
    /// timeout uses `stop()` so the same configuration can cold-start again;
    /// configuration replacement uses `retire()` so stale services cannot.
    func retire() async {
        isRetired = true
        activationBarrier = nil
        await stop()
    }

    // MARK: - Private

    private func start(epoch: UInt64) async throws -> Int {
        try validateStart(epoch: epoch)
        status = .starting

        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            status = .failed("binary missing")
            throw LlamaServerError.binaryMissing(binaryURL)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            status = .failed("model missing")
            throw LlamaServerError.modelMissing(modelPath)
        }
        for path in requiredFiles where !FileManager.default.fileExists(atPath: path) {
            status = .failed("required file missing")
            throw LlamaServerError.modelMissing(path)
        }

        if let ownedProcess = process {
            let terminated: Bool
            if ownedProcess.isRunning {
                terminated = await Self.terminateOwnedProcess(
                    ownedProcess,
                    expectedBinary: binaryURL,
                    reason: "restart_after_failure"
                )
            } else {
                terminated = true
            }
            try validateStart(epoch: epoch)
            guard terminated else {
                status = .failed("previous llama-server did not terminate")
                throw LlamaServerError.launchFailed("previous llama-server did not terminate")
            }
            process = nil
            removePIDFile(ifOwnedBy: ownedProcess.processIdentifier)
        }

        let staleTerminated = await terminateStaleServer()
        try validateStart(epoch: epoch)
        guard staleTerminated else {
            status = .failed("stale llama-server did not terminate")
            throw LlamaServerError.launchFailed("stale llama-server did not terminate")
        }

        let port: Int
        do {
            port = try await launchWithPortRetries(flashAttn: useFlashAttn, epoch: epoch)
        } catch {
            if lifecycleEpoch == epoch, !isRetired {
                status = .failed(error.localizedDescription)
            }
            throw error
        }
        try validateStart(epoch: epoch)

        let pid = process?.processIdentifier ?? -1
        status = .running(port: port, pid: pid)
        return port
    }

    private func launchWithPortRetries(flashAttn: Bool, epoch: UInt64) async throws -> Int {
        var lastError: Error?
        for attempt in 1...Self.maxLaunchPortAttempts {
            try validateStart(epoch: epoch)
            let port = try FreePortFinder.findFreeLocalhostPort()
            Log.llm.info("starting llama-server on port \(port)")
            do {
                try await launch(port: port, flashAttn: flashAttn, epoch: epoch)
                return port
            } catch {
                lastError = error
                try validateStart(epoch: epoch)
                guard Self.isRetryableLaunchFailure(error),
                      attempt < Self.maxLaunchPortAttempts
                else { throw error }
                Log.llm.notice("llama-server launch attempt \(attempt) failed; retrying on a new port")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError ?? LlamaServerError.launchFailed("no launch attempts were made")
    }

    private func validateStart(epoch: UInt64) throws {
        try Task.checkCancellation()
        guard !isRetired else { throw LlamaServerError.retired }
        guard lifecycleEpoch == epoch else { throw CancellationError() }
    }

    private static func isRetryableLaunchFailure(_ error: Error) -> Bool {
        guard let llamaError = error as? LlamaServerError else { return false }
        if case .launchFailed = llamaError {
            return true
        }
        return false
    }

    private func launch(port: Int, flashAttn: Bool, epoch: UInt64) async throws {
        try validateStart(epoch: epoch)
        var args = executableArgumentPrefix + [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(contextSize),
            "--n-gpu-layers", "999",
            "--no-webui",
            "--reasoning", "off",
        ]
        args += extraArguments
        if flashAttn { args += ["--flash-attn", "on"] }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw LlamaServerError.launchFailed(error.localizedDescription)
        }
        self.process = proc
        let pid = proc.processIdentifier
        // Persist ownership as soon as the child exists. A force-quit during
        // cold start must leave enough information for the next launch to
        // identify and terminate the stale helper.
        do {
            try pidFileWriter(pid, pidFile)
        } catch {
            let failure = error.localizedDescription
            let terminated: Bool
            if proc.isRunning {
                terminated = await Self.terminateOwnedProcess(
                    proc,
                    expectedBinary: binaryURL,
                    reason: "pid_persistence_failed"
                )
            } else {
                terminated = true
            }
            if lifecycleEpoch == epoch, self.process === proc {
                if terminated {
                    self.process = nil
                    removePIDFile(ifOwnedBy: pid)
                } else {
                    // The Process reference is the only remaining ownership record
                    // when the PID file cannot be written. Keep it so stop() and a
                    // later retry cannot lose or overwrite the surviving child.
                    self.process = proc
                }
            }
            let suffix = terminated ? "" : "; spawned process did not terminate"
            throw LlamaServerError.ownershipPersistenceFailed(failure + suffix)
        }

        do {
            try await waitForReady(port: port, timeout: coldTimeoutSec, process: proc)
            try validateStart(epoch: epoch)
        } catch {
            if lifecycleEpoch != epoch || isRetired || self.process !== proc {
                try validateStart(epoch: epoch)
                throw error
            }
            let terminated: Bool
            if proc.isRunning {
                terminated = await Self.terminateOwnedProcess(
                    proc,
                    expectedBinary: binaryURL,
                    reason: "startup_failed"
                )
            } else {
                terminated = true
            }
            if lifecycleEpoch == epoch, self.process === proc {
                if terminated {
                    self.process = nil
                    removePIDFile(ifOwnedBy: pid)
                } else {
                    // Preserve ownership for stop() or the next launch's stale
                    // cleanup instead of hiding an unresponsive helper.
                    self.process = proc
                }
            }
            throw error
        }
    }

    private func removePIDFile(ifOwnedBy pid: Int32) {
        guard let stored = try? String(contentsOf: pidFile, encoding: .utf8),
              stored.trimmingCharacters(in: .whitespacesAndNewlines) == String(pid)
        else { return }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// `Process.waitUntilExit()` has no deadline and can hold application
    /// termination forever. Polling the owned Process is bounded, and a child
    /// that ignores SIGTERM is force-killed before control returns.
    private static func terminateOwnedProcess(
        _ process: Process,
        expectedBinary: URL,
        reason: String
    ) async -> Bool {
        guard process.isRunning else { return true }
        let pid = process.processIdentifier
        process.terminate()
        if await waitForExit(process, timeout: terminationGraceSeconds) { return true }

        guard process.isRunning else { return true }
        switch await pidMatch(pid, expectedBinary: expectedBinary) {
        case .matches:
            break
        case .different:
            Log.llm.notice(
                "llama-server pid=\(pid) changed identity before SIGKILL; skipping kill"
            )
            return !process.isRunning
        case .unknown:
            guard process.isRunning else { return true }
            Log.llm.error(
                "could not verify llama-server pid=\(pid) before SIGKILL; preserving ownership"
            )
            return false
        }
        guard process.isRunning else { return true }
        Log.llm.notice(
            "llama-server didn't exit on SIGTERM; SIGKILL pid=\(pid) reason=\(reason, privacy: .public)"
        )
        _ = kill(pid, SIGKILL)
        let terminated = await waitForExit(process, timeout: forcedTerminationWaitSeconds)
        if !terminated {
            Log.llm.error("llama-server pid=\(pid) still reported running after SIGKILL")
        }
        return terminated
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return !process.isRunning
        }.value
    }

    private func waitForReady(port: Int, timeout: TimeInterval, process: Process) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 0.5
        while Date() < deadline {
            if !process.isRunning {
                throw LlamaServerError.launchFailed("exited before ready with status \(process.terminationStatus)")
            }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    Log.llm.info("llama-server ready on port \(port)")
                    return
                }
            } catch {
                // not ready yet
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LlamaServerError.warmupTimeout(seconds: timeout)
    }

    /// Reads the PID file, checks liveness, and terminates stale helpers only
    /// when the PID still belongs to our own llama-server binary.
    /// PIDs get recycled on macOS; killing blindly could nuke an unrelated app.
    private func terminateStaleServer() async -> Bool {
        guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }

        guard kill(pid, 0) == 0 else {
            try? FileManager.default.removeItem(at: pidFile)
            return true
        }
        switch await Self.pidMatch(pid, expectedBinary: binaryURL) {
        case .matches:
            break
        case .different:
            Log.llm.notice("pid \(pid) in llama.pid is not our llama-server (PID reused); skipping kill")
            try? FileManager.default.removeItem(at: pidFile)
            return true
        case .unknown:
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: pidFile)
                return true
            }
            Log.llm.error("could not verify stale llama-server pid=\(pid); preserving PID file")
            return false
        }

        Log.llm.notice("found stale llama-server pid=\(pid); SIGTERM")
        _ = kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: pidFile)
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Log.llm.notice("pid=\(pid) still alive; SIGKILL")
        _ = kill(pid, SIGKILL)
        for _ in 0..<10 {
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: pidFile)
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Log.llm.error("stale llama-server pid=\(pid) still alive after SIGKILL; preserving PID file")
        return false
    }

    /// True iff the given pid's executable path matches our bundled
    /// llama-server-arm64. Uses `/bin/ps -p PID -o comm=`, which returns the
    /// resolved executable path on macOS.
    private static func pidMatch(_ pid: pid_t, expectedBinary: URL) async -> PIDMatchResult {
        await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-p", "\(pid)", "-o", "comm="]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                return .unknown
            }
            let deadline = Date().addingTimeInterval(1)
            while proc.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !proc.isRunning else {
                proc.terminate()
                return .unknown
            }
            guard proc.terminationStatus == 0 else { return .unknown }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let comm = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !comm.isEmpty else { return .unknown }
            // `comm` is either the full path or just the basename, depending on
            // how the process was launched. Match either form.
            let expectedName = expectedBinary.lastPathComponent
            if comm == expectedBinary.path
                || (comm as NSString).lastPathComponent == expectedName {
                return .matches
            }
            return .different
        }.value
    }
}
