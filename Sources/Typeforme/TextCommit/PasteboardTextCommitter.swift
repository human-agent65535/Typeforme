import AppKit
import ApplicationServices

/// Spec §21 flow:
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

    static func copyForManualPaste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transientPasteboardType)
    }

    func commit(
        _ text: String,
        to snapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await checkCancelled(cancelToken)

        guard AccessibilityPermissions.isTrusted else {
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

        guard AccessibilityPermissions.isTrusted else {
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
            let current = TextEditTargetCapture.currentSelectedText(in: appSnapshot) ?? ""
            guard current == target.targetText else {
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
            let current = TextEditTargetCapture.currentValue(of: target) ?? ""
            guard current == target.targetText else {
                Self.copyForManualPaste(text)
                throw TextCommitterError.selectionChanged
            }
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

        for chunk in Self.unicodeInputChunks(for: text) {
            try await checkCancelled(cancelToken)
            let units = Array(chunk.utf16)
            try units.withUnsafeBufferPointer { buffer in
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else {
                    throw TextCommitterError.eventPostFailed
                }
                down.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            await Task.yield()
        }
        try await checkCancelled(cancelToken)
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
        if Task.isCancelled {
            throw TextCommitterError.cancelled
        }
        if let token, await token.isCancelled() {
            throw TextCommitterError.cancelled
        }
    }
}
