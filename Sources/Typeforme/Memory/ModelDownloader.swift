import Combine
import Foundation

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
    private var runner: ResumableModelDownloadRunner?
    private var destination: URL?
    private var resumeData: Data?
    private var resumeDestination: URL?
    private var runID: UUID?

    func start(
        from url: URL,
        to destination: URL,
        checksumPolicy: ModelDownloadChecksumPolicy,
        expectedBytes: Int64? = nil
    ) {
        if task != nil {
            cancel()
        }

        self.destination = destination
        let runID = UUID()
        self.runID = runID
        state = .downloading(received: 0, total: 0)

        let runner = ResumableModelDownloadRunner(
            destination: destination,
            label: destination.lastPathComponent,
            checksumPolicy: checksumPolicy,
            expectedBytes: expectedBytes,
            onProgress: { [weak self] received, total in
                Task { @MainActor in
                    guard self?.runID == runID else { return }
                    self?.state = .downloading(received: received, total: total)
                }
            },
            onCompletion: { [weak self] completion in
                Task { @MainActor in
                    guard self?.runID == runID else { return }
                    self?.handleCompletion(completion)
                }
            }
        )
        let matchingResumeData = resumeDestination == destination ? resumeData : nil
        if matchingResumeData != nil {
            resumeData = nil
        } else {
            resumeData = nil
        }

        resumeDestination = destination
        self.runner = runner
        let nextTask = runner.start(from: url, resumeData: matchingResumeData)
        task = nextTask
    }

    func cancel() {
        guard let task else {
            if case .downloading = state { state = .idle }
            return
        }

        let cancelledDestination = destination
        runner?.cancel { [weak self] data in
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
        runID = nil
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
        runner = nil
        runID = nil
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
