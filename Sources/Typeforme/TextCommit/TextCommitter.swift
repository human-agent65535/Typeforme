import Foundation

actor CommitCancellationToken {
    private var cancelled = false
    private var commitStarted = false

    /// Returns false once an irreversible text commit has begun. At that point
    /// the caller must let the completed insertion win instead of reporting a
    /// cancellation after text has already reached the target app.
    @discardableResult
    func cancel() -> Bool {
        guard !commitStarted else { return false }
        cancelled = true
        return true
    }

    func isCancelled() -> Bool {
        cancelled
    }

    func beginCommit(taskIsCancelled: Bool) -> Bool {
        guard !cancelled, !taskIsCancelled else { return false }
        commitStarted = true
        return true
    }
}

@MainActor
protocol TextCommitter: AnyObject {
    /// Insert `text` into the target app. If `snapshot` is supplied, the
    /// committer refocuses that app first.
    func commit(
        _ text: String,
        to snapshot: FrontmostAppSnapshot?,
        target: TextInsertionTargetSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws
}

enum TextCommitterError: LocalizedError {
    case accessibilityNotTrusted
    case eventSourceFailed
    case eventPostFailed
    case targetFocusLost
    case inputTargetChanged
    case selectionChanged
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Text copied to Clipboard. Grant Accessibility in System Settings → Privacy & Security → Accessibility to let Typeforme insert text automatically."
        case .eventSourceFailed: return "Could not create CGEventSource. Text copied to Clipboard."
        case .eventPostFailed:   return "Could not synthesize text input. Text copied to Clipboard."
        case .targetFocusLost:   return "Target app lost focus. Text copied to Clipboard."
        case .inputTargetChanged:return "Input target changed. Text copied to Clipboard."
        case .selectionChanged:  return "Selection changed. Replacement copied to Clipboard."
        case .cancelled:         return "Insertion cancelled."
        }
    }
}
