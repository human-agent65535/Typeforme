import Foundation

enum VoiceUXMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic = "classic"
    case voicePreview = "voice_preview"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:
            return "Classic"
        case .voicePreview:
            return "Voice Preview"
        }
    }

    var helpText: String {
        switch self {
        case .classic:
            return "Preserves the current hotkey-first behavior for compatibility."
        case .voicePreview:
            return "Keeps the HUD available as a small icon, shows live speech preview while recording, and inserts the final text directly into the focused input."
        }
    }
}
