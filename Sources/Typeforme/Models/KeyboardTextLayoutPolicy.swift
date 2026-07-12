import Foundation

enum KeyboardTextBottomLayoutKind: Equatable, Sendable {
    case standard
    case ascii
    case symbols
    case url
    case email
    case social
    case webSearch
}

struct KeyboardTextBottomShortcut: Equatable, Sendable {
    let text: String
    let width: Double
}

struct KeyboardTextBottomRowLayout: Equatable, Sendable {
    let modeKeyWidth: Double
    let showsLanguageKey: Bool
    let includesSpaceKey: Bool
    let shortcuts: [KeyboardTextBottomShortcut]
    let returnKeyWidth: Double?
}

enum KeyboardTextLayoutPolicy {
    static let minimumKeyWidth = 44.0

    /// Preferred iPhone portrait measurements from the current system
    /// keyboard. Call `fittedFixedWidths` before applying them so compact
    /// widths and an in-keyboard Globe key do not create unsatisfiable rows.
    static func bottomRow(for kind: KeyboardTextBottomLayoutKind) -> KeyboardTextBottomRowLayout {
        switch kind {
        case .standard:
            return KeyboardTextBottomRowLayout(
                modeKeyWidth: 48,
                showsLanguageKey: true,
                includesSpaceKey: true,
                shortcuts: [],
                returnKeyWidth: 103
            )
        case .ascii, .symbols:
            return KeyboardTextBottomRowLayout(
                modeKeyWidth: 103,
                showsLanguageKey: false,
                includesSpaceKey: true,
                shortcuts: [],
                returnKeyWidth: 103
            )
        case .url:
            return KeyboardTextBottomRowLayout(
                modeKeyWidth: 48,
                showsLanguageKey: true,
                includesSpaceKey: false,
                shortcuts: [
                    KeyboardTextBottomShortcut(text: ".", width: 66),
                    KeyboardTextBottomShortcut(text: "/", width: 66),
                    KeyboardTextBottomShortcut(text: ".com", width: 66),
                ],
                returnKeyWidth: 103
            )
        case .email:
            return KeyboardTextBottomRowLayout(
                modeKeyWidth: 48,
                showsLanguageKey: true,
                includesSpaceKey: true,
                shortcuts: [
                    KeyboardTextBottomShortcut(text: "@", width: 48),
                    KeyboardTextBottomShortcut(text: ".", width: 48),
                ],
                returnKeyWidth: 103
            )
        case .social:
            return KeyboardTextBottomRowLayout(
                modeKeyWidth: 48,
                showsLanguageKey: true,
                includesSpaceKey: true,
                shortcuts: [
                    KeyboardTextBottomShortcut(text: "@", width: 48),
                    KeyboardTextBottomShortcut(text: "#", width: 48),
                ],
                returnKeyWidth: nil
            )
        case .webSearch:
            return KeyboardTextBottomRowLayout(
                modeKeyWidth: 48,
                showsLanguageKey: true,
                includesSpaceKey: true,
                shortcuts: [KeyboardTextBottomShortcut(text: ".", width: 37)],
                returnKeyWidth: 69
            )
        }
    }

    /// Preserves the measured widths whenever they fit. On narrower keyboards
    /// it shrinks all fixed keys proportionally toward the minimum tap target,
    /// leaving one minimum-width slot for a flexible Space key when present.
    static func fittedFixedWidths(
        _ preferredWidths: [Double],
        availableWidth: Double,
        gapCount: Int,
        includesFlexibleKey: Bool,
        gap: Double = 6
    ) -> [Double] {
        guard !preferredWidths.isEmpty else { return [] }
        let gapWidth = Double(max(0, gapCount)) * gap
        let flexibleReserve = includesFlexibleKey ? minimumKeyWidth : 0
        let budget = max(0, availableWidth - gapWidth - flexibleReserve)
        let preferredTotal = preferredWidths.reduce(0, +)
        guard preferredTotal > budget else { return preferredWidths }

        let minimumTotal = minimumKeyWidth * Double(preferredWidths.count)
        guard budget > minimumTotal else {
            return Array(
                repeating: max(0, budget / Double(preferredWidths.count)),
                count: preferredWidths.count
            )
        }

        let preferredCapacity = preferredTotal - minimumTotal
        guard preferredCapacity > 0 else { return preferredWidths }
        let retainedCapacity = budget - minimumTotal
        let scale = retainedCapacity / preferredCapacity
        return preferredWidths.map { preferred in
            minimumKeyWidth + (preferred - minimumKeyWidth) * scale
        }
    }
}

enum KeyboardReturnKeyKind: CaseIterable, Equatable, Sendable {
    case `default`
    case go
    case google
    case join
    case next
    case route
    case search
    case send
    case yahoo
    case done
    case emergencyCall
    case `continue`
}

enum KeyboardReturnKeySymbol: Equatable, Sendable {
    case returnArrow
    case forwardArrow
    case search
    case send
    case done
    case nextChevron
    case none
}

struct KeyboardReturnKeyPresentation: Equatable, Sendable {
    let isAction: Bool
    let symbol: KeyboardReturnKeySymbol
}

enum KeyboardReturnKeyPolicy {
    static func presentation(for kind: KeyboardReturnKeyKind) -> KeyboardReturnKeyPresentation {
        switch kind {
        case .default:
            return KeyboardReturnKeyPresentation(isAction: false, symbol: .returnArrow)
        case .next:
            return KeyboardReturnKeyPresentation(isAction: false, symbol: .nextChevron)
        case .go:
            return KeyboardReturnKeyPresentation(isAction: true, symbol: .forwardArrow)
        case .google, .search, .yahoo:
            return KeyboardReturnKeyPresentation(isAction: true, symbol: .search)
        case .send:
            return KeyboardReturnKeyPresentation(isAction: true, symbol: .send)
        case .done:
            return KeyboardReturnKeyPresentation(isAction: true, symbol: .done)
        case .join, .route, .emergencyCall, .continue:
            return KeyboardReturnKeyPresentation(isAction: true, symbol: .none)
        }
    }

    static func isEnabled(enablesAutomatically: Bool, hasText: Bool) -> Bool {
        !enablesAutomatically || hasText
    }
}
