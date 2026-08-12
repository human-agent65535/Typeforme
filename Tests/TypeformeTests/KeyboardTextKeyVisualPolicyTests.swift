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
        for title in ["123", "ABC", "#+="] {
            let typography = KeyboardTextKeyVisualPolicy.typography(
                title: title,
                hasImage: false,
                role: .utility
            )
            XCTAssertEqual(typography.pointSize, 18)
            XCTAssertEqual(typography.weight, .regular)
        }
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

        XCTAssertEqual(letter.pointSize, 26)
        XCTAssertEqual(letter.topInset, 7)
        XCTAssertEqual(letter.bottomInset, 3)
        XCTAssertEqual(utility.pointSize, 20)
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

        XCTAssertEqual(letter.pointSize, 22)
        XCTAssertEqual(letter.topInset, 5)
        XCTAssertEqual(letter.bottomInset, 3)
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
            21
        )
    }

    func testFullPadSymbolsAreNotScaledLikePhoneIcons() {
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "arrow.right.to.line",
                profile: .padFull
            ),
            27
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "delete.left",
                profile: .padFull
            ),
            24
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "delete.left",
                profile: .padPortrait
            ),
            21
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.iconPointSize(
                imageName: "delete.left",
                profile: .compact
            ),
            15
        )
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
            23
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
            26
        )
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(
                for: padDigit,
                profile: .padFull,
                style: .pairedSymbol
            ),
            26
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
