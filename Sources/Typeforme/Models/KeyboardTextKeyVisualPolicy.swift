import Foundation

enum KeyboardTextKeyRole: Equatable, Sendable {
    case normal
    case numberRow
    case primary
    case utility
    case action
}

enum KeyboardTextKeyVisualProfile: Equatable, Sendable {
    case compact
    case padPortrait
    case padFull
}

enum KeyboardTextKeyStackedLegendStyle: Equatable, Sendable {
    case alternateHint
    case numberRow
    case pairedSymbol
}

enum KeyboardTextKeyContentPlacement: Equatable, Sendable {
    case centered
    case leadingCenter
    case trailingCenter
    case leadingBottom
    case trailingBottom
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

struct KeyboardTextKeyContentScale: Equatable, Sendable {
    let horizontal: Double
    let vertical: Double

    static let identity = KeyboardTextKeyContentScale(horizontal: 1, vertical: 1)
}

/// Pure visual metrics for ordinary keyboard keys. It does not describe key
/// actions, committed text, Shift state, Rime state, or touch routing.
enum KeyboardTextKeyVisualPolicy {
    static let cornerRadius = 6.0
    static let horizontalContentInset = 4.0
    static let numericDigitPointSize = 26.0
    static let numericSecondaryPointSize = 8.5
    /// The compact profile retains the established lower bound for stacked
    /// legends; full-size iPad keys use their own native-scale values below.
    static let stackedPrimaryMinimumPointSize = 17.0

    static func typography(
        title: String,
        hasImage: Bool,
        role: KeyboardTextKeyRole,
        profile: KeyboardTextKeyVisualProfile = .compact
    ) -> KeyboardTextKeyTypography {
        if profile == .padPortrait, hasImage {
            return KeyboardTextKeyTypography(
                pointSize: 18,
                weight: .regular,
                topInset: 3,
                bottomInset: 5
            )
        }
        if profile == .padFull, hasImage {
            return KeyboardTextKeyTypography(
                pointSize: 18,
                weight: .regular,
                topInset: 3,
                bottomInset: 7
            )
        }

        if profile == .padFull, role == .numberRow {
            return KeyboardTextKeyTypography(
                pointSize: 18,
                weight: .regular,
                topInset: 3,
                bottomInset: 7
            )
        }

        let isLetter = role == .normal && !hasImage && isSingleASCIILetter(title)
        if isLetter {
            if profile == .padPortrait {
                return KeyboardTextKeyTypography(
                    pointSize: title == title.uppercased() ? 20 : 22,
                    weight: .regular,
                    topInset: 3,
                    bottomInset: 5
                )
            }
            if profile == .padFull {
                return KeyboardTextKeyTypography(
                    pointSize: title == title.uppercased() ? 22 : 25,
                    weight: .regular,
                    topInset: 3,
                    bottomInset: 7
                )
            }
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
            let pointSize: Double
            switch profile {
            case .compact:
                // Native iPhone keeps the in-row alternate-symbol label
                // smaller than the bottom-row 123/ABC mode labels.
                pointSize = title == "#+=" ? 13 : 18
            case .padPortrait:
                pointSize = 17
            case .padFull:
                pointSize = 18
            }
            return KeyboardTextKeyTypography(
                pointSize: pointSize,
                weight: .regular,
                topInset: profile == .padFull ? 7 : 5,
                bottomInset: profile == .compact ? 5 : 3
            )
        }

        if profile == .compact, role == .normal, !hasImage {
            let opticalPointSize: Double?
            switch title {
            case "/": opticalPointSize = 20
            case ".", ",": opticalPointSize = 26
            case ":": opticalPointSize = 25
            default: opticalPointSize = nil
            }
            if let opticalPointSize {
                return KeyboardTextKeyTypography(
                    pointSize: opticalPointSize,
                    weight: .regular,
                    topInset: 5,
                    bottomInset: 5
                )
            }
        }

        let isShort = title.count <= 2
        let isUtilityAction = (role == .utility || role == .action) && !hasImage
        if profile == .padPortrait {
            return KeyboardTextKeyTypography(
                pointSize: isUtilityAction ? (isShort ? 17 : 15) : (isShort ? 20 : 16),
                weight: isUtilityAction || !isShort ? .medium : .regular,
                topInset: 3,
                bottomInset: 5
            )
        }
        if profile == .padFull {
            return KeyboardTextKeyTypography(
                pointSize: isUtilityAction ? (isShort ? 18 : 16) : (isShort ? 22 : 17),
                weight: isUtilityAction || !isShort ? .medium : .regular,
                topInset: 3,
                bottomInset: 7
            )
        }
        return KeyboardTextKeyTypography(
            pointSize: isUtilityAction ? (isShort ? 17 : 14) : (isShort ? 22 : 15),
            weight: isUtilityAction || !isShort ? .medium : .regular,
            topInset: 5,
            bottomInset: 5
        )
    }

    static func iconPointSize(
        imageName: String?,
        profile: KeyboardTextKeyVisualProfile
    ) -> Double {
        profile == .compact ? 15 : 16
    }

    static func contentScale(
        title: String,
        role: KeyboardTextKeyRole,
        profile: KeyboardTextKeyVisualProfile
    ) -> KeyboardTextKeyContentScale {
        guard profile == .compact else { return .identity }
        switch (role, title) {
        case (.utility, "#+="):
            return KeyboardTextKeyContentScale(horizontal: 1.03, vertical: 0.82)
        default:
            return .identity
        }
    }

    static func stackedSecondaryPointSize(
        profile: KeyboardTextKeyVisualProfile,
        style: KeyboardTextKeyStackedLegendStyle = .alternateHint
    ) -> Double {
        if profile == .padFull, style == .numberRow { return 15 }
        if profile == .padFull, style == .pairedSymbol { return 15 }
        switch profile {
        case .compact:
            return 15
        case .padPortrait:
            return 10
        case .padFull:
            return 13
        }
    }

    static func shadowOpacity(role: KeyboardTextKeyRole, isDark: Bool) -> Double {
        switch role {
        case .normal, .numberRow, .primary:
            return isDark ? 0.22 : 0.12
        case .utility, .action:
            return isDark ? 0.24 : 0.14
        }
    }

    static func stackedPrimaryPointSize(
        for typography: KeyboardTextKeyTypography,
        profile: KeyboardTextKeyVisualProfile = .compact,
        style: KeyboardTextKeyStackedLegendStyle = .alternateHint
    ) -> Double {
        if profile == .padFull, style == .numberRow { return 15 }
        if profile == .padFull, style == .pairedSymbol { return 15 }
        if profile == .padPortrait {
            return max(20, typography.pointSize - 1)
        }
        if profile == .padFull {
            return max(22, typography.pointSize - 1)
        }
        return max(stackedPrimaryMinimumPointSize, typography.pointSize - 1)
    }

    private static func isSingleASCIILetter(_ title: String) -> Bool {
        guard title.utf8.count == 1, let byte = title.utf8.first else { return false }
        return (65...90).contains(byte) || (97...122).contains(byte)
    }
}
