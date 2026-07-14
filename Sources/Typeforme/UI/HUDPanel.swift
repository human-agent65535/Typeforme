import AppKit

/// Frameless, non-activating panel. Showing this panel must not steal focus
/// from the user's current app.
final class HUDPanel: NSPanel {
    var allowsKeyFocus = false
    var manualDragRegionHeight: CGFloat = 0
    var onManualDragBegan: (() -> Void)?
    var onManualDragMoved: (() -> Void)?
    var onManualDragEnded: (() -> Void)?
    var isManualDragging: Bool { dragSession?.isDragging == true }

    private struct DragSession {
        let startMouseLocation: NSPoint
        let startFrame: NSRect
        var isDragging: Bool
    }

    private var dragSession: DragSession?
    private static let dragThreshold: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // AppKit shadows are rectangular while a borderless clear panel is
        // being resized, which shows up as a square outline before SwiftUI's
        // rounded HUD surface catches up.
        hasShadow = false
        level = .floating
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Defensive: macOS will silently refuse `setFrame` calls that go
        // below these floors. SwiftUI hosting views sometimes nudge them up.
        contentMinSize = .zero
        minSize = .zero
    }

    // Input actions operate on the text control focused in another app, so
    // the panel stays non-key while they are available. A completed preview
    // may opt in so its text remains selectable after the commit is finished.
    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if pointIsInManualDragRegion(event.locationInWindow) {
                dragSession = DragSession(
                    startMouseLocation: NSEvent.mouseLocation,
                    startFrame: frame,
                    isDragging: false
                )
            } else {
                dragSession = nil
            }
            super.sendEvent(event)
        case .leftMouseDragged:
            guard var session = dragSession else {
                super.sendEvent(event)
                return
            }

            let current = NSEvent.mouseLocation
            let delta = NSPoint(
                x: current.x - session.startMouseLocation.x,
                y: current.y - session.startMouseLocation.y
            )
            if !session.isDragging {
                let distance = hypot(delta.x, delta.y)
                guard distance >= Self.dragThreshold else {
                    super.sendEvent(event)
                    return
                }
                session.isDragging = true
                onManualDragBegan?()
            }

            dragSession = session
            setFrameOrigin(NSPoint(
                x: session.startFrame.origin.x + delta.x,
                y: session.startFrame.origin.y + delta.y
            ))
            onManualDragMoved?()
        case .leftMouseUp:
            let handledDrag = dragSession?.isDragging == true
            dragSession = nil
            if !handledDrag {
                super.sendEvent(event)
            } else {
                onManualDragEnded?()
            }
        default:
            super.sendEvent(event)
        }
    }

    private func pointIsInManualDragRegion(_ point: NSPoint) -> Bool {
        guard manualDragRegionHeight > 0 else { return false }
        return point.y >= 0 && point.y <= min(frame.height, manualDragRegionHeight)
    }
}
