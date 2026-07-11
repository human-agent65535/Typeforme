import Foundation

enum KeyboardMarkedTextOwnershipPolicy {
    static func contextsMatch(
        before: String,
        after: String,
        markedText: String,
        anchorBefore: String,
        anchorAfter: String
    ) -> Bool {
        guard !markedText.isEmpty else { return false }

        var beforeCandidates = [before]
        if before.hasSuffix(markedText) {
            beforeCandidates.append(String(before.dropLast(markedText.count)))
        }
        let beforeMatches = beforeCandidates.contains { candidate in
            anchorBefore.isEmpty
                ? candidate.isEmpty
                : contextBeforeMatches(candidate, anchor: anchorBefore)
        }
        guard beforeMatches else { return false }

        return anchorAfter.isEmpty
            ? after.isEmpty
            : contextAfterMatches(after, anchor: anchorAfter)
    }

    private static func contextBeforeMatches(_ candidate: String, anchor: String) -> Bool {
        if candidate.hasSuffix(anchor) { return true }
        return !candidate.isEmpty && anchor.hasSuffix(candidate)
    }

    private static func contextAfterMatches(_ candidate: String, anchor: String) -> Bool {
        if candidate.hasPrefix(anchor) { return true }
        return !candidate.isEmpty && anchor.hasPrefix(candidate)
    }
}
