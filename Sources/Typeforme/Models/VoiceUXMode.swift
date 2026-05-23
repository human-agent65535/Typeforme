import Foundation

enum VoiceUXMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic = "classic"
    case voiceDraft = "voice_draft"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:
            return "Classic"
        case .voiceDraft:
            return "Voice Draft (Beta)"
        }
    }

    var helpText: String {
        switch self {
        case .classic:
            return "Preserves the current hotkey-first behavior for compatibility."
        case .voiceDraft:
            return "Places recognized text in the focused input as a selected draft. Use Insert to accept, or run Style/Wand to replace the draft in place."
        }
    }
}
