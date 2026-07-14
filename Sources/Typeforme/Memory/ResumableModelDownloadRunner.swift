import Foundation
import Darwin
import os.lock

enum ModelDownloadRunnerError: LocalizedError {
    case httpStatus(Int, label: String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let label):
            return "\(label) download failed with HTTP \(status)"
        }
    }
}

enum ModelDownloadCompletion: Sendable {
    case success(URL)
    case failure(message: String, resumeData: Data?, wasCancelled: Bool)
}

/// Commits a verified download without exposing a partially written model or
/// deleting the last known file first. The per-destination lock is shared by
/// UI and automatic installers, so independently created downloaders cannot
/// race their final validation and rename.
enum ModelDownloadFileInstaller {
    private static let copyChunkSize = 1024 * 1024
    private static let destinationLocks = OSAllocatedUnfairLock(initialState: [String: NSLock]())

    static func install(
        downloadedFile: URL,
        at destination: URL,
        checksumPolicy: ModelDownloadChecksumPolicy,
        expectedBytes: Int64?,
        label: String,
        cancellationCheck: @escaping () throws -> Void,
        beginCommit: () throws -> Void
    ) throws {
        let lock = lock(for: destination)
        lock.lock()
        defer { lock.unlock() }

        try cancellationCheck()
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).install-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.moveItem(at: downloadedFile, to: staging)
        } catch {
            try copyFile(
                from: downloadedFile,
                to: staging,
                cancellationCheck: cancellationCheck
            )
        }

        try ModelDownloadIntegrity.validateFile(
            at: staging,
            checksumPolicy: checksumPolicy,
            expectedBytes: expectedBytes,
            label: label,
            cancellationCheck: cancellationCheck
        )
        // beginCommit is the atomic cancellation boundary. Its caller must
        // reject cancellation already requested and then mark the commit as
        // started in one synchronization step. No cancellation check belongs
        // between this point and rename: once rename starts, its result wins.
        try beginCommit()
        try atomicRename(from: staging, to: destination)
    }

    static func remove(at destination: URL) throws {
        let lock = lock(for: destination)
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        ModelDownloadResumeStore.remove(for: destination)
    }

    private static func lock(for destination: URL) -> NSLock {
        let path = destination.standardizedFileURL.path
        return destinationLocks.withLock { locks in
            if let existing = locks[path] { return existing }
            let lock = NSLock()
            locks[path] = lock
            return lock
        }
    }

    private static func copyFile(
        from source: URL,
        to destination: URL,
        cancellationCheck: () throws -> Void
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        while true {
            try cancellationCheck()
            let chunk = try input.read(upToCount: copyChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
        try cancellationCheck()
        try output.synchronize()
    }

    private static func atomicRename(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSFilePathErrorKey: destination.path,
                    NSLocalizedDescriptionKey: String(cString: strerror(code)),
                ]
            )
        }
    }
}

struct ModelDownloadRunnerLifecycle {
    private(set) var didComplete = false
    private(set) var cancellationRequested = false
    private(set) var isInstalling = false
    private(set) var commitStarted = false

    mutating func prepareForStart() -> Bool {
        let wasCancellationRequested = cancellationRequested
        didComplete = false
        isInstalling = false
        commitStarted = false
        return wasCancellationRequested
    }

    mutating func beginInstalling() -> Bool {
        guard !didComplete, !isInstalling else { return false }
        isInstalling = true
        return true
    }

    mutating func requestCancellation() -> Bool {
        guard !didComplete, !commitStarted else { return false }
        cancellationRequested = true
        return true
    }

    mutating func beginCommit() -> Bool {
        guard isInstalling,
              !didComplete,
              !cancellationRequested,
              !commitStarted
        else { return false }
        commitStarted = true
        return true
    }

    mutating func claimCompletion(unlessInstalling: Bool = false) -> Bool {
        guard !didComplete, !(unlessInstalling && isInstalling) else { return false }
        didComplete = true
        cancellationRequested = false
        isInstalling = false
        commitStarted = false
        return true
    }
}

