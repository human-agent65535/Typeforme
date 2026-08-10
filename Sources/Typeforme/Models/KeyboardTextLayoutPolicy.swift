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

    /// Removes only optional text shortcuts when a floating keyboard is too
    /// narrow to preserve 44pt controls. Mode, Globe, language, Space, and
    /// Return remain present because they are navigation or editing controls.
    static func fittedBottomRow(
        _ layout: KeyboardTextBottomRowLayout,
        availableWidth: Double,
        showsGlobeKey: Bool,
        showsLanguageKey: Bool,
        gap: Double = 6
    ) -> KeyboardTextBottomRowLayout {
        guard availableWidth > 0 else { return layout }
        var shortcuts = layout.shortcuts

        func minimumRequiredWidth(shortcutCount: Int) -> Double {
            let fixedKeyCount = 1
                + (showsGlobeKey ? 1 : 0)
                + (showsLanguageKey ? 1 : 0)
                + shortcutCount
                + (layout.returnKeyWidth == nil ? 0 : 1)
            let visibleKeyCount = fixedKeyCount + (layout.includesSpaceKey ? 1 : 0)
            return Double(visibleKeyCount) * minimumKeyWidth
                + Double(max(0, visibleKeyCount - 1)) * gap
        }

        while !shortcuts.isEmpty,
              minimumRequiredWidth(shortcutCount: shortcuts.count) > availableWidth {
            shortcuts.removeLast()
        }
        return KeyboardTextBottomRowLayout(
            modeKeyWidth: layout.modeKeyWidth,
            showsLanguageKey: layout.showsLanguageKey,
            includesSpaceKey: layout.includesSpaceKey,
            shortcuts: shortcuts,
            returnKeyWidth: layout.returnKeyWidth
        )
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
        guard budget >= minimumTotal else {
            // Structural fitting removes optional shortcuts first. If UIKit
            // ever supplies an even narrower surface, preserve minimum touch
            // targets and let the system resolve the exceptional constraint
            // pressure instead of silently creating undersized controls.
            return Array(repeating: minimumKeyWidth, count: preferredWidths.count)
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

struct KeyboardSurfaceMetrics: Equatable, Sendable {
    let voiceContentHeight: Double
    let textContentHeight: Double
    let orbDiameter: Double
    let voiceSideColumnWidth: Double
    let inputModeSwitchWidth: Double
    let textKeyHorizontalGap: Double
    let textKeyVerticalGap: Double
    let textUtilityKeyWidth: Double
    let usesPadFullTextLayout: Bool
    let usesPadFloatingLayout: Bool
    let usesPadNumberRow: Bool
    let padNumberRowHeight: Double?
}

enum KeyboardSurfaceLayoutPolicy {
    static let maximumContentWidth = 900.0
    static let minimumPadFullTextWidth = 600.0
    static let minimumLargePadTextWidth = 1_000.0
    static let minimumLargePadShortestSide = 1_000.0
    /// The custom candidate/action toolbar is additional to the iPad input
    /// assistant row. Full-size text keyboards therefore need this much more
    /// surface than the matching native key block to preserve native key size.
    static let padTextToolbarCompensation = 41.0
    // The orb is centered independently of its two side columns. With the
    // standard 132/104/68pt controls, the left column needs 376pt of usable
    // width to clear the orb without constraint pressure.
    private static let standardVoiceMinimumWidth = 376.0

    static func interfaceOrientationIsLandscape(
        surfaceWidth: Double,
        screenWidth: Double,
        screenHeight: Double,
        sceneOrientationIsLandscape: Bool
    ) -> Bool {
        let shortSide = min(screenWidth, screenHeight)
        let longSide = max(screenWidth, screenHeight)
        guard surfaceWidth >= minimumPadFullTextWidth,
              longSide - shortSide > 1
        else { return sceneOrientationIsLandscape }
        return abs(surfaceWidth - longSide) < abs(surfaceWidth - shortSide)
    }

    static func metrics(
        availableWidth: Double,
        verticalSizeIsCompact: Bool,
        interfaceIdiomIsPad: Bool = false,
        interfaceOrientationIsLandscape: Bool = false,
        screenShortestSide: Double = 0
    ) -> KeyboardSurfaceMetrics {
        let usesCompactWidth = availableWidth > 1 && availableWidth < standardVoiceMinimumWidth
        let usesPadFloatingLayout = interfaceIdiomIsPad
            && availableWidth > 1
            && availableWidth < minimumPadFullTextWidth
        let usesPadFullTextLayout = interfaceIdiomIsPad
            && !usesPadFloatingLayout
            && availableWidth >= minimumPadFullTextWidth
        let usesLargePadLayout = usesPadFullTextLayout
            && availableWidth >= minimumLargePadTextWidth
            && screenShortestSide >= minimumLargePadShortestSide
        let usesPadNumberRow = usesLargePadLayout

        // These are the native key-block profiles measured on iPadOS 27,
        // plus the 41pt occupied by Typeforme's own text toolbar. Screen class
        // and real interface orientation are explicit: surface width alone
        // cannot distinguish a 13-inch portrait keyboard from 11-inch
        // landscape, and floating keyboards intentionally use compact width.
        let padTextContentHeight: Double
        let padNumberRowHeight: Double?
        switch (usesLargePadLayout, interfaceOrientationIsLandscape) {
        case (true, true):
            padTextContentHeight = 428 + padTextToolbarCompensation
            padNumberRowHeight = 59
        case (true, false):
            padTextContentHeight = 338 + padTextToolbarCompensation
            padNumberRowHeight = 44
        case (false, true):
            padTextContentHeight = 353 + padTextToolbarCompensation
            padNumberRowHeight = nil
        case (false, false):
            padTextContentHeight = 267 + padTextToolbarCompensation
            padNumberRowHeight = nil
        }

        let standardContentHeight = verticalSizeIsCompact || usesCompactWidth ? 253.0 : 267.0
        let voiceContentHeight = usesPadFullTextLayout ? 267.0 : standardContentHeight
        let textContentHeight = usesPadFullTextLayout ? padTextContentHeight : standardContentHeight
        // A docked iPad keyboard does not stretch the phone rows. Its outer
        // utility columns absorb the extra width, and grow modestly between
        // portrait and landscape while the character keys stay near native
        // proportions.
        let padUtilityKeyWidth = min(132, max(88, availableWidth * 0.11))
        return KeyboardSurfaceMetrics(
            voiceContentHeight: voiceContentHeight,
            textContentHeight: textContentHeight,
            orbDiameter: usesCompactWidth ? 112 : 132,
            voiceSideColumnWidth: usesCompactWidth ? 76 : 104,
            inputModeSwitchWidth: usesCompactWidth ? 56 : 68,
            textKeyHorizontalGap: usesCompactWidth ? 4 : (usesPadFullTextLayout ? 8 : 6),
            textKeyVerticalGap: usesPadFullTextLayout ? 9 : 11,
            textUtilityKeyWidth: usesCompactWidth
                ? 44
                : (usesPadFullTextLayout ? padUtilityKeyWidth : 51),
            usesPadFullTextLayout: usesPadFullTextLayout,
            usesPadFloatingLayout: usesPadFloatingLayout,
            usesPadNumberRow: usesPadNumberRow,
            padNumberRowHeight: padNumberRowHeight
        )
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
