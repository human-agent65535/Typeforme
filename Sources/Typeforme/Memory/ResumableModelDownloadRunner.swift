import Foundation
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

final class ResumableModelDownloadRunner: NSObject, URLSessionDownloadDelegate {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        var didComplete = false
        var cancellationRequested = false
    }

    private let destination: URL
    private let label: String
    private let expectedSHA256: String?
    private let expectedBytes: Int64?
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private let onCompletion: (@Sendable (ModelDownloadCompletion) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let session = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    init(
        destination: URL,
        label: String? = nil,
        expectedSHA256: String?,
        expectedBytes: Int64?,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        onCompletion: (@Sendable (ModelDownloadCompletion) -> Void)? = nil
    ) {
        self.destination = destination
        self.label = label ?? destination.lastPathComponent
        self.expectedSHA256 = expectedSHA256
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
            state.didComplete = false
            let cancellationRequested = state.cancellationRequested
            if !cancellationRequested {
                state.cancellationRequested = false
            }
            return cancellationRequested
        }
        if cancellationRequested {
            nextTask.cancel()
            finish(.failure(CancellationError()), wasCancelled: true)
        } else {
            nextTask.resume()
        }
        return nextTask
    }

    func cancel(onResumeData: (@Sendable (Data?) -> Void)? = nil) {
        let cancellation = state.withLock { state in
            state.cancellationRequested = true
            return (task: state.task, hasContinuation: state.continuation != nil)
        }
        guard let activeTask = cancellation.task else {
            if cancellation.hasContinuation {
                finish(.failure(CancellationError()), wasCancelled: true)
            }
            onResumeData?(nil)
            return
        }
        activeTask.cancel { data in
            if let data, !data.isEmpty {
                ModelDownloadResumeStore.store(data, for: self.destination)
            }
            onResumeData?(data)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            ModelDownloadResumeStore.remove(for: destination)
            finish(.failure(ModelDownloadRunnerError.httpStatus(http.statusCode, label: label)))
            return
        }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ModelDownloadIntegrity.validateFile(
                at: location,
                expectedSHA256: expectedSHA256,
                expectedBytes: expectedBytes,
                label: label
            )
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            ModelDownloadResumeStore.remove(for: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        let producedResumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let producedResumeData, !producedResumeData.isEmpty {
            ModelDownloadResumeStore.store(producedResumeData, for: destination)
        } else if nsError.code != NSURLErrorCancelled {
            ModelDownloadResumeStore.remove(for: destination)
        }

        if nsError.code == NSURLErrorCancelled {
            finish(.failure(CancellationError()), resumeData: producedResumeData, wasCancelled: true)
        } else {
            finish(.failure(error), resumeData: producedResumeData, wasCancelled: false)
        }
    }

    private func finish(_ result: Result<Void, Error>, resumeData: Data? = nil, wasCancelled: Bool = false) {
        let continuation = state.withLock { state in
            guard !state.didComplete else { return nil as CheckedContinuation<Void, Error>? }
            state.didComplete = true
            state.task = nil
            state.cancellationRequested = false
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }

        invalidateSession()
        switch result {
        case .success:
            onCompletion?(.success(destination))
            continuation?.resume()
        case .failure(let error):
            onCompletion?(.failure(
                message: error.localizedDescription,
                resumeData: resumeData,
                wasCancelled: wasCancelled
            ))
            continuation?.resume(throwing: error)
        }
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
