import AppKit
import ApplicationServices

/// Automatic text commit flow:
///   refocus target → synthesize Unicode text input directly into the focused
///   control.
///
/// The pasteboard is not used as the automatic transport. It is only populated
/// after direct input cannot be attempted or fails, so the user still has a
/// manual paste fallback without overwriting their Clipboard on every success.
@MainActor
final class PasteboardTextCommitter: TextCommitter {
    private static let unicodeInputChunkUTF16Limit = 32
    private static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private struct PreparedUnicodeEvents {
        let down: CGEvent
        let up: CGEvent
    }

    static func copyForManualPaste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transientPasteboardType)
    }

    func commit(
        _ text: String,
        to snapshot: FrontmostAppSnapshot?,
        target: TextInsertionTargetSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await checkCancelled(cancelToken)

        guard AppPermissions.accessibilityTrusted else {
            Self.copyForManualPaste(text)
            throw TextCommitterError.accessibilityNotTrusted
        }

        if let snapshot {
            await MainActor.run { FrontmostAppCapture.refocus(snapshot) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let isTargetFrontmost = await MainActor.run {
                FrontmostAppCapture.isFrontmost(snapshot)
            }
            guard isTargetFrontmost else {
                Self.copyForManualPaste(text)
                throw TextCommitterError.targetFocusLost
            }
        }
        try await checkCancelled(cancelToken)

        // A nil target means this session began without a verifiable AX input
        // owner. Never upgrade it to automatic insertion merely because the
        // user granted Accessibility while transcription was in flight.
        guard let target,
              TextEditTargetCapture.insertionTargetStillMatches(target, in: snapshot)
        else {
            Self.copyForManualPaste(text)
            throw TextCommitterError.inputTargetChanged
        }

        do {
            try await sendUnicodeText(text, cancelToken: cancelToken)
        } catch TextCommitterError.cancelled {
            throw TextCommitterError.cancelled
        } catch {
            Self.copyForManualPaste(text)
            throw error
        }
    }

    func commitTextEdit(
        _ text: String,
        target: TextEditTargetSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await checkCancelled(cancelToken)

        guard AppPermissions.accessibilityTrusted else {
            Self.copyForManualPaste(text)
            throw TextCommitterError.accessibilityNotTrusted
        }

        if let appSnapshot {
            await MainActor.run { FrontmostAppCapture.refocus(appSnapshot) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let isTargetFrontmost = await MainActor.run {
                FrontmostAppCapture.isFrontmost(appSnapshot)
            }
            guard isTargetFrontmost else {
                Self.copyForManualPaste(text)
                throw TextCommitterError.targetFocusLost
            }
        }
        try await checkCancelled(cancelToken)

        switch target.kind {
        case .selection:
            guard TextEditTargetCapture.selectionStillMatches(target, in: appSnapshot) else {
                Self.copyForManualPaste(text)
                throw TextCommitterError.selectionChanged
            }
            do {
                try await sendUnicodeText(text, cancelToken: cancelToken)
            } catch TextCommitterError.cancelled {
                throw TextCommitterError.cancelled
            } catch {
                Self.copyForManualPaste(text)
                throw error
            }
        case .focusedValue:
            guard TextEditTargetCapture.focusedValueStillMatches(target, in: appSnapshot) else {
                Self.copyForManualPaste(text)
                throw TextCommitterError.selectionChanged
            }
            try await beginIrreversibleCommit(cancelToken)
            guard TextEditTargetCapture.setFocusedValue(text, target: target) else {
                Self.copyForManualPaste(text)
                throw TextCommitterError.eventPostFailed
            }
        }
    }

    // MARK: - Synthetic text input

    private func sendUnicodeText(_ text: String, cancelToken: CommitCancellationToken?) async throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextCommitterError.eventSourceFailed
        }

        try await TextCommitEventSequence.run(
            chunks: Self.unicodeInputChunks(for: text),
            prepare: { chunk in
                let units = Array(chunk.utf16)
                return try units.withUnsafeBufferPointer { buffer in
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                    else {
                        throw TextCommitterError.eventPostFailed
                    }
                    down.keyboardSetUnicodeString(
                        stringLength: buffer.count,
                        unicodeString: buffer.baseAddress
                    )
                    return PreparedUnicodeEvents(down: down, up: up)
                }
            },
            checkCancellation: {
                try await self.beginIrreversibleCommit(cancelToken)
            },
            post: { events in
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
            }
        )
    }

    private static func unicodeInputChunks(for text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUTF16Count = 0

        for character in text {
            let characterText = String(character)
            let characterUTF16Count = characterText.utf16.count
            if !current.isEmpty,
               currentUTF16Count + characterUTF16Count > unicodeInputChunkUTF16Limit {
                chunks.append(current)
                current = ""
                currentUTF16Count = 0
            }
            current += characterText
            currentUTF16Count += characterUTF16Count
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func checkCancelled(_ token: CommitCancellationToken?) async throws {
        let tokenIsCancelled: Bool
        if let token {
            tokenIsCancelled = await token.isCancelled()
        } else {
            tokenIsCancelled = false
        }
        if TextCommitCancellationPolicy.shouldAbort(
            taskIsCancelled: Task.isCancelled,
            tokenIsCancelled: tokenIsCancelled
        ) {
            throw TextCommitterError.cancelled
        }
    }

    private func beginIrreversibleCommit(_ token: CommitCancellationToken?) async throws {
        let taskIsCancelled = Task.isCancelled
        if let token {
            guard await token.beginCommit(taskIsCancelled: taskIsCancelled) else {
                throw TextCommitterError.cancelled
            }
        } else if taskIsCancelled {
            throw TextCommitterError.cancelled
        }
    }
}

enum TextCommitCancellationPolicy {
    static func shouldAbort(
        taskIsCancelled: Bool,
        tokenIsCancelled: Bool
    ) -> Bool {
        taskIsCancelled || tokenIsCancelled
    }
}

/// Builds every reversible event before the final cancellation boundary, then
/// posts the prepared sequence without a suspension point that could split the
/// commit between chunks.
@MainActor
enum TextCommitEventSequence {
    static func run<Prepared>(
        chunks: [String],
        prepare: (String) throws -> Prepared,
        checkCancellation: () async throws -> Void,
        post: (Prepared) -> Void
    ) async throws {
        let prepared = try chunks.map(prepare)
        try await checkCancellation()
        for item in prepared {
            post(item)
        }
    }
}
