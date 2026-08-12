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

    static func largePadLetterSecondaryTitle(for key: String) -> String? {
        [
            "[": "{", "]": "}", "\\": "|",
            ";": ":", "'": "\"",
            ",": "<", ".": ">", "/": "?",
        ][key]
    }

    /// The large iPad symbol keyboard follows the same four character-row
    /// geometry as the native letter keyboard: 13, 13, 11, and 10 ordinary
    /// keys. Keeping those counts stable lets Tab/Delete, mode/Return, and the
    /// wide fourth-row mode slot line up with their letter-key counterparts
    /// instead of producing a different floating grid on every symbol row.
    static func largePadSymbolRows(
        alternate: Bool,
        usesChinesePunctuation: Bool
    ) -> [[String]] {
        if alternate {
            return [
                ["§", "±", "×", "÷", "√", "π", "°", "©", "®", "™", "<", ">", "≈"],
                ["_", "\\", "|", "~", "^", "•", "·", "∞", "≠", "≤", "≥", "{", "}"],
                ["€", "£", "¥", "¢", "₩", "₽", "₹", "₺", "₫", "₪", "₴"],
                ["…", "¿", "¡", "‘", "’", "“", "”", "–", "—", "•"],
            ]
        }

        let punctuation = usesChinesePunctuation
            ? ["…", "。", "，", "、", "？", "！", "“", "”", "——", "•"]
            : ["…", ".", ",", "?", "!", "'", "\"", "_", "€", "•"]
        return [
            ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "<", ">"],
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "=", "\\", "|", "~"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "£", "¥"],
            punctuation,
        ]
    }

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

    /// Removes only optional text shortcuts when a compact surface is too
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

/// The visible iPad secondary legend and the committed flick character share
/// this source of truth. A secondary character must never be rendered unless a
/// downward flick on that same key can commit it.
enum KeyboardTextKeyFlickPolicy {
    static let minimumDownwardDistance = 18.0
    static let verticalAxisDominance = 1.15

    static func letterAlternate(for key: String, usesNumberRow: Bool) -> String? {
        if usesNumberRow {
            return KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: key)
        }
        return [
            "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
            "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
            "a": "@", "s": "#", "d": "$", "f": "&", "g": "*",
            "h": "(", "j": ")", "k": "'", "l": "\"",
            "z": "%", "x": "-", "c": "+", "v": "=", "b": "/",
            "n": ";", "m": ":", ",": "!", ".": "?",
        ][key.lowercased()]
    }

    static func numberRowAlternate(for key: String) -> String? {
        [
            "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+",
        ][key]
    }

    static func selectsAlternate(
        startX: Double,
        startY: Double,
        currentX: Double,
        currentY: Double
    ) -> Bool {
        let deltaX = currentX - startX
        let deltaY = currentY - startY
        return deltaY >= minimumDownwardDistance
            && deltaY >= abs(deltaX) * verticalAxisDominance
    }
}

struct KeyboardSurfaceMetrics: Equatable, Sendable {
    let voiceContentHeight: Double
    let textContentHeight: Double
    let orbDiameter: Double
    let voiceSideColumnWidth: Double
    let inputModeSwitchWidth: Double
    let voiceLeftControlGap: Double
    let voiceRightControlGap: Double
    let textKeyHorizontalGap: Double
    let textKeyVerticalGap: Double
    let textSurfaceHorizontalInset: Double
    let textUtilityKeyWidth: Double
    let textLanguageUtilityKeyWidth: Double
    let textShiftUtilityKeyWidth: Double
    let textKeyVisualProfile: KeyboardTextKeyVisualProfile
    let usesPadFullTextLayout: Bool
    let usesPadNumberRow: Bool
    let padNumberRowHeight: Double?
}

enum KeyboardSurfaceLayoutPolicy {
    static let maximumContentWidth = 900.0
    static let minimumPadDockedOrientationWidth = 600.0
    static let minimumLargePadTextWidth = 1_000.0
    static let minimumLargePadShortestSide = 1_000.0
    static let standardHorizontalInset = 20.0 / 3.0
    static let padFullHorizontalInset = 3.5
    static let voiceLeftEdgeInset = 10.0
    static let voiceRightEdgeInset = 14.0
    /// The host responder owns iPad's input-assistant row; a keyboard extension
    /// cannot publish Rime candidates or host editing actions into it. Keep the
    /// extension-owned candidate/action toolbar separate and reserve its exact
    /// height so the native-sized key block is not compressed.
    static let padTextToolbarCompensation = 41.0
    // The orb is centered independently of its two side columns. With the
    // standard 132/104/68pt controls and an 8pt control gap, the left column
    // needs 376pt of usable width to clear the orb without constraint pressure.
    private static let standardVoiceMinimumWidth = 376.0
    private static let minimumVoiceControlGap = 8.0
    private static let padFullVoiceControlGap = 24.0
    // The widest current iPhone portrait surface is 440pt before the standard
    // root insets. Cap the Voice stage there so a future wider surface or a
    // synthetic test canvas does not send the side controls arbitrarily far
    // away from the centered orb.
    private static let maximumPhonePortraitVoiceStageWidth = 440.0
        - standardHorizontalInset * 2

