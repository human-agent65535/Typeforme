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
}
