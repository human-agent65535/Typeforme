import XCTest
@testable import Typeforme

final class KeyboardTextKeyVisualPolicyTests: XCTestCase {
    func testLowercaseAndUppercaseLettersKeepNativeMeasuredSizes() {
        let lowercase = KeyboardTextKeyVisualPolicy.typography(
            title: "a",
            hasImage: false,
            role: .normal
        )
        let uppercase = KeyboardTextKeyVisualPolicy.typography(
            title: "A",
            hasImage: false,
            role: .normal
        )

        XCTAssertEqual(lowercase.pointSize, 25)
        XCTAssertEqual(uppercase.pointSize, 22)
        XCTAssertEqual(lowercase.topInset, 5)
        XCTAssertEqual(lowercase.bottomInset, 5)
    }

    func testCompactModeKeysUseDedicatedTypography() {
        for title in ["123", "ABC"] {
            let typography = KeyboardTextKeyVisualPolicy.typography(
                title: title,
                hasImage: false,
                role: .utility
            )
            XCTAssertEqual(typography.pointSize, 18)
            XCTAssertEqual(typography.weight, .regular)
        }

        let alternateSymbols = KeyboardTextKeyVisualPolicy.typography(
            title: "#+=",
            hasImage: false,
            role: .utility
        )
        XCTAssertEqual(alternateSymbols.pointSize, 13)
        XCTAssertEqual(alternateSymbols.weight, .regular)
    }

    func testCompactSlashUsesNativeOpticalScale() {
        let slash = KeyboardTextKeyVisualPolicy.typography(
            title: "/",
            hasImage: false,
            role: .normal
        )

        XCTAssertEqual(slash.pointSize, 20)
        XCTAssertEqual(slash.weight, .regular)
    }

    func testCompactPunctuationUsesNativeOpticalScale() {
        for (title, expectedPointSize) in [(".", 26.0), (",", 26.0), (":", 25.0)] {
            let punctuation = KeyboardTextKeyVisualPolicy.typography(
                title: title,
                hasImage: false,
                role: .normal
            )
            XCTAssertEqual(punctuation.pointSize, expectedPointSize)
            XCTAssertEqual(punctuation.weight, .regular)
        }
    }

    func testCompactNarrowSymbolsUseNativeOpticalProportions() {
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.contentScale(
                title: "#+=",
                role: .utility,
                profile: .compact
            ),
            KeyboardTextKeyContentScale(horizontal: 1.03, vertical: 0.82)
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.contentScale(
                title: "/",
                role: .normal,
                profile: .compact
            ),
            .identity
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.contentScale(
                title: "q",
                role: .normal,
                profile: .compact
            ),
            .identity
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.contentScale(
                title: "#+=",
                role: .utility,
                profile: .padFull
            ),
            .identity
        )
    }

    func testFullPadKeyLegendsUseNativeScaleAndBaseline() {
        let letter = KeyboardTextKeyVisualPolicy.typography(
            title: "Q",
            hasImage: false,
            role: .normal,
            profile: .padFull
        )
        let utility = KeyboardTextKeyVisualPolicy.typography(
            title: "123",
            hasImage: false,
            role: .utility,
            profile: .padFull
        )

        XCTAssertEqual(letter.pointSize, 22)
        XCTAssertEqual(letter.topInset, 3)
        XCTAssertEqual(letter.bottomInset, 7)
        XCTAssertEqual(utility.pointSize, 18)

        let lowercase = KeyboardTextKeyVisualPolicy.typography(
            title: "q",
            hasImage: false,
            role: .normal,
            profile: .padFull
        )
        XCTAssertEqual(lowercase.pointSize, 25)
    }

    func testPortraitPadUsesCompactNativeLegendScale() {
        let letter = KeyboardTextKeyVisualPolicy.typography(
            title: "Q",
            hasImage: false,
            role: .normal,
            profile: .padPortrait
        )
        let utility = KeyboardTextKeyVisualPolicy.typography(
            title: "123",
            hasImage: false,
            role: .utility,
            profile: .padPortrait
        )

        XCTAssertEqual(letter.pointSize, 20)
        XCTAssertEqual(letter.topInset, 3)
        XCTAssertEqual(letter.bottomInset, 5)
        XCTAssertEqual(utility.pointSize, 17)
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize(profile: .padPortrait),
            10
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                for: letter,
                profile: .padPortrait
            ),
            20
        )
    }

    func testPadUtilitySymbolsMatchNativeGlyphScale() {
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "arrow.right.to.line",
                profile: .padFull
            ),
            16
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "delete.left",
                profile: .padFull
            ),
            16
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "delete.left",
                profile: .padPortrait
            ),
            16
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "delete.left",
                profile: .compact
            ),
            15
        )
    }

    func testFullPadNumberRowUsesNativeSingleLegendScale() {
        let digit = KeyboardTextKeyVisualPolicy.typography(
            title: "1",
            hasImage: false,
            role: .numberRow,
            profile: .padFull
        )

        XCTAssertEqual(digit.pointSize, 18)
        XCTAssertEqual(digit.weight, .regular)
        XCTAssertEqual(digit.topInset, 3)
        XCTAssertEqual(digit.bottomInset, 7)
    }

    func testActionAndUtilityKeysShareActionTypographyWithoutSharingSemantics() {
        let utility = KeyboardTextKeyVisualPolicy.typography(
            title: "go",
            hasImage: false,
            role: .utility
        )
        let action = KeyboardTextKeyVisualPolicy.typography(
            title: "go",
            hasImage: false,
            role: .action
        )

        XCTAssertEqual(utility, action)
        XCTAssertNotEqual(KeyboardTextKeyRole.utility, KeyboardTextKeyRole.action)
    }

    func testStackedIPadLegendsKeepAlternateSymbolsReadable() {
        let digit = KeyboardTextKeyVisualPolicy.typography(
            title: "1",
            hasImage: false,
            role: .normal
        )

        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize(profile: .compact),
            15
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(for: digit),
            21
        )

        let padDigit = KeyboardTextKeyVisualPolicy.typography(
            title: "1",
            hasImage: false,
            role: .normal,
            profile: .padFull
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize(profile: .padFull),
            13
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                for: padDigit,
                profile: .padFull
            ),
            22
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize(
                profile: .padFull,
                style: .numberRow
            ),
            15
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                for: padDigit,
                profile: .padFull,
                style: .numberRow
            ),
            15
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize(
                profile: .padFull,
                style: .pairedSymbol
            ),
            15
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                for: padDigit,
                profile: .padFull,
                style: .pairedSymbol
            ),
            15
        )
    }

    func testUtilityKeysRetainStrongerShadowThanNormalKeys() {
        XCTAssertGreaterThan(
            KeyboardTextKeyVisualPolicy.shadowOpacity(role: .utility, isDark: false),
            KeyboardTextKeyVisualPolicy.shadowOpacity(role: .normal, isDark: false)
        )
        XCTAssertGreaterThan(
            KeyboardTextKeyVisualPolicy.shadowOpacity(role: .utility, isDark: true),
            KeyboardTextKeyVisualPolicy.shadowOpacity(role: .normal, isDark: true)
        )
    }
}
