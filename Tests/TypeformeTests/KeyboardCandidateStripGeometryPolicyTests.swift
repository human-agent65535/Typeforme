import XCTest
@testable import Typeforme

final class KeyboardCandidateStripGeometryPolicyTests: XCTestCase {
    func testTerminalInlineCandidateReachesTheOverlaySafeEdge() {
        let viewportTrailingEdge = 332.0
        let safeTrailingEdge = 330.0
        let contentWidth = 738.0
        let reserve = KeyboardCandidateStripGeometryPolicy.trailingRevealReserve(
            viewportTrailingEdge: viewportTrailingEdge,
            safeTrailingEdge: safeTrailingEdge
        )
        let maximumOffset = contentWidth - viewportTrailingEdge + reserve
        let terminalCandidateTrailingEdge = contentWidth - maximumOffset

        XCTAssertEqual(reserve, 2)
        XCTAssertEqual(terminalCandidateTrailingEdge, safeTrailingEdge)
    }

    func testNonOverlappingActionNeedsNoTrailingReserve() {
        XCTAssertEqual(
            KeyboardCandidateStripGeometryPolicy.trailingRevealReserve(
                viewportTrailingEdge: 332,
                safeTrailingEdge: 334
            ),
            0
        )
    }

    func testReverseGeometryIsClampedToZero() {
        XCTAssertEqual(
            KeyboardCandidateStripGeometryPolicy.trailingRevealReserve(
                viewportTrailingEdge: -10,
                safeTrailingEdge: 4
            ),
            0
        )
    }
}
