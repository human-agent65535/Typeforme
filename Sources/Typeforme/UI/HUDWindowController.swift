import AppKit
import Combine
import SwiftUI

/// Owns the HUD panel: placement, adaptive width per state, and the
/// show/hide animation.
@MainActor
final class HUDWindowController {
    private let panel: HUDPanel
    private let coordinator: DictationCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var moveObserver: NSObjectProtocol?
    /// Locks the panel at preview width across the preview→correcting→preview
    /// round-trip that a chip click triggers — otherwise the HUD shrinks to
    /// "correcting" width and bounces back, which is what made the preview
    /// chip row feel frantic.
    private var holdAtPreviewWidth = false
    /// AppDelegate calls `show()` on every non-idle state change. We must not
    /// re-run the entrance animation each time — that resets the panel frame
    /// and clobbers the in-flight width animation from `applyWidth`. Track
    /// shown-ness explicitly so `show()` becomes a true no-op once visible.
    private var isShown = false
    /// User-anchored bottom-center of the panel. The HUD grows UPWARD from
    /// this point as state changes, so the bottom edge stays put and never
    /// flies off the bottom of the screen when the preview wraps to multiple
    /// lines. `nil` until the user drags — then we use the default position.
    private var anchorBottomCenter: NSPoint?
    /// Set while we're moving the panel ourselves (entrance / width change);
    /// suppresses the user-drag observer so we don't treat it as a manual move.
    private var isProgrammaticallyMoving = false
    private var cachedPreviewText: String?
    private var cachedPreviewSize: NSSize?

    private static let compactHeight: CGFloat = 52
    /// Idle is a small circular presence pip — the panel shrinks to this on
    /// both axes so the corner radius (24pt) renders the surface as a circle.
    private static let idleSize: CGFloat = 40
    private static let previewMaxHeight: CGFloat = 420
    private static let previewWidth: CGFloat = 620
    private static let voiceDraftBarSize = NSSize(width: 552, height: 48)
    private static let bottomMargin: CGFloat = 80
    private static let entranceLift: CGFloat = 14
    private static let edgePadding: CGFloat = 8
    /// Chrome around the preview text inside the panel:
    ///   top padding (14) + bottom padding (6) + VStack spacing (20) + chip row (~28) + small safety buffer (4).
    /// Matches `HUDView.expandedPreviewBody`'s natural height exactly.
    private static let previewChromeHeight: CGFloat = 14 + 6 + 20 + 28 + 4
    /// The anchor `y` is the BOTTOM edge of the panel. Persisted to disk in
    /// this key; older builds wrote the panel center, but bottom-anchoring
    /// stops the HUD from sliding lower whenever the preview grows tall.
    private static let anchorXKey = "hud.anchor.bottomX"
    private static let anchorYKey = "hud.anchor.bottomY"