final class ResumableModelDownloadRunner: NSObject, URLSessionDownloadDelegate {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        var lifecycle = ModelDownloadRunnerLifecycle()
    }

    private let destination: URL
    private let label: String
    private let checksumPolicy: ModelDownloadChecksumPolicy
    private let expectedBytes: Int64?
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private let onCompletion: (@Sendable (ModelDownloadCompletion) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let session = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    init(
        destination: URL,
        label: String? = nil,
        checksumPolicy: ModelDownloadChecksumPolicy,
        expectedBytes: Int64?,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        onCompletion: (@Sendable (ModelDownloadCompletion) -> Void)? = nil
    ) {
        self.destination = destination
        self.label = label ?? destination.lastPathComponent
        self.checksumPolicy = checksumPolicy
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        super.init()
    }

    @discardableResult
    func start(from url: URL, resumeData: Data? = nil) -> URLSessionDownloadTask {
        start(from: url, resumeData: resumeData, continuation: nil)
    }

    func download(from url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try Task.checkCancellation()
                } catch {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                start(from: url, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    @discardableResult
    private func start(
        from url: URL,
        resumeData: Data? = nil,
        continuation: CheckedContinuation<Void, Error>?
    ) -> URLSessionDownloadTask {
        let activeSession = makeSession()
        let nextTask: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            nextTask = activeSession.downloadTask(withResumeData: resumeData)
        } else if let diskResumeData = ModelDownloadResumeStore.load(for: destination) {
            nextTask = activeSession.downloadTask(withResumeData: diskResumeData)
        } else {
            nextTask = activeSession.downloadTask(with: URLRequest(url: url))
        }

        let cancellationRequested = state.withLock { state in
            state.continuation = continuation
            state.task = nextTask
            return state.lifecycle.prepareForStart()
        }
        if cancellationRequested {
            nextTask.cancel()
            finish(
                .failure(CancellationError()),
                wasCancelled: true,
                matching: nextTask
            )
        } else {
            nextTask.resume()
        }
        return nextTask
    }

    func cancel(onResumeData: (@Sendable (Data?) -> Void)? = nil) {
        let cancellation = state.withLock { state -> (
            accepted: Bool,
            task: URLSessionDownloadTask?,
            hasContinuation: Bool
        ) in
            guard state.lifecycle.requestCancellation() else {
                return (accepted: false, task: nil, hasContinuation: false)
            }
            return (accepted: true, task: state.task, hasContinuation: state.continuation != nil)
        }
        guard cancellation.accepted else { return }
        guard let activeTask = cancellation.task else {
            if cancellation.hasContinuation {
                finish(.failure(CancellationError()), wasCancelled: true)
            }
            onResumeData?(nil)
            return
        }
        activeTask.cancel { data in
            let wonCompletion = self.finish(
                .failure(CancellationError()),
                resumeData: data,
                wasCancelled: true,
                matching: activeTask,
                unlessInstalling: true,
                persistResumeData: true
            )
            if wonCompletion {
                onResumeData?(data)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let shouldReport = state.withLock { state in
            state.task === downloadTask && !state.lifecycle.didComplete
        }
        guard shouldReport else { return }
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let shouldInstall = state.withLock { state in
            guard state.task === downloadTask else { return false }
            return state.lifecycle.beginInstalling()
        }
        guard shouldInstall else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            ModelDownloadResumeStore.remove(for: destination)
            finish(
                .failure(ModelDownloadRunnerError.httpStatus(http.statusCode, label: label)),
                matching: downloadTask
            )
            return
        }

        // The transfer is complete; resume data from an older partial transfer
        // must not survive a validation or install failure.
        ModelDownloadResumeStore.remove(for: destination)
        do {
            try ModelDownloadFileInstaller.install(
                downloadedFile: location,
                at: destination,
                checksumPolicy: checksumPolicy,
                expectedBytes: expectedBytes,
                label: label,
                cancellationCheck: checkCancellation,
                beginCommit: beginInstallCommit
            )
            ModelDownloadResumeStore.remove(for: destination)
            finish(.success(()), matching: downloadTask)
        } catch {
            let wasCancelled = error is CancellationError || cancellationRequested
            finish(
                .failure(wasCancelled ? CancellationError() : error),
                wasCancelled: wasCancelled,
                matching: downloadTask
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let callbackState = state.withLock { state in
            (
                matchesActiveTask: state.task === task,
                didComplete: state.lifecycle.didComplete,
                isInstalling: state.lifecycle.isInstalling
            )
        }
        guard callbackState.matchesActiveTask,
              !callbackState.didComplete,
              !callbackState.isInstalling
        else { return }
        guard let error else { return }
        let nsError = error as NSError
        let producedResumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        if nsError.code == NSURLErrorCancelled {
            finish(
                .failure(CancellationError()),
                resumeData: producedResumeData,
                wasCancelled: true,
                matching: task,
                unlessInstalling: true,
                persistResumeData: true
            )
        } else {
            finish(
                .failure(error),
                resumeData: producedResumeData,
                wasCancelled: false,
                matching: task,
                unlessInstalling: true,
                persistResumeData: true,
                removeResumeDataWhenMissing: true
            )
        }
    }

    @discardableResult
    private func finish(
        _ result: Result<Void, Error>,
        resumeData: Data? = nil,
        wasCancelled: Bool = false,
        matching task: URLSessionTask? = nil,
        unlessInstalling: Bool = false,
        persistResumeData: Bool = false,
        removeResumeDataWhenMissing: Bool = false
    ) -> Bool {
        let completion = state.withLock { state in
            if let task, state.task !== task {
                return (won: false, continuation: nil as CheckedContinuation<Void, Error>?)
            }
            guard state.lifecycle.claimCompletion(unlessInstalling: unlessInstalling) else {
                return (won: false, continuation: nil as CheckedContinuation<Void, Error>?)
            }
            state.task = nil
            let continuation = state.continuation
            state.continuation = nil
            return (won: true, continuation: continuation)
        }
        guard completion.won else { return false }

        if persistResumeData {
            if let resumeData, !resumeData.isEmpty {
                ModelDownloadResumeStore.store(resumeData, for: destination)
            } else if removeResumeDataWhenMissing {
                ModelDownloadResumeStore.remove(for: destination)
            }
        }

        invalidateSession()
        switch result {
        case .success:
            onCompletion?(.success(destination))
            completion.continuation?.resume()
        case .failure(let error):
            onCompletion?(.failure(
                message: error.localizedDescription,
                resumeData: resumeData,
                wasCancelled: wasCancelled
            ))
            completion.continuation?.resume(throwing: error)
        }
        return true
    }

    private var cancellationRequested: Bool {
        state.withLock { $0.lifecycle.cancellationRequested }
    }

    private func checkCancellation() throws {
        guard !cancellationRequested else { throw CancellationError() }
    }

    private func beginInstallCommit() throws {
        let didBegin = state.withLock { state in
            state.lifecycle.beginCommit()
        }
        guard didBegin else { throw CancellationError() }
    }

    private func makeSession() -> URLSession {
        session.withLock { session in
            if let session { return session }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 60 * 60 * 4
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            let nextSession = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            session = nextSession
            return nextSession
        }
    }

    private func invalidateSession() {
        let activeSession = session.withLock { session in
            let activeSession = session
            session = nil
            return activeSession
        }
        activeSession?.invalidateAndCancel()
    }
}

enum ModelDownloadResumeStore {
    static func store(_ data: Data, for destination: URL) {
        try? data.write(to: resumeDataURL(for: destination), options: .atomic)
    }

    static func load(for destination: URL) -> Data? {
        let url = resumeDataURL(for: destination)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    static func remove(for destination: URL?) {
        guard let destination else { return }
        try? FileManager.default.removeItem(at: resumeDataURL(for: destination))
    }

    private static func resumeDataURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).resumeData")
    }
}
