import Foundation
import os.lock

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

enum ModelInstallRegistry {
    private static let activeLabelsByPath = OSAllocatedUnfairLock(initialState: [String: String]())

    static func markInstalling(path: String, label: String) {
        activeLabelsByPath.withLock { labels in
            labels[path] = label
        }
    }

    static func markFinished(path: String) {
        activeLabelsByPath.withLock { labels in
            labels[path] = nil
        }
    }

    static func isInstalling(path: String) -> Bool {
        activeLabelsByPath.withLock { labels in
            labels[path] != nil
        }
    }
}

actor ModelAutoInstaller {
    static let shared = ModelAutoInstaller()

    private var tasks: [String: Task<Void, Error>] = [:]

    func ensureFile(
        atPath path: String,
        downloadURLString: String,
        label: String,
        expectedBytes: Int64? = nil
    ) async throws {
        let trimmedURL = downloadURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ModelAutoInstallError.emptyURL(label: label)
        }
        guard let url = URL(string: trimmedURL) else {
            throw ModelAutoInstallError.invalidURL(trimmedURL)
        }
        let existingFileChecksumPolicy = ModelDownloadIntegrity.expectedSHA256(for: url)
            .map(ModelDownloadChecksumPolicy.verifySHA256) ?? .allowMissingChecksum

        if FileManager.default.fileExists(atPath: path) {
            do {
                try ModelDownloadIntegrity.validateFile(
                    at: URL(fileURLWithPath: path),
                    checksumPolicy: existingFileChecksumPolicy,
                    expectedBytes: expectedBytes,
                    label: label
                )
                return
            } catch {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let key = "\(path)|\(url.absoluteString)"
        if let existing = tasks[key] {
            try await existing.value
            return
        }

        let destination = URL(fileURLWithPath: path)
        let task = Task {
            let checksumPolicy = try ModelDownloadIntegrity.checksumPolicy(for: url, label: label)
            try await Self.download(
                from: url,
                to: destination,
                label: label,
                checksumPolicy: checksumPolicy,
                expectedBytes: expectedBytes
            )
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        try await task.value
    }

    private static func download(
        from url: URL,
        to destination: URL,
        label: String,
        checksumPolicy: ModelDownloadChecksumPolicy,
        expectedBytes: Int64?
    ) async throws {
        Log.store.notice("auto-installing model: \(label, privacy: .public)")
        ModelInstallRegistry.markInstalling(path: destination.path, label: label)
        defer { ModelInstallRegistry.markFinished(path: destination.path) }

        let runner = ResumableModelDownloadRunner(
            destination: destination,
            label: label,
            checksumPolicy: checksumPolicy,
            expectedBytes: expectedBytes
        )
        try await runner.download(from: url)
        Log.store.info("model auto-installed: \(destination.lastPathComponent, privacy: .public)")
    }
}