    /// Cached because we recompute it on every state / lastCorrected change
    /// and the SwiftUI font lookup is non-trivial.
    private static let previewMeasureFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        if let desc = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: desc, size: 13.5) {
            return rounded
        }
        return base
    }()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.panel = HUDPanel()
        let hosting = NSHostingView(rootView: HUDView(coordinator: coordinator))
        hosting.autoresizingMask = [.width, .height]
        // Empty sizing options: we explicitly do NOT want SwiftUI's preferred
        // content size to feed back into the hosting view's
        // intrinsicContentSize. Without this, the panel kept growing back to
        // SwiftUI's natural size a moment after our setFrame settled.
        hosting.sizingOptions = []
        // NSHostingView is layer-backed; the four corners outside the capsule
        // would otherwise paint an opaque white square that the system shadow
        // traces, producing a rectangular halo.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.alphaValue = 0

        anchorBottomCenter = Self.loadAnchor()

        // Re-apply the frame whenever state OR previewed text OR the live
        // partial changes — the corrected text grows / shrinks the preview
        // panel; the live partial grows / shrinks the compact body while the
        // user is actively dictating.
        Publishers.CombineLatest3(
            coordinator.$state.removeDuplicates(),
            coordinator.$lastCorrected.removeDuplicates(),
            coordinator.$livePartialTranscript.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, _, _ in
            self?.applyWidth(for: state, animated: true)
        }
        .store(in: &cancellables)

        coordinator.$previewAnchorRect
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyWidth(for: self.coordinator.state, animated: true)
            }
            .store(in: &cancellables)

        // The user dragged the HUD — persist the new center so it sticks
        // across width changes and across app launches.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleManualMove()
            }
        }
    }

    deinit {
        if let m = moveObserver {
            NotificationCenter.default.removeObserver(m)
        }
    }

    var isVisible: Bool { isShown }

    func show() {
        guard !isShown else { return }
        isShown = true
        let size = self.size(for: coordinator.state)
        let finalOrigin = origin(for: coordinator.state, size: size)
        // Slide-up entrance: start a few points below the target and fade in.
        let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - Self.entranceLift)
        isProgrammaticallyMoving = true
        panel.setFrame(NSRect(origin: startOrigin, size: size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: finalOrigin, size: size), display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isProgrammaticallyMoving = false
            }
        })
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        holdAtPreviewWidth = false
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Reset the HUD back to its default bottom-center anchor. Wired up
    /// via the menu bar when the user has dragged it somewhere unreachable.
    func resetAnchor() {
        anchorBottomCenter = nil
        UserDefaults.standard.removeObject(forKey: Self.anchorXKey)
        UserDefaults.standard.removeObject(forKey: Self.anchorYKey)
        if isShown {
            applyWidth(for: coordinator.state, animated: true)
        }
    }

    // MARK: - Adaptive width

    private func applyWidth(for state: DictationState, animated: Bool) {
        guard isShown else { return }

        // Re-correct latch: see the chip-click width-thrash bug for context.
        if state == .preview {
            holdAtPreviewWidth = true
        } else if state == .correcting && holdAtPreviewWidth {
            return
        } else {
            holdAtPreviewWidth = false
        }

        let size = self.size(for: state)
        let frame = NSRect(origin: origin(for: state, size: size), size: size)
        isProgrammaticallyMoving = true
        let release: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.isProgrammaticallyMoving = false
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: release)
        } else {
            panel.setFrame(frame, display: true)
            release()
        }
    }

    // MARK: - Anchor

    private func anchorOrDefault() -> NSPoint {
        anchorBottomCenter ?? Self.defaultAnchor()
    }

    private func origin(for state: DictationState, size: NSSize) -> NSPoint {
        if isVoiceDraftBarVisible(for: state),
           let rect = coordinator.previewAnchorRect,
           Self.isUsableRect(rect) {
            return originNearAXRect(rect, size: size)
        }
        return originForAnchor(anchorOrDefault(), size: size)
    }

    private func originNearAXRect(_ axRect: CGRect, size: NSSize) -> NSPoint {
        guard let screen = screen(containingAXRect: axRect) ?? NSScreen.main else {
            return originForAnchor(anchorOrDefault(), size: size)
        }

        let rect = appKitRect(fromAXRect: axRect, on: screen)
        let visible = screen.visibleFrame
        let minX = visible.minX + Self.edgePadding
        let maxX = visible.maxX - size.width - Self.edgePadding
        let minY = visible.minY + Self.edgePadding
        let maxY = visible.maxY - size.height - Self.edgePadding

        var x = rect.maxX - size.width
        if minX <= maxX {
            x = max(minX, min(maxX, x))
        }

        let below = rect.minY - size.height - 8
        let above = rect.maxY + 8
        var y = below >= minY ? below : above
        if minY <= maxY {
            y = max(minY, min(maxY, y))
        }
        return NSPoint(x: x, y: y)
    }

    private func appKitRect(fromAXRect rect: CGRect, on screen: NSScreen) -> NSRect {
        let candidate = NSRect(
            x: rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        if screen.frame.intersects(candidate) || screen.visibleFrame.intersects(candidate) {
            return candidate
        }
        return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func screen(containingAXRect rect: CGRect) -> NSScreen? {
        guard Self.isUsableRect(rect) else { return nil }
        return NSScreen.screens.first { screen in
            let converted = appKitRect(fromAXRect: rect, on: screen)
            let raw = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            return screen.frame.intersects(converted) || screen.frame.intersects(raw)
        }
    }

    private static func isUsableRect(_ rect: CGRect) -> Bool {
        rect.minX.isFinite &&
            rect.minY.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 1 &&
            rect.height > 1
    }

    /// Compute the panel origin so the panel's BOTTOM edge sits on `anchor.y`
    /// and is horizontally centered on `anchor.x`. The bottom is the fixed
    /// point: height changes grow the panel upward only, so the user's chip
    /// row never slides closer to (or below) the screen edge as text wraps.
    private func originForAnchor(_ anchor: NSPoint, size: NSSize) -> NSPoint {
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let minX = visible.minX + Self.edgePadding
            let maxX = visible.maxX - size.width - Self.edgePadding
            let minY = visible.minY + Self.edgePadding
            let maxY = visible.maxY - size.height - Self.edgePadding
            if minX <= maxX { origin.x = max(minX, min(maxX, origin.x)) }
            if minY <= maxY { origin.y = max(minY, min(maxY, origin.y)) }
        }
        return origin
    }

    private static func defaultAnchor() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX, y: visible.minY + bottomMargin)
    }

    private static func loadAnchor() -> NSPoint? {
        let ud = UserDefaults.standard
        guard ud.object(forKey: anchorXKey) != nil,
              ud.object(forKey: anchorYKey) != nil else { return nil }
        let p = NSPoint(x: ud.double(forKey: anchorXKey), y: ud.double(forKey: anchorYKey))
        guard !NSScreen.screens.isEmpty else { return nil }
        if NSScreen.screens.contains(where: { $0.frame.contains(p) }) {
            return p
        }

        // Display topology can change while the app is running. Preserve the
        // user's intent by clamping the old point onto the nearest screen
        // instead of discarding their placement.
        guard let nearest = NSScreen.screens.min(by: {
            distanceSquared(from: p, to: $0.frame.center) < distanceSquared(from: p, to: $1.frame.center)
        }) else { return nil }
        let visible = nearest.visibleFrame
        return NSPoint(
            x: max(visible.minX + edgePadding, min(visible.maxX - edgePadding, p.x)),
            y: max(visible.minY + edgePadding, min(visible.maxY - edgePadding, p.y))
        )
    }

    private static func distanceSquared(from lhs: NSPoint, to rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func handleManualMove() {
        guard !isProgrammaticallyMoving else { return }
        let bottomCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        anchorBottomCenter = bottomCenter
        let ud = UserDefaults.standard
        ud.set(Double(bottomCenter.x), forKey: Self.anchorXKey)
        ud.set(Double(bottomCenter.y), forKey: Self.anchorYKey)
    }

    /// Per-state target size. Preview height is `measuredTextHeight +
    /// previewChromeHeight` — sized to fit the SwiftUI VStack's natural
    /// height exactly, so no Spacer ends up growing to fill leftover space
    /// inside the HUD. Capped at `previewMaxHeight` so a 5-minute monologue
    /// can't paint over the entire screen.
    private func size(for state: DictationState) -> NSSize {
        switch state {
        case .idle:
            return NSSize(width: Self.idleSize, height: Self.idleSize)
        case .recording, .transcribing, .inserting:
            return livePartialSize(for: state) ?? NSSize(width: Self.width(for: state), height: Self.compactHeight)
        case .preview:
            if isVoiceDraftBarVisible(for: state) {
                return Self.voiceDraftBarSize
            }
            return previewSize()
        case .correcting where !coordinator.lastCorrected.isEmpty:
            if isVoiceDraftBarVisible(for: state) {
                return Self.voiceDraftBarSize
            }
            return previewSize()
        case .correcting:
            return livePartialSize(for: state) ?? NSSize(width: Self.width(for: state), height: Self.compactHeight)
        default:
            return NSSize(width: Self.width(for: state), height: Self.compactHeight)
        }
    }

    private func isVoiceDraftBarVisible(for state: DictationState) -> Bool {
        guard AppSettings.voiceUXMode == .voiceDraft else { return false }
        return state == .preview || (state == .correcting && !coordinator.lastCorrected.isEmpty)
    }

    private func previewSize() -> NSSize {
        // Trim mirrors HUDView.previewText. The corrector occasionally
        // emits trailing whitespace / newlines that SwiftUI's Text drops
        // visually, but `NSString.boundingRect` would count them as full
        // lines — left untreated, that's how a short preview ends up in
        // a 200pt-tall panel with empty material below the chips.
        let raw = coordinator.lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty ? "Preview" : raw
        if cachedPreviewText == text, let cachedPreviewSize {
            return cachedPreviewSize
        }
        let textHeight = Self.measuredTextHeight(for: text, inWidth: Self.previewWidth - 36)
        let height = min(textHeight + Self.previewChromeHeight, Self.previewMaxHeight)
        let size = NSSize(width: Self.previewWidth, height: height)
        cachedPreviewText = text
        cachedPreviewSize = size
        return size
    }

    private func livePartialSize(for state: DictationState) -> NSSize? {
        let text = coordinator.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let textWidth = Self.measuredTextWidth(for: text)
        let chrome = state == .recording ? CGFloat(190) : CGFloat(96)
        let width = min(Self.previewWidth, max(CGFloat(240), ceil(textWidth + chrome)))
        return NSSize(width: width, height: Self.compactHeight)
    }

    private static func measuredTextWidth(for text: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: previewMeasureFont]
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }

    private static func measuredTextHeight(for text: String, inWidth width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: previewMeasureFont]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(bounds.height)
    }

    /// Widths for the compact (non-idle, non-preview) capsule. Status text
    /// lives in color + icon + timer + tooltip, so these widths only reserve
    /// space for active controls.
    private static func width(for state: DictationState) -> CGFloat {
        switch state {
        case .idle:                          return idleSize  // unused; size(for:) handles idle specially
        case .recording:                     return 240
        case .transcribing, .correcting:     return 120
        case .preview:                       return previewWidth
        case .inserting:                     return 120
        case .success:                       return 100
        case .error:                         return 380
        }
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
