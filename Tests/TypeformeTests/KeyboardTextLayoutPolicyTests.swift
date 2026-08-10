import XCTest
@testable import Typeforme

final class KeyboardTextLayoutPolicyTests: XCTestCase {
    func testStandardAndSymbolRowsKeepNativeFunctionalKeyPositions() {
        let standard = KeyboardTextLayoutPolicy.bottomRow(for: .standard)
        XCTAssertEqual(standard.modeKeyWidth, 48)
        XCTAssertTrue(standard.showsLanguageKey)
        XCTAssertTrue(standard.includesSpaceKey)
        XCTAssertEqual(standard.returnKeyWidth, 103)

        let symbols = KeyboardTextLayoutPolicy.bottomRow(for: .symbols)
        XCTAssertEqual(symbols.modeKeyWidth, 103)
        XCTAssertFalse(symbols.showsLanguageKey)
        XCTAssertTrue(symbols.includesSpaceKey)
        XCTAssertEqual(symbols.returnKeyWidth, 103)
    }

    func testURLAndWebSearchRemainDistinctLayouts() {
        let url = KeyboardTextLayoutPolicy.bottomRow(for: .url)
        XCTAssertFalse(url.includesSpaceKey)
        XCTAssertEqual(url.shortcuts.map(\.text), [".", "/", ".com"])
        XCTAssertEqual(url.shortcuts.map(\.width), [66, 66, 66])

        let webSearch = KeyboardTextLayoutPolicy.bottomRow(for: .webSearch)
        XCTAssertTrue(webSearch.includesSpaceKey)
        XCTAssertEqual(webSearch.shortcuts, [KeyboardTextBottomShortcut(text: ".", width: 37)])
        XCTAssertEqual(webSearch.returnKeyWidth, 69)
    }

    func testEmailAndSocialExposeTheirNativeShortcuts() {
        let email = KeyboardTextLayoutPolicy.bottomRow(for: .email)
        XCTAssertEqual(email.shortcuts.map(\.text), ["@", "."])
        XCTAssertEqual(email.returnKeyWidth, 103)

        let social = KeyboardTextLayoutPolicy.bottomRow(for: .social)
        XCTAssertEqual(social.shortcuts.map(\.text), ["@", "#"])
        XCTAssertNil(social.returnKeyWidth)
    }

    func testMeasuredWidthsRemainExactWhenTheyFit() {
        let widths = KeyboardTextLayoutPolicy.fittedFixedWidths(
            [48, 48, 66, 66, 66, 103],
            availableWidth: 440,
            gapCount: 5,
            includesFlexibleKey: false
        )
        XCTAssertEqual(widths, [48, 48, 66, 66, 66, 103])
    }

    func testURLWidthsFitCompactScreensAndVisibleGlobe() {
        let widths = KeyboardTextLayoutPolicy.fittedFixedWidths(
            [48, 48, 48, 66, 66, 66, 103],
            availableWidth: 375,
            gapCount: 6,
            includesFlexibleKey: false
        )
        XCTAssertEqual(widths.count, 7)
        XCTAssertEqual(widths.reduce(0, +) + 36, 375, accuracy: 0.001)
        XCTAssertTrue(widths.allSatisfy { $0 >= 44 })
    }

    func testBottomRowWidthsReturnToPortraitValuesAfterRotation() {
        let preferred = [48.0, 48, 48, 66, 66, 66, 103]
        let portrait = KeyboardTextLayoutPolicy.fittedFixedWidths(
            preferred,
            availableWidth: 375,
            gapCount: 6,
            includesFlexibleKey: false
        )
        let landscape = KeyboardTextLayoutPolicy.fittedFixedWidths(
            preferred,
            availableWidth: 812,
            gapCount: 6,
            includesFlexibleKey: false
        )
        let portraitAgain = KeyboardTextLayoutPolicy.fittedFixedWidths(
            preferred,
            availableWidth: 375,
            gapCount: 6,
            includesFlexibleKey: false
        )

        XCTAssertEqual(landscape, preferred)
        XCTAssertEqual(portraitAgain, portrait)
    }

    func testFlexibleSpaceKeepsMinimumTapTargetOnCompactScreens() {
        let widths = KeyboardTextLayoutPolicy.fittedFixedWidths(
            [48, 48, 48, 48, 103],
            availableWidth: 375,
            gapCount: 5,
            includesFlexibleKey: true
        )
        XCTAssertLessThanOrEqual(widths.reduce(0, +) + 30 + 44, 375.001)
        XCTAssertTrue(widths.allSatisfy { $0 >= 44 })
    }

    func testFloatingKeyboardDropsOnlyOptionalTrailingShortcuts() {
        let url = KeyboardTextLayoutPolicy.fittedBottomRow(
            KeyboardTextLayoutPolicy.bottomRow(for: .url),
            availableWidth: 307,
            showsGlobeKey: true,
            showsLanguageKey: true
        )
        XCTAssertEqual(url.shortcuts.map(\.text), [".", "/"])
        XCTAssertNotNil(url.returnKeyWidth)

        let email = KeyboardTextLayoutPolicy.fittedBottomRow(
            KeyboardTextLayoutPolicy.bottomRow(for: .email),
            availableWidth: 307,
            showsGlobeKey: true,
            showsLanguageKey: true
        )
        XCTAssertEqual(email.shortcuts.map(\.text), ["@"])
        XCTAssertTrue(email.includesSpaceKey)
        XCTAssertNotNil(email.returnKeyWidth)
    }

