import Foundation

/// Sizes the Rime candidate prefix independently from candidate ranking and UI
/// state. The per-key engine capture stays at two Rime pages; viewport-derived
/// counts apply only when a surface is materialized or the user asks to scroll,
/// so a wide keyboard does not make every keystroke capture a large prefix.
enum KeyboardCandidateWindowPolicy {
    static func absoluteSelectionIndex(candidateOffset: Int, rawIndex: Int) -> Int {
        precondition(candidateOffset >= 0 && rawIndex >= 0)
        return candidateOffset + rawIndex
    }

    /// Surface changes may ask for a different initial window size, but the
    /// shared window for one composition is append-only until that composition
    /// changes.
    static func nonShrinkingTarget(initialCount: Int, loadedCount: Int) -> Int {
        max(0, max(initialCount, loadedCount))
    }

    /// Rime's current menu is authoritative when it already represents the
    /// final page. Otherwise load one additional page of headroom so ordinary
    /// inline scrolling does not immediately cross the engine boundary.
    static func initialEngineCount(
        menuCount: Int,
        pageSize: Int,
        isLastPage: Bool
    ) -> Int {
        let menuCount = max(0, menuCount)
        guard menuCount > 0 else { return 0 }
        guard !isLastPage else { return menuCount }
        return max(menuCount, normalizedPageSize(pageSize) * 2)
    }

    /// A rendered surface may retain its existing cells only when layout is
    /// unchanged and the next projection extends the exact same semantic
    /// prefix. Shrinks and replacements require one coherent reflow.
    static func canAppendRenderedPrefix<Key: Equatable>(
        existingKeys: [Key],
        nextKeys: [Key],
        layoutIsStable: Bool
    ) -> Bool {
        layoutIsStable
            && nextKeys.count >= existingKeys.count
            && nextKeys.prefix(existingKeys.count).elementsEqual(existingKeys)
    }

    /// Materialize at least two pages, and enough of an already-loaded window
    /// to overflow the widest possible visible prefix. This method never asks
    /// Rime for more candidates; an intentional scroll gesture owns that cost.
    static func initialInlineRenderCount(
        viewportWidth: Double,
        minimumCellWidth: Double,
        pageSize: Int
    ) -> Int {
        let pageSize = normalizedPageSize(pageSize)
        let viewportCapacity = cellCapacity(
            availableLength: viewportWidth,
            minimumCellLength: minimumCellWidth
        )
        return roundedUpToPage(
            max(pageSize * 2, viewportCapacity + 1),
            pageSize: pageSize
        )
    }

    static func inlineExpansionCount(
        viewportWidth: Double,
        minimumCellWidth: Double,
        pageSize: Int
    ) -> Int {
        let pageSize = normalizedPageSize(pageSize)
        let viewportCapacity = cellCapacity(
            availableLength: viewportWidth,
            minimumCellLength: minimumCellWidth
        )
        return roundedUpToPage(max(pageSize * 2, viewportCapacity), pageSize: pageSize)
    }

    static func initialGridCount(
        viewportHeight: Double,
        rowHeight: Double,
        columnCount: Int,
        pageSize: Int
    ) -> Int {
        let pageSize = normalizedPageSize(pageSize)
        let visibleRows = cellCapacity(
            availableLength: viewportHeight,
            minimumCellLength: rowHeight
        )
        let visibleCellsWithHeadroom = (visibleRows + 1) * max(1, columnCount)
        return roundedUpToPage(max(pageSize * 2, visibleCellsWithHeadroom), pageSize: pageSize)
    }

    static func gridExpansionCount(
        viewportHeight: Double,
        rowHeight: Double,
        columnCount: Int,
        pageSize: Int
    ) -> Int {
        let pageSize = normalizedPageSize(pageSize)
        let visibleRows = cellCapacity(
            availableLength: viewportHeight,
            minimumCellLength: rowHeight
        )
        let visibleCells = visibleRows * max(1, columnCount)
        return roundedUpToPage(max(pageSize * 2, visibleCells), pageSize: pageSize)
    }

    private static func cellCapacity(
        availableLength: Double,
        minimumCellLength: Double
    ) -> Int {
        guard availableLength > 0, minimumCellLength > 0 else { return 0 }
        return Int(ceil(availableLength / minimumCellLength))
    }

    private static func normalizedPageSize(_ pageSize: Int) -> Int {
        max(1, pageSize)
    }

    private static func roundedUpToPage(_ count: Int, pageSize: Int) -> Int {
        let positiveCount = max(1, count)
        return ((positiveCount + pageSize - 1) / pageSize) * pageSize
    }
}
