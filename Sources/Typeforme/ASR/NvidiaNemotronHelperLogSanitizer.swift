import Foundation

enum NvidiaNemotronHelperLogSanitizer {
    static func publicStderrLineSummary(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }

        if trimmed.hasPrefix("typeforme-nemotron-asr ready ") {
            return "ready"
        }
        if trimmed.hasPrefix("typeforme-nemotron-asr stream chunk=") {
            return "stream_chunk"
        }

        let lower = trimmed.lowercased()
        if lower.contains("traceback") || lower.contains("exception") || lower.contains("error") || lower.contains("failed") {
            return "error_line chars=\(trimmed.count)"
        }
        if lower.contains("warn") {
            return "warning_line chars=\(trimmed.count)"
        }
        if lower.contains("load") || lower.contains("model") || lower.contains("encoder") || lower.contains("decoder") || lower.contains("tokenizer") {
            return "runtime_status chars=\(trimmed.count)"
        }
        return "redacted_line chars=\(trimmed.count)"
    }

    static func publicErrorSummary(stderr: String, exitCode: Int32) -> String {
        let lines = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lastSummary = lines.last.map(publicStderrLineSummary) ?? "none"
        return "Nemotron helper failed exit_code=\(exitCode) stderr_lines=\(lines.count) stderr_chars=\(stderr.count) last_status=\(lastSummary)"
    }
}
