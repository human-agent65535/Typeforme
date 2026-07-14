import AppKit
import Testing
@testable import Typeforme

@Suite("HUD placement")
struct HUDPlacementTests {
    @Test @MainActor func clampsToScreenContainingPersistedAnchor() {
        let screens = [
            (frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
             visibleFrame: NSRect(x: 0, y: 24, width: 1_920, height: 1_056)),
            (frame: NSRect(x: 1_920, y: 0, width: 1_280, height: 1_024),
             visibleFrame: NSRect(x: 1_920, y: 0, width: 1_280, height: 1_024)),
        ]

        let origin = HUDWindowController.clampedOrigin(
            for: NSPoint(x: 2_560, y: 80),
            size: NSSize(width: 620, height: 420),
            screens: screens
        )

        #expect(origin == NSPoint(x: 2_250, y: 80))
    }

    @Test @MainActor func clampsMissingDisplayAnchorToNearestRemainingScreen() {
        let screens = [
            (frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
             visibleFrame: NSRect(x: 0, y: 24, width: 1_920, height: 1_056)),
        ]

        let origin = HUDWindowController.clampedOrigin(
            for: NSPoint(x: 5_000, y: -500),
            size: NSSize(width: 620, height: 420),
            screens: screens
        )

        #expect(origin == NSPoint(x: 1_292, y: 32))
    }

    @Test @MainActor func nearestScreenUsesFrameEdgeRatherThanScreenCenter() {
        let screens = [
            (frame: NSRect(x: 0, y: 0, width: 4_000, height: 1_000),
             visibleFrame: NSRect(x: 0, y: 0, width: 4_000, height: 1_000)),
            (frame: NSRect(x: 4_050, y: 0, width: 500, height: 1_000),
             visibleFrame: NSRect(x: 4_050, y: 0, width: 500, height: 1_000)),
        ]

        let origin = HUDWindowController.clampedOrigin(
            for: NSPoint(x: 3_900, y: 2_000),
            size: NSSize(width: 620, height: 420),
            screens: screens
        )

        #expect(origin == NSPoint(x: 3_372, y: 572))
    }
}
