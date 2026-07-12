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
        XCTAssertEqual(lowercase.topInset, 3)
        XCTAssertEqual(lowercase.bottomInset, 7)
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
