import Combine
import Foundation
import os.lock

/// Streams a single GGUF (or any large file) from a URL to disk with live
/// progress, suitable for binding from SwiftUI via `@ObservedObject`.
/// Used by the Settings UI download buttons.
@MainActor
final class ModelDownloader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case completed(at: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var delegate: ModelDownloadDelegate?
    private var destination: URL?
    private var resumeData: Data?
    private var resumeDestination: URL?

    func start(
        from url: URL,
        to destination: URL,
        expectedSHA256: String? = nil,
        expectedBytes: Int64? = nil
    ) {
        if task != nil {
            cancel()
        }

        self.destination = destination
        state = .downloading(received: 0, total: 0)

        let delegate = ModelDownloadDelegate(
            destination: destination,
            expectedSHA256: expectedSHA256,
            expectedBytes: expectedBytes,
            onProgress: { [weak self] received, total in
                Task { @MainActor in
                    self?.state = .downloading(received: received, total: total)
                }
            },
            onCompletion: { [weak self] completion in
                Task { @MainActor in
                    self?.handleCompletion(completion)
                }
            }
        )
        let session = URLSession(
            configuration: Self.sessionConfiguration(),
            delegate: delegate,
            delegateQueue: Self.delegateQueue()
        )

        let matchingResumeData = resumeDestination == destination ? resumeData : nil
        let diskResumeData = matchingResumeData ?? ModelDownloadResumeStore.load(for: destination)
        let nextTask: URLSessionDownloadTask
        if let data = matchingResumeData {
            nextTask = session.downloadTask(withResumeData: data)
            resumeData = nil
        } else if let diskResumeData {
            nextTask = session.downloadTask(withResumeData: diskResumeData)
        } else {
            resumeData = nil
            nextTask = session.downloadTask(with: URLRequest(url: url))
        }

        resumeDestination = destination
        self.delegate = delegate
        self.session = session
        task = nextTask
        nextTask.resume()
    }

    func cancel() {
        guard let task else {
            if case .downloading = state { state = .idle }
            return
        }

        let cancelledDestination = destination
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.storeResumeData(data, for: cancelledDestination)
                }
                if self.task === task {
                    self.finishActiveTask()
                    if case .downloading = self.state {
                        self.state = .idle
                    }
                }
            }
        }
        if case .downloading = state { state = .idle }
    }

    func reset() {
        cancel()
        resumeData = nil
        resumeDestination = nil
        ModelDownloadResumeStore.remove(for: destination)
        state = .idle
    }

    var progress: Double {
        if case .downloading(let received, let total) = state, total > 0 {
            return Double(received) / Double(total)
        }
        return 0
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 4
        return config
    }

    private static func delegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }

    private func handleCompletion(_ completion: ModelDownloadCompletion) {
        switch completion {
        case .success(let url):
            finishActiveTask()
            resumeData = nil
            resumeDestination = nil
            state = .completed(at: url)
            Log.store.info("model downloaded: \(url.lastPathComponent, privacy: .public)")
        case .failure(let message, let producedResumeData, let wasCancelled):
            if let producedResumeData, !producedResumeData.isEmpty {
                storeResumeData(producedResumeData, for: destination)
            } else if !wasCancelled {
                ModelDownloadResumeStore.remove(for: destination)
            }
            finishActiveTask()
            state = wasCancelled ? .idle : .failed(message)
        }
    }

    private func finishActiveTask() {
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }

    private func storeResumeData(_ data: Data, for destination: URL?) {
        resumeData = data
        resumeDestination = destination
        guard let destination else { return }
        ModelDownloadResumeStore.store(data, for: destination)
    }
}

@MainActor
final class ModelDownloadRegistry: ObservableObject {
    private var downloaders: [String: ModelDownloader] = [:]
    private var cancellables: [String: AnyCancellable] = [:]

    func downloader(for key: String) -> ModelDownloader {
        if let downloader = downloaders[key] {
            return downloader
        }

        let downloader = ModelDownloader()
        downloaders[key] = downloader
        cancellables[key] = downloader.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
        return downloader
    }
}

private enum ModelDownloadCompletion: Sendable {
    case success(URL)
    case failure(message: String, resumeData: Data?, wasCancelled: Bool)
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedSHA256: String?
    private let expectedBytes: Int64?
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onCompletion: @Sendable (ModelDownloadCompletion) -> Void
    private let didComplete = OSAllocatedUnfairLock(initialState: false)

    init(
        destination: URL,
        expectedSHA256: String?,
        expectedBytes: Int64?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onCompletion: @escaping @Sendable (ModelDownloadCompletion) -> Void
    ) {
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            ModelDownloadResumeStore.remove(for: destination)
            finish(.failure(message: "HTTP \(http.statusCode)", resumeData: nil, wasCancelled: false))
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
                label: destination.lastPathComponent
            )
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            ModelDownloadResumeStore.remove(for: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(message: error.localizedDescription, resumeData: nil, wasCancelled: false))
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
        finish(
            .failure(
                message: error.localizedDescription,
                resumeData: producedResumeData,
                wasCancelled: nsError.code == NSURLErrorCancelled
            )
        )
    }

    private func finish(_ completion: ModelDownloadCompletion) {
        let shouldComplete = didComplete.withLock { didComplete in
            guard !didComplete else { return false }
            didComplete = true
            return true
        }
        guard shouldComplete else { return }
        onCompletion(completion)
    }
}

private enum ModelDownloadResumeStore {
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
