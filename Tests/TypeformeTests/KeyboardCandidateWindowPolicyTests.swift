import XCTest
@testable import Typeforme

final class KeyboardCandidateWindowPolicyTests: XCTestCase {
    private struct CandidateKey: Equatable {
        let index: Int
        let text: String
    }

    func testEngineUsesOnlyTheAuthoritativeFinalMenu() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialEngineCount(
                menuCount: 5,
                pageSize: 9,
                isLastPage: true
            ),
            5
        )
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialEngineCount(
                menuCount: 0,
                pageSize: 9,
                isLastPage: true
            ),
            0
        )
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialEngineCount(
                menuCount: 0,
                pageSize: 0,
                isLastPage: false
            ),
            0
        )
    }

    func testEngineKeepsTwoPagesOfHeadroomWhenMoreCandidatesExist() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialEngineCount(
                menuCount: 9,
                pageSize: 9,
                isLastPage: false
            ),
            18
        )
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialEngineCount(
                menuCount: 24,
                pageSize: 9,
                isLastPage: false
            ),
            24
        )
    }

    func testRenderedCandidatePrefixAppendsOnlyForStableContentAndLayout() {
        let existing = [
            CandidateKey(index: 0, text: "你"),
            CandidateKey(index: 1, text: "你好"),
        ]
        let extended = existing + [CandidateKey(index: 2, text: "拟好")]

        XCTAssertTrue(
            KeyboardCandidateWindowPolicy.canAppendRenderedPrefix(
                existingKeys: existing,
                nextKeys: extended,
                layoutIsStable: true
            )
        )
        XCTAssertFalse(
            KeyboardCandidateWindowPolicy.canAppendRenderedPrefix(
                existingKeys: existing,
                nextKeys: Array(extended.dropFirst()),
                layoutIsStable: true
            )
        )
        XCTAssertFalse(
            KeyboardCandidateWindowPolicy.canAppendRenderedPrefix(
                existingKeys: existing,
                nextKeys: extended,
                layoutIsStable: false
            )
        )
        XCTAssertFalse(
            KeyboardCandidateWindowPolicy.canAppendRenderedPrefix(
                existingKeys: existing,
                nextKeys: Array(existing.prefix(1)),
                layoutIsStable: true
            )
        )
    }

    func testSelectionIndexRemainsAbsoluteAcrossRimePagesAndFiltering() {
        let secondPageIndices = (0..<9).map {
            KeyboardCandidateWindowPolicy.absoluteSelectionIndex(
                candidateOffset: 9,
                rawIndex: $0
            )
        }
        let filteredIndices = secondPageIndices.enumerated().compactMap { index, selectionIndex in
            index == 2 || index == 5 ? nil : selectionIndex
        }

        XCTAssertEqual(secondPageIndices, Array(9...17))
        XCTAssertEqual(filteredIndices, [9, 10, 12, 13, 15, 16, 17])
    }

    func testInlineSurfaceMaterializesEnoughCellsToMakeWideViewportScrollable() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialInlineRenderCount(
                viewportWidth: 332,
                minimumCellWidth: 41,
                pageSize: 9
            ),
            18
        )
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialInlineRenderCount(
                viewportWidth: 700,
                minimumCellWidth: 41,
                pageSize: 9
            ),
            27
        )
    }

    func testWideRotationChangesOnlyTheSurfaceTargetNotThePerKeyEngineWindow() {
        let engineCount = KeyboardCandidateWindowPolicy.initialEngineCount(
            menuCount: 9,
            pageSize: 9,
            isLastPage: false
        )
        let portraitRenderCount = KeyboardCandidateWindowPolicy.initialInlineRenderCount(
            viewportWidth: 332,
            minimumCellWidth: 41,
            pageSize: 9
        )
        let landscapeRenderCount = KeyboardCandidateWindowPolicy.initialInlineRenderCount(
            viewportWidth: 850,
            minimumCellWidth: 41,
            pageSize: 9
        )

        XCTAssertEqual(engineCount, 18)
        XCTAssertEqual(portraitRenderCount, 18)
        XCTAssertEqual(landscapeRenderCount, 27)
        XCTAssertGreaterThan(landscapeRenderCount, engineCount)
    }

    func testWindowUsesRuntimePageSizeInsteadOfAssumingNine() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.inlineExpansionCount(
                viewportWidth: 700,
                minimumCellWidth: 41,
                pageSize: 8
            ),
            24
        )
    }

    func testGridInitialWindowCoversViewportAndOneRowOfHeadroom() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialGridCount(
                viewportHeight: 226,
                rowHeight: 45,
                columnCount: 6,
                pageSize: 9
            ),
            45
        )
    }

    func testGridExpansionCoversAnotherViewport() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.gridExpansionCount(
                viewportHeight: 226,
                rowHeight: 45,
                columnCount: 6,
                pageSize: 9
            ),
            36
        )
    }

    func testInvalidGeometryStillProvidesTwoPages() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialInlineRenderCount(
                viewportWidth: 0,
                minimumCellWidth: 0,
                pageSize: 9
            ),
            18
        )
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.initialGridCount(
                viewportHeight: 0,
                rowHeight: 0,
                columnCount: 0,
                pageSize: 9
            ),
            18
        )
    }

    func testSurfaceChangeNeverShrinksAnExpandedCompositionWindow() {
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.nonShrinkingTarget(
                initialCount: 45,
                loadedCount: 90
            ),
            90
        )
        XCTAssertEqual(
            KeyboardCandidateWindowPolicy.nonShrinkingTarget(
                initialCount: 45,
                loadedCount: 18
            ),
            45
        )
    }
}
