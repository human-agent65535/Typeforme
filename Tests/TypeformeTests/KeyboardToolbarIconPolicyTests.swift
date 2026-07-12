import XCTest
@testable import Typeforme

final class KeyboardToolbarIconPolicyTests: XCTestCase {
    func testEveryToolbarRoleHasExplicitUsableMetrics() {
        for role in KeyboardToolbarIconRole.allCases {
            let metrics = KeyboardToolbarIconPolicy.metrics(for: role)
            XCTAssertGreaterThanOrEqual(metrics.pointSize, 14)
            XCTAssertLessThanOrEqual(metrics.pointSize, 21)
            XCTAssertGreaterThanOrEqual(metrics.cornerRadius, 8)
        }
    }

    func testOpticallyTallSymbolsUseSmallerPointSizes() {
        let brush = KeyboardToolbarIconPolicy.metrics(for: .refineStyle)
        let undo = KeyboardToolbarIconPolicy.metrics(for: .undo)
        let host = KeyboardToolbarIconPolicy.metrics(for: .host)

        XCTAssertLessThan(brush.pointSize, undo.pointSize)
        XCTAssertLessThan(host.pointSize, undo.pointSize)
    }

    func testCandidateChevronKeepsItsSeparateNativeLikeGeometry() {
        let candidate = KeyboardToolbarIconPolicy.metrics(for: .candidateChevron)
        XCTAssertEqual(candidate.pointSize, 21)
        XCTAssertEqual(candidate.weight, .medium)
        XCTAssertEqual(candidate.verticalOffset, 0)
        XCTAssertEqual(candidate.horizontalInset, 0)
    }

    func testDisabledOpacityIsVisibleButClearlySecondary() {
        XCTAssertGreaterThan(KeyboardToolbarIconPolicy.disabledOpacity, 0.35)
        XCTAssertLessThan(KeyboardToolbarIconPolicy.disabledOpacity, 0.5)
    }
}