    static func interfaceOrientationIsLandscape(
        surfaceWidth: Double,
        screenWidth: Double,
        screenHeight: Double,
        sceneOrientationIsLandscape: Bool
    ) -> Bool {
        let shortSide = min(screenWidth, screenHeight)
        let longSide = max(screenWidth, screenHeight)
        guard surfaceWidth >= minimumPadDockedOrientationWidth,
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
        // Third-party iPad keyboards only use the docked surface. Width-based
        // compact sizing belongs to iPhone and must not create a synthetic
        // floating-keyboard mode on iPad.
        let usesCompactWidth = !interfaceIdiomIsPad
            && availableWidth > 1
            && availableWidth < standardVoiceMinimumWidth
        let usesPadFullTextLayout = interfaceIdiomIsPad
        let usesLargePadLayout = usesPadFullTextLayout
            && availableWidth >= minimumLargePadTextWidth
            && screenShortestSide >= minimumLargePadShortestSide
        // iPadOS 27 keeps the 13-inch hardware-like five-row grid in both
        // orientations. The portrait reference is 1,032pt wide and measures
        // 64pt ordinary keys, a 46pt number row, and 61pt regular rows.
        let usesPadNumberRow = usesLargePadLayout

        // These are the native key-block profiles measured on iPadOS 27,
        // plus the 41pt occupied by Typeforme's own text toolbar. Screen class
        // and real interface orientation are explicit: surface width alone
        // cannot distinguish a 13-inch portrait keyboard from 11-inch
        // landscape.
        let padTextContentHeight: Double
        let padNumberRowHeight: Double?
        switch (usesLargePadLayout, interfaceOrientationIsLandscape) {
        case (true, true):
            padTextContentHeight = 428 + padTextToolbarCompensation
            padNumberRowHeight = 59
        case (true, false):
            // 34pt toolbar + 7pt toolbar gap + the measured native key block:
            // 46 + 4×61pt rows + 4×7pt row gaps, including container insets.
            padTextContentHeight = 331 + padTextToolbarCompensation
            padNumberRowHeight = 46
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
        let padUtilityKeyWidth = usesLargePadLayout && !interfaceOrientationIsLandscape
            ? 102.5
            : min(132, max(88, availableWidth * 0.11))
        let padLanguageUtilityKeyWidth = usesLargePadLayout && !interfaceOrientationIsLandscape
            ? 118.5
            : padUtilityKeyWidth * 1.25
        let padShiftUtilityKeyWidth = usesLargePadLayout && !interfaceOrientationIsLandscape
            ? 154
            : padUtilityKeyWidth * 1.55
        let orbDiameter = usesCompactWidth ? 112.0 : (usesPadFullTextLayout ? 148.0 : 132.0)
        let voiceSideColumnWidth = usesCompactWidth ? 76.0 : (usesPadFullTextLayout ? 112.0 : 104.0)
        let inputModeSwitchWidth = usesCompactWidth ? 56.0 : (usesPadFullTextLayout ? 72.0 : 68.0)
        let baseVoiceControlGap = usesPadFullTextLayout
            ? padFullVoiceControlGap
            : minimumVoiceControlGap
        let spreadsPhonePortraitControls = !interfaceIdiomIsPad && !verticalSizeIsCompact
        let voiceStageWidth = min(
            max(0, availableWidth),
            maximumPhonePortraitVoiceStageWidth
        )
        let voiceSideSpace = max(0, (voiceStageWidth - orbDiameter) / 2)
        let voiceLeftControlGap = spreadsPhonePortraitControls
            ? max(
                baseVoiceControlGap,
                voiceSideSpace - voiceSideColumnWidth - voiceLeftEdgeInset
            )
            : baseVoiceControlGap
        let voiceRightControlGap = spreadsPhonePortraitControls
            ? max(
                baseVoiceControlGap,
                voiceSideSpace - inputModeSwitchWidth - voiceRightEdgeInset
            )
            : baseVoiceControlGap
        return KeyboardSurfaceMetrics(
            voiceContentHeight: voiceContentHeight,
            textContentHeight: textContentHeight,
            orbDiameter: orbDiameter,
            voiceSideColumnWidth: voiceSideColumnWidth,
            inputModeSwitchWidth: inputModeSwitchWidth,
            voiceLeftControlGap: voiceLeftControlGap,
            voiceRightControlGap: voiceRightControlGap,
            textKeyHorizontalGap: usesCompactWidth
                ? 4
                : (usesLargePadLayout && !interfaceOrientationIsLandscape
                    ? 7
                    : (usesPadFullTextLayout ? 8 : 6)),
            textKeyVerticalGap: usesLargePadLayout && !interfaceOrientationIsLandscape
                ? 7
                : (usesPadFullTextLayout ? 9 : 11),
            textSurfaceHorizontalInset: usesPadFullTextLayout
                ? padFullHorizontalInset
                : standardHorizontalInset,
            textUtilityKeyWidth: usesCompactWidth
                ? 44
                : (usesPadFullTextLayout ? padUtilityKeyWidth : 51),
            textLanguageUtilityKeyWidth: usesCompactWidth
                ? 44
                : (usesPadFullTextLayout ? padLanguageUtilityKeyWidth : 51),
            textShiftUtilityKeyWidth: usesCompactWidth
                ? 44
                : (usesPadFullTextLayout ? padShiftUtilityKeyWidth : 51),
            textKeyVisualProfile: usesPadFullTextLayout
                ? (usesLargePadLayout || interfaceOrientationIsLandscape ? .padFull : .padPortrait)
                : .compact,
            usesPadFullTextLayout: usesPadFullTextLayout,
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
