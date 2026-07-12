import Foundation

enum KeyboardToolbarIconRole: CaseIterable, Equatable, Sendable {
    case dictation
    case refineStyle
    case undo
    case command
    case voiceMode
    case host
    case keyboardMode
    case candidateChevron
}

enum KeyboardToolbarSymbolWeight: Equatable, Sendable {
    case regular
    case medium
}

struct KeyboardToolbarIconMetrics: Equatable, Sendable {
    let pointSize: Double
    let weight: KeyboardToolbarSymbolWeight
    let verticalOffset: Double
    let horizontalInset: Double
    let cornerRadius: Double
}

enum KeyboardToolbarIconPolicy {
    static let disabledOpacity = 0.42

    /// SF Symbols with the same point size have very different optical bounds.
    /// These values target a common perceived height inside the existing 32x34
    /// toolbar slots; they do not own visibility, enablement, or button action.
    static func metrics(for role: KeyboardToolbarIconRole) -> KeyboardToolbarIconMetrics {
        switch role {
        case .dictation:
            return KeyboardToolbarIconMetrics(
                pointSize: 16,
                weight: .regular,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .refineStyle:
            return KeyboardToolbarIconMetrics(
                pointSize: 14,
                weight: .regular,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .undo:
            return KeyboardToolbarIconMetrics(
                pointSize: 18,
                weight: .medium,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .command:
            return KeyboardToolbarIconMetrics(
                pointSize: 15,
                weight: .regular,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .voiceMode:
            return KeyboardToolbarIconMetrics(
                pointSize: 16,
                weight: .regular,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .host:
            return KeyboardToolbarIconMetrics(
                pointSize: 15,
                weight: .regular,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .keyboardMode:
            return KeyboardToolbarIconMetrics(
                pointSize: 16,
                weight: .regular,
                verticalOffset: -2,
                horizontalInset: 4,
                cornerRadius: 8
            )
        case .candidateChevron:
            return KeyboardToolbarIconMetrics(
                pointSize: 21,
                weight: .medium,
                verticalOffset: 0,
                horizontalInset: 0,
                cornerRadius: 10
            )
        }
    }
}
