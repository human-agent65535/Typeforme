import Foundation
import OSLog

final class ReturnTracker {
    private let logName: String
    private let enabledKey: String
    private let logger = Logger(subsystem: TypeformeBundleConfiguration.hostBundleIdentifier, category: "return")

    init(logName: String, enabledKey: String) {
        self.logName = logName
        self.enabledKey = enabledKey
    }

    func reset(_ message: String) {
        guard isEnabled else { return }
        guard let url = traceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try traceLine(message).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("return trace reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func append(_ message: String) {
        guard isEnabled else { return }
        guard let url = traceURL,
              let data = traceLine(message).data(using: .utf8)
        else { return }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                reset(message)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            logger.error("return trace append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("Typeforme return-to-keyboard: \(message)")
    }

    private var traceURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(logName)
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private func traceLine(_ message: String) -> String {
        "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    }
}
