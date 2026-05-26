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

    func insertVoiceDraft(
        _ text: String,
        target: VoiceDraftInsertionTarget,
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws -> VoiceDraftTextSnapshot {
        try await prepareTarget(appSnapshot: appSnapshot, cancelToken: cancelToken)
        TextEditTargetCapture.setSelectedRange(target.originalSelectedRange, in: target.element)
        try await sendUnicodeText(text, cancelToken: cancelToken)

        let draftRange = CFRange(
            location: target.originalSelectedRange.location,
            length: (text as NSString).length
        )
        _ = TextEditTargetCapture.setSelectedRange(draftRange, in: target.element)
        return VoiceDraftTextSnapshot(
            element: target.element,
            originalSelectedRange: target.originalSelectedRange,
            originalSelectedText: target.originalSelectedText,
            originalValue: target.originalValue,
            draftRange: draftRange,
            draftText: text,
            anchorRect: TextEditTargetCapture.bounds(for: draftRange, in: target.element)
        )
    }

    func replaceVoiceDraft(
        _ text: String,
        draft: VoiceDraftTextSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws -> VoiceDraftTextSnapshot {
        try await prepareTarget(appSnapshot: appSnapshot, cancelToken: cancelToken)
        try verifyDraftStillCurrent(draft)
        _ = TextEditTargetCapture.setSelectedRange(draft.draftRange, in: draft.element)
        try await sendUnicodeText(text, cancelToken: cancelToken)

        var updated = draft
        updated.draftText = text
        updated.draftRange = CFRange(
            location: draft.draftRange.location,
            length: (text as NSString).length
        )
        _ = TextEditTargetCapture.setSelectedRange(updated.draftRange, in: updated.element)
        updated.anchorRect = TextEditTargetCapture.bounds(for: updated.draftRange, in: updated.element)
        return updated
    }

    func acceptVoiceDraft(
        _ draft: VoiceDraftTextSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await prepareTarget(appSnapshot: appSnapshot, cancelToken: cancelToken)
        try verifyDraftStillCurrent(draft)
        let cursor = CFRange(location: draft.draftRange.location + draft.draftRange.length, length: 0)
        _ = TextEditTargetCapture.setSelectedRange(cursor, in: draft.element)
    }

    func removeVoiceDraft(
        _ draft: VoiceDraftTextSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await prepareTarget(appSnapshot: appSnapshot, cancelToken: cancelToken)

        if let originalValue = draft.originalValue,
           TextEditTargetCapture.setValue(originalValue, in: draft.element) {
            _ = TextEditTargetCapture.setSelectedRange(draft.originalSelectedRange, in: draft.element)
            return
        }

        _ = TextEditTargetCapture.setSelectedRange(draft.draftRange, in: draft.element)
        if draft.originalSelectedText.isEmpty {
            try await sendDelete(cancelToken: cancelToken)
        } else {
            try await sendUnicodeText(draft.originalSelectedText, cancelToken: cancelToken)
            _ = TextEditTargetCapture.setSelectedRange(draft.originalSelectedRange, in: draft.element)
        }
    }

    // MARK: - Synthetic text input

    private func prepareTarget(
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await checkCancelled(cancelToken)

        guard AccessibilityPermissions.isTrusted else {
            throw TextCommitterError.accessibilityNotTrusted
        }

        if let appSnapshot {
            await MainActor.run { FrontmostAppCapture.refocus(appSnapshot) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let isTargetFrontmost = await MainActor.run {
                FrontmostAppCapture.isFrontmost(appSnapshot)
            }
            guard isTargetFrontmost else {
                throw TextCommitterError.targetFocusLost
            }
        }
        try await checkCancelled(cancelToken)
    }

    private func verifyDraftStillCurrent(_ draft: VoiceDraftTextSnapshot) throws {
        guard let value = TextEditTargetCapture.currentValue(of: draft.element) else { return }
        let ns = value as NSString
        guard draft.draftRange.location >= 0,
              draft.draftRange.length >= 0,
              draft.draftRange.location + draft.draftRange.length <= ns.length
        else {
            throw TextCommitterError.selectionChanged
        }
        let current = ns.substring(
            with: NSRange(location: draft.draftRange.location, length: draft.draftRange.length)
        )
        guard current == draft.draftText else {
            throw TextCommitterError.selectionChanged
        }
    }

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

    private func sendDelete(cancelToken: CommitCancellationToken?) async throws {
        try await checkCancelled(cancelToken)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
        else {
            throw TextCommitterError.eventSourceFailed
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
