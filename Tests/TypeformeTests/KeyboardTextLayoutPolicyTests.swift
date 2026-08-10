import XCTest
@testable import Typeforme

final class KeyboardTextLayoutPolicyTests: XCTestCase {
    func testLargePadLetterPunctuationUsesNativeStackedLegends() {
        XCTAssertEqual(KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: "["), "{")
        XCTAssertEqual(KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: ";"), ":")
        XCTAssertEqual(KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: ","), "<")
        XCTAssertEqual(KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: "."), ">")
        XCTAssertEqual(KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: "/"), "?")
        XCTAssertNil(KeyboardTextLayoutPolicy.largePadLetterSecondaryTitle(for: "a"))
    }

    func testLargePadSymbolRowsKeepNativeLetterGridGeometry() {
        let primary = KeyboardTextLayoutPolicy.largePadSymbolRows(
            alternate: false,
            usesChinesePunctuation: false
        )
        XCTAssertEqual(primary.map(\.count), [13, 13, 11, 10])
        XCTAssertEqual(Array(primary[0].prefix(3)), ["`", "1", "2"])
        XCTAssertTrue(primary[1].contains("\\"))
        XCTAssertEqual(primary[3], ["…", ".", ",", "?", "!", "'", "\"", "_", "€", "•"])

        let chinese = KeyboardTextLayoutPolicy.largePadSymbolRows(
            alternate: false,
            usesChinesePunctuation: true
        )
        XCTAssertEqual(chinese.map(\.count), [13, 13, 11, 10])
        XCTAssertTrue(chinese[3].contains("。"))
        XCTAssertTrue(chinese[3].contains("、"))

        let alternate = KeyboardTextLayoutPolicy.largePadSymbolRows(
            alternate: true,
            usesChinesePunctuation: false
        )
        XCTAssertEqual(alternate.map(\.count), [13, 13, 11, 10])
    }

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
        XCTAssertEqual(floating.voiceContentHeight, 253)
        XCTAssertEqual(floating.textContentHeight, 253)
        XCTAssertEqual(floating.orbDiameter, 112)
        XCTAssertEqual(floating.voiceSideColumnWidth, 76)
        XCTAssertEqual(floating.inputModeSwitchWidth, 56)
        XCTAssertEqual(floating.voiceControlGap, 8)
        XCTAssertEqual(floating.textKeyHorizontalGap, 4)
        XCTAssertEqual(floating.textKeyVerticalGap, 11)
        XCTAssertEqual(floating.textUtilityKeyWidth, 44)
        XCTAssertFalse(floating.usesPadFullTextLayout)
        XCTAssertFalse(floating.usesPadFloatingLayout)
        XCTAssertFalse(floating.usesPadNumberRow)

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
        XCTAssertEqual(docked.voiceContentHeight, 267)
        XCTAssertEqual(docked.textContentHeight, 267)
        XCTAssertEqual(docked.orbDiameter, 132)
        XCTAssertEqual(docked.voiceControlGap, 8)
        XCTAssertEqual(docked.textKeyHorizontalGap, 6)
        XCTAssertEqual(docked.textKeyVerticalGap, 11)
        XCTAssertEqual(docked.textUtilityKeyWidth, 51)
        XCTAssertEqual(KeyboardSurfaceLayoutPolicy.maximumContentWidth, 900)
    }

    func testPadFloatingKeyboardUsesExplicitCompactProfile() {
        let floating = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 307,
            verticalSizeIsCompact: false,
            interfaceIdiomIsPad: true,
            interfaceOrientationIsLandscape: true,
            screenShortestSide: 1_032
        )
        XCTAssertTrue(floating.usesPadFloatingLayout)
        XCTAssertFalse(floating.usesPadFullTextLayout)
        XCTAssertFalse(floating.usesPadNumberRow)
        XCTAssertEqual(floating.voiceContentHeight, 253)
        XCTAssertEqual(floating.textContentHeight, 253)
        XCTAssertEqual(floating.orbDiameter, 112)
        XCTAssertEqual(floating.textUtilityKeyWidth, 44)
    }

    func testDockedOrientationUsesPhysicalSurfaceWhenRemoteSceneIsStale() {
        XCTAssertFalse(KeyboardSurfaceLayoutPolicy.interfaceOrientationIsLandscape(
            surfaceWidth: 1_032,
            screenWidth: 1_032,
            screenHeight: 1_376,
            sceneOrientationIsLandscape: false
        ))
        XCTAssertTrue(KeyboardSurfaceLayoutPolicy.interfaceOrientationIsLandscape(
            surfaceWidth: 1_376,
            screenWidth: 1_032,
            screenHeight: 1_376,
            sceneOrientationIsLandscape: false
        ))
        XCTAssertTrue(KeyboardSurfaceLayoutPolicy.interfaceOrientationIsLandscape(
            surfaceWidth: 320,
            screenWidth: 1_032,
            screenHeight: 1_376,
            sceneOrientationIsLandscape: true
        ))
    }

    func testPadFullKeyboardUsesNativeScaleProfilesInsteadOfWidthGuessing() {
        let portrait = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 821,
            verticalSizeIsCompact: false,
            interfaceIdiomIsPad: true,
            interfaceOrientationIsLandscape: false,
            screenShortestSide: 820
        )
        XCTAssertTrue(portrait.usesPadFullTextLayout)
        XCTAssertFalse(portrait.usesPadFloatingLayout)
        XCTAssertFalse(portrait.usesPadNumberRow)
        XCTAssertEqual(portrait.voiceContentHeight, 267)
        XCTAssertEqual(portrait.orbDiameter, 148)
        XCTAssertEqual(portrait.voiceSideColumnWidth, 112)
        XCTAssertEqual(portrait.inputModeSwitchWidth, 72)
        XCTAssertEqual(portrait.voiceControlGap, 24)
        XCTAssertEqual(portrait.textContentHeight, 308)
        XCTAssertNil(portrait.padNumberRowHeight)
        XCTAssertEqual(portrait.textKeyHorizontalGap, 8)
        XCTAssertEqual(portrait.textKeyVerticalGap, 9)
        XCTAssertEqual(portrait.textUtilityKeyWidth, 90.31, accuracy: 0.001)

        let landscape = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 1_197,
            verticalSizeIsCompact: false,
            interfaceIdiomIsPad: true,
            interfaceOrientationIsLandscape: true,
            screenShortestSide: 834
        )
        XCTAssertTrue(landscape.usesPadFullTextLayout)
        XCTAssertFalse(landscape.usesPadNumberRow)
        XCTAssertEqual(landscape.voiceContentHeight, 267)
        XCTAssertEqual(landscape.orbDiameter, 148)
        XCTAssertEqual(landscape.voiceControlGap, 24)
        XCTAssertEqual(landscape.textContentHeight, 394)
        XCTAssertEqual(landscape.textUtilityKeyWidth, 131.67, accuracy: 0.001)

        let largePortrait = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 1_019,
            verticalSizeIsCompact: false,
            interfaceIdiomIsPad: true,
            interfaceOrientationIsLandscape: false,
            screenShortestSide: 1_032
        )
        XCTAssertTrue(largePortrait.usesPadNumberRow)
        XCTAssertEqual(largePortrait.voiceContentHeight, 267)
        XCTAssertEqual(largePortrait.textContentHeight, 379)
        XCTAssertEqual(largePortrait.padNumberRowHeight, 44)

        let largeLandscape = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 1_363,
            verticalSizeIsCompact: false,
            interfaceIdiomIsPad: true,
            interfaceOrientationIsLandscape: true,
            screenShortestSide: 1_032
        )
        XCTAssertTrue(largeLandscape.usesPadNumberRow)
        XCTAssertEqual(largeLandscape.voiceContentHeight, 267)
        XCTAssertEqual(largeLandscape.textContentHeight, 469)
        XCTAssertEqual(largeLandscape.padNumberRowHeight, 59)
        XCTAssertEqual(largeLandscape.textUtilityKeyWidth, 132)
    }

    func testPhoneLandscapeDoesNotSelectPadFullKeyboard() {
        let phoneLandscape = KeyboardSurfaceLayoutPolicy.metrics(
            availableWidth: 920,
            verticalSizeIsCompact: true,
            interfaceIdiomIsPad: false
        )
        XCTAssertFalse(phoneLandscape.usesPadFullTextLayout)
        XCTAssertFalse(phoneLandscape.usesPadFloatingLayout)
        XCTAssertFalse(phoneLandscape.usesPadNumberRow)
        XCTAssertEqual(phoneLandscape.voiceContentHeight, 253)
        XCTAssertEqual(phoneLandscape.textContentHeight, 253)
        XCTAssertEqual(phoneLandscape.textUtilityKeyWidth, 51)
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
                + metrics.voiceControlGap
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
