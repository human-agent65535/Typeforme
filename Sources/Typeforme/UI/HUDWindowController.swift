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
    /// The panel is permanently on screen once shown (idle collapses it to a
    /// pip instead of hiding). Guarding here keeps `show()` a no-op if called
    /// again so the entrance animation can't clobber an in-flight width
    /// animation from `applyWidth`.
    private var isShown = false
    /// User-anchored bottom-center of the panel. The HUD grows UPWARD from
    /// this point as state changes, so the bottom edge stays put and never
    /// flies off the bottom of the screen when the preview wraps to multiple
    /// lines. `nil` until the user drags — then we use the default position.
    private var anchorBottomCenter: NSPoint?
    /// Set while we're moving the panel ourselves (entrance / width change);
    /// suppresses the user-drag observer so we don't treat it as a manual move.
    private var isProgrammaticallyMoving = false
    private var isUserDragging = false
    private var cachedPreviewText: String?
    private var cachedPreviewSize: NSSize?

    private static let compactHeight: CGFloat = 52
    /// Idle is a small circular presence pip — the panel shrinks to this on
    /// both axes so the corner radius (24pt) renders the surface as a circle.
    private static let idleSize: CGFloat = 40
    private static let previewMaxHeight: CGFloat = 420
    private static let previewWidth: CGFloat = 620
    private static let degradedSuccessWidth: CGFloat = 220
    private static let voicePreviewBarSize = NSSize(width: 488, height: 48)
    private static let bottomMargin: CGFloat = 80
    private static let entranceLift: CGFloat = 14
    private static let edgePadding: CGFloat = 8
    /// Chrome around the preview text inside the panel:
    ///   top padding (14) + bottom padding (6) + VStack spacing (12) + inline action row (~36) + safety buffer (6).
    /// Matches `HUDView.expandedPreviewBody`'s natural height exactly.
    private static let previewChromeHeight: CGFloat = 14 + 6 + 12 + 36 + 6
    private static let previewWarningHeight: CGFloat = 36
    private static let livePartialWidthBucket: CGFloat = 72
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

    init(coordinator: DictationCoordinator, onOpenSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.panel = HUDPanel()
        let hosting = TransparentHUDHostingView(rootView: HUDView(coordinator: coordinator, onOpenSettings: onOpenSettings))
        hosting.autoresizingMask = [.width, .height]
        // Empty sizing options: we explicitly do NOT want SwiftUI's preferred
        // content size to feed back into the hosting view's
        // intrinsicContentSize. Without this, the panel kept growing back to
        // SwiftUI's natural size a moment after our setFrame settled.
        hosting.sizingOptions = []
        // NSHostingView is layer-backed; keep its layer transparent so only
        // the SwiftUI rounded HUD surface paints the borderless panel.
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.masksToBounds = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.alphaValue = 0

        anchorBottomCenter = Self.loadAnchor()

        // Re-apply the frame whenever state OR previewed text OR the live
        // partial changes — the corrected text grows / shrinks the preview
        // panel; the live partial grows / shrinks the compact body while the
        // user is actively dictating.
        Publishers.CombineLatest4(
            coordinator.$state.removeDuplicates(),
            coordinator.$lastCorrected.removeDuplicates(),
            coordinator.$livePartialTranscript.removeDuplicates(),
            coordinator.$lastWarning.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, _, _, _ in
            self?.applyWidth(for: state, animated: true)
        }
        .store(in: &cancellables)

        coordinator.$voicePreviewHUDExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyWidth(for: self.coordinator.state, animated: true)
            }
            .store(in: &cancellables)

        panel.onManualDragBegan = { [weak self] in
            self?.isUserDragging = true
        }
        panel.onManualDragMoved = { [weak self] in
            self?.updateAnchorFromCurrentFrame()
        }
        panel.onManualDragEnded = { [weak self] in
            guard let self else { return }
            self.updateAnchorFromCurrentFrame()
            self.persistCurrentAnchor()
            self.isUserDragging = false
        }

        // The user dragged the HUD — persist the new center so it sticks
        // across width changes and across app launches.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleManualMove()
                }
            }
            .store(in: &cancellables)
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        let size = self.size(for: coordinator.state)
        let finalOrigin = origin(for: coordinator.state, size: size)
        panel.manualDragRegionHeight = dragRegionHeight(for: coordinator.state, size: size)
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
        panel.allowsKeyFocus = state == .success && !voicePreviewText(for: state).isEmpty
        guard isShown, !isUserDragging else { return }

        let size = self.size(for: state)
        let frame = NSRect(origin: origin(for: state, size: size), size: size)
        panel.manualDragRegionHeight = dragRegionHeight(for: state, size: size)
        guard !Self.frameApproximatelyEqual(panel.frame, frame) else { return }
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
        return originForAnchor(anchorOrDefault(), size: size)
    }

    /// Compute the panel origin so the panel's BOTTOM edge sits on `anchor.y`
    /// and is horizontally centered on `anchor.x`. The bottom is the fixed
    /// point: height changes grow the panel upward only, so the user's chip
    /// row never slides closer to (or below) the screen edge as text wraps.
    private func originForAnchor(_ anchor: NSPoint, size: NSSize) -> NSPoint {
        Self.clampedOrigin(
            for: anchor,
            size: size,
            screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        )
    }

    static func clampedOrigin(
        for anchor: NSPoint,
        size: NSSize,
        screens: [(frame: NSRect, visibleFrame: NSRect)]
    ) -> NSPoint {
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        let selectedScreen = screens.first(where: { $0.frame.contains(anchor) })
            ?? screens.min(by: {
                distanceSquared(from: anchor, to: $0.frame)
                    < distanceSquared(from: anchor, to: $1.frame)
            })
        if let visible = selectedScreen?.visibleFrame {
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
            distanceSquared(from: p, to: $0.frame) < distanceSquared(from: p, to: $1.frame)
        }) else { return nil }
        let visible = nearest.visibleFrame
        return NSPoint(
            x: max(visible.minX + edgePadding, min(visible.maxX - edgePadding, p.x)),
            y: max(visible.minY + edgePadding, min(visible.maxY - edgePadding, p.y))
        )
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return dx * dx + dy * dy
    }

    private func handleManualMove() {
        guard !isProgrammaticallyMoving, !panel.isManualDragging else { return }
        updateAnchorFromCurrentFrame()
        persistCurrentAnchor()
    }

    private func updateAnchorFromCurrentFrame() {
        let bottomCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        anchorBottomCenter = bottomCenter
    }

    private func persistCurrentAnchor() {
        guard let anchorBottomCenter else { return }
        let ud = UserDefaults.standard
        ud.set(Double(anchorBottomCenter.x), forKey: Self.anchorXKey)
        ud.set(Double(anchorBottomCenter.y), forKey: Self.anchorYKey)
    }

    /// Per-state target size. Expanded height is `measuredTextHeight +
    /// previewChromeHeight` — sized to fit the SwiftUI VStack's natural
    /// height exactly, so no Spacer ends up growing to fill leftover space
    /// inside the HUD. Capped at `previewMaxHeight` so a 5-minute monologue
    /// can't paint over the entire screen.
    private func size(for state: DictationState) -> NSSize {
        if isVoicePreviewExpanded(for: state) {
            return voicePreviewSize(for: state)
        }

        switch state {
        case .idle:
            return NSSize(width: Self.idleSize, height: Self.idleSize)
        case .inserting:
            return livePartialSize() ?? NSSize(width: Self.width(for: state), height: Self.compactHeight)
        case .success where coordinator.lastWarning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false:
            return NSSize(width: Self.degradedSuccessWidth, height: Self.compactHeight)
        default:
            return NSSize(width: Self.width(for: state), height: Self.compactHeight)
        }
    }

    private func isVoicePreviewExpanded(for state: DictationState) -> Bool {
        switch state {
        case .idle:
            return coordinator.voicePreviewHUDExpanded
        case .recording, .transcribing, .correcting:
            return true
        case .success:
            return !voicePreviewText(for: state).isEmpty
        case .inserting, .error:
            return false
        }
    }

    private func voicePreviewSize(for state: DictationState) -> NSSize {
        let text = voicePreviewText(for: state)
        guard !text.isEmpty else {
            return Self.voicePreviewBarSize
        }
        let warning = coordinator.lastWarning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cacheKey = warning.isEmpty ? "voicePreview:\(text)" : "voicePreview:\(text)|warning:\(warning)"
        if cachedPreviewText == cacheKey, let cachedPreviewSize {
            return cachedPreviewSize
        }
        let textHeight = Self.measuredTextHeight(for: text, inWidth: Self.previewWidth - 36)
        let warningHeight: CGFloat = !warning.isEmpty
            ? Self.previewWarningHeight
            : 0
        let height = min(textHeight + warningHeight + Self.previewChromeHeight, Self.previewMaxHeight)
        let size = NSSize(width: Self.previewWidth, height: height)
        cachedPreviewText = cacheKey
        cachedPreviewSize = size
        return size
    }

    private func voicePreviewText(for state: DictationState) -> String {
        let live = coordinator.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            switch state {
            case .recording, .transcribing, .correcting:
                return live
            default:
                break
            }
        }
        return coordinator.lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dragRegionHeight(for state: DictationState, size: NSSize) -> CGFloat {
        min(size.height, Self.compactHeight)
    }

    /// Compact-capsule width while `.inserting` still shows the live partial
    /// text. All other live-partial states use the expanded panel.
    private func livePartialSize() -> NSSize? {
        let text = coordinator.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let textWidth = Self.measuredTextWidth(for: text)
        let rawWidth = max(CGFloat(240), ceil(textWidth + 96))
        let bucketedWidth = ceil(rawWidth / Self.livePartialWidthBucket) * Self.livePartialWidthBucket
        let width = min(Self.previewWidth, bucketedWidth)
        return NSSize(width: width, height: Self.compactHeight)
    }

    private static func frameApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
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

    /// Widths for the compact capsule states. Status text lives in color +
    /// icon + tooltip, so these widths only reserve space for active controls.
    /// Recording / transcribing / correcting never reach here — they always
    /// use the expanded panel.
    private static func width(for state: DictationState) -> CGFloat {
        switch state {
        case .idle:                          return idleSize  // unused; size(for:) handles idle specially
        case .recording:                     return 240
        case .transcribing, .correcting:     return 120
        case .inserting:                     return 120
        case .success:                       return 100
        case .error:                         return 380
        }
    }
}

private final class TransparentHUDHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
