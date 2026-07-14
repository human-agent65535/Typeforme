import Foundation

enum AsyncTaskBarrierError: Error, Sendable {
    case timedOut
}

/// Waits for a shared task without cancelling or joining that task when this
/// caller times out or is cancelled. This keeps one request's deadline from
/// changing the lifecycle of the shared operation.
enum AsyncTaskBarrier {
    static func wait(
        for task: Task<Void, Never>,
        timeoutNanoseconds: UInt64? = nil
    ) async throws {
        try Task.checkCancellation()
        let completion = AsyncTaskBarrierCompletion()
        Task.detached {
            await task.value
            completion.resolve(.completed)
        }
        let timeoutTask: Task<Void, Never>?
        if let timeoutNanoseconds {
            timeoutTask = Task.detached {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    completion.resolve(.timedOut)
                } catch {
                    // The barrier or caller completed first.
                }
            }
        } else {
            timeoutTask = nil
        }
        defer { timeoutTask?.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
            }
        } onCancel: {
            completion.resolve(.cancelled)
        }
    }
}

private final class AsyncTaskBarrierCompletion: @unchecked Sendable {
    enum Outcome {
        case completed
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var outcome: Outcome?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let resolved = lock.withLock { () -> Outcome? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let resolved {
            Self.resume(continuation, with: resolved)
        }
    }

    func resolve(_ outcome: Outcome) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        if let continuation {
            Self.resume(continuation, with: outcome)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, any Error>,
        with outcome: Outcome
    ) {
        switch outcome {
        case .completed:
            continuation.resume()
        case .timedOut:
            continuation.resume(throwing: AsyncTaskBarrierError.timedOut)
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
    }
}
