import Foundation

enum ModelAutoInstallError: LocalizedError {
    case emptyURL(label: String)
    case invalidURL(String)
    case httpStatus(Int, label: String)

    var errorDescription: String? {
        switch self {
        case .emptyURL(let label):
            return "Download URL is empty for \(label)"
        case .invalidURL(let value):
            return "Invalid model download URL: \(value)"
        case .httpStatus(let status, let label):
            return "\(label) download failed with HTTP \(status)"
        }
    }
}

private final class ModelAutoInstallDownloadRunner: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let label: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(destination: URL, label: String) {
        self.destination = destination
        self.label = label
    }

    func download(from url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                self.continuation = continuation
                let resumeData = Self.loadResumeData(for: self.destination)
                let nextTask: URLSessionDownloadTask
                if let resumeData {
                    nextTask = self.session.downloadTask(withResumeData: resumeData)
                } else {
                    nextTask = self.session.downloadTask(with: URLRequest(url: url))
                }
                self.task = nextTask
                self.lock.unlock()
                nextTask.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let activeTask = task
        lock.unlock()
        activeTask?.cancel { data in
            if let data, !data.isEmpty {
                Self.storeResumeData(data, for: self.destination)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            Self.removeResumeData(for: destination)
            finish(.failure(ModelAutoInstallError.httpStatus(http.statusCode, label: label)))
            return
        }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            Self.removeResumeData(for: destination)
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
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !data.isEmpty {
            Self.storeResumeData(data, for: destination)
        } else if nsError.code != NSURLErrorCancelled {
            Self.removeResumeData(for: destination)
        }

        if nsError.code == NSURLErrorCancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        task = nil
        lock.unlock()

        guard let cont else { return }
        session.invalidateAndCancel()
        switch result {
        case .success:
            cont.resume()
        case .failure(let error):
            cont.resume(throwing: error)
        }
    }

    private static func storeResumeData(_ data: Data, for destination: URL) {
        try? data.write(to: resumeDataURL(for: destination), options: .atomic)
    }

    private static func loadResumeData(for destination: URL) -> Data? {
        let url = resumeDataURL(for: destination)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private static func removeResumeData(for destination: URL) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: destination))
    }

    private static func resumeDataURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).resumeData")
    }
}

enum ModelInstallRegistry {
    private static let lock = NSLock()
    private static var activeLabelsByPath: [String: String] = [:]

    static func markInstalling(path: String, label: String) {
        lock.lock()
        activeLabelsByPath[path] = label
        lock.unlock()
    }

    static func markFinished(path: String) {
        lock.lock()
        activeLabelsByPath.removeValue(forKey: path)
        lock.unlock()
    }

    static func isInstalling(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeLabelsByPath[path] != nil
    }
}

actor ModelAutoInstaller {
    static let shared = ModelAutoInstaller()

    private var tasks: [String: Task<Void, Error>] = [:]

    func ensureFile(atPath path: String, downloadURLString: String, label: String) async throws {
        if FileManager.default.fileExists(atPath: path) { return }

        let trimmedURL = downloadURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ModelAutoInstallError.emptyURL(label: label)
        }
        guard let url = URL(string: trimmedURL) else {
            throw ModelAutoInstallError.invalidURL(trimmedURL)
        }

        let key = "\(path)|\(url.absoluteString)"
        if let existing = tasks[key] {
            try await existing.value
            return
        }

        let destination = URL(fileURLWithPath: path)
        let task = Task {
            try await Self.download(from: url, to: destination, label: label)
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        try await task.value
    }

    private static func download(from url: URL, to destination: URL, label: String) async throws {
        Log.store.notice("auto-installing model: \(label, privacy: .public)")
        ModelInstallRegistry.markInstalling(path: destination.path, label: label)
        defer { ModelInstallRegistry.markFinished(path: destination.path) }

        let runner = ModelAutoInstallDownloadRunner(destination: destination, label: label)
        try await runner.download(from: url)
        Log.store.info("model auto-installed: \(destination.lastPathComponent, privacy: .public)")
    }
}
