import AppKit
import Testing
@testable import Typeforme

@Suite("HUD focus ownership")
struct HUDFocusOwnershipTests {
    @Test @MainActor func inputActionsKeepTheTargetAppKey() {
        let panel = HUDPanel()

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)

        panel.allowsKeyFocus = true
        #expect(panel.canBecomeKey)

        panel.allowsKeyFocus = false
        #expect(!panel.canBecomeKey)
    }
}
