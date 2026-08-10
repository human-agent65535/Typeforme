import Foundation

enum KeyboardTextKeyRole: Equatable, Sendable {
    case normal
    case primary
    case utility
    case action
}

enum KeyboardTextKeyFontWeight: Equatable, Sendable {
    case regular
    case medium
}

struct KeyboardTextKeyTypography: Equatable, Sendable {
    let pointSize: Double
    let weight: KeyboardTextKeyFontWeight
    let topInset: Double
    let bottomInset: Double
}

/// Pure visual metrics for ordinary keyboard keys. It does not describe key
/// actions, committed text, Shift state, Rime state, or touch routing.
enum KeyboardTextKeyVisualPolicy {
    static let cornerRadius = 6.0
    static let iconPointSize = 15.0
    static let horizontalContentInset = 4.0
    static let numericDigitPointSize = 26.0
    static let numericSecondaryPointSize = 8.5
    /// iPad's stacked key legends keep the alternate symbol readable instead
    /// of treating it like a phone-key hint. This is shared by the number row
    /// and the compact iPad letter layout.
    static let stackedSecondaryPointSize = 15.0
    static let stackedPrimaryMinimumPointSize = 17.0

    static func typography(
        title: String,
        hasImage: Bool,
        role: KeyboardTextKeyRole
    ) -> KeyboardTextKeyTypography {
        let isLetter = role == .normal && !hasImage && isSingleASCIILetter(title)
        if isLetter {
            return KeyboardTextKeyTypography(
                pointSize: title == title.uppercased() ? 22 : 25,
                weight: .regular,
                topInset: 5,
                bottomInset: 5
            )
        }

        let isCompactUtility = role == .utility
            && !hasImage
            && (title == "123" || title == "ABC" || title == "#+=")
        if isCompactUtility {
            return KeyboardTextKeyTypography(
                pointSize: 18,
                weight: .regular,
                topInset: 5,
                bottomInset: 5
            )
        }

        let isShort = title.count <= 2
        let isUtilityAction = (role == .utility || role == .action) && !hasImage
        return KeyboardTextKeyTypography(
            pointSize: isUtilityAction ? (isShort ? 17 : 14) : (isShort ? 22 : 15),
            weight: isUtilityAction || !isShort ? .medium : .regular,
            topInset: 5,
            bottomInset: 5
        )
    }

    static func shadowOpacity(role: KeyboardTextKeyRole, isDark: Bool) -> Double {
        switch role {
        case .normal, .primary:
            return isDark ? 0.22 : 0.12
        case .utility, .action:
            return isDark ? 0.24 : 0.14
        }
    }

    static func stackedPrimaryPointSize(for typography: KeyboardTextKeyTypography) -> Double {
        max(stackedPrimaryMinimumPointSize, typography.pointSize - 1)
    }

    private static func isSingleASCIILetter(_ title: String) -> Bool {
        guard title.utf8.count == 1, let byte = title.utf8.first else { return false }
        return (65...90).contains(byte) || (97...122).contains(byte)
    }
}
