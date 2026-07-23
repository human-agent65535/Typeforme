enum KeyboardCandidateStripGeometryPolicy {
    /// The action column owns its enlarged hit band. Add the part of that band
    /// inside the candidate viewport to the terminal scroll range so the final
    /// candidate can stop at the same safe edge used by the text overlay.
    static func trailingRevealReserve(
        viewportTrailingEdge: Double,
        safeTrailingEdge: Double
    ) -> Double {
        max(0, viewportTrailingEdge - safeTrailingEdge)
    }
}
