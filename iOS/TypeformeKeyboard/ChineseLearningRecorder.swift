import Foundation

/// Tracks recently committed Chinese phrases and mirrors them to the App
/// Group so the host can show what rime's self-learning is being fed — the
/// librime user dictionary itself lives inside the extension sandbox and is
/// not enumerable from the host. Phrases of ≥2 CJK characters only: those
/// are the user-dictionary learning signal; single characters would flood
/// the capped list with noise.
final class ChineseLearningRecorder {
    private struct Entry {
        var count: Int
        var lastUsedAt: TimeInterval
    }

    private static let maxEntries = 200
    private static let persistDebounce: TimeInterval = 0.6

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var pendingPersist: DispatchWorkItem?

    func recordCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.unicodeScalars.allSatisfy(Self.isCJKScalar)
        else { return }
        loadIfNeeded()
        var entry = entries[trimmed] ?? Entry(count: 0, lastUsedAt: 0)
        entry.count += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        entries[trimmed] = entry
        trimIfNeeded()
        schedulePersist()
    }

    func reset() {
        pendingPersist?.cancel()
        pendingPersist = nil
        entries = [:]
        loaded = true
        KeyboardSharedDefaults.clearChineseLearningSnapshot()
    }

    func flush() {
        guard pendingPersist != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = nil
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let snapshot = KeyboardSharedDefaults.loadChineseLearningSnapshot() else { return }
        for entry in snapshot.entries {
            entries[entry.text] = Entry(count: entry.count, lastUsedAt: entry.lastUsedAt)
        }
    }

    private func trimIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let overflow = entries.count - Self.maxEntries
        let oldestKeys = entries
            .sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            entries.removeValue(forKey: key)
        }
    }

    private func schedulePersist() {
        guard pendingPersist == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPersist = nil
            self?.persist()
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDebounce, execute: work)
    }

    private func persist() {
        let snapshotEntries = entries
            .map { KeyboardChineseLearningEntry(text: $0.key, count: $0.value.count, lastUsedAt: $0.value.lastUsedAt) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        KeyboardSharedDefaults.saveChineseLearningSnapshot(KeyboardChineseLearningSnapshot(
            updatedAt: Date().timeIntervalSince1970,
            entries: snapshotEntries
        ))
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
