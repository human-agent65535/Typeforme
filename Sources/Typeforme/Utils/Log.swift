import Foundation
import os

/// Central log categories. Normal logs must never include full user text; log
/// provider, latency, text length, hash, and error code instead.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.typeforme.mac"
    static let app          = Logger(subsystem: subsystem, category: "app")
    static let coordinator  = Logger(subsystem: subsystem, category: "coordinator")
    static let audio        = Logger(subsystem: subsystem, category: "audio")
    static let asr          = Logger(subsystem: subsystem, category: "asr")
    static let llm          = Logger(subsystem: subsystem, category: "llm")
    static let textCommit   = Logger(subsystem: subsystem, category: "textCommit")
    static let hotkey       = Logger(subsystem: subsystem, category: "hotkey")
    static let ui           = Logger(subsystem: subsystem, category: "ui")
    static let bridge       = Logger(subsystem: subsystem, category: "bridge")
    static let store        = Logger(subsystem: subsystem, category: "store")
}

enum LivePreviewFileTrace {
    private static let queue = DispatchQueue(label: "typeforme.live-preview.trace")
    private static let maxFileBytes = 1_048_576

    static func record(
        _ event: String,
        sessionID: String? = nil,
        fields: [String: any CustomStringConvertible] = [:]
    ) {
        let timestampMS = Int(Date().timeIntervalSince1970 * 1_000)
        let session = sessionID.map { String($0.prefix(8)) } ?? "none"
        var parts = [
            "ts_ms=\(timestampMS)",
            "event=\(sanitize(event))",
            "session=\(sanitize(session))",
        ]
        for key in fields.keys.sorted() {
            if let value = fields[key] {
                parts.append("\(sanitize(key))=\(sanitize(String(describing: value)))")
            }
        }
        let line = parts.joined(separator: " ") + "\n"
        queue.async {
            append(line)
        }
    }

    private static func append(_ line: String) {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.logsDir,
                withIntermediateDirectories: true
            )
            let url = AppPaths.logsDir.appendingPathComponent("live-preview-trace.log")
            rotateIfNeeded(url)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            handle.write(Data(line.utf8))
            try handle.close()
        } catch {
            Log.bridge.notice("Live preview trace write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxFileBytes
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
