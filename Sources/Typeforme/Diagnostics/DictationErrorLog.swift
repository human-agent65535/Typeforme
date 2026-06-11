import Foundation

/// In-memory record of recent dictation errors. The HUD error capsule
/// auto-dismisses, so Diagnostics needs somewhere the user can re-read what
/// failed after it disappears. Session-only by design: error strings are
/// operational (provider / permission / network), but they are still not
/// worth persisting to disk outside debug capture.
@MainActor
final class DictationErrorLog: ObservableObject {
    static let shared = DictationErrorLog()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let message: String
    }

    private static let capacity = 5

    @Published private(set) var entries: [Entry] = []

    func record(_ message: String) {
        entries.insert(Entry(at: Date(), message: message), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
