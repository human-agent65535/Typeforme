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

        XCTAssertEqual(KeyboardTextKeyVisualPolicy.stackedSecondaryPointSize, 15)
        XCTAssertEqual(
            KeyboardTextKeyVisualPolicy.stackedPrimaryPointSize(for: digit),
            21
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
