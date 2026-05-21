import Foundation
import Combine

/// Streams a single GGUF (or any large file) from a URL to disk with live
/// progress, suitable for binding from SwiftUI via `@ObservedObject`.
/// Used by the Settings UI download buttons.
final class ModelDownloader: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case completed(at: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var resumeData: Data?
    private var resumeDestination: URL?
    /// Delegate callbacks fire on the main queue so we can safely touch
    /// `@Published` from inside them.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 60
        config.timeoutIntervalForResource = 60 * 60 * 4  // GGUF can take a while
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    func start(from url: URL, to destination: URL) {
        if task != nil {
            cancel()
        }
        self.destination = destination
        state = .downloading(received: 0, total: 0)
        let t: URLSessionDownloadTask
        if let data = resumeData, resumeDestination == destination {
            t = session.downloadTask(withResumeData: data)
            resumeData = nil
        } else {
            resumeData = nil
            let req = URLRequest(url: url)
            t = session.downloadTask(with: req)
        }
        resumeDestination = destination
        task = t
        t.resume()
    }

    func cancel() {
        guard let task else {
            if case .downloading = state { state = .idle }
            return
        }
        let cancelledDestination = destination
        task.cancel { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.resumeData = data
                    self.resumeDestination = cancelledDestination
                }
                let isCurrentTask = self.task === task
                if isCurrentTask {
                    self.task = nil
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
        state = .idle
    }

    var progress: Double {
        if case .downloading(let r, let t) = state, t > 0 {
            return Double(r) / Double(t)
        }
        return 0
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        state = .downloading(received: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is a temporary file that vanishes when this delegate
        // returns, so move it synchronously.
        guard let dest = destination else {
            state = .failed("no destination set")
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            state = .failed("HTTP \(http.statusCode)")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            resumeData = nil
            resumeDestination = nil
            state = .completed(at: dest)
            Log.store.info("model downloaded: \(dest.lastPathComponent, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        if case .completed = state { return }     // success path beat us here
        let isCurrentTask = self.task.map { $0 === task } ?? false
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty {
            resumeData = data
            resumeDestination = destination
        }
        guard isCurrentTask else { return }
        self.task = nil
        if ns.code == NSURLErrorCancelled {
            state = .idle
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}