    func testWideKeyboardRestoresAllShortcuts() {
        let url = KeyboardTextLayoutPolicy.fittedBottomRow(
            KeyboardTextLayoutPolicy.bottomRow(for: .url),
            availableWidth: KeyboardSurfaceLayoutPolicy.maximumContentWidth,
            showsGlobeKey: true,
            showsLanguageKey: true
        )
        XCTAssertEqual(url.shortcuts.map(\.text), [".", "/", ".com"])
    }

    func testExceptionalWidthNeverShrinksFixedKeysBelowMinimumTarget() {
        let widths = KeyboardTextLayoutPolicy.fittedFixedWidths(
            [48, 48, 103],
            availableWidth: 120,
            gapCount: 2,
            includesFlexibleKey: false
        )
        XCTAssertEqual(widths, [44, 44, 44])
    }

    func testSurfaceMetricsUseActualWidthAndCapWideCanvas() {
        let floating = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 307,
            verticalSizeIsCompact: false
        )
        XCTAssertEqual(floating.contentHeight, 253)
        XCTAssertEqual(floating.orbDiameter, 112)
        XCTAssertEqual(floating.voiceSideColumnWidth, 76)
        XCTAssertEqual(floating.inputModeSwitchWidth, 56)
        XCTAssertEqual(floating.textKeyHorizontalGap, 4)
        XCTAssertEqual(floating.textUtilityKeyWidth, 44)

        let narrowPhone = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 362,
            verticalSizeIsCompact: false
        )
        XCTAssertEqual(narrowPhone.orbDiameter, 112)

        let standardBoundary = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 376,
            verticalSizeIsCompact: false
        )
        XCTAssertEqual(standardBoundary.orbDiameter, 132)

        let docked = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: KeyboardSurfaceLayoutPolicy.maximumContentWidth,
            verticalSizeIsCompact: false
        )
        XCTAssertEqual(docked.contentHeight, 267)
        XCTAssertEqual(docked.orbDiameter, 132)
        XCTAssertEqual(docked.textKeyHorizontalGap, 6)
        XCTAssertEqual(docked.textUtilityKeyWidth, 51)
        XCTAssertEqual(KeyboardSurfaceLayoutPolicy.maximumContentWidth, 900)
    }

    func testCompactSurfaceFitsRepresentative320PointKeyboard() {
        let availableWidth = 307.0
        let metrics = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: availableWidth,
            verticalSizeIsCompact: false
        )
        let utilitySpacer = max(0, 13 - metrics.textKeyHorizontalGap * 2)
        let thirdRowMinimumWidth = metrics.textUtilityKeyWidth * 2
            + utilitySpacer * 2
            + 24 * 7
            + metrics.textKeyHorizontalGap * 10
        XCTAssertLessThanOrEqual(thirdRowMinimumWidth, availableWidth)

        let voiceLeftClearanceWidth = 2 * (
            10
                + metrics.voiceSideColumnWidth
                + 8
                + metrics.orbDiameter / 2
        )
        XCTAssertLessThanOrEqual(voiceLeftClearanceWidth, availableWidth)
    }

    func testReturnPresentationSeparatesNeutralAndActionSemantics() {
        XCTAssertEqual(
            KeyboardReturnKeyPolicy.presentation(for: .default),
            KeyboardReturnKeyPresentation(isAction: false, symbol: .returnArrow)
        )
        XCTAssertEqual(
            KeyboardReturnKeyPolicy.presentation(for: .next),
            KeyboardReturnKeyPresentation(isAction: false, symbol: .nextChevron)
        )
        XCTAssertEqual(KeyboardReturnKeyPolicy.presentation(for: .search).symbol, .search)
        XCTAssertEqual(KeyboardReturnKeyPolicy.presentation(for: .send).symbol, .send)
        XCTAssertEqual(KeyboardReturnKeyPolicy.presentation(for: .done).symbol, .done)
        for kind in KeyboardReturnKeyKind.allCases where kind != .default && kind != .next {
            XCTAssertTrue(KeyboardReturnKeyPolicy.presentation(for: kind).isAction)
        }
    }

    func testReturnAutomaticEnablementTracksDocumentText() {
        XCTAssertTrue(KeyboardReturnKeyPolicy.isEnabled(enablesAutomatically: false, hasText: false))
        XCTAssertFalse(KeyboardReturnKeyPolicy.isEnabled(enablesAutomatically: true, hasText: false))
        XCTAssertTrue(KeyboardReturnKeyPolicy.isEnabled(enablesAutomatically: true, hasText: true))
    }

    func testReturnAutomaticEnablementCanBeReevaluatedAfterSend() {
        XCTAssertFalse(KeyboardReturnKeyPolicy.isEnabled(enablesAutomatically: true, hasText: false))
        XCTAssertTrue(KeyboardReturnKeyPolicy.isEnabled(enablesAutomatically: true, hasText: true))
        XCTAssertFalse(KeyboardReturnKeyPolicy.isEnabled(enablesAutomatically: true, hasText: false))
    }
}
