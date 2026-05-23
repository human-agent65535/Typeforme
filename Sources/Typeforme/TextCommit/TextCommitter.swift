import Foundation

actor CommitCancellationToken {
    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func isCancelled() -> Bool {
        cancelled
    }
}

@MainActor
protocol TextCommitter: AnyObject {
    /// Insert `text` into the target app. If `snapshot` is supplied, the
    /// committer refocuses that app first.
    func commit(
        _ text: String,
        to snapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws
}

enum TextCommitterError: LocalizedError {
    case accessibilityNotTrusted
    case eventSourceFailed
    case eventPostFailed
    case targetFocusLost
    case selectionChanged
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Text copied to Clipboard. Grant Accessibility in System Settings → Privacy & Security → Accessibility to let Typeforme insert text automatically."
        case .eventSourceFailed: return "Could not create CGEventSource. Text copied to Clipboard."
        case .eventPostFailed:   return "Could not synthesize text input. Text copied to Clipboard."
        case .targetFocusLost:   return "Target app lost focus. Text copied to Clipboard."
        case .selectionChanged:  return "Selection changed. Replacement copied to Clipboard."
        case .cancelled:         return "Insertion cancelled."
        }
    }
}
