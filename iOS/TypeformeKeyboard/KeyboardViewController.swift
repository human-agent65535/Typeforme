import UIKit
import SwiftUI
import Darwin
import ObjectiveC
import OSLog
import QuartzCore

private let kbLog = Logger(subsystem: TypeformeBundleConfiguration.keyboardBundleIdentifier, category: "ui")

@MainActor
private final class KeyboardHostLinkOpener: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let url: URL
        let completion: @Sendable (Bool) -> Void
    }

    @Published fileprivate var request: Request?

    private var hostController: UIHostingController<KeyboardHostLinkOpenerView>?

    func installIfNeeded(in parent: UIViewController) {
        if hostController?.parent === parent { return }
        if let hostController {
            hostController.willMove(toParent: nil)
            hostController.view.removeFromSuperview()
            hostController.removeFromParent()
            self.hostController = nil
        }

        let controller = UIHostingController(rootView: KeyboardHostLinkOpenerView(opener: self))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        controller.view.alpha = 0.01
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
        parent.addChild(controller)
        parent.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.widthAnchor.constraint(equalToConstant: 1),
            controller.view.heightAnchor.constraint(equalToConstant: 1),
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
        ])
        controller.didMove(toParent: parent)
        hostController = controller
    }

    func open(_ url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        guard hostController != nil else {
            kbLog.notice("openHostApp: SwiftUI link opener unavailable")
            completion(false)
            return
        }
        request = Request(url: url, completion: completion)
    }

    fileprivate func finish(_ id: UUID, accepted: Bool) {
        guard request?.id == id else { return }
        let completion = request?.completion
        request = nil
        completion?(accepted)
    }
}

private struct KeyboardHostLinkOpenerView: View {
    @ObservedObject var opener: KeyboardHostLinkOpener
    @Environment(\.openURL) private var openURL
    @State private var handledRequestID: UUID?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear(perform: openPendingRequest)
            .onChange(of: opener.request?.id) { _, _ in
                openPendingRequest()
            }
    }

    private func openPendingRequest() {
        guard let request = opener.request,
              handledRequestID != request.id
        else { return }
        handledRequestID = request.id
        openURL(request.url) { accepted in
            Task { @MainActor in
                opener.finish(request.id, accepted: accepted)
            }
        }
    }
}

fileprivate enum KeyboardTouchTarget {
    case textKey(UIButton)
    case candidateAction(UIButton)
    case focusSurface

    var allowsKeyboardFocusSwipe: Bool {
        switch self {
        case .textKey, .focusSurface:
            return true
        case .candidateAction:
            return false
        }
    }

}

private extension CorrectionMode {
    var title: String {
        switch self {
        case .clean:         return NSLocalizedString("Clean", comment: "Correction mode")
        case .polishPlus:    return NSLocalizedString("Polish+", comment: "Correction mode")
        case .structurePlus: return NSLocalizedString("Structure+", comment: "Correction mode")
        case .formalPlus:    return NSLocalizedString("Formal+", comment: "Correction mode")
        case .fast:          return NSLocalizedString("Fast", comment: "Correction mode")
        }
    }
}

final class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    private enum CapsuleStyle {
        case chrome
        case key
        case utility
    }

    private enum KeyboardFocus: String {
        case voice
        case text
    }

    private struct KeyboardFocusPager {
        static let minimumSwipeDistance: CGFloat = 72
        static let axisDominance: CGFloat = 1.6
        static let handledCooldown: CFTimeInterval = 0.45
        // Shorter than the 0.26s focus animation so a deliberate tap right after
        // a swipe is not silently dropped; the easing curve has the keys
        // visually settled well before the animation formally ends.
        static let commitSuppressionDuration: CFTimeInterval = 0.18

        static func horizontalIntent(start: CGPoint, current: CGPoint) -> CGFloat? {
            let dx = current.x - start.x
            let dy = current.y - start.y
            guard isSwipeIntent(dx: dx, dy: dy, threshold: minimumSwipeDistance) else { return nil }
            return dx
        }

        static func target(from current: KeyboardFocus, horizontalIntent: CGFloat) -> KeyboardFocus? {
            guard abs(horizontalIntent) > .ulpOfOne else { return nil }
            return current == .voice ? .text : .voice
        }

        static func enteringOffset(horizontalIntent: CGFloat?, fallbackTarget: KeyboardFocus, width: CGFloat) -> CGFloat {
            if let horizontalIntent, abs(horizontalIntent) > .ulpOfOne {
                return horizontalIntent < 0 ? width : -width
            }
            return fallbackTarget == .text ? width : -width
        }

        static func leavingOffset(horizontalIntent: CGFloat?, fallbackTarget: KeyboardFocus, width: CGFloat) -> CGFloat {
            if let horizontalIntent, abs(horizontalIntent) > .ulpOfOne {
                return horizontalIntent < 0 ? -width : width
            }
            return fallbackTarget == .text ? -width : width
        }

        private static func isSwipeIntent(dx: CGFloat, dy: CGFloat, threshold: CGFloat) -> Bool {
            abs(dx) >= threshold && abs(dx) > abs(dy) * axisDominance
        }
    }

    private struct TextKeyboardTouchModel {
        // Route with an intent point, then draw feedback on the resolved key.
        // Keep horizontal routing aligned to the visible key centers; a fixed
        // horizontal bias makes adjacent pairs like i/o and n/m feel random.
        // The vertical correction keeps low fingertip contact inside the
        // intended character row without stealing bottom controls.
        static let characterIntentXCorrection: CGFloat = 0
        static let characterIntentYCorrection: CGFloat = 7
        // Guard strips keep near-row misses useful without letting candidate or
        // bottom controls become accidental character keys.
        static let rowTopOverflow: CGFloat = 14
        static let rowBottomOverflow: CGFloat = 13
        // True inter-key gaps can be reassigned as a whole by touch learning.
        // This radius is only the extra visible-key edge band where we allow
        // probabilistic correction without stealing each key's center anchor.
        static let gutterRadius: CGFloat = 6
    }

    private struct TextKeyboardLayoutModel {
        static let keyHorizontalGap: CGFloat = 6
        static let keyVerticalGap: CGFloat = 11
        static let utilityKeyWidthMultiplier: CGFloat = 1.22
        static let utilityLetterGap: CGFloat = 44.0 / 3.0
        static let bottomModeKeyWidth: CGFloat = 50
        static let bottomGlobeKeyWidth: CGFloat = 50
        static let bottomLanguageKeyWidth: CGFloat = 52
        static let bottomReturnKeyWidth: CGFloat = 92
        static let keyIconPointSize: CGFloat = 15
        static let letterTitleFontSize: CGFloat = 25
        static let uppercaseLetterTitleFontSize: CGFloat = 22
        static let numericDigitTitleFontSize: CGFloat = 26
        static let numericSecondaryTitleFontSize: CGFloat = 8.5
        static let compactUtilityTitleFontSize: CGFloat = 18
        static let utilityActionTitleFontSize: CGFloat = 17
        static var utilityLetterSpacerWidth: CGFloat {
            max(0, utilityLetterGap - keyHorizontalGap * 2)
        }
    }

    @MainActor
    private final class KeyboardHaptics {
        private static let textKeyCooldown: CFTimeInterval = 0.035

        /// Mirrors the host's Keyboard Settings → Feedback toggles. Sound
        /// additionally follows the system keyboard-click setting because it
        /// goes through UIDevice.playInputClick().
        var clickSoundsEnabled = true
        var hapticsEnabled = true

        // .rigid, not .light: light is a low-sharpness, slow-decay thump that
        // reads as soft and laggy under fast typing. Rigid is the short,
        // high-sharpness tick that matches the native keyboard's key click.
        private let textKeyImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
        private let controlImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
        private let selectionGenerator = UISelectionFeedbackGenerator()
        private var lastTextKeyFeedbackAt: CFTimeInterval = 0

        func prepareForKeyboardReady() {
            textKeyImpactGenerator.prepare()
            controlImpactGenerator.prepare()
            selectionGenerator.prepare()
        }

        func prepareForTextInput() {
            textKeyImpactGenerator.prepare()
        }

        func playTextKeyPress() {
            if clickSoundsEnabled {
                UIDevice.current.playInputClick()
            }
            guard hapticsEnabled else { return }
            let now = CACurrentMediaTime()
            guard now - lastTextKeyFeedbackAt > Self.textKeyCooldown else { return }
            lastTextKeyFeedbackAt = now
            textKeyImpactGenerator.impactOccurred(intensity: 1.0)
            textKeyImpactGenerator.prepare()
        }

        func playControlTap() {
            guard hapticsEnabled else { return }
            controlImpactGenerator.impactOccurred(intensity: 0.8)
            controlImpactGenerator.prepare()
            textKeyImpactGenerator.prepare()
        }

        func playSelectionChanged() {
            guard hapticsEnabled else { return }
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
            textKeyImpactGenerator.prepare()
        }
    }

    private enum TextInputLanguage: String {
        case chinese
        case english

        var title: String {
            switch self {
            case .chinese: return "中"
            case .english: return "英"
            }
        }
    }

    private struct LetterCasingSnapshot: Equatable {
        let shift: Bool
        let autoCap: Bool
        let language: TextInputLanguage
    }

    private enum TextRewriteTarget {
        case selection(text: String, contextBefore: String, contextAfter: String)
        case context(before: String, after: String)

        var text: String {
            switch self {
            case .selection(let text, _, _):
                return text
            case .context(let before, let after):
                return before + after
            }
        }

        var refineUndoScope: RefineUndoScope {
            switch self {
            case .selection:
                return .selection
            case .context:
                return .context
            }
        }

        var diagnosticFields: [String: String] {
            switch self {
            case .selection(let text, let contextBefore, let contextAfter):
                return [
                    "scope": "selection",
                    "target_chars": "\(text.count)",
                    "before_chars": "\(contextBefore.count)",
                    "after_chars": "\(contextAfter.count)",
                ]
            case .context(let before, let after):
                return [
                    "scope": "context",
                    "target_chars": "\(before.count + after.count)",
                    "before_chars": "\(before.count)",
                    "after_chars": "\(after.count)",
                ]
            }
        }
    }

    private struct PendingRecordingTextTarget {
        let commandID: String
        let target: TextRewriteTarget
    }

    private struct PendingDictationInsertionAnchor {
        let commandID: String
        let contextBefore: String
        let contextAfter: String
    }

    private struct LivePartialPreviewState {
        let commandID: String
        var text: String
        var contextBefore: String
        var contextAfter: String
        let textInputIdentity: ObjectIdentifier?
        var consumedByUser: Bool
        var ownershipInvalidated: Bool
    }

    private struct LivePartialPreviewAnchor {
        let contextBefore: String
        let contextAfter: String
    }

    private struct RimeInputTarget {
        let textInputIdentity: ObjectIdentifier?
        let contextBefore: String?
        let contextAfter: String?
    }

    private enum LivePartialFinalCommitPlan {
        case consumed
        case ownedMarked
        case missingAnchor

        var logName: String {
            switch self {
            case .consumed:
                return "consumed"
            case .ownedMarked:
                return "owned_marked"
            case .missingAnchor:
                return "missing_anchor"
            }
        }
    }

    private enum RefineUndoScope: String, Codable {
        case selection
        case context
    }

    private struct RefineUndoTarget: Codable {
        let scope: RefineUndoScope
        let text: String
        let contextBefore: String
        let contextAfter: String
    }

    private struct RefineUndoState: Codable {
        let restoredText: String
        let current: RefineUndoTarget
        let updatedAt: TimeInterval
    }

    private enum MarkedTextOwner {
        case rimeComposition
        case livePartial

        var logName: String {
            switch self {
            case .rimeComposition:
                return "rime_composition"
            case .livePartial:
                return "live_partial"
            }
        }
    }

    private enum MarkedTextCommitReason: String {
        case rimeCommit = "rime_commit"
        case rimeRaw = "rime_raw"
        case bridgeResult = "bridge_result"
        case generic
    }

    private enum MarkedTextCommitPlan {
        case plainInsert
        case ownedMarked(MarkedTextOwner)
        case staleMarkedState

        var logName: String {
            switch self {
            case .plainInsert:
                return "plain_insert"
            case .ownedMarked(let owner):
                return "owned_\(owner.logName)"
            case .staleMarkedState:
                return "stale_marked_state"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let localClient = KeyboardLocalClient()
    private let inputModeKey = "keyboard.inputMode"
    private let keyboardFocusKey = "keyboard.focus"
    private let textInputLanguageKey = "keyboard.textInputLanguage"
    private let hostDefaultTextInputLanguageKey = "keyboard.hostDefaultTextInputLanguage"
    private let hostChineseInputEnabledKey = "keyboard.hostChineseInputEnabled"
    private let rimeLearningResetGenerationKey = "keyboard.rimeLearningResetGeneration"
    private let touchLearningResetGenerationKey = "keyboard.touchLearningResetGeneration"
    private let rimeUserPhrasesRevisionKey = "keyboard.rimeUserPhrasesRevision"
    private let lastInsertedCommandIDKey = "keyboard.lastInsertedCommandID"
    private let refineUndoStateKey = "keyboard.refineUndoState.v2"
    private let textTouchLearningStatsKey = "keyboard.textTouchGaussianStats.v1"
    private let keyboardTouchTraceEnabledKey = "keyboard.touchTraceEnabled"
    private let keyPressOverlayTag = 0x74797065
    private let hostLinkOpener = KeyboardHostLinkOpener()

    private var correctionMode: CorrectionMode = .polishPlus
    private var pendingDefaultCorrectionMode: CorrectionMode?
    private var inputMode: VoiceInputMode = .tap
    private var keyboardFocus: KeyboardFocus = .voice
    private var textInputLanguage: TextInputLanguage = .chinese
    private var rimeProfile = RimeKeyboardProfile()
    private var rimeUserPhrasesRevision = ""
    private var isSymbolKeyboard = false
    private var isAlternateSymbolKeyboard = false
    private var isPhoneSymbolKeyboard = false
    private var showsStandardLayoutForNumericTraits = false
    private var renderedTextKeyboardLayoutKind: TextKeyboardLayoutKind?
    private var isAutoCapitalizationEnabled = true
    private var isCharacterPreviewEnabled = false
    private var isChineseInputEnabled = true
    private var isTouchLearningEnabled = true
    private var chinesePunctuationStyle: KeyboardChinesePunctuationStyle = .chinese
    private let rimeInput = RimeInputController()
    private lazy var textTouchLearner = TextKeyTouchLearner(
        defaults: defaults,
        storageKey: textTouchLearningStatsKey
    )
    private let chineseLearningRecorder = ChineseLearningRecorder()
    private var pendingRimeCharacters: [String] = []
    private var pendingRimeDirectTextKeys: [String] = []
    private var rimeInputTarget: RimeInputTarget?
    private var currentTextInputIdentity: ObjectIdentifier?
    private var isDiscardingStaleRimeInput = false
    private var activeMarkedText = ""
    private var activeMarkedTextOwner: MarkedTextOwner?
    private var heightConstraint: NSLayoutConstraint?
    /// While entering Typeforme from the system globe menu, UIKit may retarget
    /// the original selection touch to our globe key. Suppress that activation
    /// touch sequence, but let a fresh touch that starts after activation switch
    /// keyboards immediately.
    private var isSuppressingCarryoverInputModeTouch = true
    private var didSuppressInitialInputModeSwitchEvent = false
    private var keyboardActivationStartedAt: CFTimeInterval = 0
    private var suppressedInputModeTouches: Set<ObjectIdentifier> = []
    private static let inputModeCarryoverBeganGrace: CFTimeInterval = 0.12
    private static let inputModeCarryoverNoTouchGrace: CFTimeInterval = 0.25
    private var pendingTextKeyboardTraitRefresh: DispatchWorkItem?
    /// Last time a routed character key committed (on touch-down). A shift
    /// toggle (touch-up) arriving within `adjacentKeyGuardWindow` is treated as
    /// a stray second contact from the same fat press on the a↔shift seam and
    /// ignored, so "a + shift" can't both fire from one press.
    private var lastTextKeyCommitAt: CFTimeInterval = 0
    private static let adjacentKeyGuardWindow: CFTimeInterval = 0.12
    private var lastPresentationGateLogKey = ""
    private var orbContainerHeightConstraint: NSLayoutConstraint?
    private var textKeyboardContainerHeightConstraint: NSLayoutConstraint?
    private var lastStatusSignature = ""
    private var lastMissingAudioLevelLogAt: TimeInterval = 0
    private var isApplyingHostBridgeStatus = false
    private var lastReportedKeyboardIssueSignature = ""
    private var bridgeStatus: KeyboardBridgeStatus? {
        didSet {
            // Local/Darwin-only statuses do not know Mac route reachability.
            // Keep the last host-probed value until a host status explicitly
            // updates it, so the readiness dot does not flicker green between
            // failed-route status frames.
            guard let status = bridgeStatus else { return }
            if status.state != .idle,
               status.backendReachable == nil,
               let reachable = oldValue?.backendReachable {
                bridgeStatus = status.withBackendReachable(reachable)
                return
            }
            reportKeyboardIssueToHostIfNeeded(status)
        }
    }
    private var lastBridgeContactAt: TimeInterval = 0
    private var insertedFlashUntil: TimeInterval = 0
    private var insertedFlashClearTask: DispatchWorkItem?
    private static let insertedFlashDuration: TimeInterval = 1.2
    private var textToolbarStatusText: String?
    private var textToolbarStatusColor: UIColor = .secondaryLabel
    private var textToolbarStatusClearTask: DispatchWorkItem?
    private static let textToolbarStatusDuration: TimeInterval = 1.2
    private var transientKeyboardErrorClearWorkItem: DispatchWorkItem?
    private var transientKeyboardErrorGeneration: UInt64 = 0
    private var transientKeyboardErrorPriorStatus: KeyboardBridgeStatus?
    private var transientKeyboardErrorPriorLastBridgeContactAt: TimeInterval = 0
    private var transientKeyboardErrorWasBridgeAwake = false
    private var transientKeyboardErrorPriorBackendReachable: Bool?
    private var transientKeyboardErrorMessage: String?
    private static let transientKeyboardErrorDuration: TimeInterval = 2.0
    /// Set whenever the host posts a Darwin signal that proves the bridge is
    /// alive (sessionStarted, dictationStarted, dictationStopped). Cleared by
    /// `sessionEnded`, by a confirmed `.start` failure, or when a fresh
    /// session-status challenge gets no host echo. This is independent of
    /// `lastBridgeContactAt`, so a mic press right after a finished dictation
    /// skips the slow probe while still letting a killed host go gray.
    private var lastDarwinAwakeAt: TimeInterval = 0
    private var sessionStatusChallengeGeneration: UInt = 0
    private var openingHostUntil: TimeInterval = 0
    private var appliedKeyboardInterfaceStyle: UIUserInterfaceStyle?
    private var lastCorrectionModeButtonSignature = ""
    private var lastTextRecordingButtonsSignature = ""
    private var hasPresentedInitialFrame = false
    private var isVoicePressActive = false
    private var voiceDragOutCancelArmed = false
    private var voiceUndoShowsCancel = false
    private var textUndoShowsCancel = false
    private var keyboardRecordingStartedAt: TimeInterval = 0
    private var recordingElapsedTimer: Timer?
    /// Hold-mode "release-to-cancel" zone: set when the user drags the
    /// finger off the orb mid-press, cleared if they drag back in. Lift
    /// while true => cancel; lift while false => commit.
    private var voicePressBeganAt: TimeInterval = 0
    private var isStartRequestInFlight = false
    private var shouldStopWhenStartCompletes = false
    private var shouldCancelWhenStartCompletes = false
    private var pendingStartCommandID: String?
    private var pendingDarwinStartAckCommandID: String?
    private var confirmedRecordingCommandID: String?
    private var trackedStartCommandIDs: [String: TimeInterval] = [:]
    private var tapRecordingActive = false
    private var isCommandPressActive = false
    private var activeRecordingCommandID: String?
    private var activeRecordingTextTarget: PendingRecordingTextTarget?
    private var activeRecordingTextEditIntent: TextEditIntent?
    private var activeDictationInsertionAnchor: PendingDictationInsertionAnchor?
    private var livePartialPreviewState: LivePartialPreviewState?
    private var suppressedRefineResultCommandIDs: [String: TimeInterval] = [:]
    private var pendingStopCommandID: String?
    private var pendingCancelCommandID: String?
    private var recentSelectionTarget: TextRewriteTarget?
    private var recentSelectionCapturedAt: TimeInterval = 0
    private var refineUndoState: RefineUndoState?
    private var styleRewriteCommandID: String?
    private var isTextSpaceCursorTracking = false
    private var textSpaceCursorStartX: CGFloat = 0
    private var suppressTextSpaceTapUntil: TimeInterval = 0
    private var scheduledHostOpenTask: Task<Void, Never>?
    private var scheduledStopTask: Task<Void, Never>?
    private var hostWakeResetTask: Task<Void, Never>?
    private var deleteRepeatTask: Task<Void, Never>?
    private var startConfirmationTask: Task<Void, Never>?
    private var darwinStartAckTask: Task<Void, Never>?
    private var statusStreamGeneration: UInt64 = 0
    private var statusStreamBridgeToken: String?
    private var lastStatusStreamFrameAt: TimeInterval = 0
    private var statusStreamStopTask: Task<Void, Never>?
    private var activeStatusReconcileTask: Task<Void, Never>?
    private var lastSlowUpdateUILogAt: TimeInterval = 0
    private var lastStatusStreamFailureLogAt: TimeInterval = 0
    private var lastActiveStatusReconcileLogAt: TimeInterval = 0
    private var bridgeCommandTasks: [String: Task<Void, Never>] = [:]
    private var hostOpenAttemptedStartCommandIDs: Set<String> = []
    private var processedCommandReceiptIDs: [String: TimeInterval] = [:]
    private var styleRewriteTask: Task<Void, Never>?
    private var styleConfigureTask: Task<Void, Never>?
    private var pendingTextTouchSample: TextKeyTouchSample?
    private var pendingTextTouchCorrection: PendingTextTouchCorrection?
    private var deferredStartupWorkItem: DispatchWorkItem?
    private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    /// Hold-to-talk cancel: dragging OUT past the control's frame expanded
    /// by the arm inset shows "Release to Cancel"; dragging back inside the
    /// smaller expansion disarms. Hysteresis keeps the boundary calm.
    private static let voiceDragOutCancelArmInset: CGFloat = 36
    private static let voiceDragOutCancelDisarmInset: CGFloat = 16
    private let minimumHoldRecordingDuration: TimeInterval = 0.55
    /// Hold-mode releases shorter than this are treated as accidental brushes
    /// and cancel the in-flight start. iOS system mic accepts very short taps,
    /// so this should be just long enough to reject finger-brushes (~100ms)
    /// rather than reject deliberate quick taps.
    private let minimumIntentReleaseDuration: TimeInterval = 0.10
    private let selectionSnapshotTTL: TimeInterval = 1.25
    private let refineUndoStateTTL: TimeInterval = 10 * 60
    private static let suppressedRefineResultTTL: TimeInterval = 10 * 60
    private static let dictationContextLimit = 600
    private static let textRewriteContextExpansionLimit = 2_000
    private static let textRewriteContextExpansionMaxSteps = 40
    private static let textTouchCorrectionWindow: TimeInterval = 2.25
    private static let textTouchPositiveTTL: TimeInterval = 12
    private static let sharedStatusSnapshotMaxAge: TimeInterval = 30
    private static let sharedActiveStatusSnapshotMaxAge: TimeInterval = 3
    private static let sharedStandbyLivenessSnapshotMaxAge: TimeInterval = 8
    private static let sharedStandbyPresentationSnapshotMaxAge: TimeInterval = 20 * 60
    private static let statusStreamFreshnessAfterDarwinStart: TimeInterval = 1.0
    private static let activeStatusStreamStaleAge: TimeInterval = 4.5
    private static let activeBridgeStatusReconcileInterval: TimeInterval = 2.5
    private static let startProbeHelloTimeout: TimeInterval = 0.45
    private static let startProbeStatusTimeout: TimeInterval = 0.45
    private static let startConfirmationTimeout: TimeInterval = 5.00
    private static let darwinStartAckTimeout: TimeInterval = 0.45
    private static let startHandshakeCommandTTL: TimeInterval = 12
    private static let processedCommandReceiptTTL: TimeInterval = 30
    private static let textSpaceCursorPointsPerCharacter: CGFloat = 9
    private static let containingAppBundleIdentifier = TypeformeBundleConfiguration.hostBundleIdentifier
    private let deleteRepeatInitialDelay: UInt64 = 450_000_000
    private let deleteRepeatInterval: UInt64 = 70_000_000

    private let rootStack = UIStackView()
    private let keyboardSurfaceView = KeyboardSurfaceView()
    private let keyboardSurfaceMaskLayer = CAShapeLayer()
    private let keyboardContentView = UIView()
    private let keyboardTouchOverlay = KeyboardTouchOverlayView()
    private let topRow = UIView()
    private let statusGroup = UIStackView()
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    private let settingsButton = UIButton(type: .system)
    private let keyboardFocusButton = UIButton(type: .system)
    /// Compact trigger that lives left of the orb. Shows the currently-active
    /// preset + a chevron; tapping it expands `correctionPopover` over the
    /// orb area with all 5 presets as ≥44pt hit targets. Replaces the old
    /// 5-stacked-vertically panel whose buttons were ~24pt and violated HIG.
    private let correctionModePanel = UIView()
    private let correctionModeTrigger = UIButton(type: .system)
    /// Floating popover anchored over the orb. Hidden by default.
    private let correctionPopover = UIView()
    private let correctionPopoverStack = UIStackView()
    /// Transparent backdrop sitting between the keyboard chrome and the
    /// popover — tap-to-dismiss. Sized to fill `view` so any tap outside
    /// the popover closes it.
    private let correctionPopoverDismissOverlay = UIControl()
    private var correctionModeButtons: [(preset: CorrectionMode, button: UIButton)] = []
    private var isCorrectionPopoverVisible = false

    /// Circular orb (`voiceButton`) sits centered in `orbContainer`. Pulse
    /// rings are rendered as direct sublayers kept behind the orb in z-order.
    private let orbContainer = UIView()
    private let voiceButton = VoiceOrbButton(type: .custom)
    private let voiceGradient = CAGradientLayer()
    private let voiceHighlight = CAGradientLayer()
    private var pulseRings: [CAShapeLayer] = []
    private let voiceIconView = UIImageView()
    private let voicePrint = VoicePrintView()
    /// Hold mode hides the in-orb voiceprint behind the user's finger, so we
    /// surface a second strip in the topRow while hold-recording. Tap mode
    /// keeps the original in-orb voiceprint since the orb stays visible.
    private let topRowVoicePrint = VoicePrintView()
    /// Overlay shown on the text-keyboard toolbar during recording. Replaces
    /// the toolbar icons visually so the user only sees the live waveform.
    private let textToolbarVoicePrint = VoicePrintView()
    /// Unified text-keyboard status overlay. Candidate strip stays dedicated to
    /// Rime candidates; operation status (opening, sending, undo, result/error)
    /// is rendered here.
    private let textToolbarStatusLabel = UILabel()
    /// Elapsed readout beside the text-toolbar voiceprint while recording.
    private let textToolbarElapsedLabel = UILabel()
    /// Smoothed audioLevel driving pulse-ring brightness — louder voice =
    /// brighter rings, visible at the orb's edges even when a finger covers
    /// the rest of the orb.
    private var smoothedAudioLevel: Float = 0
    private let voiceSpinner = UIActivityIndicatorView(style: .large)
    private let voiceTitleLabel = UILabel()
    private let inputModeSwitch = VoiceInputModeSwitch()
    /// Driving-safe "send" button on the voice keyboard's left column,
    /// above the Refine trigger. Tapping inserts "\n" via the host text
    /// document proxy — in chat apps (iMessage / WhatsApp / WeChat) that
    /// triggers the send action. Bigger and more obvious than the host
    /// app's own send button so it's easier to hit one-handed.
    private let voiceSendButton = HitInsetButton(frame: .zero)
    private static let orbDiameter: CGFloat = 132
    /// Smaller variant for the 32pt text-toolbar mic button.
    private static let textToolsReadyDotDiameter: CGFloat = 8
    // +9 vs the original 258/244 to fund the taller candidate strip; the orb
    // container and key-row heights both derive as remainders and stay equal.
    private static let portraitKeyboardContentHeight: CGFloat = 267
    private static let compactKeyboardContentHeight: CGFloat = 253
    private static let rootHorizontalInset: CGFloat = 20.0 / 3.0
    private static let rootVerticalInset: CGFloat = 4
    private static let stackSpacing: CGFloat = 4
    /// 0.01-alpha is required: iOS custom-keyboard extensions probe pixel
    /// alpha for hit-test eligibility, so `.clear` lets gap touches leak to
    /// the host app even when `point(inside:)` returns true.
    private static let keyboardTouchableBackgroundColor = UIColor.white.withAlphaComponent(0.01)
    private static let candidateExpandButtonWidth: CGFloat = 45
    private static let candidateChevronSymbolPointSize: CGFloat = 21
    private static let candidateExpandActionHeight: CGFloat = 58
    /// 34pt (was 25): 20pt candidate text on a 25pt-tall strip was the single
    /// most-missed target on the keyboard. The extra 9pt comes out of total
    /// keyboard height (content height +9), so key rows are unchanged.
    private static let candidateToolbarHeight: CGFloat = 34
    /// Vertical touch overflow for the inline candidate strip. Combined with
    /// the composing-time hand-off in `textCharacterTouchBandFrame`, the
    /// effective candidate target is ~48pt tall while candidates are showing.
    private static let candidateStripTouchOverflowY: CGFloat = 8
    private static let toolbarIconVerticalOffset: CGFloat = -2
    private static let textKeyboardTopProtectionInset: CGFloat = 2
    private static let textKeyboardToolbarKeyGap: CGFloat = 10
    /// Text mode has a 2pt protection inset above its toolbar; voice mode needs
    /// the same content offset so the two top bars share the same visual center.
    private static let voiceTopRowContentVerticalOffset: CGFloat = 2
    /// Matches the idle toolbar clearance in `textCharacterTouchBandFrame`, so
    /// the text toolbar surface overlaps the key-band surface instead of leaving
    /// a visible unmasked seam.
    private static let textToolbarIdleBottomSurfaceExpansion: CGFloat = 2
    private static let candidateInlineMinimumCellWidth: CGFloat = 41
    private static let candidateInlineCellHorizontalPadding: CGFloat = 20
    /// Inline candidate strip renders in windows of this many cells. Rime can
    /// return up to 60 candidates per keystroke but only ~6-8 are visible;
    /// one chunk covers roughly two screen widths so a normal scroll never
    /// reaches unrendered area, and the rest materialize on demand.
    private static let candidateInlineRenderChunkCount = 14
    private static let candidateTextFontSize: CGFloat = 20
    /// The native Chinese expanded candidate panel uses compact 45pt rows and
    /// length-aware cells: short candidates fill six even columns, while long
    /// candidates reduce the row count and get wider cells.
    private static let candidateGridRowHeight: CGFloat = 45
    private static let candidateGridPreferredCellWidth: CGFloat = 66
    private static let candidateGridMaximumColumnCount = 6
    private static let candidateGridColumnSpanTolerance: CGFloat = 4
    private static let candidateGridMinimumCellWidth: CGFloat = 59
    private static let candidateGridTwoCharacterMinimumCellWidth: CGFloat = 64
    /// Tightened (was 6 / 24) once the strip itself grew to 34pt: the chevron
    /// keeps a ≥44pt effective target (34 + 2×8) without annexing the trailing
    /// edge of the right-most visible candidate or the toolbar↔keys gap.
    private static let candidateActionColumnGap: CGFloat = 2
    private static let candidateExpandTouchOverflowY: CGFloat = 8
    /// Per-cell horizontal padding already creates the visible gap between
    /// adjacent candidates; the stack spacing stays at 0 so the total gap
    /// stays close to iOS native (~18–20pt between candidate centers).
    private static let topCandidateSpacing: CGFloat = 0
    private static let topRowHeight: CGFloat = candidateToolbarHeight
    private static let utilityRowHeight: CGFloat = 48
    private static func orbContainerHeight(for contentHeight: CGFloat) -> CGFloat {
        max(1, contentHeight
            - rootVerticalInset * 2
            - stackSpacing * 2
            - topRowHeight
            - utilityRowHeight)
    }
    private static func textKeyboardBodyHeight(for contentHeight: CGFloat) -> CGFloat {
        max(1, contentHeight - rootVerticalInset * 2)
    }
    private static let topChromeCoverHeight: CGFloat = 0

    private let utilityRow = UIStackView()
    private let commandButton = UIButton(type: .system)
    private let voiceUndoButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    private let textKeyboardContainer = UIStackView()
    private let textToolbar = UIStackView()
    private let textWandButton = UIButton(type: .system)
    private let textStylePickerButton = UIButton(type: .system)
    private let textUndoButton = UIButton(type: .system)
    private let textToolsButton = UIButton(type: .system)
    /// Text-mode toolbar mic readiness signal; voice mode uses the top-left
    /// status dot instead of adding chrome to the orb.
    private let textToolsReadyDot = UIView()
    private let textKeyboardSwitchButton = UIButton(type: .system)
    private let textHostSettingsButton = UIButton(type: .system)
    private let textCandidateGridButton = HitInsetButton(frame: .zero)
    private let candidateGridCollapseButton = HitInsetButton(frame: .zero)
    private let textModeButton = UIButton(type: .system)
    private let textAlternateSymbolButton = UIButton(type: .system)
    private let textGlobeButton = UIButton(type: .system)
    private let textLanguageButton = UIButton(type: .system)
    private let textLanguageLabel = UILabel()
    private let candidateScrollView = UIScrollView()
    private let candidateStack = UIStackView()
    /// Persistent flexible trailing spacer at the end of `candidateStack`.
    /// Cells are pinned at required hugging priority (exact widths), so the
    /// stack's `.fill` distribution has nothing to stretch when total cell
    /// width is narrower than the scroll view. Without this spacer, Auto
    /// Layout's only option is to break a cell's width constraint and grow
    /// it — producing the "2-column" visual where one cell takes the whole
    /// remaining row. The spacer (low hugging) absorbs the gap so cells
    /// stay at exact widths.
    private let candidateTrailingSpacer = UIView()
    private let keyRowsStack = UIStackView()
    private let candidateGridScrollView = UIScrollView()
    private let candidateGridStack = UIStackView()
    private let candidateTextOverlay = UIView()
    private var reusableCandidateTextOverlayLabels: [UILabel] = []
    private let keyPreviewBubble = UIView()
    private let keyPreviewLabel = UILabel()
    private lazy var textTrackpadPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTextTrackpadPan(_:)))
    private lazy var candidateScrollTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleCandidateScrollTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
    /// Hold a candidate to magnify it (20pt cells truncate long candidates),
    /// slide to re-target, release to commit. Default non-simultaneous policy
    /// makes the tap recognizer fail once this begins, so no double-commit;
    /// cancelsTouchesInView (default true) freezes the strip's pan while
    /// previewing.
    private lazy var candidateLongPressRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleCandidateLongPress(_:)))
        recognizer.minimumPressDuration = 0.3
        recognizer.delegate = self
        return recognizer
    }()
    private weak var candidatePreviewTarget: UIButton?
    private lazy var candidateGridTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleCandidateGridTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
    private var textKeyboardButtons: [UIButton] = []
    private var textKeyboardHitRows: [TextKeyboardHitRow] = []
    private var letterButtonMap: [String: UIButton] = [:]
    private var textKeyCommitCharacters: [ObjectIdentifier: String] = [:]
    private var reusableCandidateButtons: [UIButton] = []
    private var candidateButtonWidthConstraints: [NSLayoutConstraint] = []
    /// Source list + rendered prefix length for the windowed inline strip.
    /// Cleared by `resetCandidateStackForReuse` so non-candidate content
    /// (status labels, notices) can never trigger a deferred append.
    private var pendingInlineCandidates: [RimeKeyboardCandidate] = []
    private var renderedInlineCandidateCount = 0
    private var reusableCandidateSeparators: [UIView] = []
    private var reusableCandidateStatusLabels: [UILabel] = []
    private var candidateStatusLabelWidthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var isCandidateGridExpanded = false
    private var activeCandidateSeparatorIndex = 0
    private var activeCandidateStatusLabelIndex = 0
    private var keyboardRowConstraints: [NSLayoutConstraint] = []
    private weak var textReturnKeyButton: UIButton?
    private weak var textShiftButton: UIButton?
    private weak var textSpaceKeyButton: UIButton?
    private var lastReturnKeyTitle = ""
    private var lastReturnKeyImageName: String?
    private var lastLetterCasingSnapshot: LetterCasingSnapshot?
    private var isTextShiftEnabled = false
    private var isTextShiftLocked = false
    private var isTextAutoCapitalizationSuppressed = false
    private var lastShiftTapTime: TimeInterval = 0
    private var doubleQuoteOpen = true
    private var singleQuoteOpen = true
    private weak var activeTrackpadSourceView: UIView?
    private var textTrackpadLastStepX = 0
    private let keyboardHaptics = KeyboardHaptics()
    private var keyboardFocusSwipeHandledUntil: CFTimeInterval = 0
    private var suppressTextKeyCommitUntil: CFTimeInterval = 0
    private var pendingKeyboardFocusAnimationIntent: CGFloat?
    private var isShowingTextRecordingStatus = false
    private var lastTouchSurfaceLayoutLogKey = ""
    private var lastKeyboardPresentationLayoutLogKey = ""
    private var keyboardPresentationLayoutLogCount = 0
    private var keyboardLifecycleStartedAt = CACurrentMediaTime()
    private var keyboardStartupSnapshotCount = 0
    private var didLogReadyKeyboardSnapshot = false
    private let activePressedControls = NSHashTable<UIControl>.weakObjects()
    private var pressCleanupWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]

    private struct TextKeyboardHitRow {
        weak var row: UIStackView?
        let routedButtons: [UIButton]
        let directButtons: [UIButton]
        let boundaryButtons: [UIButton]
        let kind: TextKeyboardHitRowKind
    }

    private struct TextKeyboardHitRegion {
        let row: UIStackView
        let frame: CGRect
        let buttons: [UIButton]
        let boundaryButtons: [UIButton]
        let kind: TextKeyboardHitRowKind
    }

    private enum TextKeyboardHitRowKind {
        case character
        case bottom
    }

    private struct TextKeyboardHitButton {
        let button: UIButton
        let frame: CGRect
    }

    private enum TextKeyboardLayoutKind: Equatable {
        case standard
        case numeric(decimalSeparator: String?, phoneSymbols: Bool)
    }

    private struct TextKeyTouchSample {
        let character: String
        let buttonFrame: CGRect
        let touchPoint: CGPoint
        let committedAt: TimeInterval
    }

    private struct PendingTextTouchCorrection {
        let sample: TextKeyTouchSample
        let startedAt: TimeInterval
    }

    private struct TextTouchGutterProximity {
        let isNear: Bool
        let distance: CGFloat
        let threshold: CGFloat
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        configureSystemKeyboardAffordances()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSystemKeyboardAffordances()
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        [.left, .right]
    }

    override func loadView() {
        keyboardLifecycleStartedAt = CACurrentMediaTime()
        let initialHeight = currentKeyboardContentHeight + Self.topChromeCoverHeight
        beginInputModeCarryoverSuppression()
        let rootView = ClickFeedbackInputView(
            frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: initialHeight),
            // `.keyboard` is required for full-keyboard replacements. `.default`
            // is for accessory views laid on top of the system keyboard; using
            // it for a full keyboard caused iOS to allocate extra accessory
            // height and unstable presentation.
            inputViewStyle: .keyboard
        )
        rootView.allowsSelfSizing = false
        rootView.isOpaque = false
        rootView.backgroundColor = .clear
        rootView.clipsToBounds = false
        rootView.layer.masksToBounds = false
        let initialHeightConstraint = rootView.heightAnchor.constraint(equalToConstant: initialHeight)
        // 999 (not .required): system inputView transition constraints win the
        // first-frame race at .required, briefly clipping the toolbar top.
        initialHeightConstraint.priority = UILayoutPriority(999)
        initialHeightConstraint.isActive = true
        heightConstraint = initialHeightConstraint
        inputView = rootView
        view = rootView
        logKeyboardStartupSnapshot("loadView", force: true)
        logKeyboardPresentationLayout("loadView", force: true)
    }

    private func keyboardFocusSwipeSurfacePoint(_ point: CGPoint) -> Bool {
        expandedFrame(of: rootStack, dx: 10, dy: 10).contains(point)
    }

    fileprivate func keyboardOverlayTouchTarget(at point: CGPoint) -> KeyboardTouchTarget? {
        guard let target = keyboardTouchTarget(at: point) else { return nil }
        switch target {
        case .textKey, .focusSurface:
            return target
        case .candidateAction:
            return shouldKeyboardOverlayHandleCandidateAction(at: point) ? target : nil
        }
    }

    fileprivate func keyboardTouchTarget(at point: CGPoint) -> KeyboardTouchTarget? {
        guard !rootStack.isHidden,
              rootStack.alpha > 0.01,
              view.bounds.insetBy(dx: -16, dy: -10).contains(point),
              !isCorrectionPopoverVisible
        else { return nil }

        if isTextToolbarDirectControlPoint(point) {
            return nil
        }
        if candidateActionColumnFrame().contains(point) {
            return .candidateAction(isCandidateGridExpanded ? candidateGridCollapseButton : textCandidateGridButton)
        }

        if keyboardFocus == .text {
            if isTextKeyboardDirectControlPoint(point) {
                return nil
            }
            if shouldTextKeyTouchSurfaceHandle(point: point) {
                if let button = nearestTextKeySurfaceTarget(at: point) {
                    return .textKey(button)
                }
                return .focusSurface
            }
            if isCandidateScrollableSurfacePoint(point) || isCandidateGridExpanded {
                return nil
            }
        }

        let textBottomControls: [UIControl?] = [
            textModeButton,
            textGlobeButton,
            textLanguageButton,
            textSpaceKeyButton,
            textReturnKeyButton,
        ]
        if textBottomControls.compactMap(\.self).contains(where: { expandedFrame(of: $0, dx: 6, dy: 6).contains(point) }) {
            return nil
        }

        let controls: [UIControl] = [
            settingsButton,
            keyboardFocusButton,
            correctionModeTrigger,
            correctionPopoverDismissOverlay,
            voiceButton,
            inputModeSwitch,
            voiceSendButton,
            commandButton,
            voiceUndoButton,
            spaceButton,
            deleteButton,
            returnButton,
            textCandidateGridButton,
            candidateGridCollapseButton,
            textModeButton,
            textGlobeButton,
            textWandButton,
            textStylePickerButton,
            textUndoButton,
            textToolsButton,
            textKeyboardSwitchButton,
            textHostSettingsButton,
        ]
        if controls.contains(where: { expandedFrame(of: $0, dx: 6, dy: 6).contains(point) }) {
            return nil
        }
        return keyboardFocusSwipeSurfacePoint(point) && !isCandidateScrollableSurfacePoint(point) ? .focusSurface : nil
    }

    fileprivate func keyboardTouchTargetLogName(_ target: KeyboardTouchTarget?) -> String {
        guard let target else { return "none" }
        switch target {
        case .textKey:
            return "textKey"
        case .candidateAction:
            return "candidateAction"
        case .focusSurface:
            return "focusSurface"
        }
    }

    fileprivate func keyboardTouchTargetLogKey(_ target: KeyboardTouchTarget?) -> String {
        guard case .textKey(let button) = target,
              let character = textKeyCommitCharacters[ObjectIdentifier(button)]
        else { return "" }
        return character
    }

    fileprivate func logKeyboardTouchEvent(
        _ event: String,
        target: KeyboardTouchTarget?,
        point: CGPoint?,
        intent: CGFloat? = nil
    ) {
        guard defaults.bool(forKey: keyboardTouchTraceEnabledKey) else { return }
        let name = keyboardTouchTargetLogName(target)
        let key = keyboardTouchTargetLogKey(target)
        let x = point.map { Int($0.x.rounded()) } ?? -1
        let y = point.map { Int($0.y.rounded()) } ?? -1
        let dx = intent.map { Int($0.rounded()) } ?? 0
        kbLog.notice("touch \(event, privacy: .public) target=\(name, privacy: .public) key=\(key, privacy: .private) x=\(x, privacy: .public) y=\(y, privacy: .public) dx=\(dx, privacy: .public) focus=\(self.keyboardFocus.rawValue, privacy: .public)")
    }

    /// Begin a routed key touch. Character keys COMMIT here, on touch-down —
    /// native-keyboard parity. Committing on release added the whole finger
    /// dwell (~60–150ms) plus a multi-finger ordering hold-back to every
    /// keystroke, which read as candidate-strip lag. Returns true when a text
    /// key was committed (the release must not commit again).
    fileprivate func pressKeyboardTouchTarget(_ target: KeyboardTouchTarget, point: CGPoint) -> Bool {
        logKeyboardTouchEvent("press", target: target, point: point)
        switch target {
        case .textKey(let button):
            controlPressDown(button)
            let title = button.accessibilityValue ?? button.currentTitle ?? ""
            showKeyPreview(for: button, title: title)
            let didCommit = commitTextKey(button, point: point)
            if didCommit {
                lastTextKeyCommitAt = CACurrentMediaTime()
            }
            return didCommit
        case .candidateAction(let button):
            controlPressDown(button)
            return false
        case .focusSurface:
            return false
        }
    }

    fileprivate func releaseKeyboardTouchTarget(_ target: KeyboardTouchTarget, point: CGPoint) {
        logKeyboardTouchEvent("release", target: target, point: point)
        switch target {
        case .textKey(let button):
            resetPressedControlState(button)
        case .candidateAction(let button):
            resetPressedControlState(button)
            if candidateActionColumnFrame().contains(point) {
                button.sendActions(for: .touchUpInside)
            }
        case .focusSurface:
            break
        }
    }

    @discardableResult
    private func commitTextKey(_ button: UIButton, point: CGPoint) -> Bool {
        guard let character = textKeyCommitCharacters[ObjectIdentifier(button)] else { return false }
        let shouldReturnToAlphabetKeyboard = shouldReturnToAlphabetKeyboardAfterSymbolInput(character)
        let sample = textKeyTouchSample(
            button: button,
            character: character,
            touchPoint: textCharacterIntentPoint(from: point)
        )
        guard handleTextCharacter(character) else { return false }
        if let sample {
            registerCommittedTextTouch(sample)
        } else {
            finishNonLearnableTextTouch()
        }
        if shouldReturnToAlphabetKeyboard {
            returnToAlphabetKeyboardAfterSymbolInput()
        }
        return true
    }

    /// A horizontal focus swipe that started on a character key has already
    /// typed it (commit happens on touch-down); remove that character before
    /// switching surfaces.
    fileprivate func undoTextKeyCommitForFocusSwipe() {
        pendingTextTouchSample = nil
        if !pendingRimeDirectTextKeys.isEmpty {
            pendingRimeDirectTextKeys.removeLast()
            applyRimeState(rimeInput.state())
            return
        }
        if !pendingRimeCharacters.isEmpty {
            pendingRimeCharacters.removeLast()
            applyRimeState(rimeInput.state())
            return
        }
        if rimeInput.state().isComposing {
            applyRimeState(rimeInput.processKeyCode(0xFF08))
            return
        }
        textDocumentProxy.deleteBackward()
    }

    fileprivate func cancelKeyboardTouchTarget(_ target: KeyboardTouchTarget, point: CGPoint) {
        logKeyboardTouchEvent("cancel", target: target, point: point)
        switch target {
        case .textKey(let button):
            resetPressedControlState(button)
        case .candidateAction(let button):
            resetPressedControlState(button)
        case .focusSurface:
            break
        }
    }

    private func shouldKeyboardOverlayHandleCandidateAction(at point: CGPoint) -> Bool {
        guard keyboardFocus == .text,
              !isCandidateGridExpanded,
              !textCandidateGridButton.isHidden
        else { return false }

        let directButtonFrame = textCandidateGridButton
            .convert(textCandidateGridButton.bounds, to: view)
            .insetBy(dx: -Self.candidateActionColumnGap, dy: -Self.candidateExpandTouchOverflowY)
        return !directButtonFrame.contains(point)
    }

    private func isCandidateScrollableSurfacePoint(_ point: CGPoint) -> Bool {
        if expandedFrame(of: candidateGridScrollView, dx: 0, dy: 4).contains(point) {
            return true
        }
        guard expandedFrame(of: candidateScrollView, dx: 0, dy: Self.candidateStripTouchOverflowY).contains(point) else {
            return false
        }
        if candidateScrollHitTarget(at: point) != nil {
            return true
        }
        return candidateScrollView.contentSize.width > candidateScrollView.bounds.width + 2
    }

    fileprivate func shouldTextKeyTouchSurfaceHandle(point: CGPoint) -> Bool {
        guard keyboardFocus == .text,
              !textKeyboardContainer.isHidden,
              !keyRowsStack.isHidden,
              keyRowsStack.alpha > 0.01,
              keyRowsStack.bounds.width > 0,
              keyRowsStack.bounds.height > 0,
              !isCandidateGridExpanded
        else { return false }

        guard let characterBand = textCharacterTouchBandFrame() else { return false }
        return characterBand.contains(point)
    }

    private func isTextKeyboardDirectControlPoint(_ point: CGPoint) -> Bool {
        textKeyboardHitRows
            .flatMap(\.directButtons)
            .contains { button in
                guard !button.isHidden,
                      button.isEnabled,
                      button.alpha > 0.01,
                      button.bounds.width > 0,
                      button.bounds.height > 0
                else { return false }
                return button.convert(button.bounds, to: view).contains(point)
            }
    }

    private func isTextToolbarDirectControlPoint(_ point: CGPoint) -> Bool {
        [
            textModeButton,
            textGlobeButton,
            textWandButton,
            textStylePickerButton,
            textUndoButton,
            textToolsButton,
            textKeyboardSwitchButton,
            textHostSettingsButton,
        ].contains { button in
            guard !button.isHidden,
                  button.alpha > 0.01,
                  button.bounds.width > 0,
                  button.bounds.height > 0
            else { return false }
            return button.convert(button.bounds, to: view).contains(point)
        }
    }

    private func textCharacterTouchBandFrame() -> CGRect? {
        let characterRows = textKeyboardHitRegions().filter { $0.kind == .character }
        guard let firstRow = characterRows.first,
              let lastRow = characterRows.last
        else { return nil }
        let bottomLimit: CGFloat
        if let bottomRow = textKeyboardHitRegions().first(where: { $0.kind == .bottom }) {
            bottomLimit = min(
                lastRow.frame.maxY + TextKeyboardTouchModel.rowBottomOverflow,
                bottomRow.frame.minY - 2
            )
        } else {
            bottomLimit = lastRow.frame.maxY + TextKeyboardTouchModel.rowBottomOverflow
        }
        let topLimit: CGFloat
        if !textToolbar.isHidden,
           textToolbar.alpha > 0.01,
           textToolbar.bounds.height > 0 {
            // While the candidate strip is up, the strip owns most of the
            // toolbar↔keys gap: low taps aimed at a candidate used to be
            // routed to the q-row (which claimed everything below
            // toolbar.maxY+2 with a 14pt rescue overflow on top), which is
            // why candidates felt untappable. Keys keep a 4pt rescue band.
            let isCandidateStripActive = !textCandidateGridButton.isHidden
            let toolbarClearance: CGFloat = isCandidateStripActive ? 6 : 2
            let rowOverflow: CGFloat = isCandidateStripActive ? 4 : TextKeyboardTouchModel.rowTopOverflow
            topLimit = max(
                firstRow.frame.minY - rowOverflow,
                textToolbar.convert(textToolbar.bounds, to: view).maxY + toolbarClearance
            )
        } else {
            topLimit = firstRow.frame.minY - TextKeyboardTouchModel.rowTopOverflow
        }
        let characterBand = CGRect(
            x: view.bounds.minX,
            y: topLimit,
            width: view.bounds.width,
            height: max(0, bottomLimit - topLimit)
        )
        return characterBand
    }

    private func candidateScrollHitTarget(at point: CGPoint) -> UIButton? {
        guard !candidateScrollView.isHidden,
              !textCandidateGridButton.isHidden
        else { return nil }

        let scrollFrame = candidateScrollView.convert(candidateScrollView.bounds, to: view)
        guard scrollFrame.insetBy(dx: 0, dy: -Self.candidateStripTouchOverflowY).contains(point) else { return nil }
        let buttons = candidateStack.arrangedSubviews.compactMap { $0 as? UIButton }
        return horizontalButtonBandTarget(
            in: buttons,
            at: point,
            leftLimit: scrollFrame.minX,
            rightLimit: scrollFrame.maxX,
            edgeExpansion: 8
        )
    }

    private func candidateGridHitTarget(at point: CGPoint) -> UIButton? {
        guard !candidateGridScrollView.isHidden else { return nil }
        let gridFrame = candidateGridScrollView.convert(candidateGridScrollView.bounds, to: view)
        guard gridFrame.insetBy(dx: 0, dy: -4).contains(point) else { return nil }

        let rows = candidateGridStack.arrangedSubviews
            .compactMap { $0 as? UIStackView }
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .sorted { $0.convert($0.bounds, to: view).midY < $1.convert($1.bounds, to: view).midY }
        for row in rows {
            let rowFrame = row.convert(row.bounds, to: view)
            guard rowFrame.insetBy(dx: 0, dy: -4).contains(point) else { continue }
            let buttons = row.arrangedSubviews.compactMap { $0 as? UIButton }
            return horizontalButtonBandTarget(
                in: buttons,
                at: point,
                leftLimit: rowFrame.minX,
                rightLimit: rowFrame.maxX,
                edgeExpansion: 6
            )
        }
        return nil
    }

    private func horizontalButtonBandTarget(
        in sourceButtons: [UIButton],
        at point: CGPoint,
        leftLimit: CGFloat,
        rightLimit: CGFloat,
        edgeExpansion: CGFloat
    ) -> UIButton? {
        let buttons = visibleHitButtons(in: sourceButtons)
            .map { button in
                TextKeyboardHitButton(button: button, frame: button.convert(button.bounds, to: view))
            }
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard !buttons.isEmpty else { return nil }

        for index in buttons.indices {
            let frame = buttons[index].frame
            let leftBoundary: CGFloat
            let rightBoundary: CGFloat
            if index == buttons.startIndex {
                leftBoundary = max(leftLimit, frame.minX - edgeExpansion)
            } else {
                leftBoundary = (buttons[index - 1].frame.maxX + frame.minX) * 0.5
            }
            if index == buttons.index(before: buttons.endIndex) {
                rightBoundary = min(rightLimit, frame.maxX + edgeExpansion)
            } else {
                rightBoundary = (frame.maxX + buttons[index + 1].frame.minX) * 0.5
            }
            let isLastButton = index == buttons.index(before: buttons.endIndex)
            if point.x >= leftBoundary && (point.x < rightBoundary || (isLastButton && point.x <= rightBoundary)) {
                return buttons[index].button
            }
        }
        return nil
    }

    private func containingControl(of view: UIView) -> UIControl? {
        var current: UIView? = view
        while let v = current {
            if let control = v as? UIControl { return control }
            current = v.superview
        }
        return nil
    }

    private func expandedFrame(of targetView: UIView, dx: CGFloat, dy: CGFloat) -> CGRect {
        guard !targetView.isHidden, targetView.alpha > 0.01 else { return .null }
        return targetView.convert(targetView.bounds, to: view).insetBy(dx: -dx, dy: -dy)
    }

    private func textKeyboardHitRegions() -> [TextKeyboardHitRegion] {
        textKeyboardHitRows.compactMap { hitRow -> TextKeyboardHitRegion? in
            guard let row = hitRow.row,
                  !row.isHidden,
                  row.alpha > 0.01,
                  row.bounds.width > 0,
                  row.bounds.height > 0 else { return nil }
            let buttons = visibleHitButtons(in: hitRow.routedButtons)
            guard !buttons.isEmpty else { return nil }
            return TextKeyboardHitRegion(
                row: row,
                frame: row.convert(row.bounds, to: view),
                buttons: buttons,
                boundaryButtons: visibleHitButtons(in: hitRow.boundaryButtons),
                kind: hitRow.kind
            )
        }
        .filter { !$0.frame.isEmpty }
        .sorted { $0.frame.midY < $1.frame.midY }
    }

    private func nearestTextKeySurfaceTarget(at point: CGPoint) -> UIButton? {
        guard !keyRowsStack.isHidden, keyRowsStack.alpha > 0.01 else { return nil }
        let intentPoint = textCharacterIntentPoint(from: point)
        let rows = textKeyboardHitRegions().filter { $0.kind == .character }
        guard !rows.isEmpty else { return nil }

        for index in rows.indices {
            let row = rows[index]
            let previousFrame = index > rows.startIndex ? rows[rows.index(before: index)].frame : nil
            let nextFrame = index < rows.index(before: rows.endIndex) ? rows[rows.index(after: index)].frame : nil
            let upperBoundary = previousFrame.map { ($0.maxY + row.frame.minY) * 0.5 }
                ?? (row.frame.minY - TextKeyboardTouchModel.rowTopOverflow)
            let lowerBoundary = nextFrame.map { (row.frame.maxY + $0.minY) * 0.5 }
                ?? min(row.frame.maxY + TextKeyboardTouchModel.rowBottomOverflow, bottomTextControlTopLimit())
            if intentPoint.y >= upperBoundary && intentPoint.y <= lowerBoundary {
                return textKeyButtonBandTarget(in: row, at: intentPoint)
            }
        }

        return nil
    }

    private func textCharacterIntentPoint(from point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(
                max(point.x - TextKeyboardTouchModel.characterIntentXCorrection, view.bounds.minX),
                view.bounds.maxX
            ),
            y: point.y - TextKeyboardTouchModel.characterIntentYCorrection
        )
    }

    private func textKeyButtonBandTarget(in row: TextKeyboardHitRegion, at point: CGPoint) -> UIButton? {
        let buttons = visibleHitButtons(in: row.buttons)
            .map { button in
                TextKeyboardHitButton(button: button, frame: button.convert(button.bounds, to: view))
            }
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard !buttons.isEmpty else { return nil }

        let boundaryButtons = visibleHitButtons(in: row.boundaryButtons)
            .map { button in
                TextKeyboardHitButton(button: button, frame: button.convert(button.bounds, to: view))
            }
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.midX < $1.frame.midX }
        let targetIDs = Set(buttons.map { ObjectIdentifier($0.button) })

        for index in buttons.indices {
            let frame = buttons[index].frame
            let previousBoundary = boundaryButtons.last {
                $0.frame.maxX <= frame.minX && ObjectIdentifier($0.button) != ObjectIdentifier(buttons[index].button)
            }
            let nextBoundary = boundaryButtons.first {
                $0.frame.minX >= frame.maxX && ObjectIdentifier($0.button) != ObjectIdentifier(buttons[index].button)
            }
            let leftBoundary: CGFloat
            let rightBoundary: CGFloat
            if index == buttons.startIndex {
                if let previousBoundary {
                    leftBoundary = (previousBoundary.frame.maxX + frame.minX) * 0.5
                } else {
                    leftBoundary = view.bounds.minX
                }
            } else {
                leftBoundary = (buttons[index - 1].frame.maxX + frame.minX) * 0.5
            }
            if index == buttons.index(before: buttons.endIndex) {
                if let nextBoundary {
                    rightBoundary = (frame.maxX + nextBoundary.frame.minX) * 0.5
                } else {
                    rightBoundary = view.bounds.maxX
                }
            } else {
                rightBoundary = (frame.maxX + buttons[index + 1].frame.minX) * 0.5
            }
            if let previousBoundary,
               index == buttons.startIndex,
               !targetIDs.contains(ObjectIdentifier(previousBoundary.button)),
               point.x < leftBoundary {
                return nil
            }
            if let nextBoundary,
               index == buttons.index(before: buttons.endIndex),
               !targetIDs.contains(ObjectIdentifier(nextBoundary.button)),
               point.x > rightBoundary {
                return nil
            }
            if isTouchLearningEnabled,
               let chosen = learnedInterKeyGapWinner(buttons: buttons, index: index, point: point) {
                return chosen
            }
            let isLastButton = index == buttons.index(before: buttons.endIndex)
            if point.x >= leftBoundary && (point.x < rightBoundary || (isLastButton && point.x <= rightBoundary)) {
                return resolveGutterCandidate(
                    buttons: buttons,
                    index: index,
                    leftBoundary: leftBoundary,
                    rightBoundary: rightBoundary,
                    point: point
                )
            }
        }
        return nil
    }

    private func learnedInterKeyGapWinner(
        buttons: [TextKeyboardHitButton],
        index: Int,
        point: CGPoint
    ) -> UIButton? {
        if index > buttons.startIndex,
           point.x >= buttons[index - 1].frame.maxX,
           point.x <= buttons[index].frame.minX {
            return interKeyGapWinner(left: index - 1, right: index, buttons: buttons)
        }
        if index < buttons.index(before: buttons.endIndex),
           point.x >= buttons[index].frame.maxX,
           point.x <= buttons[index + 1].frame.minX {
            return interKeyGapWinner(left: index, right: index + 1, buttons: buttons)
        }
        return nil
    }

    private func resolveGutterCandidate(
        buttons: [TextKeyboardHitButton],
        index: Int,
        leftBoundary: CGFloat,
        rightBoundary: CGFloat,
        point: CGPoint
    ) -> UIButton {
        guard isTouchLearningEnabled else { return buttons[index].button }
        let gutter = TextKeyboardTouchModel.gutterRadius
        if index > buttons.startIndex,
           point.x - leftBoundary < gutter,
           let chosen = gutterResolutionWinner(left: index - 1, right: index, buttons: buttons, point: point) {
            return chosen
        }
        if index < buttons.index(before: buttons.endIndex),
           rightBoundary - point.x < gutter,
           let chosen = gutterResolutionWinner(left: index, right: index + 1, buttons: buttons, point: point) {
            return chosen
        }
        return buttons[index].button
    }

    private func interKeyGapWinner(left: Int, right: Int, buttons: [TextKeyboardHitButton]) -> UIButton? {
        if let probeWinner = gutterProbeWinner(left: left, right: right, buttons: buttons) {
            return probeWinner
        }
        return gutterGapBiasWinner(left: left, right: right, buttons: buttons)
    }

    private func gutterResolutionWinner(
        left: Int,
        right: Int,
        buttons: [TextKeyboardHitButton],
        point: CGPoint
    ) -> UIButton? {
        if let probeWinner = gutterProbeWinner(left: left, right: right, buttons: buttons) {
            return probeWinner
        }
        return gutterGaussianWinner(left: left, right: right, buttons: buttons, point: point)
    }

    private func gutterProbeWinner(left: Int, right: Int, buttons: [TextKeyboardHitButton]) -> UIButton? {
        guard textInputLanguage == .chinese, !isTextShiftEnabled else { return nil }
        guard let leftLetter = pinyinProbeLetter(for: buttons[left].button),
              let rightLetter = pinyinProbeLetter(for: buttons[right].button)
        else { return nil }
        let result = rimeInput.probeGutterValidity(left: leftLetter, right: rightLetter)
        if result.left == .extend && result.right == .split {
            return buttons[left].button
        }
        if result.right == .extend && result.left == .split {
            return buttons[right].button
        }
        return nil
    }

    private func gutterGapBiasWinner(
        left: Int,
        right: Int,
        buttons: [TextKeyboardHitButton]
    ) -> UIButton? {
        guard let leftCharacter = learnableTextKeyCharacter(for: buttons[left].button),
              let rightCharacter = learnableTextKeyCharacter(for: buttons[right].button)
        else { return nil }
        let leftCandidate = TextKeyTouchLearner.Candidate(
            character: leftCharacter,
            frame: buttons[left].frame
        )
        let rightCandidate = TextKeyTouchLearner.Candidate(
            character: rightCharacter,
            frame: buttons[right].frame
        )
        guard let decision = textTouchLearner.gapWinner(
            left: leftCandidate,
            right: rightCandidate
        ) else { return nil }
        let leftSamples = Int(decision.leftSamples.rounded())
        let rightSamples = Int(decision.rightSamples.rounded())
        let marginPercent = Int((decision.margin * 100).rounded())
        kbLog.debug("touch gap pick side=\(decision.side.rawValue, privacy: .public) leftSamples=\(leftSamples, privacy: .public) rightSamples=\(rightSamples, privacy: .public) marginPct=\(marginPercent, privacy: .public)")
        switch decision.side {
        case .left:
            return buttons[left].button
        case .right:
            return buttons[right].button
        }
    }

    private func gutterGaussianWinner(
        left: Int,
        right: Int,
        buttons: [TextKeyboardHitButton],
        point: CGPoint
    ) -> UIButton? {
        guard let leftCharacter = learnableTextKeyCharacter(for: buttons[left].button),
              let rightCharacter = learnableTextKeyCharacter(for: buttons[right].button)
        else { return nil }
        let leftCandidate = TextKeyTouchLearner.Candidate(
            character: leftCharacter,
            frame: buttons[left].frame
        )
        let rightCandidate = TextKeyTouchLearner.Candidate(
            character: rightCharacter,
            frame: buttons[right].frame
        )
        guard let decision = textTouchLearner.gutterWinner(
            left: leftCandidate,
            right: rightCandidate,
            touchPoint: point
        ) else { return nil }
        let leftSamples = Int(decision.leftSamples.rounded())
        let rightSamples = Int(decision.rightSamples.rounded())
        let marginPercent = Int((decision.margin * 100).rounded())
        kbLog.debug("touch gaussian pick side=\(decision.side.rawValue, privacy: .public) leftSamples=\(leftSamples, privacy: .public) rightSamples=\(rightSamples, privacy: .public) marginPct=\(marginPercent, privacy: .public)")
        switch decision.side {
        case .left:
            return buttons[left].button
        case .right:
            return buttons[right].button
        }
    }

    private func pinyinProbeLetter(for button: UIButton) -> Character? {
        guard let value = textKeyCommitCharacters[ObjectIdentifier(button)],
              value.count == 1,
              let scalar = value.unicodeScalars.first,
              scalar.value >= 0x61 && scalar.value <= 0x7A
        else { return nil }
        return Character(scalar)
    }

    private func learnableTextKeyCharacter(for button: UIButton) -> String? {
        guard let value = textKeyCommitCharacters[ObjectIdentifier(button)] else { return nil }
        return normalizedLearnableTextKeyCharacter(value)
    }

    private func normalizedLearnableTextKeyCharacter(_ character: String) -> String? {
        guard character.count == 1,
              let scalar = character.lowercased().unicodeScalars.first,
              scalar.value >= 0x61,
              scalar.value <= 0x7A
        else { return nil }
        return String(scalar)
    }

    private func textKeyTouchSample(
        button: UIButton,
        character: String,
        touchPoint: CGPoint
    ) -> TextKeyTouchSample? {
        guard let normalized = normalizedLearnableTextKeyCharacter(character) else { return nil }
        let frame = button.convert(button.bounds, to: view)
        guard frame.width > 1, frame.height > 1 else { return nil }
        return TextKeyTouchSample(
            character: normalized,
            buttonFrame: frame,
            touchPoint: touchPoint,
            committedAt: Date().timeIntervalSince1970
        )
    }

    private func registerCommittedTextTouch(_ sample: TextKeyTouchSample) {
        guard isTouchLearningEnabled else {
            pendingTextTouchSample = nil
            pendingTextTouchCorrection = nil
            return
        }
        if let correction = pendingTextTouchCorrection {
            let isCorrectionCandidate = sample.committedAt - correction.startedAt <= Self.textTouchCorrectionWindow
                && correction.sample.character != sample.character
                && textTouchLearner.areHorizontalNeighbors(
                    correction.sample.buttonFrame,
                    sample.buttonFrame
                )
            if isCorrectionCandidate {
                let proximity = correctionTouchGutterProximity(
                    correction: correction.sample,
                    replacement: sample
                )
                if proximity.isNear {
                    textTouchLearner.recordTouch(
                        touchPoint: correction.sample.touchPoint,
                        intendedFrame: sample.buttonFrame,
                        character: sample.character,
                        kind: .correction
                    )
                } else {
                    let distance = Int(proximity.distance.rounded())
                    let threshold = Int(proximity.threshold.rounded())
                    kbLog.debug("touch gaussian learn skipped reason=center distance=\(distance, privacy: .public) threshold=\(threshold, privacy: .public)")
                }
            }
            pendingTextTouchCorrection = nil
            pendingTextTouchSample = sample
            return
        }

        acceptPendingTextTouchIfSurvived(now: sample.committedAt)
        pendingTextTouchSample = sample
    }

    private func correctionTouchGutterProximity(
        correction: TextKeyTouchSample,
        replacement: TextKeyTouchSample
    ) -> TextTouchGutterProximity {
        let originalFrame = correction.buttonFrame
        let replacementFrame = replacement.buttonFrame
        let boundaryX: CGFloat
        if originalFrame.maxX <= replacementFrame.minX {
            boundaryX = (originalFrame.maxX + replacementFrame.minX) * 0.5
        } else if replacementFrame.maxX <= originalFrame.minX {
            boundaryX = (replacementFrame.maxX + originalFrame.minX) * 0.5
        } else {
            boundaryX = (originalFrame.midX + replacementFrame.midX) * 0.5
        }
        let maxWidth = max(originalFrame.width, replacementFrame.width)
        let threshold = min(TextKeyboardTouchModel.gutterRadius * 2, maxWidth * 0.35)
        let distance = abs(correction.touchPoint.x - boundaryX)
        return TextTouchGutterProximity(
            isNear: distance <= threshold,
            distance: distance,
            threshold: threshold
        )
    }

    private func acceptPendingTextTouchIfSurvived(now: TimeInterval = Date().timeIntervalSince1970) {
        if let correction = pendingTextTouchCorrection,
           now - correction.startedAt > Self.textTouchCorrectionWindow {
            pendingTextTouchCorrection = nil
        }
        guard let sample = pendingTextTouchSample else { return }
        pendingTextTouchSample = nil
        guard isTouchLearningEnabled else { return }
        guard now - sample.committedAt <= Self.textTouchPositiveTTL else { return }
        textTouchLearner.recordTouch(
            touchPoint: sample.touchPoint,
            intendedFrame: sample.buttonFrame,
            character: sample.character,
            kind: .accepted
        )
    }

    private func finishNonLearnableTextTouch() {
        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()
    }

    private func beginTextTouchCorrectionFromBackspace(compositionActive: Bool) {
        guard deleteRepeatTask == nil else { return }
        guard isTouchLearningEnabled else {
            pendingTextTouchSample = nil
            pendingTextTouchCorrection = nil
            return
        }
        let now = Date().timeIntervalSince1970
        guard let sample = pendingTextTouchSample else {
            pendingTextTouchCorrection = nil
            return
        }
        guard now - sample.committedAt <= Self.textTouchCorrectionWindow else {
            pendingTextTouchSample = nil
            pendingTextTouchCorrection = nil
            return
        }
        if !compositionActive {
            guard let last = textDocumentProxy.documentContextBeforeInput?.last,
                  String(last).lowercased() == sample.character
            else { return }
        }
        pendingTextTouchSample = nil
        pendingTextTouchCorrection = PendingTextTouchCorrection(
            sample: sample,
            startedAt: now
        )
    }

    private func resetTextTouchLearning() {
        pendingTextTouchSample = nil
        pendingTextTouchCorrection = nil
        textTouchLearner.flush()
        textTouchLearner.reset()
    }

    private func bottomTextControlTopLimit() -> CGFloat {
        let top = [
            textModeButton,
            textGlobeButton,
            textLanguageButton,
            textSpaceKeyButton,
            textReturnKeyButton,
        ]
            .compactMap { button -> CGFloat? in
                guard let button,
                      !button.isHidden,
                      button.alpha > 0.01,
                      button.isDescendant(of: keyRowsStack),
                      button.bounds.height > 0
                else { return nil }
                return button.convert(button.bounds, to: view).minY
            }
            .min()
        return (top ?? view.bounds.maxY) - 4
    }

    private func visibleHitButtons(in buttons: [UIButton]) -> [UIButton] {
        buttons.filter {
            !$0.isHidden
                && $0.isEnabled
                && $0.alpha > 0.01
                && $0.bounds.width > 0
                && $0.bounds.height > 0
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSystemKeyboardAffordances()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        configureRimeStateCallback()
        loadState()
        syncPrimaryLanguage()
        configureRoot()
        hostLinkOpener.installIfNeeded(in: self)
        configureKeyPreview()
        configureTopRow()
        configureVoiceButton()
        configureUtilityRow()
        configureTextKeyboard()
        attachToolbarHints()
        configureKeyboardDarwinBridge()
        _ = applySharedStandbySnapshotForPresentation()
        applyKeyboardInterfaceStyle(force: true)
        updateKeyboardFocus(animated: false)
        _ = rimeInput.startIfNeeded()
        updateUI(animated: false)
        keyboardHaptics.prepareForKeyboardReady()
        // Keyboard extensions receive the active input scene's appearance as
        // traits. Re-apply concrete colors whenever those traits move; layer
        // colors don't update automatically like UIColor-backed views do.
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _) in
                self.refreshDynamicAppearance()
            }
        }
        logKeyboardStartupSnapshot("viewDidLoad", force: true)
        kbLog.debug("viewDidLoad complete; voiceButton enabled=\(self.voiceButton.isEnabled, privacy: .public), fullAccess=\(self.hasFullAccess, privacy: .public)")
    }

    /// Re-applies layer-level (CGColor) properties that don't follow trait
    /// updates automatically. UIColor-backed properties (label.textColor,
    /// view.backgroundColor with dynamic UIColor) repaint on their own.
    private func refreshDynamicAppearance() {
        applyKeyboardInterfaceStyle()
        let traits = keyboardTraitCollection
        refreshKeyboardBackground()
        voiceButton.layer.shadowColor = UIColor.systemBlue.resolvedColor(with: traits).cgColor
        voiceButton.layer.shadowOpacity = isKeyboardDark ? 0.5 : 0.42
        voiceButton.layer.borderColor = UIColor.white
            .withAlphaComponent(isKeyboardDark ? 0.28 : 0.22)
            .cgColor
        // Pulse rings tint to the same system color family as the orb.
        for ring in pulseRings {
            ring.strokeColor = pulseRingColor.resolvedColor(with: traits).cgColor
        }
        updateUI(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        beginInputModeCarryoverSuppression()
        configureSystemKeyboardAffordances()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        configureRimeStateCallback()
        refreshKeyboardPreferencesFromHost(rebuildIfNeeded: true)
        refreshInputModeSwitchKeyVisibility()
        applyKeyboardHeightForCurrentTraits()
        resetCorrectionModeToDefault()
        prepareInitialLayoutForDisplay()
        // The current input scene's style isn't always settled by
        // `viewDidLoad`; pick up whatever's current right before display.
        refreshDynamicAppearance()
        configureKeyboardDarwinBridge()
        _ = applySharedStandbySnapshotForFastStart()
            || applySharedStandbySnapshotForPresentation()
        keyboardHaptics.prepareForKeyboardReady()
        setKeyboardContentVisible(true)
        logKeyboardPresentationGateIfUnstable()
        logKeyboardStartupSnapshot("viewWillAppear", force: true)
        logKeyboardPresentationLayout("viewWillAppear", force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        disableGestureRecognizerDelays()
        setKeyboardContentVisible(true)
        logKeyboardPresentationGateIfUnstable()
        keyboardHaptics.prepareForKeyboardReady()
        logKeyboardStartupSnapshot("viewDidAppear", force: true)
        logKeyboardPresentationLayout("viewDidAppear", force: true)
        scheduleDeferredTextKeyboardLayoutRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.disableGestureRecognizerDelays()
            self?.setKeyboardContentVisible(true)
            self?.logKeyboardPresentationGateIfUnstable()
            self?.keyboardHaptics.prepareForKeyboardReady()
            self?.logKeyboardStartupSnapshot("viewDidAppear+100ms", force: true)
            self?.logKeyboardPresentationLayout("viewDidAppear+100ms", force: true)
        }
        scheduleDeferredStartupProbe()
    }

    override func handleInputModeList(from view: UIView, with event: UIEvent) {
        guard !shouldSuppressCarryoverInputModeSwitch(event: event) else {
            if !didSuppressInitialInputModeSwitchEvent {
                didSuppressInitialInputModeSwitchEvent = true
                kbLog.notice("suppressed carry-over input-mode switch event during keyboard activation")
            }
            return
        }
        super.handleInputModeList(from: view, with: event)
    }

    private func beginInputModeCarryoverSuppression() {
        keyboardActivationStartedAt = CACurrentMediaTime()
        isSuppressingCarryoverInputModeTouch = true
        didSuppressInitialInputModeSwitchEvent = false
        suppressedInputModeTouches.removeAll()
    }

    private func shouldSuppressCarryoverInputModeSwitch(event: UIEvent) -> Bool {
        let activationElapsed = CACurrentMediaTime() - keyboardActivationStartedAt

        guard let touches = event.allTouches, !touches.isEmpty else {
            guard isSuppressingCarryoverInputModeTouch else { return false }
            if activationElapsed <= Self.inputModeCarryoverNoTouchGrace {
                return true
            }
            isSuppressingCarryoverInputModeTouch = false
            return false
        }

        let touchIdentifiers = Set(touches.map { ObjectIdentifier($0) })
        if !suppressedInputModeTouches.isDisjoint(with: touchIdentifiers) {
            removeFinishedSuppressedInputModeTouches(from: touches)
            return true
        }

        guard isSuppressingCarryoverInputModeTouch else { return false }

        if touches.contains(where: { $0.phase == .began }) {
            let firstTimestamp = touches.map(\.timestamp).min() ?? CACurrentMediaTime()
            if firstTimestamp - keyboardActivationStartedAt <= Self.inputModeCarryoverBeganGrace {
                suppressedInputModeTouches.formUnion(touchIdentifiers)
                removeFinishedSuppressedInputModeTouches(from: touches)
                return true
            }
            isSuppressingCarryoverInputModeTouch = false
            return false
        }

        suppressedInputModeTouches.formUnion(touchIdentifiers)
        removeFinishedSuppressedInputModeTouches(from: touches)
        return true
    }

    private func removeFinishedSuppressedInputModeTouches(from touches: Set<UITouch>) {
        let finished = touches
            .filter { $0.phase == .ended || $0.phase == .cancelled }
            .map { ObjectIdentifier($0) }
        suppressedInputModeTouches.subtract(finished)
        if suppressedInputModeTouches.isEmpty,
           touches.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) {
            isSuppressingCarryoverInputModeTouch = false
        }
    }

    private func disableGestureRecognizerDelays(in root: UIView? = nil) {
        guard let startView = root ?? view else { return }
        var visited = Set<ObjectIdentifier>()

        func disableDelays(on targetView: UIView) {
            let id = ObjectIdentifier(targetView)
            guard !visited.contains(id) else { return }
            visited.insert(id)

            targetView.gestureRecognizers?.forEach { recognizer in
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.cancelsTouchesInView = false
                if let edgePan = recognizer as? UIScreenEdgePanGestureRecognizer {
                    edgePan.isEnabled = false
                }
            }

            targetView.subviews.forEach { disableDelays(on: $0) }
        }

        disableDelays(on: startView)

        var parentView = startView.superview
        while let parent = parentView {
            disableDelays(on: parent)
            parentView = parent.superview
        }

        if let window = startView.window {
            disableDelays(on: window)
            if let rootViewController = window.rootViewController {
                disableDelays(on: rootViewController.view)
            }
        }
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        currentTextInputIdentity = textInput.map { ObjectIdentifier($0 as AnyObject) }
        discardRimeInputIfTargetChanged()
        refreshInputModeSwitchKeyVisibility()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        currentTextInputIdentity = textInput.map { ObjectIdentifier($0 as AnyObject) }
        discardRimeInputIfTargetChanged()
        refreshTextKeyboardLayoutForCurrentInputTraits()
        refreshInputModeSwitchKeyVisibility()
        refreshReturnKeyTitle()
        refreshEnglishLetterCasingIfNeeded()
    }

    isolated deinit {
        pendingTextKeyboardTraitRefresh?.cancel()
        deferredStartupWorkItem?.cancel()
        textToolbarStatusClearTask?.cancel()
        scheduledHostOpenTask?.cancel()
        scheduledStopTask?.cancel()
        hostWakeResetTask?.cancel()
        stopBridgeStatusStream()
        textTouchLearner.flush()
        chineseLearningRecorder.flush()
        rimeInput.onStateChange = nil
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        cancelBridgeCommandTasks()
        styleRewriteTask?.cancel()
        styleConfigureTask?.cancel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resetAllPressedControlStates(animated: false)
        if keyboardFocus == .text {
            pendingRimeCharacters.removeAll()
            pendingRimeDirectTextKeys.removeAll()
            commitDisplayedRimeCompositionIfNeeded()
            rimeInputTarget = nil
        }
        textTouchLearner.flush()
        chineseLearningRecorder.flush()
        stopDeleteRepeat()
        clearTextShiftState()
        cancelHostWakeResetTask()
        commitLivePartialBeforeHostReturnIfNeeded()
        rimeInput.onStateChange = nil
        deferredStartupWorkItem?.cancel()
        deferredStartupWorkItem = nil
        textToolbarStatusClearTask?.cancel()
        textToolbarStatusClearTask = nil
        textToolbarStatusText = nil
        stopBridgeStatusStream()
        cancelBridgeCommandTasks()
        cancelActiveRecordingForKeyboardDismissal()
        refineUndoState = nil
        styleRewriteTask?.cancel()
        styleRewriteTask = nil
        styleConfigureTask?.cancel()
        styleConfigureTask = nil
        cancelScheduledHostOpen()
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        keyboardDarwinObservers = []
        voicePrint.isActive = false
        topRowVoicePrint.isActive = false
        textToolbarVoicePrint.isActive = false
        stopPulseRings()
        voiceDragOutCancelArmed = false
        recordingElapsedTimer?.invalidate()
        recordingElapsedTimer = nil
        // Snap the popover closed without animation so a future appearance
        // starts from a clean state.
        if isCorrectionPopoverVisible {
            isCorrectionPopoverVisible = false
            correctionPopoverDismissOverlay.isHidden = true
            correctionPopoverDismissOverlay.backgroundColor = UIColor.black.withAlphaComponent(0)
            correctionPopover.isHidden = true
            correctionPopover.alpha = 0
            correctionPopover.transform = .identity
            updateKeyboardOverlayOrdering()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            guard let self else { return }
            self.applyKeyboardHeightForCurrentTraits()
            self.view.layoutIfNeeded()
        }
    }

    private func loadState() {
        correctionMode = defaultCorrectionModeFromHost() ?? .polishPlus
        defaults.removeObject(forKey: "keyboard.correctionMode")
        if let raw = defaults.string(forKey: inputModeKey),
           let saved = VoiceInputMode(rawValue: raw) {
            inputMode = saved
        }
        if let raw = defaults.string(forKey: keyboardFocusKey),
           let saved = KeyboardFocus(rawValue: raw) {
            keyboardFocus = saved
        }
        let hasSavedTextInputLanguage = defaults.string(forKey: textInputLanguageKey) != nil
        if let raw = defaults.string(forKey: textInputLanguageKey),
           let saved = TextInputLanguage(rawValue: raw) {
            textInputLanguage = saved
        }
        isChineseInputEnabled = defaults.object(forKey: hostChineseInputEnabledKey)
            .map { _ in defaults.bool(forKey: hostChineseInputEnabledKey) } ?? true
        if !isChineseInputEnabled {
            textInputLanguage = .english
            syncPrimaryLanguage()
        }
        rimeUserPhrasesRevision = defaults.string(forKey: rimeUserPhrasesRevisionKey) ?? ""
        refreshKeyboardPreferencesFromHost(
            rebuildIfNeeded: false,
            applyDefaultTextInputLanguageIfNeeded: !hasSavedTextInputLanguage,
            applyRimeChanges: false
        )
        defaults.removeObject(forKey: "keyboard.pendingAutoStartUntil")
    }

    private func syncPrimaryLanguage() {
        primaryLanguage = isChineseInputEnabled && textInputLanguage == .chinese ? "zh-Hans" : "en-US"
    }

    private func applyTextInputOptionsToRime() {
        _ = rimeInput.setProfile(rimeProfile)
        applyRimeState(
            rimeInput.applyOptions(
                asciiPunctuation: chinesePunctuationStyle == .english,
                asciiMode: !isChineseInputEnabled || textInputLanguage == .english
            )
        )
    }

    private func resetCorrectionModeToDefault() {
        correctionMode = currentDefaultCorrectionMode()
        lastCorrectionModeButtonSignature = ""
    }

    private func applyDefaultCorrectionModeFromHost(_ rawValue: String?) {
        guard let rawValue,
              let defaultMode = CorrectionMode(rawValue: rawValue)
        else { return }
        if pendingDefaultCorrectionMode == defaultMode {
            pendingDefaultCorrectionMode = nil
        }
        guard pendingDefaultCorrectionMode == nil,
              correctionMode != defaultMode
        else { return }
        correctionMode = defaultMode
        lastCorrectionModeButtonSignature = ""
    }

    private func currentDefaultCorrectionMode() -> CorrectionMode {
        if let pendingDefaultCorrectionMode {
            return pendingDefaultCorrectionMode
        }
        return defaultCorrectionModeFromHost() ?? .polishPlus
    }

    private func defaultCorrectionModeFromHost() -> CorrectionMode? {
        hostKeyboardDefaultsPayload()?.correctionMode
    }

    private func isCorrectionModeAvailable(_: CorrectionMode) -> Bool {
        true
    }

    private var correctionModeOptions: [CorrectionMode] {
        CorrectionMode.allCases
    }

    private func refreshKeyboardPreferencesFromHost(
        rebuildIfNeeded: Bool,
        applyDefaultTextInputLanguageIfNeeded: Bool = false,
        applyRimeChanges: Bool = true
    ) {
        guard let payload = hostKeyboardDefaultsPayload() else { return }
        let previousAutoCapitalization = isAutoCapitalizationEnabled
        let previousCharacterPreview = isCharacterPreviewEnabled
        let previousChineseInputEnabled = isChineseInputEnabled
        let previousPunctuationStyle = chinesePunctuationStyle
        let previousRimeProfile = rimeProfile
        let previousRimeUserPhrasesRevision = rimeUserPhrasesRevision
        let previousTextInputLanguage = textInputLanguage
        let previousTouchLearningEnabled = isTouchLearningEnabled

        isAutoCapitalizationEnabled = payload.autoCapitalizationEnabled
        isCharacterPreviewEnabled = payload.characterPreviewEnabled
        keyboardHaptics.clickSoundsEnabled = payload.keySoundEnabled
        keyboardHaptics.hapticsEnabled = payload.keyHapticsEnabled
        isChineseInputEnabled = payload.chineseInputEnabled
        defaults.set(payload.chineseInputEnabled, forKey: hostChineseInputEnabledKey)
        chinesePunctuationStyle = payload.chinesePunctuationStyle
        rimeProfile.dictionaryTier = payload.rimeDictionaryTier
        rimeProfile.learningEnabled = payload.rimeLearningEnabled
        rimeProfile.correctionEnabled = payload.rimeCorrectionEnabled
        isTouchLearningEnabled = payload.touchLearningEnabled
        if previousTouchLearningEnabled && !isTouchLearningEnabled {
            pendingTextTouchSample = nil
            pendingTextTouchCorrection = nil
        }
        let hostRimeUserPhrases = payload.rimeUserPhrases
        let hostRimeUserPhrasesRevision = payload.rimeUserPhrasesRevision
        let userPhrasesChanged = hostRimeUserPhrasesRevision != rimeUserPhrasesRevision
        let userPhraseState = rimeInput.setUserPhrases(
            hostRimeUserPhrases,
            revision: hostRimeUserPhrasesRevision,
            reloadIfNeeded: applyRimeChanges && userPhrasesChanged
        )
        if userPhrasesChanged {
            rimeUserPhrasesRevision = hostRimeUserPhrasesRevision
            defaults.set(hostRimeUserPhrasesRevision, forKey: rimeUserPhrasesRevisionKey)
        }
        let hostDefaultLanguage = payload.defaultTextInputLanguage
        let previousHostDefault = defaults.string(forKey: hostDefaultTextInputLanguageKey)
        let shouldApplyDefault = applyDefaultTextInputLanguageIfNeeded || previousHostDefault != hostDefaultLanguage.rawValue
        defaults.set(hostDefaultLanguage.rawValue, forKey: hostDefaultTextInputLanguageKey)
        if isChineseInputEnabled,
           shouldApplyDefault,
           let defaultLanguage = textInputLanguage(for: hostDefaultLanguage) {
            if textInputLanguage == .chinese, defaultLanguage == .english {
                commitDisplayedRimeCompositionIfNeeded()
            }
            textInputLanguage = defaultLanguage
            defaults.set(defaultLanguage.rawValue, forKey: textInputLanguageKey)
            syncPrimaryLanguage()
            clearTextShiftState()
        }
        if !isChineseInputEnabled, textInputLanguage != .english {
            if applyRimeChanges {
                commitDisplayedRimeCompositionIfNeeded()
            }
            textInputLanguage = .english
            defaults.set(TextInputLanguage.english.rawValue, forKey: textInputLanguageKey)
            syncPrimaryLanguage()
            clearTextShiftState()
        }

        if applyRimeChanges,
           previousChineseInputEnabled != isChineseInputEnabled
            || previousPunctuationStyle != chinesePunctuationStyle
            || previousRimeProfile != rimeProfile
            || previousTextInputLanguage != textInputLanguage {
            resetQuoteParity()
            applyTextInputOptionsToRime()
        }
        if applyRimeChanges, userPhrasesChanged {
            applyRimeState(userPhraseState)
        }
        if applyRimeChanges,
           payload.rimeLearningResetGeneration > defaults.integer(forKey: rimeLearningResetGenerationKey) {
            defaults.set(payload.rimeLearningResetGeneration, forKey: rimeLearningResetGenerationKey)
            applyRimeState(rimeInput.resetUserData())
            chineseLearningRecorder.reset()
        }
        if payload.touchLearningResetGeneration > defaults.integer(forKey: touchLearningResetGenerationKey) {
            defaults.set(payload.touchLearningResetGeneration, forKey: touchLearningResetGenerationKey)
            resetTextTouchLearning()
        }
        guard rebuildIfNeeded else { return }
        let changed = previousAutoCapitalization != isAutoCapitalizationEnabled
            || previousCharacterPreview != isCharacterPreviewEnabled
            || previousChineseInputEnabled != isChineseInputEnabled
            || previousPunctuationStyle != chinesePunctuationStyle
            || previousRimeProfile != rimeProfile
            || previousRimeUserPhrasesRevision != rimeUserPhrasesRevision
            || previousTextInputLanguage != textInputLanguage
        guard changed else { return }

        if keyboardFocus == .text {
            rebuildTextKeyboardRows()
        }
    }

    private func hostKeyboardDefaultsPayload() -> KeyboardDefaultsPayload? {
        guard hasFullAccess else { return nil }
        return KeyboardSharedDefaults.loadPayload()
    }

    private var hostKeyboardBridgeToken: String? {
        guard hasFullAccess,
              let token = KeyboardSharedKeychain.keyboardBridgeToken(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return token
    }

    private func textInputLanguage(for hostDefaultLanguage: KeyboardDefaultTextInputLanguage) -> TextInputLanguage? {
        switch hostDefaultLanguage {
        case .lastUsed:
            return nil
        case .chinese:
            return .chinese
        case .english:
            return .english
        }
    }

    private func configureRoot() {
        refreshKeyboardBackground()

        keyboardSurfaceView.translatesAutoresizingMaskIntoConstraints = true
        keyboardSurfaceView.isUserInteractionEnabled = false
        // iOS 27 wraps keyboard extensions in a rounded system card with its
        // own shadow. Keep the 0.01-alpha rendered pixels required for gap
        // touches, but mask them to actual keyboard hit regions so the system
        // does not see a full-width top rectangle above the candidate strip.
        keyboardSurfaceView.isOpaque = false
        keyboardSurfaceView.backgroundColor = Self.keyboardTouchableBackgroundColor
        keyboardSurfaceMaskLayer.fillColor = UIColor.black.cgColor
        keyboardSurfaceView.layer.mask = keyboardSurfaceMaskLayer

        keyboardContentView.translatesAutoresizingMaskIntoConstraints = true
        keyboardContentView.backgroundColor = .clear
        keyboardContentView.isOpaque = false
        keyboardContentView.clipsToBounds = false

        candidateTextOverlay.translatesAutoresizingMaskIntoConstraints = true
        candidateTextOverlay.isUserInteractionEnabled = false
        candidateTextOverlay.backgroundColor = .clear
        candidateTextOverlay.isOpaque = false
        candidateTextOverlay.clipsToBounds = false
        candidateTextOverlay.isHidden = true

        rootStack.axis = .vertical
        rootStack.spacing = Self.stackSpacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        keyboardTouchOverlay.translatesAutoresizingMaskIntoConstraints = true
        keyboardTouchOverlay.hitController = self
        keyboardTouchOverlay.backgroundColor = .clear
        keyboardTouchOverlay.isOpaque = false

        view.addSubview(keyboardSurfaceView)
        view.addSubview(keyboardContentView)
        keyboardContentView.addSubview(rootStack)
        view.addSubview(candidateTextOverlay)
        view.addSubview(keyboardTouchOverlay)
        setKeyboardContentVisible(true)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: keyboardContentView.leadingAnchor, constant: Self.rootHorizontalInset),
            rootStack.trailingAnchor.constraint(equalTo: keyboardContentView.trailingAnchor, constant: -Self.rootHorizontalInset),
            rootStack.topAnchor.constraint(equalTo: keyboardContentView.topAnchor, constant: Self.rootVerticalInset + Self.topChromeCoverHeight),
            rootStack.bottomAnchor.constraint(equalTo: keyboardContentView.bottomAnchor, constant: -Self.rootVerticalInset),
        ])
        layoutKeyboardContentViewForCurrentBounds()
    }

    private func setKeyboardContentVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            self.view.alpha = 1
            self.keyboardContentView.alpha = visible ? 1 : 0
            self.candidateTextOverlay.alpha = visible ? 1 : 0
            self.keyboardTouchOverlay.alpha = visible ? 1 : 0
        }
        CATransaction.commit()
    }

    private func logKeyboardPresentationGateIfUnstable() {
        let gate = keyboardPresentationGateState()
        guard !gate.isStable else {
            lastPresentationGateLogKey = ""
            return
        }
        guard gate.logKey != lastPresentationGateLogKey else { return }
        lastPresentationGateLogKey = gate.logKey
        kbLog.debug("keyboard presentation geometry unsettled: \(gate.reason, privacy: .public)")
    }

    private func keyboardPresentationGateState() -> (isStable: Bool, logKey: String, reason: String) {
        let targetHeight = currentKeyboardContentHeight + Self.topChromeCoverHeight
        let heightDelta = abs(view.bounds.height - targetHeight)
        let keyboardFrame = view.convert(view.bounds, to: nil)
        let windowFrame = view.window?.frame
        let screenBottom = UIScreen.main.bounds.maxY
        let bottomDelta = windowFrame.map { abs(keyboardFrame.maxY - $0.maxY) } ?? 0
        let windowScreenDelta = windowFrame.map { abs($0.maxY - screenBottom) } ?? 0
        let hasWindow = view.window != nil
        let shouldCheckWindowScreenBottom = windowFrame.map { $0.maxY > targetHeight + 20 } ?? false
        let isBottomAnchored = !hasWindow
            || (bottomDelta <= 2 && (!shouldCheckWindowScreenBottom || windowScreenDelta <= 2))
        let isStable = heightDelta <= 2 && isBottomAnchored
        let logKey = [
            String(format: "%.1f", Double(view.bounds.height)),
            String(format: "%.1f", Double(targetHeight)),
            String(format: "%.1f", Double(keyboardFrame.minY)),
            String(format: "%.1f", Double(keyboardFrame.maxY)),
            String(format: "%.1f", Double(windowFrame?.maxY ?? -1)),
            String(format: "%.1f", Double(screenBottom)),
        ].joined(separator: "|")
        let reason = String(
            format: "height=%.1f target=%.1f heightDelta=%.1f keyboardY=%.1f keyboardBottom=%.1f windowBottom=%.1f screenBottom=%.1f bottomDelta=%.1f windowScreenDelta=%.1f",
            Double(view.bounds.height),
            Double(targetHeight),
            Double(heightDelta),
            Double(keyboardFrame.minY),
            Double(keyboardFrame.maxY),
            Double(windowFrame?.maxY ?? -1),
            Double(screenBottom),
            Double(bottomDelta),
            Double(windowScreenDelta)
        )
        return (isStable, logKey, reason)
    }

    private func refreshKeyboardBackground() {
        // Blank areas need to be real keyboard surface, not transparent host
        // passthrough. The separate touch overlay stays clear because it sits
        // above the keys; its custom hit-test owns anti-mistouch routing.
        view.isOpaque = false
        view.backgroundColor = .clear
        keyboardSurfaceView.backgroundColor = Self.keyboardTouchableBackgroundColor
        keyboardTouchOverlay.backgroundColor = .clear
    }

    private func configureKeyPreview() {
        keyPreviewBubble.isHidden = true
        keyPreviewBubble.alpha = 0
        keyPreviewBubble.isUserInteractionEnabled = false
        keyPreviewBubble.layer.cornerRadius = 10
        keyPreviewBubble.layer.borderWidth = 0.5
        keyPreviewBubble.layer.shadowColor = UIColor.black.cgColor
        keyPreviewBubble.layer.shadowOpacity = 0.18
        keyPreviewBubble.layer.shadowRadius = 9
        keyPreviewBubble.layer.shadowOffset = CGSize(width: 0, height: 4)

        keyPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        keyPreviewLabel.textAlignment = .center
        keyPreviewLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        keyPreviewLabel.textColor = .label
        keyPreviewLabel.adjustsFontSizeToFitWidth = true
        keyPreviewLabel.minimumScaleFactor = 0.6
        keyPreviewBubble.addSubview(keyPreviewLabel)
        view.addSubview(keyPreviewBubble)
        NSLayoutConstraint.activate([
            keyPreviewLabel.leadingAnchor.constraint(equalTo: keyPreviewBubble.leadingAnchor, constant: 6),
            keyPreviewLabel.trailingAnchor.constraint(equalTo: keyPreviewBubble.trailingAnchor, constant: -6),
            keyPreviewLabel.topAnchor.constraint(equalTo: keyPreviewBubble.topAnchor, constant: 4),
            keyPreviewLabel.bottomAnchor.constraint(equalTo: keyPreviewBubble.bottomAnchor, constant: -4),
        ])
    }

    private func prepareInitialLayoutForDisplay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            self.layoutKeyboardContentViewForCurrentBounds()
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.keyboardContentView.layoutIfNeeded()
            self.rootStack.layoutIfNeeded()
            self.topRow.layoutIfNeeded()
            self.topRowVoicePrint.layoutIfNeeded()
            self.orbContainer.layoutIfNeeded()
            self.correctionModePanel.layoutIfNeeded()
            self.inputModeSwitch.layoutIfNeeded()
            self.utilityRow.layoutIfNeeded()
            self.textKeyboardContainer.layoutIfNeeded()
            self.keyRowsStack.layoutIfNeeded()
        }
        CATransaction.commit()
    }

    private var currentKeyboardContentHeight: CGFloat {
        traitCollection.verticalSizeClass == .compact
            ? Self.compactKeyboardContentHeight
            : Self.portraitKeyboardContentHeight
    }

    private var effectiveKeyboardContentHeight: CGFloat {
        let contentBoundsHeight = keyboardContentView.bounds.height
        if contentBoundsHeight > 1 {
            return contentBoundsHeight - Self.topChromeCoverHeight
        }
        let viewBoundsHeight = view.bounds.height
        if viewBoundsHeight > 1 {
            return viewBoundsHeight - Self.topChromeCoverHeight
        }
        return currentKeyboardContentHeight
    }

    private func applyKeyboardHeightForCurrentTraits() {
        let targetContentHeight = currentKeyboardContentHeight
        let totalHeight = targetContentHeight + Self.topChromeCoverHeight
        heightConstraint?.constant = totalHeight
        let contentHeight = max(1, targetContentHeight)
        view.setNeedsLayout()
        layoutKeyboardContentViewForCurrentBounds()
        textKeyboardContainerHeightConstraint?.constant = Self.textKeyboardBodyHeight(for: contentHeight)
        orbContainerHeightConstraint?.constant = Self.orbContainerHeight(for: contentHeight)
        logKeyboardPresentationLayout("applyHeight", force: true)
    }

    private func keyboardContentFrameForCurrentBounds() -> CGRect {
        let bounds = view.bounds
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
    }

    private func layoutKeyboardContentViewForCurrentBounds() {
        let frame = keyboardContentFrameForCurrentBounds()
        if keyboardSurfaceView.frame != frame {
            keyboardSurfaceView.frame = frame
        }
        if keyboardContentView.frame != frame {
            keyboardContentView.frame = frame
        }
        if candidateTextOverlay.frame != frame {
            candidateTextOverlay.frame = frame
        }
        if keyboardTouchOverlay.frame != frame {
            keyboardTouchOverlay.frame = frame
        }
        let contentHeight = max(1, frame.height - Self.topChromeCoverHeight)
        textKeyboardContainerHeightConstraint?.constant = Self.textKeyboardBodyHeight(for: contentHeight)
        orbContainerHeightConstraint?.constant = Self.orbContainerHeight(for: contentHeight)
        keyboardContentView.setNeedsLayout()
        updateKeyboardSurfaceMask()
    }

    private func updateKeyboardSurfaceMask() {
        let bounds = keyboardSurfaceView.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            keyboardSurfaceMaskLayer.path = nil
            return
        }

        keyboardSurfaceMaskLayer.frame = bounds
        let path = UIBezierPath()
        var didAddRect = false

        if keyboardFocus == .text, !textKeyboardContainer.isHidden {
            didAddRect = appendTextKeyboardSurfaceRects(to: path) || didAddRect
        } else {
            didAddRect = appendVoiceKeyboardSurfaceRects(to: path) || didAddRect
        }

        keyboardSurfaceMaskLayer.path = didAddRect ? path.cgPath : nil
    }

    @discardableResult
    private func appendTextKeyboardSurfaceRects(to path: UIBezierPath) -> Bool {
        var didAddRect = false

        if let characterBand = textCharacterTouchBandFrame() {
            didAddRect = appendControllerSurfaceRect(characterBand, to: path) || didAddRect
        }

        if isCandidateGridExpanded {
            didAddRect = appendTopAnchoredSurfaceView(
                candidateGridScrollView,
                to: path,
                bottomExpansion: 4,
                extendTrailingToViewEdge: true
            ) || didAddRect
            return didAddRect
        }

        didAddRect = appendTopAnchoredSurfaceView(
            textToolbar,
            to: path,
            bottomExpansion: textCandidateGridButton.isHidden
                ? Self.textToolbarIdleBottomSurfaceExpansion
                : Self.candidateStripTouchOverflowY,
            extendTrailingToViewEdge: !textCandidateGridButton.isHidden
        ) || didAddRect
        return didAddRect
    }

    @discardableResult
    private func appendVoiceKeyboardSurfaceRects(to path: UIBezierPath) -> Bool {
        var didAddRect = false
        didAddRect = appendTopAnchoredSurfaceView(
            topRow,
            to: path,
            bottomExpansion: Self.stackSpacing
        ) || didAddRect
        didAddRect = appendSurfaceView(orbContainer, to: path, horizontalExpansion: 6, verticalExpansion: 2, cornerRadius: 10) || didAddRect
        didAddRect = appendSurfaceView(utilityRow, to: path, horizontalExpansion: 4, verticalExpansion: 4, cornerRadius: 8) || didAddRect
        return didAddRect
    }

    @discardableResult
    private func appendSurfaceView(
        _ view: UIView,
        to path: UIBezierPath,
        horizontalExpansion: CGFloat = 0,
        verticalExpansion: CGFloat = 0,
        cornerRadius: CGFloat = 0
    ) -> Bool {
        guard view.superview != nil,
              !view.isHidden,
              view.alpha > 0.01,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return false }

        let rect = view.convert(view.bounds, to: keyboardSurfaceView)
            .insetBy(dx: -horizontalExpansion, dy: -verticalExpansion)
        return appendSurfaceRect(rect, to: path, cornerRadius: cornerRadius)
    }

    @discardableResult
    private func appendTopAnchoredSurfaceView(
        _ surfaceSourceView: UIView,
        to path: UIBezierPath,
        horizontalExpansion: CGFloat = 0,
        bottomExpansion: CGFloat = 0,
        extendTrailingToViewEdge: Bool = false
    ) -> Bool {
        guard surfaceSourceView.superview != nil,
              !surfaceSourceView.isHidden,
              surfaceSourceView.alpha > 0.01,
              surfaceSourceView.bounds.width > 0,
              surfaceSourceView.bounds.height > 0
        else { return false }

        var rect = surfaceSourceView.convert(surfaceSourceView.bounds, to: keyboardSurfaceView)
        rect.origin.x -= horizontalExpansion
        rect.size.width += horizontalExpansion * 2
        if extendTrailingToViewEdge {
            let viewTrailingX = keyboardSurfaceView.convert(
                CGPoint(x: view.bounds.maxX, y: view.bounds.minY),
                from: self.view
            ).x
            rect.size.width = max(rect.width, viewTrailingX - rect.minX)
        }
        let bottom = rect.maxY + bottomExpansion
        rect.origin.y = keyboardSurfaceView.bounds.minY
        rect.size.height = bottom - rect.minY
        return appendSurfaceRect(rect, to: path)
    }

    @discardableResult
    private func appendControllerSurfaceRect(
        _ rect: CGRect,
        to path: UIBezierPath,
        cornerRadius: CGFloat = 0
    ) -> Bool {
        appendSurfaceRect(
            keyboardSurfaceView.convert(rect, from: view),
            to: path,
            cornerRadius: cornerRadius
        )
    }

    @discardableResult
    private func appendSurfaceRect(
        _ rect: CGRect,
        to path: UIBezierPath,
        cornerRadius: CGFloat = 0
    ) -> Bool {
        let clipped = rect.standardized.intersection(keyboardSurfaceView.bounds)
        guard !clipped.isNull, clipped.width > 0.5, clipped.height > 0.5 else { return false }

        if cornerRadius > 0 {
            let radius = min(cornerRadius, clipped.width / 2, clipped.height / 2)
            path.append(UIBezierPath(roundedRect: clipped, cornerRadius: radius))
        } else {
            path.append(UIBezierPath(rect: clipped))
        }
        return true
    }

    private func configureRimeStateCallback() {
        rimeInput.onStateChange = { [weak self] state in
            guard let self else { return }
            self.applyReadyRimeStateOrRender(state)
        }
    }

    @discardableResult
    private func applyKeyboardInterfaceStyle(force: Bool = false) -> Bool {
        let style = keyboardInterfaceStyle
        guard force || appliedKeyboardInterfaceStyle != style else { return false }
        appliedKeyboardInterfaceStyle = style
        lastCorrectionModeButtonSignature = ""
        lastTextRecordingButtonsSignature = ""
        let views: [UIView] = [
            rootStack,
            keyboardSurfaceView,
            topRow,
            statusGroup,
            statusLabel,
            settingsButton,
            keyboardFocusButton,
            correctionModePanel,
            correctionModeTrigger,
            correctionPopover,
            orbContainer,
            voiceButton,
            voiceIconView,
            voicePrint,
            topRowVoicePrint,
            textToolbarVoicePrint,
            voiceTitleLabel,
            inputModeSwitch,
            voiceSendButton,
            utilityRow,
            commandButton,
            voiceUndoButton,
            spaceButton,
            deleteButton,
            returnButton,
            textKeyboardContainer,
            textToolbar,
            textWandButton,
            textStylePickerButton,
            textUndoButton,
            textToolsButton,
            textKeyboardSwitchButton,
            textHostSettingsButton,
            textCandidateGridButton,
            candidateGridCollapseButton,
            textModeButton,
            textAlternateSymbolButton,
            textGlobeButton,
            textLanguageButton,
            candidateScrollView,
            candidateStack,
            keyRowsStack,
            candidateGridScrollView,
            candidateGridStack,
            keyPreviewBubble,
            keyPreviewLabel,
        ]
        views.forEach { $0.overrideUserInterfaceStyle = style }
        keyPreviewBubble.backgroundColor = UIColor.secondarySystemBackground
        keyPreviewBubble.layer.borderColor = UIColor.separator
            .resolvedColor(with: keyboardTraitCollection).cgColor
        textKeyboardButtons.forEach {
            $0.overrideUserInterfaceStyle = style
            $0.setNeedsUpdateConfiguration()
        }
        correctionModeButtons.forEach {
            $0.button.overrideUserInterfaceStyle = style
            $0.button.setNeedsUpdateConfiguration()
        }
        [settingsButton, keyboardFocusButton, spaceButton, deleteButton, returnButton].forEach {
            $0.setNeedsUpdateConfiguration()
        }
        refreshCapsuleButtonConfigurations()
        refreshCorrectionPopoverAppearance()
        inputModeSwitch.refreshAppearance(style: style)
        return true
    }

    private var keyboardTraitCollection: UITraitCollection {
        UITraitCollection(userInterfaceStyle: keyboardInterfaceStyle)
    }

    private var keyboardInterfaceStyle: UIUserInterfaceStyle {
        let controllerStyle = traitCollection.userInterfaceStyle
        if controllerStyle != .unspecified { return controllerStyle }
        let windowStyle = view.window?.windowScene?.traitCollection.userInterfaceStyle ?? .unspecified
        if windowStyle != .unspecified { return windowStyle }
        let screenStyle = UIScreen.main.traitCollection.userInterfaceStyle
        return screenStyle == .dark ? .dark : .light
    }

    private var isKeyboardDark: Bool {
        keyboardInterfaceStyle == .dark
    }

    private func configureSystemKeyboardAffordances() {
        hasDictationKey = true
    }

    private func configureKeyboardDarwinBridge() {
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        keyboardDarwinObservers = [
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.sessionStarted) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let shouldRefreshStatusStream = self.needsStatusStreamRefreshAfterDarwinStart()
                    kbLog.notice("darwin sessionStarted received state=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public) start_in_flight=\(self.isStartRequestInFlight, privacy: .public) refresh_status_stream=\(shouldRefreshStatusStream, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "keyboard-ui",
                        event: "darwin_session_started_received",
                        fields: [
                            "state": self.currentBridgeStatus?.state.rawValue ?? "nil",
                            "start_in_flight": "\(self.isStartRequestInFlight)",
                            "refresh_status_stream": "\(shouldRefreshStatusStream)",
                        ]
                    )
                    self.cancelHostWakeResetTask()
                    self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                    if !self.hasActiveKeyboardRecordingOrStopIntent,
                       self.currentBridgeStatus?.state != .recording,
                       self.currentBridgeStatus?.state != .sending {
                        if !self.applySharedBridgeStatusSnapshot() {
                            self.applyBridgeStatus(KeyboardBridgeStatus(state: .standby, message: "Ready"))
                        }
                    } else {
                        self.openingHostUntil = 0
                        self.lastBridgeContactAt = Date().timeIntervalSince1970
                        self.updateUI()
                    }
                    self.refreshBridgeStatusAfterDarwinStartIfNeeded(shouldRefreshStatusStream)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.sessionEnded) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    kbLog.notice("darwin sessionEnded received state=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public) pending_stop=\((self.pendingStopCommandID != nil), privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "keyboard-ui",
                        event: "darwin_session_ended_received",
                        fields: [
                            "state": self.currentBridgeStatus?.state.rawValue ?? "nil",
                            "pending_stop": "\((self.pendingStopCommandID != nil))",
                        ]
                    )
                    if self.currentBridgeStatus?.state == .sending || self.pendingStopCommandID != nil {
                        self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                        self.updateUI()
                        return
                    }
                    self.cancelScheduledHostOpen()
                    self.cancelHostWakeResetTask()
                    self.openingHostUntil = 0
                    self.isStartRequestInFlight = false
                    self.tapRecordingActive = false
                    self.bridgeStatus = KeyboardBridgeStatus(state: .idle, message: self.inputMode.idleTitle)
                    self.lastBridgeContactAt = 0
                    self.lastDarwinAwakeAt = 0
                    self.updateUI()
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStarted) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let shouldRefreshStatusStream = self.needsStatusStreamRefreshAfterDarwinStart()
                    kbLog.notice("darwin dictationStarted received state=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public) start_in_flight=\(self.isStartRequestInFlight, privacy: .public) active_command=\(self.activeRecordingCommandID ?? "none", privacy: .public) refresh_status_stream=\(shouldRefreshStatusStream, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "keyboard-ui",
                        event: "darwin_dictation_started_received",
                        fields: [
                            "state": self.currentBridgeStatus?.state.rawValue ?? "nil",
                            "start_in_flight": "\(self.isStartRequestInFlight)",
                            "active_command": self.activeRecordingCommandID ?? "none",
                            "refresh_status_stream": "\(shouldRefreshStatusStream)",
                        ]
                    )
                    self.cancelScheduledHostOpen()
                    self.cancelHostWakeResetTask()
                    self.cancelDarwinStartAckTimeout()
                    self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                    if self.applySharedBridgeStatusSnapshot(allowActiveState: true),
                       let status = self.currentBridgeStatus,
                       self.isLiveStartConfirmation(status) {
                        self.finishStartRequestIfNeeded(status: status)
                    } else if self.isStartRequestInFlight {
                        self.recoverBridgeStatusSnapshotForActiveCommand()
                    }
                    self.refreshBridgeStatusAfterDarwinStartIfNeeded(shouldRefreshStatusStream)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.commandReceiptUpdated) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleCommandReceiptNotification()
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStopped) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let wasStarting = self.isStartRequestInFlight
                    kbLog.notice("darwin dictationStopped received state=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public) was_starting=\(wasStarting, privacy: .public) active_command=\(self.activeRecordingCommandID ?? "none", privacy: .public) pending_stop=\(self.pendingStopCommandID ?? "none", privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "keyboard-ui",
                        event: "darwin_dictation_stopped_received",
                        fields: [
                            "state": self.currentBridgeStatus?.state.rawValue ?? "nil",
                            "was_starting": "\(wasStarting)",
                            "active_command": self.activeRecordingCommandID ?? "none",
                            "pending_stop": self.pendingStopCommandID ?? "none",
                        ]
                    )
                    self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                    if wasStarting {
                        // This notification has no command payload. It may be
                        // A's delayed recording→processing edge after the same
                        // press has already created B, so it must not clear B.
                        _ = self.applySharedBridgeStatusSnapshot(allowActiveState: true)
                        self.recoverBridgeStatusSnapshotForActiveCommand()
                        self.refreshBridgeStatus(captureSelection: false, force: true)
                        self.updateActiveStatusReconcileLoopForCurrentStatus()
                        return
                    }
                    self.finishStoppedNotification()
                    let appliedSnapshot = self.applySharedBridgeStatusSnapshot()
                    let shouldReconcileStoppedStatus = self.currentBridgeStatus?.state == .sending
                        || self.pendingStopCommandID != nil
                    if self.currentBridgeStatus?.state != .result,
                       self.currentBridgeStatus?.state != .sending {
                        if !appliedSnapshot {
                            self.bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Ready")
                        }
                        self.updateUI()
                    }
                    if shouldReconcileStoppedStatus {
                        self.refreshBridgeStatus(captureSelection: false, force: true)
                        self.recoverBridgeStatusSnapshotForActiveCommand()
                        self.updateActiveStatusReconcileLoopForCurrentStatus()
                    }
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.transcriptionReady) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshBridgeStatus(force: true)
                    self.recoverBridgeStatusSnapshotForActiveCommand()
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.keyboardDefaultsChanged) { [weak self] in
                DispatchQueue.main.async {
                    self?.refreshKeyboardPreferencesFromHost(rebuildIfNeeded: true)
                }
            },
        ]
    }

    private func configureTopRow() {
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.heightAnchor.constraint(equalToConstant: Self.topRowHeight).isActive = true

        // Inline status: just a colored dot and a label. No borders, no
        // background fill - keep the chrome quiet so the orb is the only
        // thing the eye lands on.
        statusGroup.axis = .horizontal
        statusGroup.spacing = 6
        statusGroup.alignment = .center
        statusGroup.translatesAutoresizingMaskIntoConstraints = false

        statusDot.backgroundColor = .systemGray3
        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.numberOfLines = 1
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        voiceTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        voiceTitleLabel.textColor = .label
        voiceTitleLabel.textAlignment = .center
        voiceTitleLabel.adjustsFontSizeToFitWidth = true
        voiceTitleLabel.minimumScaleFactor = 0.72
        voiceTitleLabel.numberOfLines = 1
        voiceTitleLabel.lineBreakMode = .byTruncatingTail
        voiceTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        voiceTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voiceTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Use the SAME toolbar-icon styling as the text-mode toolbar's mic /
        // waveform / gear so the chrome buttons feel like a single design
        // language across both keyboards: outlined SF Symbol, label tint,
        // no background, no shadow. Settings is also at the very top-right
        // in both modes, so users don't have to relocate it on focus switch.
        configureToolbarIconButton(settingsButton, image: "gearshape")
        settingsButton.accessibilityLabel = NSLocalizedString("Open Typeforme", comment: "Accessibility label for settings/host launcher button")
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: Self.topRowHeight).isActive = true
        settingsButton.addTarget(self, action: #selector(openHostFromSettingsButton), for: .touchUpInside)
        attachPressAnimation(settingsButton)

        configureToolbarIconButton(keyboardFocusButton, image: "keyboard")
        keyboardFocusButton.accessibilityLabel = NSLocalizedString("Show keyboard", comment: "Accessibility label for showing the screen keyboard")
        keyboardFocusButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardFocusButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        keyboardFocusButton.heightAnchor.constraint(equalToConstant: Self.topRowHeight).isActive = true
        keyboardFocusButton.addTarget(self, action: #selector(toggleKeyboardFocus), for: .touchUpInside)
        attachPressAnimation(keyboardFocusButton)

        topRowVoicePrint.translatesAutoresizingMaskIntoConstraints = false
        topRowVoicePrint.isUserInteractionEnabled = false
        topRowVoicePrint.tint = .systemRed
        topRowVoicePrint.alpha = 0
        topRowVoicePrint.accessibilityLabel = NSLocalizedString("Voice level", comment: "Accessibility label for the recording voiceprint")

        statusGroup.addArrangedSubview(statusDot)
        statusGroup.addArrangedSubview(statusLabel)
        topRow.addSubview(statusGroup)
        topRow.addSubview(voiceTitleLabel)
        topRow.addSubview(topRowVoicePrint)
        topRow.addSubview(keyboardFocusButton)
        topRow.addSubview(settingsButton)
        rootStack.addArrangedSubview(topRow)

        NSLayoutConstraint.activate([
            statusGroup.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: 6),
            statusGroup.centerYAnchor.constraint(equalTo: topRow.centerYAnchor, constant: Self.voiceTopRowContentVerticalOffset),
            statusGroup.trailingAnchor.constraint(lessThanOrEqualTo: voiceTitleLabel.leadingAnchor, constant: -8),

            voiceTitleLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            voiceTitleLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor, constant: Self.voiceTopRowContentVerticalOffset),
            voiceTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topRow.leadingAnchor, constant: 88),
            voiceTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyboardFocusButton.leadingAnchor, constant: -8),

            topRowVoicePrint.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            topRowVoicePrint.centerYAnchor.constraint(equalTo: topRow.centerYAnchor, constant: Self.voiceTopRowContentVerticalOffset),
            topRowVoicePrint.widthAnchor.constraint(equalToConstant: 160),
            topRowVoicePrint.heightAnchor.constraint(equalToConstant: 24),

            // Inter-icon spacing 4pt and right margin 0 from topRow trailing
            // (topRow is already inset by rootHorizontalInset). Matches the
            // text-mode toolbar so the keyboard-switch and settings icons
            // land in the same X positions across modes.
            keyboardFocusButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            keyboardFocusButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor, constant: Self.voiceTopRowContentVerticalOffset),

            settingsButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            settingsButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor, constant: Self.voiceTopRowContentVerticalOffset),
        ])
    }

    private func configureVoiceButton() {
        orbContainer.translatesAutoresizingMaskIntoConstraints = false
        orbContainer.isUserInteractionEnabled = true
        rootStack.addArrangedSubview(orbContainer)

        // Pulse rings: three concentric circles that bloom outward during
        // recording. Added FIRST so they sit below the orb in z-order.
        for _ in 0..<3 {
            let ring = CAShapeLayer()
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
            ring.lineWidth = 1.5
            ring.opacity = 0
            orbContainer.layer.addSublayer(ring)
            pulseRings.append(ring)
        }

        let diameter = Self.orbDiameter
        voiceButton.layer.cornerRadius = diameter / 2
        voiceButton.layer.cornerCurve = .continuous
        voiceButton.layer.shadowColor = UIColor.systemBlue.cgColor
        voiceButton.layer.shadowOpacity = isKeyboardDark ? 0.5 : 0.42
        voiceButton.layer.shadowRadius = 18
        voiceButton.layer.shadowOffset = CGSize(width: 0, height: 9)
        voiceButton.layer.borderWidth = 0.75
        voiceButton.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        voiceButton.translatesAutoresizingMaskIntoConstraints = false
        voiceButton.accessibilityLabel = NSLocalizedString("Dictate", comment: "Accessibility label for the orb")
        voiceButton.accessibilityTraits = .button
        voiceButton.isExclusiveTouch = true
        voiceButton.addTarget(self, action: #selector(voicePressDown), for: .touchDown)
        attachDragOutCancelTracker(voiceButton)
        voiceButton.addTarget(self, action: #selector(voicePressUp), for: .touchUpInside)
        // Hold mode: release outside the orb still ends the dictation (no
        // drag-out cancel — recording can only be ended, not aborted).
        voiceButton.addTarget(self, action: #selector(voicePressCancelled), for: [.touchUpOutside, .touchCancel])

        // Linear top-light → bottom-deep gradient. With a circular mask this
        // reads as a sphere; the inner highlight below adds the specular spot.
        voiceGradient.startPoint = CGPoint(x: 0.5, y: 0)
        voiceGradient.endPoint = CGPoint(x: 0.5, y: 1)
        voiceGradient.cornerRadius = diameter / 2
        voiceGradient.cornerCurve = .continuous
        voiceGradient.masksToBounds = true
        voiceButton.layer.insertSublayer(voiceGradient, at: 0)

        // Specular highlight as a radial gradient from white (center, 0.32
        // alpha) to fully transparent (edge). `CAGradientLayer` with
        // `.radial` type renders as a real soft blob on iOS — unlike a plain
        // CALayer with `compositingFilter = "screenBlendMode"`, which is a
        // macOS-only filter that on iOS just shows a hard-edged white patch.
        voiceHighlight.type = .radial
        voiceHighlight.colors = [
            UIColor.white.withAlphaComponent(0.32).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        voiceHighlight.locations = [0, 1]
        voiceHighlight.startPoint = CGPoint(x: 0.5, y: 0.5)
        voiceHighlight.endPoint = CGPoint(x: 1, y: 1)
        voiceButton.layer.addSublayer(voiceHighlight)

        voicePrint.translatesAutoresizingMaskIntoConstraints = false
        voicePrint.isUserInteractionEnabled = false
        voicePrint.tint = .white
        voicePrint.alpha = 0
        voiceButton.addSubview(voicePrint)

        voiceIconView.contentMode = .scaleAspectFit
        voiceIconView.tintColor = .white
        voiceIconView.translatesAutoresizingMaskIntoConstraints = false
        voiceIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .medium)
        voiceIconView.image = UIImage(systemName: "mic.fill")
        voiceButton.addSubview(voiceIconView)

        voiceSpinner.color = .white
        voiceSpinner.hidesWhenStopped = true
        voiceSpinner.translatesAutoresizingMaskIntoConstraints = false
        voiceButton.addSubview(voiceSpinner)

        configureCorrectionModePanel()
        configureInputModeSwitch()
        inputModeSwitch.onSelection = { [weak self] rawValue in
            self?.selectInputMode(rawValue)
        }
        configureVoiceSendButton()
        orbContainer.addSubview(correctionModePanel)
        orbContainer.addSubview(voiceSendButton)
        orbContainer.addSubview(voiceButton)
        orbContainer.addSubview(inputModeSwitch)

        // Popover (and its dismiss backdrop) float at the keyboard root so
        // they draw over orbContainer's siblings. Order matters: backdrop
        // added first → popover sits above it.
        view.addSubview(correctionPopoverDismissOverlay)
        view.addSubview(correctionPopover)
        NSLayoutConstraint.activate([
            correctionPopoverDismissOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            correctionPopoverDismissOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            correctionPopoverDismissOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            correctionPopoverDismissOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            correctionPopover.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            correctionPopover.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            // Centered on the keyboard view so the popover lands roughly over
            // the orb in voice mode AND over the keys area in text mode,
            // without needing per-mode constraint reshuffling.
            correctionPopover.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            correctionPopover.heightAnchor.constraint(equalToConstant: 60),
        ])

        orbContainerHeightConstraint = orbContainer.heightAnchor.constraint(
            equalToConstant: Self.orbContainerHeight(for: currentKeyboardContentHeight)
        )
        NSLayoutConstraint.activate([
            orbContainerHeightConstraint!,

            voiceButton.widthAnchor.constraint(equalToConstant: diameter),
            voiceButton.heightAnchor.constraint(equalToConstant: diameter),
            voiceButton.centerXAnchor.constraint(equalTo: orbContainer.centerXAnchor),
            voiceButton.centerYAnchor.constraint(equalTo: orbContainer.centerYAnchor),
            voiceButton.topAnchor.constraint(greaterThanOrEqualTo: orbContainer.topAnchor, constant: 2),
            voiceButton.bottomAnchor.constraint(lessThanOrEqualTo: orbContainer.bottomAnchor, constant: -2),

            voicePrint.leadingAnchor.constraint(equalTo: voiceButton.leadingAnchor, constant: 26),
            voicePrint.trailingAnchor.constraint(equalTo: voiceButton.trailingAnchor, constant: -26),
            voicePrint.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            voicePrint.heightAnchor.constraint(equalToConstant: 50),

            voiceIconView.centerXAnchor.constraint(equalTo: voiceButton.centerXAnchor),
            voiceIconView.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            voiceIconView.widthAnchor.constraint(equalToConstant: 56),
            voiceIconView.heightAnchor.constraint(equalToConstant: 56),

            voiceSpinner.centerXAnchor.constraint(equalTo: voiceButton.centerXAnchor),
            voiceSpinner.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),

            // Left column: voiceSendButton on top, correctionModePanel
            // below. 8pt gap between them; whole column centered on the
            // orb's vertical mid-line so the two buttons read as a paired
            // unit balanced against the Hold/Tap switch on the right.
            // 104pt wide fits the longest labels ("Structure+", "Return")
            // without text wrap, with adjustsFontSizeToFitWidth as fallback.
            voiceSendButton.leadingAnchor.constraint(equalTo: orbContainer.leadingAnchor, constant: 10),
            voiceSendButton.trailingAnchor.constraint(lessThanOrEqualTo: voiceButton.leadingAnchor, constant: -8),
            voiceSendButton.widthAnchor.constraint(equalToConstant: 104),
            voiceSendButton.heightAnchor.constraint(equalToConstant: 42),
            voiceSendButton.bottomAnchor.constraint(equalTo: voiceButton.centerYAnchor, constant: -5),

            correctionModePanel.leadingAnchor.constraint(equalTo: orbContainer.leadingAnchor, constant: 10),
            correctionModePanel.trailingAnchor.constraint(lessThanOrEqualTo: voiceButton.leadingAnchor, constant: -8),
            correctionModePanel.topAnchor.constraint(equalTo: voiceButton.centerYAnchor, constant: 5),
            correctionModePanel.widthAnchor.constraint(equalToConstant: 104),
            correctionModePanel.heightAnchor.constraint(equalToConstant: 42),

            inputModeSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: voiceButton.trailingAnchor, constant: 8),
            inputModeSwitch.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            inputModeSwitch.trailingAnchor.constraint(equalTo: orbContainer.trailingAnchor, constant: -14),
            inputModeSwitch.widthAnchor.constraint(equalToConstant: 68),
            inputModeSwitch.heightAnchor.constraint(equalToConstant: 82),
        ])
    }

    private func configureInputModeSwitch() {
        inputModeSwitch.translatesAutoresizingMaskIntoConstraints = false
        if inputModeSwitch.mode != inputMode.rawValue {
            inputModeSwitch.mode = inputMode.rawValue
        }
        // inputMode.idleTitle is already localized ("Hold to Speak" / "Tap to Speak").
        inputModeSwitch.accessibilityLabel = inputMode.idleTitle
    }

    private func configureVoiceSendButton() {
        voiceSendButton.translatesAutoresizingMaskIntoConstraints = false
        voiceSendButton.hitInsets = UIEdgeInsets(top: -4, left: -4, bottom: -4, right: -4)
        voiceSendButton.accessibilityLabel = NSLocalizedString("发送听写文本", comment: "Accessibility label for voice-mode send button")
        voiceSendButton.addTarget(self, action: #selector(voiceSendTapped), for: .touchUpInside)
        attachPressAnimation(voiceSendButton)
        applyVoiceSendButtonConfiguration()
    }

    /// `\n` only triggers "send" when the host's returnKeyType is one of
    /// .send/.go/.search/etc. In Notes / Mail body / freeform compose
    /// fields, the same character is a literal newline. So the button label
    /// follows the host's reported intent — e.g., "发送" in iMessage,
    /// "换行" in Notes.
    /// Visual: filled blue with paperplane to stand apart from the gray
    /// frosted Refine picker directly below it. The two stacked buttons
    /// would otherwise be indistinguishable.
    private func applyVoiceSendButtonConfiguration() {
        var configuration = UIButton.Configuration.filled()
        configuration.title = voiceSendButtonTitle
        configuration.image = UIImage(systemName: "paperplane.fill")
        configuration.imagePlacement = .leading
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let font: UIFont = voiceSendButtonTitle.count > 4
            ? .systemFont(ofSize: 13, weight: .semibold)
            : .systemFont(ofSize: 15, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        voiceSendButton.configuration = configuration
        voiceSendButton.titleLabel?.numberOfLines = 1
        voiceSendButton.titleLabel?.lineBreakMode = .byTruncatingTail
        voiceSendButton.titleLabel?.adjustsFontSizeToFitWidth = true
        voiceSendButton.titleLabel?.minimumScaleFactor = 0.7
    }

    private var voiceSendButtonTitle: String {
        let contextual = returnKeyTitle
        if !contextual.isEmpty { return contextual }
        return textInputLanguage == .chinese
            ? NSLocalizedString("换行", comment: "Voice send button default title (Chinese)")
            : NSLocalizedString("return", comment: "Voice send button default title (English)")
    }

    @objc private func voiceSendTapped() {
        // Insert a newline — host decides if that's "send" (chat apps) or
        // an actual newline (notes / mail / compose). Same path the text
        // Return key uses.
        guard currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending,
              !isStartRequestInFlight
        else { return }
        clearRefineUndoStateForManualEdit()
        textDocumentProxy.insertText("\n")
        lightHaptic()
    }

    private func configureCorrectionModePanel() {
        correctionModePanel.translatesAutoresizingMaskIntoConstraints = false
        correctionModeButtons.removeAll()

        // Trigger inside the panel: a single capsule showing the current
        // preset + chevron. Tap to expand the floating popover.
        correctionModeTrigger.translatesAutoresizingMaskIntoConstraints = false
        correctionModeTrigger.addTarget(self, action: #selector(toggleCorrectionPopover), for: .touchUpInside)
        attachPressAnimation(correctionModeTrigger)
        correctionModePanel.addSubview(correctionModeTrigger)
        NSLayoutConstraint.activate([
            correctionModeTrigger.leadingAnchor.constraint(equalTo: correctionModePanel.leadingAnchor),
            correctionModeTrigger.trailingAnchor.constraint(equalTo: correctionModePanel.trailingAnchor),
            correctionModeTrigger.centerYAnchor.constraint(equalTo: correctionModePanel.centerYAnchor),
            correctionModeTrigger.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Popover lives at the keyboard root so it floats above orbContainer
        // siblings. Hidden by default; `showCorrectionPopover` reveals it.
        correctionPopover.translatesAutoresizingMaskIntoConstraints = false
        correctionPopover.backgroundColor = UIColor.secondarySystemBackground
            .withAlphaComponent(isKeyboardDark ? 0.94 : 0.98)
        correctionPopover.layer.cornerRadius = 18
        correctionPopover.layer.cornerCurve = .continuous
        correctionPopover.layer.borderWidth = 0.5
        correctionPopover.layer.borderColor = UIColor.separator.cgColor
        correctionPopover.layer.shadowColor = UIColor.black.cgColor
        correctionPopover.layer.shadowOpacity = 0.18
        correctionPopover.layer.shadowRadius = 14
        correctionPopover.layer.shadowOffset = CGSize(width: 0, height: 6)
        correctionPopover.isHidden = true
        correctionPopover.alpha = 0

        correctionPopoverStack.axis = .horizontal
        correctionPopoverStack.spacing = 6
        correctionPopoverStack.alignment = .fill
        correctionPopoverStack.distribution = .fillEqually
        correctionPopoverStack.translatesAutoresizingMaskIntoConstraints = false
        correctionPopover.addSubview(correctionPopoverStack)
        NSLayoutConstraint.activate([
            correctionPopoverStack.leadingAnchor.constraint(equalTo: correctionPopover.leadingAnchor, constant: 10),
            correctionPopoverStack.trailingAnchor.constraint(equalTo: correctionPopover.trailingAnchor, constant: -10),
            correctionPopoverStack.topAnchor.constraint(equalTo: correctionPopover.topAnchor, constant: 8),
            correctionPopoverStack.bottomAnchor.constraint(equalTo: correctionPopover.bottomAnchor, constant: -8),
        ])

        // Backdrop fills the keyboard so any outside tap dismisses.
        correctionPopoverDismissOverlay.translatesAutoresizingMaskIntoConstraints = false
        correctionPopoverDismissOverlay.backgroundColor = UIColor.black.withAlphaComponent(0)
        correctionPopoverDismissOverlay.isHidden = true
        correctionPopoverDismissOverlay.addTarget(self, action: #selector(hideCorrectionPopover), for: .touchUpInside)

        for preset in CorrectionMode.allCases {
            let button = UIButton(type: .system)
            configureCorrectionModeButton(button, preset: preset)
            button.addTarget(self, action: #selector(selectCorrectionModeButton(_:)), for: .touchUpInside)
            attachPressAnimation(button)
            correctionModeButtons.append((preset, button))
            correctionPopoverStack.addArrangedSubview(button)
        }
        updateCorrectionModeButtons()
    }

    private func configureCorrectionModeButton(_ button: UIButton, preset: CorrectionMode) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = preset.title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityLabel = preset.title
        // Force single-line + shrink-to-fit. Without this, "Structure+" wraps
        // the "+" onto a second line on phones where the per-button slot is
        // tight. Tested on iPhone 17 Pro Max.
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        // 44pt minimum height for the popover row to meet HIG.
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutKeyboardContentViewForCurrentBounds()
        keyboardContentView.layoutIfNeeded()
        voiceGradient.frame = voiceButton.bounds

        // Position the specular ellipse upper-left, matching the host app's
        // proportions (ellipse center at 0.34, 0.28 of orb diameter). Width
        // 0.55x diameter, height 0.32x → soft horizontal sheen.
        let diameter = Self.orbDiameter
        let highlightWidth = diameter * 0.55
        let highlightHeight = diameter * 0.32
        voiceHighlight.frame = CGRect(
            x: diameter * 0.34 - highlightWidth / 2,
            y: diameter * 0.28 - highlightHeight / 2,
            width: highlightWidth,
            height: highlightHeight
        )

        // Pulse rings: same diameter as the orb, centered on the orb's center
        // within `orbContainer`. They scale outward up to 1.7x during recording.
        let center = voiceButton.center
        for ring in pulseRings {
            ring.frame = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            // Path geometry depends only on the constant orb diameter; build
            // it once instead of allocating a CGPath on every layout pass.
            if ring.path == nil {
                ring.path = UIBezierPath(
                    ovalIn: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
                ).cgPath
            }
        }
        updateCandidateScrollViewport()
        updateCandidateGridCollapseButtonFrame()
        updateKeyboardSurfaceMask()
        updateCandidateTextOverlay()
        applyToolbarIconLayoutTweaks()
        updateKeyboardOverlayOrdering()
        setKeyboardContentVisible(true)
        logKeyboardPresentationGateIfUnstable()
        logKeyboardStartupSnapshot("layout")
        logKeyboardPresentationLayout("layout")
        logKeyboardTouchSurfaceLayoutIfNeeded()
        CATransaction.commit()
    }

    private func applyToolbarIconLayoutTweaks() {
        let toolbarIconTransform = CGAffineTransform(
            translationX: 0,
            y: Self.toolbarIconVerticalOffset
        )
        [
            settingsButton,
            keyboardFocusButton,
            textWandButton,
            textStylePickerButton,
            textUndoButton,
            textToolsButton,
            textKeyboardSwitchButton,
            textHostSettingsButton,
        ].forEach { button in
            button.imageView?.transform = toolbarIconTransform
        }
        textCandidateGridButton.imageView?.transform = .identity
        candidateGridCollapseButton.imageView?.transform = .identity
    }

    private func logKeyboardTouchSurfaceLayoutIfNeeded() {
        // Runs on every layout pass; the dedupe key alone costs several rect
        // conversions plus a hit-band computation, so gate the whole thing
        // behind the same flag as the touch event trace.
        guard defaults.bool(forKey: keyboardTouchTraceEnabledKey) else { return }
        let surfaceFrame = view.bounds.integral
        let viewFrame = view.frame.integral
        let superviewFrame = view.superview?.frame.integral ?? .zero
        let windowFrame = view.convert(view.bounds, to: nil).integral
        let contentFrame = keyboardContentView.frame.integral
        let rootFrame = rootStack.convert(rootStack.bounds, to: view).integral
        let safeInsets = view.safeAreaInsets
        let characterBand = textCharacterTouchBandFrame()?.integral
        let bandX = characterBand.map { Int($0.minX) } ?? -1
        let bandY = characterBand.map { Int($0.minY) } ?? -1
        let bandWidth = characterBand.map { Int($0.width) } ?? 0
        let bandHeight = characterBand.map { Int($0.height) } ?? 0
        let key = "\(Int(surfaceFrame.width))x\(Int(surfaceFrame.height))|\(Int(windowFrame.minY))|\(Int(contentFrame.minY))|\(bandY)-\(bandY + bandHeight)|\(keyboardFocus.rawValue)"
        guard key != lastTouchSurfaceLayoutLogKey else { return }
        lastTouchSurfaceLayoutLogKey = key
        kbLog.notice("touch layout surface=(\(Int(surfaceFrame.minX), privacy: .public),\(Int(surfaceFrame.minY), privacy: .public),\(Int(surfaceFrame.width), privacy: .public),\(Int(surfaceFrame.height), privacy: .public)) viewFrame=(\(Int(viewFrame.minX), privacy: .public),\(Int(viewFrame.minY), privacy: .public),\(Int(viewFrame.width), privacy: .public),\(Int(viewFrame.height), privacy: .public)) super=(\(Int(superviewFrame.minX), privacy: .public),\(Int(superviewFrame.minY), privacy: .public),\(Int(superviewFrame.width), privacy: .public),\(Int(superviewFrame.height), privacy: .public)) window=(\(Int(windowFrame.minX), privacy: .public),\(Int(windowFrame.minY), privacy: .public),\(Int(windowFrame.width), privacy: .public),\(Int(windowFrame.height), privacy: .public)) content=(\(Int(contentFrame.minX), privacy: .public),\(Int(contentFrame.minY), privacy: .public),\(Int(contentFrame.width), privacy: .public),\(Int(contentFrame.height), privacy: .public)) root=(\(Int(rootFrame.minX), privacy: .public),\(Int(rootFrame.minY), privacy: .public),\(Int(rootFrame.width), privacy: .public),\(Int(rootFrame.height), privacy: .public)) safe=(\(Int(safeInsets.left), privacy: .public),\(Int(safeInsets.top), privacy: .public),\(Int(safeInsets.right), privacy: .public),\(Int(safeInsets.bottom), privacy: .public)) charBand=(\(bandX, privacy: .public),\(bandY, privacy: .public),\(bandWidth, privacy: .public),\(bandHeight, privacy: .public)) focus=\(self.keyboardFocus.rawValue, privacy: .public)")
    }

    private func logKeyboardStartupSnapshot(_ event: String, force: Bool = false) {
        guard isViewLoaded else { return }
        if didLogReadyKeyboardSnapshot, !force {
            return
        }
        let surfaceFrame = view.bounds
        let viewFrame = view.frame
        let windowFrame = view.convert(view.bounds, to: nil)
        let hostWindowFrame = view.window?.frame
        let contentFrame = frameInController(keyboardContentView)
        let rootFrame = frameInController(rootStack)
        let counts = keyboardControlCounts(in: rootStack)
        let hasReadyFrame = surfaceFrame.width > 1
            && surfaceFrame.height > 1
            && (rootFrame?.width ?? 0) > 1
            && (rootFrame?.height ?? 0) > 1
            && keyboardContentView.alpha > 0.01
            && !rootStack.isHidden
            && counts.visible > 0

        guard force || keyboardStartupSnapshotCount < 12 || (hasReadyFrame && !didLogReadyKeyboardSnapshot) else {
            return
        }
        keyboardStartupSnapshotCount += 1
        if hasReadyFrame {
            didLogReadyKeyboardSnapshot = true
        }
        let elapsedMS = (CACurrentMediaTime() - keyboardLifecycleStartedAt) * 1000
        kbLog.notice("keyboard startup event=\(event, privacy: .public) elapsedMs=\(elapsedMS, privacy: .public) readyFrame=\(hasReadyFrame, privacy: .public) fullAccess=\(self.hasFullAccess, privacy: .public) focus=\(self.keyboardFocus.rawValue, privacy: .public) hasWindow=\((self.view.window != nil), privacy: .public) surface=\(self.frameLogString(surfaceFrame), privacy: .public) view=\(self.frameLogString(viewFrame), privacy: .public) window=\(self.frameLogString(windowFrame), privacy: .public) hostWindow=\(self.frameLogString(hostWindowFrame), privacy: .public) content=\(self.frameLogString(contentFrame), privacy: .public) root=\(self.frameLogString(rootFrame), privacy: .public) contentAlpha=\(self.valueLogString(self.keyboardContentView.alpha), privacy: .public) rootHidden=\(self.rootStack.isHidden, privacy: .public) visibleControls=\(counts.visible, privacy: .public) totalControls=\(counts.total, privacy: .public)")
    }

    private func keyboardControlCounts(in view: UIView, ancestorsVisible: Bool = true) -> (visible: Int, total: Int) {
        let isControl = view is UIControl
        let subtreeVisible = ancestorsVisible
            && !view.isHidden
            && view.alpha > 0.01
            && view.window != nil
        let isVisibleControl = isControl
            && subtreeVisible
            && view.bounds.width > 0
            && view.bounds.height > 0
        var visible = isVisibleControl ? 1 : 0
        var total = isControl ? 1 : 0
        for subview in view.subviews {
            let counts = keyboardControlCounts(in: subview, ancestorsVisible: subtreeVisible)
            visible += counts.visible
            total += counts.total
        }
        return (visible: visible, total: total)
    }

    private func logKeyboardPresentationLayout(_ event: String, force: Bool = false) {
        guard isViewLoaded else { return }
        guard defaults.bool(forKey: keyboardTouchTraceEnabledKey) else { return }

        let surfaceFrame = view.bounds
        let viewFrame = view.frame
        let superviewFrame = view.superview?.frame
        let windowFrame = view.convert(view.bounds, to: nil)
        let hostWindowFrame = view.window?.frame
        let surfaceBackgroundFrame = frameInController(keyboardSurfaceView)
        let contentFrame = keyboardContentView.frame
        let touchOverlayFrame = keyboardTouchOverlay.frame
        let rootFrame = frameInController(rootStack)
        let toolbarFrame = frameInController(textToolbar)
        let keyRowsFrame = frameInController(keyRowsStack)
        let voiceSettingsFrame = frameInController(settingsButton)
        let voiceSwitchFrame = frameInController(keyboardFocusButton)
        let textSwitchFrame = frameInController(textKeyboardSwitchButton)
        let textSettingsFrame = frameInController(textHostSettingsButton)
        let textSettingsIconFrame = frameInController(textHostSettingsButton.imageView)
        let textSwitchIconFrame = frameInController(textKeyboardSwitchButton.imageView)
        let toolbarTopGap = toolbarFrame.map { $0.minY - contentFrame.minY } ?? -1
        let toolbarKeyGap: CGFloat
        if let toolbarFrame, let keyRowsFrame {
            toolbarKeyGap = keyRowsFrame.minY - toolbarFrame.maxY
        } else {
            toolbarKeyGap = -1
        }

        let key = [
            event,
            frameLogString(surfaceFrame),
            frameLogString(viewFrame),
            frameLogString(windowFrame),
            frameLogString(surfaceBackgroundFrame),
            frameLogString(contentFrame),
            frameLogString(touchOverlayFrame),
            frameLogString(toolbarFrame),
            frameLogString(keyRowsFrame),
            String(format: "%.1f", Double(toolbarTopGap)),
            String(format: "%.1f", Double(toolbarKeyGap)),
            keyboardFocus.rawValue,
        ].joined(separator: "|")
        guard force || key != lastKeyboardPresentationLayoutLogKey else { return }
        guard force || keyboardPresentationLayoutLogCount < 80 else { return }
        lastKeyboardPresentationLayoutLogKey = key
        keyboardPresentationLayoutLogCount += 1
        let effectiveHeight = effectiveKeyboardContentHeight

        kbLog.notice("present layout event=\(event, privacy: .public) focus=\(self.keyboardFocus.rawValue, privacy: .public) surface=\(self.frameLogString(surfaceFrame), privacy: .public) view=\(self.frameLogString(viewFrame), privacy: .public) super=\(self.frameLogString(superviewFrame), privacy: .public) window=\(self.frameLogString(windowFrame), privacy: .public) hostWindow=\(self.frameLogString(hostWindowFrame), privacy: .public) surfaceView=\(self.frameLogString(surfaceBackgroundFrame), privacy: .public) content=\(self.frameLogString(contentFrame), privacy: .public) touchOverlay=\(self.frameLogString(touchOverlayFrame), privacy: .public) root=\(self.frameLogString(rootFrame), privacy: .public) effectiveH=\(self.valueLogString(effectiveHeight), privacy: .public) safe=\(self.insetsLogString(self.view.safeAreaInsets), privacy: .public)")
        kbLog.notice("toolbar layout event=\(event, privacy: .public) toolbar=\(self.frameLogString(toolbarFrame), privacy: .public) keys=\(self.frameLogString(keyRowsFrame), privacy: .public) topGap=\(self.valueLogString(toolbarTopGap), privacy: .public) keyGap=\(self.valueLogString(toolbarKeyGap), privacy: .public) voiceSwitch=\(self.frameLogString(voiceSwitchFrame), privacy: .public) voiceSettings=\(self.frameLogString(voiceSettingsFrame), privacy: .public) textSwitch=\(self.frameLogString(textSwitchFrame), privacy: .public) textSettings=\(self.frameLogString(textSettingsFrame), privacy: .public) textSwitchIcon=\(self.frameLogString(textSwitchIconFrame), privacy: .public) textSettingsIcon=\(self.frameLogString(textSettingsIconFrame), privacy: .public)")
    }

    private func frameInController(_ targetView: UIView?) -> CGRect? {
        guard let targetView,
              targetView.superview != nil || targetView === view
        else { return nil }
        return targetView.convert(targetView.bounds, to: view)
    }

    private func frameLogString(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return frameLogString(frame)
    }

    private func frameLogString(_ frame: CGRect) -> String {
        String(
            format: "%.1f,%.1f %.1fx%.1f",
            Double(frame.minX),
            Double(frame.minY),
            Double(frame.width),
            Double(frame.height)
        )
    }

    private func insetsLogString(_ insets: UIEdgeInsets) -> String {
        String(
            format: "%.1f,%.1f,%.1f,%.1f",
            Double(insets.left),
            Double(insets.top),
            Double(insets.right),
            Double(insets.bottom)
        )
    }

    private func valueLogString(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func configureUtilityRow() {
        utilityRow.axis = .horizontal
        utilityRow.spacing = 6
        utilityRow.alignment = .fill
        utilityRow.distribution = .fill
        utilityRow.heightAnchor.constraint(equalToConstant: Self.utilityRowHeight).isActive = true

        configureCapsuleButton(commandButton, title: "", image: "wand.and.stars", style: .utility)
        commandButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        commandButton.accessibilityLabel = NSLocalizedString("Command input", comment: "Accessibility label for command/edit-input button")
        commandButton.addTarget(self, action: #selector(commandPressDown), for: [.touchDown, .touchDragEnter])
        attachDragOutCancelTracker(commandButton)
        commandButton.addTarget(self, action: #selector(commandPressUp), for: .touchUpInside)
        commandButton.addTarget(self, action: #selector(commandPressCancelled), for: [.touchUpOutside, .touchCancel, .touchDragExit])

        configureCapsuleButton(voiceUndoButton, title: "", image: "arrow.uturn.backward", style: .utility)
        voiceUndoButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        voiceUndoButton.accessibilityLabel = NSLocalizedString("Undo refine", comment: "Accessibility label for undoing the latest refine")
        voiceUndoButton.addTarget(self, action: #selector(undoRefineTapped), for: .touchUpInside)
        attachPressAnimation(voiceUndoButton)

        configureCapsuleButton(spaceButton, title: "space", image: nil, style: .key)
        spaceButton.addTarget(self, action: #selector(insertSpace), for: .touchDown)
        attachPressAnimation(spaceButton)

        configureCapsuleButton(deleteButton, title: "", image: "delete.left", style: .utility)
        deleteButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        deleteButton.addTarget(self, action: #selector(deletePressDown), for: [.touchDown, .touchDragEnter])
        deleteButton.addTarget(self, action: #selector(deletePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        attachPressAnimation(deleteButton)

        configureCapsuleButton(returnButton, title: "return", image: nil, style: .utility)
        returnButton.widthAnchor.constraint(equalToConstant: 78).isActive = true
        returnButton.addTarget(self, action: #selector(insertReturn), for: .touchDown)
        attachPressAnimation(returnButton)

        utilityRow.addArrangedSubview(commandButton)
        utilityRow.addArrangedSubview(voiceUndoButton)
        utilityRow.addArrangedSubview(spaceButton)
        utilityRow.addArrangedSubview(deleteButton)
        utilityRow.addArrangedSubview(returnButton)
        rootStack.addArrangedSubview(utilityRow)
    }

    private func configureTextKeyboard() {
        textKeyboardContainer.axis = .vertical
        textKeyboardContainer.spacing = Self.textKeyboardToolbarKeyGap
        textKeyboardContainer.alignment = .fill
        textKeyboardContainer.distribution = .fill
        textKeyboardContainer.isLayoutMarginsRelativeArrangement = true
        textKeyboardContainer.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Self.textKeyboardTopProtectionInset,
            leading: 0,
            bottom: 0,
            trailing: 0
        )
        textKeyboardContainerHeightConstraint = textKeyboardContainer.heightAnchor.constraint(
            equalToConstant: Self.textKeyboardBodyHeight(for: currentKeyboardContentHeight)
        )
        textKeyboardContainerHeightConstraint?.isActive = true

        textToolbar.axis = .horizontal
        textToolbar.spacing = 4
        textToolbar.alignment = .fill
        textToolbar.distribution = .fill
        textToolbar.heightAnchor.constraint(equalToConstant: Self.candidateToolbarHeight).isActive = true

        // Wand (voice-command edit current input) — text-mode users
        // already have fingers on keys, so press-and-hold is awkward. Use
        // tap-toggle instead: first tap starts the command recording, second
        // tap ends it. The voice-mode commandButton keeps its hold contract.
        configureToolbarIconButton(textWandButton, image: "wand.and.stars")
        textWandButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textWandButton.accessibilityLabel = NSLocalizedString("Command input", comment: "Accessibility label for command/edit-input button")
        textWandButton.addTarget(self, action: #selector(textWandTapped), for: .touchUpInside)
        attachPressAnimation(textWandButton)

        // Preset picker — opens the same correctionPopover as the voice-mode
        // correctionModeTrigger, so text-mode users have on-demand access to
        // the 4 style chips (Clean / Polish+ / Structure+ / Formal+)
        // without having to dictate first. Paint-brush icon distinguishes it
        // from the wand (wand = free-form voice command, picker = preset).
        configureToolbarIconButton(textStylePickerButton, image: "paintbrush")
        textStylePickerButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textStylePickerButton.accessibilityLabel = NSLocalizedString("Pick refine style", comment: "Accessibility label for text-mode style preset picker")
        textStylePickerButton.addTarget(self, action: #selector(toggleCorrectionPopover), for: .touchUpInside)
        attachPressAnimation(textStylePickerButton)

        configureToolbarIconButton(textUndoButton, image: "arrow.uturn.backward")
        textUndoButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textUndoButton.accessibilityLabel = NSLocalizedString("Undo refine", comment: "Accessibility label for undoing the latest refine")
        textUndoButton.addTarget(self, action: #selector(undoRefineTapped), for: .touchUpInside)
        attachPressAnimation(textUndoButton)

        configureToolbarIconButton(textToolsButton, image: "mic.fill")
        textToolsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textToolsButton.accessibilityLabel = NSLocalizedString("Dictate", comment: "Accessibility label for keyboard dictation button")
        textToolsButton.addTarget(self, action: #selector(textVoiceTapped), for: .touchUpInside)
        textToolsButton.showsMenuAsPrimaryAction = false
        attachPressAnimation(textToolsButton)

        // Readiness dot mirrors the orb's badge (top-right of the mic glyph).
        // Toolbar mic glyph is system-sized inside a 32pt button, so a smaller
        // diameter + thinner border keeps the dot from swallowing the icon.
        configureReadyDot(textToolsReadyDot, diameter: Self.textToolsReadyDotDiameter, borderWidth: 1.0)
        textToolsButton.addSubview(textToolsReadyDot)
        NSLayoutConstraint.activate([
            textToolsReadyDot.widthAnchor.constraint(equalToConstant: Self.textToolsReadyDotDiameter),
            textToolsReadyDot.heightAnchor.constraint(equalToConstant: Self.textToolsReadyDotDiameter),
            textToolsReadyDot.trailingAnchor.constraint(equalTo: textToolsButton.trailingAnchor, constant: -1),
            textToolsReadyDot.topAnchor.constraint(equalTo: textToolsButton.topAnchor, constant: 1),
        ])

        configureToolbarIconButton(textKeyboardSwitchButton, image: "waveform")
        textKeyboardSwitchButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textKeyboardSwitchButton.accessibilityLabel = NSLocalizedString("Show voice input", comment: "Accessibility label for switching to voice input")
        textKeyboardSwitchButton.addTarget(self, action: #selector(showVoiceFocus), for: .touchUpInside)
        attachPressAnimation(textKeyboardSwitchButton)

        configureToolbarIconButton(textHostSettingsButton, image: "gearshape")
        textHostSettingsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textHostSettingsButton.accessibilityLabel = NSLocalizedString("Open Typeforme", comment: "Accessibility label for opening host settings")
        textHostSettingsButton.addTarget(self, action: #selector(openHostFromSettingsButton), for: .touchUpInside)
        attachPressAnimation(textHostSettingsButton)

        configureCandidateExpandButton(isExpanded: false)
        textCandidateGridButton.widthAnchor.constraint(equalToConstant: Self.candidateExpandButtonWidth).isActive = true
        // Keep the visible chevron and its touch overflow coupled; the
        // candidate scroll/grid recognizers route taps in the surrounding
        // action column back to this same button.
        textCandidateGridButton.hitInsets = UIEdgeInsets(
            top: -Self.candidateExpandTouchOverflowY,
            left: -Self.candidateActionColumnGap,
            bottom: -Self.candidateExpandTouchOverflowY,
            right: -Self.candidateActionColumnGap
        )
        textCandidateGridButton.accessibilityLabel = NSLocalizedString("Show more candidates", comment: "Accessibility label for expanding candidate list")
        textCandidateGridButton.isHidden = true
        textCandidateGridButton.addTarget(self, action: #selector(toggleCandidateGrid), for: .touchUpInside)
        attachPressAnimation(textCandidateGridButton)

        configureCandidateGridCollapseButton(isExpanded: true)
        candidateGridCollapseButton.hitInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        candidateGridCollapseButton.accessibilityLabel = NSLocalizedString("Hide candidates", comment: "Accessibility label for collapsing candidate list")
        candidateGridCollapseButton.isHidden = true
        candidateGridCollapseButton.addTarget(self, action: #selector(toggleCandidateGrid), for: .touchUpInside)
        attachPressAnimation(candidateGridCollapseButton)
        view.addSubview(candidateGridCollapseButton)

        candidateScrollView.showsHorizontalScrollIndicator = false
        candidateScrollView.alwaysBounceHorizontal = true
        // Cells are now `isUserInteractionEnabled = false`, so the scroll
        // view's pan recognizer owns all touches without competing against
        // UIControl tracking. delaysContentTouches=false then just means
        // the empty hit-test fall-through reaches the scroll view as fast
        // as possible.
        candidateScrollView.delaysContentTouches = false
        candidateScrollView.canCancelContentTouches = true
        candidateScrollView.isDirectionalLockEnabled = true
        // Drives the windowed candidate rendering: scrolling toward the
        // rendered edge appends the next chunk (scrollViewDidScroll).
        candidateScrollView.delegate = self
        candidateScrollView.addGestureRecognizer(candidateScrollTapRecognizer)
        candidateScrollView.addGestureRecognizer(candidateLongPressRecognizer)
        // UIScrollView's clipsToBounds default is false — without this, the
        // last candidate near the right edge can render under the chevron.
        candidateScrollView.clipsToBounds = true
        candidateScrollView.heightAnchor.constraint(equalToConstant: Self.candidateToolbarHeight).isActive = true
        candidateScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        candidateStack.axis = .horizontal
        candidateStack.spacing = Self.topCandidateSpacing
        candidateStack.alignment = .fill
        candidateStack.distribution = .fill
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScrollView.addSubview(candidateStack)

        candidateTrailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        candidateTrailingSpacer.isUserInteractionEnabled = false
        candidateTrailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateTrailingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScrollView.frameLayoutGuide.heightAnchor),
        ])
        candidateGridScrollView.showsVerticalScrollIndicator = false
        candidateGridScrollView.alwaysBounceVertical = true
        candidateGridScrollView.delaysContentTouches = false
        candidateGridScrollView.canCancelContentTouches = true
        candidateGridScrollView.isDirectionalLockEnabled = true
        candidateGridScrollView.delegate = self
        candidateGridScrollView.addGestureRecognizer(candidateGridTapRecognizer)
        candidateGridScrollView.clipsToBounds = true
        candidateGridScrollView.isHidden = true

        candidateGridStack.axis = .vertical
        candidateGridStack.spacing = 0
        candidateGridStack.alignment = .leading
        candidateGridStack.distribution = .fill
        candidateGridStack.isUserInteractionEnabled = false
        candidateGridStack.translatesAutoresizingMaskIntoConstraints = false
        candidateGridScrollView.addSubview(candidateGridStack)
        NSLayoutConstraint.activate([
            candidateGridStack.leadingAnchor.constraint(equalTo: candidateGridScrollView.contentLayoutGuide.leadingAnchor),
            candidateGridStack.trailingAnchor.constraint(equalTo: candidateGridScrollView.contentLayoutGuide.trailingAnchor),
            candidateGridStack.topAnchor.constraint(equalTo: candidateGridScrollView.contentLayoutGuide.topAnchor),
            candidateGridStack.bottomAnchor.constraint(equalTo: candidateGridScrollView.contentLayoutGuide.bottomAnchor),
            candidateGridStack.widthAnchor.constraint(equalTo: candidateGridScrollView.frameLayoutGuide.widthAnchor),
        ])

        keyRowsStack.axis = .vertical
        keyRowsStack.spacing = TextKeyboardLayoutModel.keyVerticalGap
        keyRowsStack.alignment = .fill
        keyRowsStack.distribution = .fillEqually
        textTrackpadPanRecognizer.isEnabled = false
        textTrackpadPanRecognizer.cancelsTouchesInView = true
        textKeyboardContainer.addGestureRecognizer(textTrackpadPanRecognizer)

        configureTextControlButton(textModeButton, title: "123", image: nil)
        textModeButton.widthAnchor.constraint(equalToConstant: TextKeyboardLayoutModel.bottomModeKeyWidth).isActive = true
        textModeButton.addTarget(self, action: #selector(toggleSymbolKeyboard), for: .touchUpInside)
        attachPressAnimation(textModeButton)

        configureTextControlButton(textAlternateSymbolButton, title: "#+=", image: nil)
        textAlternateSymbolButton.addTarget(self, action: #selector(toggleAlternateSymbolKeyboard), for: .touchUpInside)
        attachPressAnimation(textAlternateSymbolButton)

        configureTextControlButton(textGlobeButton, title: "", image: "globe")
        textGlobeButton.widthAnchor.constraint(equalToConstant: TextKeyboardLayoutModel.bottomGlobeKeyWidth).isActive = true
        textGlobeButton.accessibilityLabel = NSLocalizedString("Next keyboard", comment: "Accessibility label for switching to the next keyboard")
        textGlobeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        attachPressAnimation(textGlobeButton)

        configureTextLanguageButton()
        textLanguageButton.widthAnchor.constraint(equalToConstant: TextKeyboardLayoutModel.bottomLanguageKeyWidth).isActive = true
        textLanguageButton.addTarget(self, action: #selector(toggleTextInputLanguage), for: .touchUpInside)
        attachPressAnimation(textLanguageButton)

        textLanguageLabel.translatesAutoresizingMaskIntoConstraints = false
        textLanguageLabel.isUserInteractionEnabled = false
        textLanguageLabel.textAlignment = .center
        textLanguageLabel.adjustsFontSizeToFitWidth = true
        textLanguageLabel.minimumScaleFactor = 0.7
        textLanguageButton.addSubview(textLanguageLabel)
        NSLayoutConstraint.activate([
            textLanguageLabel.centerXAnchor.constraint(equalTo: textLanguageButton.centerXAnchor),
            textLanguageLabel.centerYAnchor.constraint(equalTo: textLanguageButton.centerYAnchor),
            textLanguageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textLanguageButton.leadingAnchor, constant: 4),
            textLanguageLabel.trailingAnchor.constraint(lessThanOrEqualTo: textLanguageButton.trailingAnchor, constant: -4),
        ])

        textKeyboardContainer.addArrangedSubview(textToolbar)
        textToolbar.addArrangedSubview(textToolsButton)
        textToolbar.addArrangedSubview(textStylePickerButton)
        textToolbar.addArrangedSubview(textUndoButton)
        textToolbar.addArrangedSubview(textWandButton)
        textToolbar.addArrangedSubview(candidateScrollView)
        textToolbar.addArrangedSubview(textCandidateGridButton)
        textToolbar.setCustomSpacing(0, after: candidateScrollView)
        textToolbar.addArrangedSubview(textKeyboardSwitchButton)
        textToolbar.addArrangedSubview(textHostSettingsButton)

        // Overlay shown during text-mode recording; covers the toolbar slots
        // visually. Non-arranged subview so it stays out of the stack layout.
        textToolbarVoicePrint.translatesAutoresizingMaskIntoConstraints = false
        textToolbarVoicePrint.isUserInteractionEnabled = false
        textToolbarVoicePrint.tint = .systemRed
        textToolbarVoicePrint.alpha = 0
        textToolbarVoicePrint.accessibilityLabel = NSLocalizedString("Voice level", comment: "Accessibility label for the recording voiceprint")
        textToolbar.addSubview(textToolbarVoicePrint)
        NSLayoutConstraint.activate([
            textToolbarVoicePrint.centerXAnchor.constraint(equalTo: textToolbar.centerXAnchor),
            textToolbarVoicePrint.centerYAnchor.constraint(equalTo: textToolbar.centerYAnchor),
            textToolbarVoicePrint.widthAnchor.constraint(equalToConstant: 180),
            textToolbarVoicePrint.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Text-mode status bar. Same center slot as the recording voiceprint.
        textToolbarStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        textToolbarStatusLabel.isUserInteractionEnabled = false
        textToolbarStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        textToolbarStatusLabel.textColor = .secondaryLabel
        textToolbarStatusLabel.textAlignment = .center
        textToolbarStatusLabel.adjustsFontSizeToFitWidth = true
        textToolbarStatusLabel.minimumScaleFactor = 0.7
        textToolbarStatusLabel.alpha = 0
        textToolbar.addSubview(textToolbarStatusLabel)

        textToolbarElapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        textToolbarElapsedLabel.isUserInteractionEnabled = false
        textToolbarElapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        textToolbarElapsedLabel.textColor = .secondaryLabel
        textToolbarElapsedLabel.alpha = 0
        textToolbar.addSubview(textToolbarElapsedLabel)
        NSLayoutConstraint.activate([
            textToolbarStatusLabel.leadingAnchor.constraint(equalTo: candidateScrollView.leadingAnchor, constant: 6),
            textToolbarStatusLabel.trailingAnchor.constraint(equalTo: candidateScrollView.trailingAnchor, constant: -6),
            textToolbarStatusLabel.centerYAnchor.constraint(equalTo: textToolbar.centerYAnchor),
            textToolbarElapsedLabel.leadingAnchor.constraint(equalTo: textToolbarVoicePrint.trailingAnchor, constant: 10),
            textToolbarElapsedLabel.centerYAnchor.constraint(equalTo: textToolbar.centerYAnchor),
        ])

        textKeyboardContainer.addArrangedSubview(keyRowsStack)
        textKeyboardContainer.addArrangedSubview(candidateGridScrollView)
        rootStack.addArrangedSubview(textKeyboardContainer)

        rebuildTextKeyboardRows()
        renderRimeState(RimeKeyboardState(
            isReady: true,
            isComposing: false,
            input: "",
            preedit: "",
            candidates: [],
            candidateOffset: 0,
            hasPreviousPage: false,
            hasNextPage: false,
            commitText: "",
            errorMessage: nil
        ))
    }

    private var textKeyboardLayoutKindForCurrentTraits: TextKeyboardLayoutKind {
        let traitLayoutKind = textKeyboardTraitLayoutKind
        if showsStandardLayoutForNumericTraits,
           case .numeric = traitLayoutKind {
            return .standard
        }
        return traitLayoutKind
    }

    private var textKeyboardTraitLayoutKind: TextKeyboardLayoutKind {
        switch textDocumentProxy.keyboardType {
        case .numberPad, .asciiCapableNumberPad:
            return .numeric(decimalSeparator: nil, phoneSymbols: false)
        case .decimalPad:
            return .numeric(decimalSeparator: Locale.current.decimalSeparator ?? ".", phoneSymbols: false)
        case .phonePad, .namePhonePad:
            return .numeric(decimalSeparator: nil, phoneSymbols: true)
        default:
            return .standard
        }
    }

    private var isCurrentTextInputNumericTrait: Bool {
        if case .numeric = textKeyboardTraitLayoutKind {
            return true
        }
        return false
    }

    private var isRenderedNumericTextKeyboard: Bool {
        if case .numeric = renderedTextKeyboardLayoutKind {
            return true
        }
        return false
    }

    private func refreshTextKeyboardLayoutForCurrentInputTraits() {
        guard renderedTextKeyboardLayoutKind != nil else { return }
        if !isCurrentTextInputNumericTrait {
            showsStandardLayoutForNumericTraits = false
        }
        let next = textKeyboardLayoutKindForCurrentTraits
        guard renderedTextKeyboardLayoutKind != next else { return }
        if case .numeric = next {
            clearNumericIncompatibleCompositionState()
        }
        rebuildTextKeyboardRows(layoutKind: next)
        applyKeyboardHeightForCurrentTraits()
        updateKeyboardSurfaceMask()
    }

    private func scheduleDeferredTextKeyboardLayoutRefresh() {
        pendingTextKeyboardTraitRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTextKeyboardTraitRefresh = nil
            self.refreshTextKeyboardLayoutForCurrentInputTraits()
        }
        pendingTextKeyboardTraitRefresh = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func clearNumericIncompatibleCompositionState() {
        pendingRimeCharacters.removeAll()
        pendingRimeDirectTextKeys.removeAll()
        clearTextShiftState()
        applyRimeState(rimeInput.clearComposition())
    }

    private func rebuildTextKeyboardRows(layoutKind explicitLayoutKind: TextKeyboardLayoutKind? = nil) {
        resetAllPressedControlStates(animated: false)
        let layoutKind = explicitLayoutKind ?? renderedTextKeyboardLayoutKind ?? textKeyboardLayoutKindForCurrentTraits
        renderedTextKeyboardLayoutKind = layoutKind
        isCandidateGridExpanded = false
        textToolbar.isHidden = layoutKind != .standard
        keyRowsStack.isHidden = false
        candidateGridScrollView.isHidden = true
        candidateGridCollapseButton.isHidden = true
        NSLayoutConstraint.deactivate(keyboardRowConstraints)
        keyboardRowConstraints.removeAll()
        keyRowsStack.arrangedSubviews.forEach { row in
            keyRowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        detachReusableTextControlButtons()
        textKeyboardButtons.removeAll()
        textKeyboardHitRows.removeAll()
        letterButtonMap.removeAll()
        textKeyCommitCharacters.removeAll()
        lastLetterCasingSnapshot = nil
        textShiftButton = nil
        textSpaceKeyButton = nil
        textReturnKeyButton = nil

        if case .numeric(let decimalSeparator, let phoneSymbols) = layoutKind {
            isSymbolKeyboard = false
            isAlternateSymbolKeyboard = false
            if !phoneSymbols {
                isPhoneSymbolKeyboard = false
            }
            addNumericKeyboardRows(decimalSeparator: decimalSeparator, phoneSymbols: phoneSymbols)
        } else if isSymbolKeyboard {
            isPhoneSymbolKeyboard = false
            let rows = symbolRowsForCurrentLanguage()
            addTextKeyRow(rows[0])
            addTextKeyRow(rows[1])
            addTextKeyRow(rows[2], includeAlternateSymbols: true, includeDelete: true)
        } else {
            isPhoneSymbolKeyboard = false
            addTextKeyRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
            addTextKeyRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"], usesHalfKeyHorizontalOffset: true)
            addTextKeyRow(["z", "x", "c", "v", "b", "n", "m"], includeShift: true, includeDelete: true)
        }
        if layoutKind == .standard {
            addTextBottomRow()
        }
        refreshTextControlTitles()
        refreshTextToolbarControlsForCurrentLayout()
    }

    private func detachReusableTextControlButtons() {
        [textModeButton, textGlobeButton].forEach { button in
            if let stack = button.superview as? UIStackView {
                stack.removeArrangedSubview(button)
            }
            button.removeFromSuperview()
        }
    }

    private func refreshTextToolbarControlsForCurrentLayout() {
        if isRenderedNumericTextKeyboard {
            attachNumericTextToolbarControls()
            return
        }
        updateCandidateToolbarControls(for: rimeInput.state())
    }

    private func attachNumericTextToolbarControls() {
        textToolbar.isHidden = false
        if textModeButton.superview !== textToolbar {
            textToolbar.insertArrangedSubview(textModeButton, at: 0)
        }
        if textGlobeButton.superview !== textToolbar {
            textToolbar.addArrangedSubview(textGlobeButton)
        }

        textModeButton.isHidden = false
        textModeButton.alpha = 1
        textModeButton.isEnabled = true
        textGlobeButton.isHidden = !needsInputModeSwitchKey
        textGlobeButton.alpha = 1
        textGlobeButton.isEnabled = needsInputModeSwitchKey

        textWandButton.isHidden = true
        textToolsButton.isHidden = true
        textStylePickerButton.isHidden = true
        textUndoButton.isHidden = true
        textKeyboardSwitchButton.isHidden = true
        textHostSettingsButton.isHidden = true
        textCandidateGridButton.isHidden = true
        candidateGridCollapseButton.isHidden = true
        candidateGridScrollView.isHidden = true
        candidateScrollView.isHidden = false
        candidateScrollView.alpha = 1
        resetCandidateStackForReuse()
        updateCandidateScrollViewport()
    }

    private func symbolRowsForCurrentLanguage() -> [[String]] {
        let englishPunctuationPage: [[String]] = [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            [".", ",", "?", "!", "'"],
        ]
        let chinesePunctuationPage: [[String]] = [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""],
            ["。", "，", "、", "？", "！"],
        ]
        if isAlternateSymbolKeyboard {
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                [".", ",", "?", "!", "'"],
            ]
        }
        if textInputLanguage == .chinese,
           chinesePunctuationStyle == .chinese {
            return chinesePunctuationPage
        }
        return englishPunctuationPage
    }

    private func addNumericKeyboardRows(decimalSeparator: String?, phoneSymbols: Bool) {
        if phoneSymbols, isPhoneSymbolKeyboard {
            addNumericKeyRow(["+", "*", "#"])
            addNumericKeyRow(["1", "2", "3"])
            addNumericKeyRow(["4", "5", "6"])
            addPhoneSymbolBottomRow()
            return
        }
        [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
        ].forEach { addNumericKeyRow($0) }
        addNumericBottomRow(decimalSeparator: decimalSeparator, phoneSymbols: phoneSymbols)
    }

    private func addNumericKeyRow(_ keys: [String]) {
        let row = makeTextKeyRow()
        row.distribution = .fillEqually
        var keyButtons: [UIButton] = []
        keys.forEach { key in
            let button = makeNumericDigitButton(key)
            row.addArrangedSubview(button)
            textKeyboardButtons.append(button)
            textKeyCommitCharacters[ObjectIdentifier(button)] = key
            keyButtons.append(button)
        }
        keyRowsStack.addArrangedSubview(row)
        registerTextKeyboardHitRow(
            row,
            routedButtons: keyButtons,
            directButtons: [],
            boundaryButtons: keyButtons,
            kind: .character
        )
    }

    private func addNumericBottomRow(decimalSeparator: String?, phoneSymbols: Bool) {
        let row = makeTextKeyRow()
        row.distribution = .fillEqually
        var routedButtons: [UIButton] = []
        var directButtons: [UIButton] = []
        var boundaryButtons: [UIButton] = []

        if let decimalSeparator {
            let decimalButton = makeTextKeyButton(title: decimalSeparator)
            decimalButton.accessibilityLabel = NSLocalizedString("Decimal separator", comment: "Accessibility label for decimal separator key")
            row.addArrangedSubview(decimalButton)
            textKeyboardButtons.append(decimalButton)
            textKeyCommitCharacters[ObjectIdentifier(decimalButton)] = decimalSeparator
            routedButtons.append(decimalButton)
            boundaryButtons.append(decimalButton)
        } else if phoneSymbols {
            let phoneSymbolsButton = makeTextKeyButton(title: "+*#", weight: .utility)
            phoneSymbolsButton.accessibilityLabel = NSLocalizedString("Show phone symbols", comment: "Accessibility label for phone symbols key")
            phoneSymbolsButton.addTarget(self, action: #selector(togglePhoneSymbolKeyboard), for: .touchUpInside)
            row.addArrangedSubview(phoneSymbolsButton)
            textKeyboardButtons.append(phoneSymbolsButton)
            directButtons.append(phoneSymbolsButton)
            boundaryButtons.append(phoneSymbolsButton)
        } else {
            let placeholder = makeNumericPlaceholderButton()
            row.addArrangedSubview(placeholder)
            textKeyboardButtons.append(placeholder)
            directButtons.append(placeholder)
            boundaryButtons.append(placeholder)
        }

        let zeroButton = makeNumericDigitButton("0")
        row.addArrangedSubview(zeroButton)
        textKeyboardButtons.append(zeroButton)
        textKeyCommitCharacters[ObjectIdentifier(zeroButton)] = "0"
        routedButtons.append(zeroButton)
        boundaryButtons.append(zeroButton)

        let deleteKey = makeTextKeyButton(title: "", image: "delete.left", weight: .utility)
        deleteKey.addTarget(self, action: #selector(deletePressDown), for: [.touchDown, .touchDragEnter])
        deleteKey.addTarget(self, action: #selector(deletePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        row.addArrangedSubview(deleteKey)
        textKeyboardButtons.append(deleteKey)
        directButtons.append(deleteKey)
        boundaryButtons.append(deleteKey)

        keyRowsStack.addArrangedSubview(row)
        registerTextKeyboardHitRow(
            row,
            routedButtons: routedButtons,
            directButtons: directButtons,
            boundaryButtons: boundaryButtons,
            kind: .character
        )
    }

    private func addPhoneSymbolBottomRow() {
        let row = makeTextKeyRow()
        row.distribution = .fillEqually
        var directButtons: [UIButton] = []
        var boundaryButtons: [UIButton] = []

        let numericButton = makeTextKeyButton(title: "123", weight: .utility)
        numericButton.accessibilityLabel = NSLocalizedString("Show numbers", comment: "Accessibility label for returning to phone numbers")
        numericButton.addTarget(self, action: #selector(togglePhoneSymbolKeyboard), for: .touchUpInside)
        row.addArrangedSubview(numericButton)
        textKeyboardButtons.append(numericButton)
        directButtons.append(numericButton)
        boundaryButtons.append(numericButton)

        let zeroButton = makeNumericDigitButton("0")
        row.addArrangedSubview(zeroButton)
        textKeyboardButtons.append(zeroButton)
        textKeyCommitCharacters[ObjectIdentifier(zeroButton)] = "0"
        boundaryButtons.append(zeroButton)

        let deleteKey = makeTextKeyButton(title: "", image: "delete.left", weight: .utility)
        deleteKey.addTarget(self, action: #selector(deletePressDown), for: [.touchDown, .touchDragEnter])
        deleteKey.addTarget(self, action: #selector(deletePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        row.addArrangedSubview(deleteKey)
        textKeyboardButtons.append(deleteKey)
        directButtons.append(deleteKey)
        boundaryButtons.append(deleteKey)

        keyRowsStack.addArrangedSubview(row)
        registerTextKeyboardHitRow(
            row,
            routedButtons: [zeroButton],
            directButtons: directButtons,
            boundaryButtons: boundaryButtons,
            kind: .character
        )
    }

    private func makeNumericDigitButton(_ digit: String) -> UIButton {
        let button = makeTextKeyButton(title: "")
        button.accessibilityLabel = digit
        installNumericDigitLabels(on: button, digit: digit)
        return button
    }

    private func installNumericDigitLabels(on button: UIButton, digit: String) {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = -3
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        let digitLabel = UILabel()
        digitLabel.text = digit
        digitLabel.textColor = .label
        digitLabel.textAlignment = .center
        digitLabel.font = .systemFont(ofSize: TextKeyboardLayoutModel.numericDigitTitleFontSize, weight: .regular)
        digitLabel.adjustsFontSizeToFitWidth = true
        digitLabel.minimumScaleFactor = 0.9
        stack.addArrangedSubview(digitLabel)

        if let secondary = numericSecondaryTitle(for: digit) {
            let secondaryLabel = UILabel()
            secondaryLabel.text = secondary
            secondaryLabel.textColor = .label
            secondaryLabel.textAlignment = .center
            secondaryLabel.font = .systemFont(ofSize: TextKeyboardLayoutModel.numericSecondaryTitleFontSize, weight: .semibold)
            secondaryLabel.adjustsFontSizeToFitWidth = true
            secondaryLabel.minimumScaleFactor = 0.85
            stack.addArrangedSubview(secondaryLabel)
        }

        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -6),
        ])
    }

    private func numericSecondaryTitle(for digit: String) -> String? {
        switch digit {
        case "2": return "A B C"
        case "3": return "D E F"
        case "4": return "G H I"
        case "5": return "J K L"
        case "6": return "M N O"
        case "7": return "P Q R S"
        case "8": return "T U V"
        case "9": return "W X Y Z"
        default: return nil
        }
    }

    private func makeNumericPlaceholderButton() -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.background.backgroundColor = .clear
        configuration.baseForegroundColor = .clear
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        button.configuration = configuration
        button.accessibilityElementsHidden = true
        return button
    }

    private func addTextKeyRow(
        _ keys: [String],
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0,
        usesHalfKeyHorizontalOffset: Bool = false,
        leadingTextKey: String? = nil,
        includeAlternateSymbols: Bool = false,
        includeShift: Bool = false,
        includeDelete: Bool = false
    ) {
        let row = makeTextKeyRow()
        var keyButtons: [UIButton] = []
        var routedEdgeButtons: [UIButton] = []
        var directButtons: [UIButton] = []
        var leadingUtilityButton: UIButton?
        var trailingUtilityButton: UIButton?
        var leadingHalfKeySpacer: UIView?
        var trailingHalfKeySpacer: UIView?
        let separatesUtilityEdges = (includeAlternateSymbols || includeShift) && includeDelete && !keys.isEmpty

        if leadingInset > 0 {
            addFixedTextRowSpacer(to: row, width: leadingInset)
        } else if usesHalfKeyHorizontalOffset {
            leadingHalfKeySpacer = addConstrainedTextRowSpacer(to: row)
        }
        if includeAlternateSymbols {
            row.addArrangedSubview(textAlternateSymbolButton)
            textKeyboardButtons.append(textAlternateSymbolButton)
            leadingUtilityButton = textAlternateSymbolButton
            directButtons.append(textAlternateSymbolButton)
        } else if let leadingTextKey {
            let title = displayTitle(forTextKey: leadingTextKey)
            let button = makeTextKeyButton(title: title, weight: .utility)
            attachKeyPreview(to: button, title: title)
            row.addArrangedSubview(button)
            textKeyboardButtons.append(button)
            textKeyCommitCharacters[ObjectIdentifier(button)] = leadingTextKey
            leadingUtilityButton = button
            routedEdgeButtons.append(button)
        } else if includeShift {
            let shiftKey = makeTextShiftButton()
            row.addArrangedSubview(shiftKey)
            textKeyboardButtons.append(shiftKey)
            leadingUtilityButton = shiftKey
            directButtons.append(shiftKey)
        }
        if separatesUtilityEdges {
            addFixedTextRowSpacer(to: row, width: TextKeyboardLayoutModel.utilityLetterSpacerWidth)
        }
        keys.forEach { key in
            let title = displayTitle(forTextKey: key)
            let button = makeTextKeyButton(title: title)
            attachKeyPreview(to: button, title: title)
            row.addArrangedSubview(button)
            textKeyboardButtons.append(button)
            textKeyCommitCharacters[ObjectIdentifier(button)] = key
            if isAlphabeticTextKey(key) {
                letterButtonMap[key.lowercased()] = button
            }
            keyButtons.append(button)
        }
        if includeDelete {
            if separatesUtilityEdges {
                addFixedTextRowSpacer(to: row, width: TextKeyboardLayoutModel.utilityLetterSpacerWidth)
            }
            let deleteKey = makeTextKeyButton(title: "", image: "delete.left", weight: .utility)
            deleteKey.addTarget(self, action: #selector(deletePressDown), for: [.touchDown, .touchDragEnter])
            deleteKey.addTarget(self, action: #selector(deletePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            row.addArrangedSubview(deleteKey)
            textKeyboardButtons.append(deleteKey)
            trailingUtilityButton = deleteKey
            directButtons.append(deleteKey)
        }
        if trailingInset > 0 {
            addFixedTextRowSpacer(to: row, width: trailingInset)
        } else if usesHalfKeyHorizontalOffset {
            trailingHalfKeySpacer = addConstrainedTextRowSpacer(to: row)
        }
        constrainTextKeyRow(
            keyButtons: keyButtons,
            leadingUtilityButton: leadingUtilityButton,
            trailingUtilityButton: trailingUtilityButton,
            leadingHalfKeySpacer: leadingHalfKeySpacer,
            trailingHalfKeySpacer: trailingHalfKeySpacer
        )
        keyRowsStack.addArrangedSubview(row)

        registerTextKeyboardHitRow(
            row,
            routedButtons: routedEdgeButtons + keyButtons,
            directButtons: directButtons,
            boundaryButtons: directButtons + routedEdgeButtons + keyButtons,
            kind: .character
        )
    }

    private func registerTextKeyboardHitRow(
        _ row: UIStackView,
        routedButtons: [UIButton],
        directButtons: [UIButton],
        boundaryButtons: [UIButton],
        kind: TextKeyboardHitRowKind
    ) {
        textKeyboardHitRows.append(TextKeyboardHitRow(
            row: row,
            routedButtons: routedButtons,
            directButtons: directButtons,
            boundaryButtons: boundaryButtons,
            kind: kind
        ))
    }

    private func addFixedTextRowSpacer(to row: UIStackView, width: CGFloat) {
        let spacer = addConstrainedTextRowSpacer(to: row)
        let constraint = spacer.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        keyboardRowConstraints.append(constraint)
    }

    private func addConstrainedTextRowSpacer(to row: UIStackView) -> UIView {
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        spacer.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(spacer)
        return spacer
    }

    private func constrainTextKeyRow(
        keyButtons: [UIButton],
        leadingUtilityButton: UIButton?,
        trailingUtilityButton: UIButton?,
        leadingHalfKeySpacer: UIView? = nil,
        trailingHalfKeySpacer: UIView? = nil
    ) {
        guard let referenceButton = keyButtons.first else { return }
        var constraints: [NSLayoutConstraint] = [
            referenceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ]
        constraints.append(contentsOf: keyButtons.dropFirst().map {
            $0.widthAnchor.constraint(equalTo: referenceButton.widthAnchor)
        })
        if let leadingUtilityButton {
            constraints.append(leadingUtilityButton.widthAnchor.constraint(
                equalTo: referenceButton.widthAnchor,
                multiplier: TextKeyboardLayoutModel.utilityKeyWidthMultiplier
            ))
        }
        if let trailingUtilityButton {
            constraints.append(trailingUtilityButton.widthAnchor.constraint(
                equalTo: referenceButton.widthAnchor,
                multiplier: TextKeyboardLayoutModel.utilityKeyWidthMultiplier
            ))
        }
        if let leadingHalfKeySpacer {
            constraints.append(NSLayoutConstraint(
                item: leadingHalfKeySpacer,
                attribute: .width,
                relatedBy: .equal,
                toItem: referenceButton,
                attribute: .width,
                multiplier: 0.5,
                constant: -TextKeyboardLayoutModel.keyHorizontalGap / 2
            ))
        }
        if let trailingHalfKeySpacer {
            constraints.append(NSLayoutConstraint(
                item: trailingHalfKeySpacer,
                attribute: .width,
                relatedBy: .equal,
                toItem: referenceButton,
                attribute: .width,
                multiplier: 0.5,
                constant: -TextKeyboardLayoutModel.keyHorizontalGap / 2
            ))
        }
        NSLayoutConstraint.activate(constraints)
        keyboardRowConstraints.append(contentsOf: constraints)
    }

    private func makeTextShiftButton() -> UIButton {
        let autoCap = shouldAutoCapitalizeNextEnglishLetter()
        let isShiftActive = effectiveTextShiftActive(autoCap: autoCap)
        let button = makeTextKeyButton(
            title: "",
            image: isTextShiftLocked ? "capslock.fill" : (isShiftActive ? "shift.fill" : "shift"),
            weight: .utility
        )
        button.isSelected = isShiftActive || isTextShiftLocked
        button.setNeedsUpdateConfiguration()
        button.accessibilityLabel = isTextShiftLocked
            ? NSLocalizedString("Caps Lock on", comment: "Accessibility label for active Caps Lock key")
            : (isShiftActive
                ? NSLocalizedString("Shift on", comment: "Accessibility label for active Shift key")
                : NSLocalizedString("Shift", comment: "Accessibility label for Shift key"))
        button.addTarget(self, action: #selector(toggleTextShift), for: .touchUpInside)
        textShiftButton = button
        return button
    }

    private func displayTitle(forTextKey key: String, autoCap: Bool? = nil) -> String {
        if textInputLanguage == .chinese,
           !isAlphabeticTextKey(key),
           chinesePunctuationStyle == .chinese,
           !isSymbolKeyboard,
           isChinesePunctuationContext {
            return chinesePunctuationDisplayTitle(for: key)
        }
        if isAlphabeticTextKey(key),
           effectiveTextShiftActive(autoCap: autoCap ?? shouldAutoCapitalizeNextEnglishLetter()) {
            return key.uppercased()
        }
        return key
    }

    private func addTextBottomRow() {
        let row = makeTextKeyRow()
        row.distribution = .fill

        row.addArrangedSubview(textModeButton)
        textKeyboardButtons.append(textModeButton)

        textGlobeButton.isHidden = !needsInputModeSwitchKey
        row.addArrangedSubview(textGlobeButton)
        textKeyboardButtons.append(textGlobeButton)

        if isChineseInputEnabled {
            row.addArrangedSubview(textLanguageButton)
            textKeyboardButtons.append(textLanguageButton)
        }

        let spaceKey = makeTextKeyButton(title: spaceKeyTitle, weight: .primary)
        spaceKey.addTarget(self, action: #selector(textSpaceTapped), for: .touchUpInside)
        attachSpaceCursorGesture(to: spaceKey)
        row.addArrangedSubview(spaceKey)
        textKeyboardButtons.append(spaceKey)
        textSpaceKeyButton = spaceKey

        let returnKey = makeTextKeyButton(title: returnKeyTitle, image: returnKeyImageName, weight: .utility)
        returnKey.widthAnchor.constraint(equalToConstant: TextKeyboardLayoutModel.bottomReturnKeyWidth).isActive = true
        returnKey.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        row.addArrangedSubview(returnKey)
        textKeyboardButtons.append(returnKey)
        textReturnKeyButton = returnKey
        lastReturnKeyTitle = returnKeyTitle
        lastReturnKeyImageName = returnKeyImageName

        keyRowsStack.addArrangedSubview(row)
        let directButtons = isChineseInputEnabled
            ? [textModeButton, textGlobeButton, textLanguageButton, spaceKey, returnKey]
            : [textModeButton, textGlobeButton, spaceKey, returnKey]
        registerTextKeyboardHitRow(
            row,
            routedButtons: [],
            directButtons: directButtons,
            boundaryButtons: directButtons,
            kind: .bottom
        )
    }

    private func refreshReturnKeyTitle() {
        applyVoiceSendButtonConfiguration()
        guard let textReturnKeyButton else { return }
        let next = returnKeyTitle
        let nextImage = returnKeyImageName
        guard next != lastReturnKeyTitle || nextImage != lastReturnKeyImageName else { return }
        lastReturnKeyTitle = next
        lastReturnKeyImageName = nextImage
        configureTextKeyButton(textReturnKeyButton, title: next, image: nextImage, weight: .utility)
    }

    private var spaceKeyTitle: String {
        textInputLanguage == .chinese
            ? NSLocalizedString("空格", comment: "Space key title in Chinese input mode")
            : NSLocalizedString("space", comment: "Space key title in English input mode")
    }

    /// Swaps the space key label to the recording-stop hint and back. Driven
    /// from `updateUI` so the title tracks the bridge recording state.
    private func updateSpaceKeyTitleForRecording(_ recording: Bool, stopsRefine: Bool = false) {
        guard let spaceKey = textSpaceKeyButton else { return }
        if recording {
            configureTextKeyButton(
                spaceKey,
                title: NSLocalizedString("点击发送", comment: "Space key label during text-keyboard dictation"),
                image: nil,
                weight: .primary
            )
        } else if stopsRefine {
            configureTextKeyButton(
                spaceKey,
                title: stopRefineSpaceKeyTitle,
                image: nil,
                weight: .primary
            )
        } else {
            configureTextKeyButton(spaceKey, title: spaceKeyTitle, image: nil, weight: .primary)
        }
    }

    private var stopRefineSpaceKeyTitle: String {
        textInputLanguage == .chinese
            ? NSLocalizedString("发送", comment: "Space key label while accepting active refine")
            : NSLocalizedString("send", comment: "Space key label while accepting active refine")
    }

    private var returnKeyTitle: String {
        let isChinese = textInputLanguage == .chinese
        switch textDocumentProxy.returnKeyType {
        case .go:
            return isChinese
                ? NSLocalizedString("前往", comment: "Go return key title in Chinese input mode")
                : NSLocalizedString("go", comment: "Go return key title in English input mode")
        case .google:
            return isChinese
                ? NSLocalizedString("搜索", comment: "Google return key title in Chinese input mode")
                : NSLocalizedString("google", comment: "Google return key title in English input mode")
        case .join:
            return isChinese
                ? NSLocalizedString("加入", comment: "Join return key title in Chinese input mode")
                : NSLocalizedString("join", comment: "Join return key title in English input mode")
        case .next:
            return isChinese
                ? NSLocalizedString("下一项", comment: "Next return key title in Chinese input mode")
                : NSLocalizedString("next", comment: "Next return key title in English input mode")
        case .route:
            return isChinese
                ? NSLocalizedString("路线", comment: "Route return key title in Chinese input mode")
                : NSLocalizedString("route", comment: "Route return key title in English input mode")
        case .search:
            return isChinese
                ? NSLocalizedString("搜索", comment: "Search return key title in Chinese input mode")
                : NSLocalizedString("search", comment: "Search return key title in English input mode")
        case .send:
            return isChinese
                ? NSLocalizedString("发送", comment: "Send return key title in Chinese input mode")
                : NSLocalizedString("send", comment: "Send return key title in English input mode")
        case .yahoo:
            return isChinese
                ? NSLocalizedString("搜索", comment: "Yahoo return key title in Chinese input mode")
                : NSLocalizedString("yahoo", comment: "Yahoo return key title in English input mode")
        case .done:
            return isChinese
                ? NSLocalizedString("完成", comment: "Done return key title in Chinese input mode")
                : NSLocalizedString("done", comment: "Done return key title in English input mode")
        case .emergencyCall:
            return isChinese
                ? NSLocalizedString("紧急呼叫", comment: "Emergency call return key title in Chinese input mode")
                : NSLocalizedString("emergency", comment: "Emergency call return key title in English input mode")
        case .continue:
            return isChinese
                ? NSLocalizedString("继续", comment: "Continue return key title in Chinese input mode")
                : NSLocalizedString("continue", comment: "Continue return key title in English input mode")
        default:
            return ""
        }
    }

    private var returnKeyImageName: String? {
        switch textDocumentProxy.returnKeyType {
        case .default:
            return "return"
        default:
            return nil
        }
    }

    private func makeTextKeyRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = TextKeyboardLayoutModel.keyHorizontalGap
        row.alignment = .fill
        row.distribution = .fill
        return row
    }

    private enum TextKeyWeight {
        case normal
        case primary
        case utility
    }

    private func makeTextKeyButton(title: String, image: String? = nil, weight: TextKeyWeight = .normal) -> UIButton {
        let button = UIButton(type: .system)
        configureTextKeyButton(button, title: title, image: image, weight: weight)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byClipping
        attachPressAnimation(button)
        return button
    }

    private func configureTextControlButton(_ button: UIButton, title: String, image: String?) {
        configureTextKeyButton(button, title: title, image: image, weight: .utility)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    /// Toolbar icons (mic / waveform / gear / candidate expand chevron) want
    /// a different look from the keyboard's keys: transparent background, no
    /// shadow, just a tinted SF Symbol — matching how iOS draws the
    /// predictive-bar's right-hand dictation indicator. Sharing the key
    /// chrome on these makes the toolbar look like a row of stubby buttons.
    private func configureToolbarIconButton(_ button: UIButton, image: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: image)
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = .clear
        configuration.background.strokeWidth = 0
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.configuration = configuration
        button.clipsToBounds = false
        button.imageView?.clipsToBounds = false
        button.layer.shadowOpacity = 0
        button.layer.borderWidth = 0
    }

    private func configureCandidateExpandButton(isExpanded: Bool) {
        configureCandidateChevronButton(textCandidateGridButton, isExpanded: isExpanded)
    }

    private func configureCandidateGridCollapseButton(isExpanded: Bool) {
        configureCandidateChevronButton(candidateGridCollapseButton, isExpanded: isExpanded)
    }

    private func configureCandidateChevronButton(_ button: UIButton, isExpanded: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down")
        configuration.cornerStyle = .fixed
        configuration.contentInsets = isExpanded
            ? NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            : NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        configuration.baseForegroundColor = .label
        // The expanded-grid collapse chevron floats alone at top-right with no
        // toolbar context, so it gets a faint pill background to read as a
        // tappable affordance. The collapsed-state expand chevron lives next
        // to the candidate strip and stays bare to match iOS native.
        if isExpanded {
            configuration.background.backgroundColor = UIColor.label.withAlphaComponent(isKeyboardDark ? 0.18 : 0.08)
            configuration.background.cornerRadius = 10
        } else {
            configuration.background.backgroundColor = .clear
            configuration.background.cornerRadius = 0
        }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: Self.candidateChevronSymbolPointSize,
            weight: .medium
        )
        button.configuration = configuration
    }

    private func configureTextKeyButton(_ button: UIButton, title: String, image: String?, weight: TextKeyWeight) {
        button.configurationUpdateHandler = nil
        let configuration = textKeyConfiguration(title: title, image: image, weight: weight, isPressed: false, isSelected: button.isSelected)
        button.configuration = configuration
        button.configurationUpdateHandler = { [weak self, weak button] control in
            guard let self, let button else { return }
            let isPressed = control.isHighlighted
            let isSelected = control.isSelected
            button.configuration = self.textKeyConfiguration(title: title, image: image, weight: weight, isPressed: isPressed, isSelected: isSelected)
            self.applyTextKeyLayerStyle(to: button, weight: weight, isPressed: isPressed, isSelected: isSelected)
        }
        applyTextKeyLayerStyle(to: button, weight: weight, isPressed: false, isSelected: button.isSelected)
        button.accessibilityLabel = title.isEmpty ? image : title
    }

    private func textKeyConfiguration(
        title: String,
        image: String?,
        weight: TextKeyWeight,
        isPressed: Bool,
        isSelected: Bool
    ) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        let usesSystemLetterTypography = weight == .normal && image == nil && title.range(
            of: #"^[A-Za-z]$"#,
            options: .regularExpression
        ) != nil
        let usesUppercaseLetterTypography = usesSystemLetterTypography && title == title.uppercased()
        let isCompactUtilityTitle = weight == .utility
            && image == nil
            && (title == "123" || title == "ABC" || title == "#+=")
        let usesUtilityActionTypography = weight == .utility
            && image == nil
            && !isCompactUtilityTitle
        configuration.title = title
        configuration.image = image.flatMap { UIImage(systemName: $0) }
        if image != nil {
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: TextKeyboardLayoutModel.keyIconPointSize,
                weight: .regular
            )
        }
        configuration.titleLineBreakMode = .byClipping
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 6
        configuration.contentInsets = usesSystemLetterTypography
            ? NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 7, trailing: 4)
            : NSDirectionalEdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4)
        configuration.baseForegroundColor = systemKeyboardKeyForeground(for: weight, isSelected: isSelected)
        configuration.baseBackgroundColor = systemKeyboardKeyBackground(for: weight, isPressed: isPressed, isSelected: isSelected)
        configuration.background.strokeWidth = isPressed ? 0 : 0.35
        configuration.background.strokeColor = UIColor.separator.withAlphaComponent(isKeyboardDark ? 0.18 : 0.10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            let isShortGlyph = title.count <= 2
            outgoing.font = usesSystemLetterTypography
                ? .systemFont(
                    ofSize: usesUppercaseLetterTypography
                        ? TextKeyboardLayoutModel.uppercaseLetterTitleFontSize
                        : TextKeyboardLayoutModel.letterTitleFontSize,
                    weight: .regular
                )
                : (isCompactUtilityTitle
                    ? .systemFont(ofSize: TextKeyboardLayoutModel.compactUtilityTitleFontSize, weight: .regular)
                    : (usesUtilityActionTypography
                        ? .systemFont(ofSize: isShortGlyph ? TextKeyboardLayoutModel.utilityActionTitleFontSize : 14, weight: .medium)
                        : .systemFont(ofSize: isShortGlyph ? 22 : 15, weight: isShortGlyph ? .regular : .medium)))
            return outgoing
        }
        return configuration
    }

    private func applyTextKeyLayerStyle(to button: UIButton, weight: TextKeyWeight, isPressed: Bool, isSelected: Bool) {
        button.layer.cornerRadius = 6
        button.layer.cornerCurve = .continuous
        button.layer.masksToBounds = false
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: isPressed ? 0 : 0.3)
        button.layer.shadowRadius = 0
        let baseOpacity: Float = {
            switch weight {
            case .normal, .primary:
                return isKeyboardDark ? 0.22 : 0.12
            case .utility:
                return isKeyboardDark ? 0.24 : 0.14
            }
        }()
        button.layer.shadowOpacity = isPressed ? baseOpacity * 0.4 : baseOpacity
        button.layer.borderWidth = isPressed ? 0.5 : 0
        button.layer.borderColor = UIColor.label.withAlphaComponent(isKeyboardDark ? 0.08 : 0.05).cgColor
    }

    private func systemKeyboardKeyForeground(for weight: TextKeyWeight, isSelected: Bool) -> UIColor {
        UIColor { traits in
            if isSelected {
                return traits.userInterfaceStyle == .dark ? .black : .label
            }
            return .label
        }
    }

    private func systemKeyboardKeyBackground(for weight: TextKeyWeight, isPressed: Bool = false, isSelected: Bool = false) -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                if isSelected {
                    return UIColor(white: 0.86, alpha: 1.0)
                }
                switch weight {
                case .normal, .primary:
                    return UIColor(white: isPressed ? 0.42 : 0.33, alpha: 1.0)
                case .utility:
                    return UIColor(white: isPressed ? 0.36 : 0.25, alpha: 1.0)
                }
            }
            if isSelected {
                return UIColor(white: 0.98, alpha: 1.0)
            }
            switch weight {
            case .normal, .primary:
                return UIColor(white: isPressed ? 0.78 : 0.99, alpha: 1.0)
            case .utility:
                return UIColor(white: isPressed ? 0.56 : 0.68, alpha: 1.0)
            }
        }
    }

    private func configureCapsuleButton(_ button: UIButton, title: String, image: String?, style: CapsuleStyle) {
        button.configuration = capsuleButtonConfiguration(title: title, image: image, style: style)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    private func refreshCapsuleButtonConfigurations() {
        commandButton.configuration = capsuleButtonConfiguration(title: "", image: "wand.and.stars", style: .utility)
        voiceUndoButton.configuration = capsuleButtonConfiguration(
            title: "",
            image: voiceUndoShowsCancel ? "xmark" : "arrow.uturn.backward",
            style: .utility
        )
        spaceButton.configuration = capsuleButtonConfiguration(title: "space", image: nil, style: .key)
        deleteButton.configuration = capsuleButtonConfiguration(title: "", image: "delete.left", style: .utility)
        returnButton.configuration = capsuleButtonConfiguration(title: "return", image: nil, style: .utility)
    }

    /// Re-pull `isKeyboardDark`-derived layer colors so the popover and
    /// trigger match the keyboard's current appearance. Driven from
    /// `applyKeyboardInterfaceStyle`.
    private func refreshCorrectionPopoverAppearance() {
        correctionPopover.backgroundColor = UIColor.secondarySystemBackground
            .withAlphaComponent(isKeyboardDark ? 0.94 : 0.98)
        correctionPopover.layer.borderColor = UIColor.separator
            .resolvedColor(with: keyboardTraitCollection).cgColor
        // Trigger picks up `isKeyboardDark` inside its configuration; force a
        // rebuild via the same path updateCorrectionModeButtons uses so the
        // signature debounce there can't suppress a dark-mode refresh.
        lastCorrectionModeButtonSignature = ""
        lastTextRecordingButtonsSignature = ""
        updateCorrectionModeButtons()
    }

    private func capsuleButtonConfiguration(title: String, image: String?, style: CapsuleStyle) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = image.map { UIImage(systemName: $0) } ?? nil
        configuration.imagePlacement = .leading
        configuration.imagePadding = title.isEmpty ? 0 : 5
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        configuration.titleAlignment = .center
        configuration.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
        configuration.background.strokeWidth = 0.5
        configuration.background.strokeColor = UIColor.separator.withAlphaComponent(isKeyboardDark ? 0.24 : 0.18)

        let font: UIFont = title.count > 5 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 15, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }

        switch style {
        case .chrome:
            configuration.baseBackgroundColor = UIColor.secondarySystemGroupedBackground
                .withAlphaComponent(isKeyboardDark ? 0.20 : 0.54)
        case .key:
            configuration.baseBackgroundColor = UIColor.systemBackground
                .withAlphaComponent(isKeyboardDark ? 0.18 : 0.58)
        case .utility:
            configuration.baseBackgroundColor = UIColor.secondarySystemBackground
                .withAlphaComponent(isKeyboardDark ? 0.22 : 0.50)
        }
        configuration.baseForegroundColor = .label

        return configuration
    }

    private func updateUI(animated: Bool = true) {
        let updateStartedAt = CACurrentMediaTime()
        let state = currentBridgeStatus?.state
        defer {
            logSlowUpdateUI(startedAt: updateStartedAt, animated: animated, state: state)
        }

        updateCorrectionModeButtons()
        configureInputModeSwitch()

        let isRecordingState = state == .recording
        let isSendingState = state == .sending

        // Hold mode covers the orb with the user's finger, so the in-orb
        // voiceprint is invisible during recording. Mirror it into topRow's
        // center slot — where voiceTitleLabel normally lives — for the
        // duration of the hold. Tap mode keeps the in-orb voiceprint since
        // the orb itself stays uncovered.
        let isHoldRecording = isRecordingState && inputMode == .hold
        let showsInOrbVoicePrint = isRecordingState && !isHoldRecording
        let showsTopRowVoicePrint = isHoldRecording
        let updates = {
            self.statusLabel.text = self.statusText
            self.statusDot.backgroundColor = self.statusDotColor
            let showsStatusGroup = self.shouldShowStatusGroup
            self.statusGroup.isHidden = !showsStatusGroup
            self.statusGroup.alpha = showsStatusGroup ? 1 : 0

            if self.keyboardFocus == .text {
                self.voiceTitleLabel.text = NSLocalizedString("中文键盘", comment: "Title for Chinese keyboard focus")
                self.voiceTitleLabel.textColor = .label
                self.voiceTitleLabel.alpha = 1
            } else {
                self.voiceTitleLabel.text = self.voiceTitle
                self.voiceTitleLabel.textColor = self.voiceTitleColor
                self.voiceTitleLabel.alpha = isHoldRecording ? 0 : 1
            }
            let canStopRefine = self.canStopActiveRefine
            self.voiceIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: canStopRefine ? 42 : 52,
                weight: .medium
            )
            self.voiceIconView.image = Self.cachedSymbolImage(named: self.voiceIconName)
            let showsSpinner = (isSendingState && !canStopRefine) || (!isRecordingState && (self.isStartRequestInFlight || self.isOpeningHostApp))
            self.voiceIconView.alpha = (isRecordingState || showsSpinner) ? 0 : 1
            self.voicePrint.alpha = showsInOrbVoicePrint ? 1 : 0
            self.topRowVoicePrint.alpha = (self.keyboardFocus == .text ? false : showsTopRowVoicePrint) ? 1 : 0
            self.voiceButton.alpha = 1
            self.voiceSpinner.alpha = showsSpinner ? 1 : 0

            let acceptsVoiceTouch = !isSendingState || self.isVoicePressActive || canStopRefine
            self.voiceButton.isEnabled = acceptsVoiceTouch
            self.voiceButton.accessibilityValue = self.inputMode.title
            let commandCanStopActiveCommand = isRecordingState
                && self.activeRecordingTextEditIntent == .command
                && self.inputMode == .tap
            let commandEnabled = self.isCommandPressActive
                || commandCanStopActiveCommand
                || (!isRecordingState && !isSendingState && !self.isStartRequestInFlight)
            self.commandButton.isEnabled = commandEnabled
            self.commandButton.alpha = self.commandButton.isEnabled ? 1 : 0.45
            self.inputModeSwitch.setEnabled(!isRecordingState && !isSendingState && !self.isStartRequestInFlight)
            let voiceUtilityEnabled = !isRecordingState && !isSendingState && !self.isStartRequestInFlight
            for button in [self.voiceSendButton, self.spaceButton, self.deleteButton] {
                button.isEnabled = voiceUtilityEnabled
                button.alpha = voiceUtilityEnabled ? 1 : 0.45
            }
            self.returnButton.isEnabled = voiceUtilityEnabled
            self.returnButton.alpha = voiceUtilityEnabled ? 1 : 0.45
            let locksTextRows = self.keyboardFocus == .text && (isRecordingState || isSendingState)
            let textSpaceCanStopRefine = isSendingState && self.keyboardFocus == .text && canStopRefine
            // Keep rows touchable only for explicit in-flight affordances:
            // space stops text-keyboard recording, then stops active refine
            // once the host enters the refine stage. Disabled buttons are
            // filtered by the touch router.
            self.keyRowsStack.isUserInteractionEnabled = !locksTextRows || isRecordingState || textSpaceCanStopRefine
            // Dim per-key (not the whole stack) so the space key, which stays
            // the live stop-and-send affordance during recording, can render
            // at full opacity. UIView.alpha cascades multiplicatively, so we
            // can't set the stack to 0.48 and the space child back to 1.
            self.keyRowsStack.alpha = 1
            let textBusyDim = locksTextRows && self.keyboardFocus == .text
            for button in self.textKeyboardButtons {
                let staysEnabled: Bool
                if isRecordingState && self.keyboardFocus == .text {
                    staysEnabled = button === self.textSpaceKeyButton
                } else if isSendingState && self.keyboardFocus == .text {
                    staysEnabled = button === self.textSpaceKeyButton && textSpaceCanStopRefine
                } else {
                    staysEnabled = true
                }
                button.isEnabled = staysEnabled
                button.alpha = textBusyDim && !staysEnabled ? 0.48 : 1
            }
            self.updateSpaceKeyTitleForRecording(
                isRecordingState && self.keyboardFocus == .text,
                stopsRefine: textSpaceCanStopRefine
            )
            self.candidateScrollView.alpha = locksTextRows ? 0.62 : 1
            self.refreshTextRecordingButtons(isRecording: isRecordingState, isSending: isSendingState)
            // Voice-orb mode: dim the correction mode chip during recording /
            // sending so its disabled state reads visually. The mic + send
            // buttons stay at full opacity because they're the only live
            // affordances during dictation.
            let voiceModeDim = (isRecordingState || isSendingState) && self.keyboardFocus == .voice
            self.correctionModePanel.alpha = voiceModeDim ? 0.48 : 1
            self.voiceButton.layer.shadowColor = self.voiceShadowColor.cgColor

            self.textToolsReadyDot.alpha = 0
            self.textToolsReadyDot.isHidden = true

            if showsSpinner {
                self.voiceSpinner.startAnimating()
            } else {
                self.voiceSpinner.stopAnimating()
            }
        }

        let gradientColors = voiceGradientColors.map { $0.cgColor }
        let shouldAnimate = keyboardFocus != .text && animated && !isVoicePressActive && !isStartRequestInFlight
        if shouldAnimate {
            UIView.transition(with: voiceButton, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction], animations: updates)
            let anim = CABasicAnimation(keyPath: "colors")
            anim.fromValue = voiceGradient.colors
            anim.toValue = gradientColors
            anim.duration = 0.22
            voiceGradient.colors = gradientColors
            voiceGradient.add(anim, forKey: "colors")
        } else {
            updates()
            voiceGradient.colors = gradientColors
        }

        let showsTextToolbarVoicePrint = isRecordingState && keyboardFocus == .text
        let isErrorState = state == .error
        let isTransientKeyboardErrorState = isShowingTransientKeyboardError
        let suppressesInitialTextStatus = keyboardFocus == .text && !hasPresentedInitialFrame
        let transientStatusText = textToolbarStatusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showsTransientTextStatus = keyboardFocus == .text
            && !isRecordingState
            && !suppressesInitialTextStatus
            && !transientStatusText.isEmpty
        let isInsertedFlash = keyboardFocus == .text
            && Date().timeIntervalSince1970 < insertedFlashUntil
        let showsTextToolbarStatus = keyboardFocus == .text
            && !suppressesInitialTextStatus
            && (showsTransientTextStatus || isSendingState || isErrorState || isInsertedFlash)
        voicePrint.isActive = showsInOrbVoicePrint
        topRowVoicePrint.isActive = isHoldRecording
        textToolbarVoicePrint.isActive = showsTextToolbarVoicePrint
        textToolbarVoicePrint.alpha = showsTextToolbarVoicePrint ? 1 : 0
        if showsTextToolbarStatus {
            if showsTransientTextStatus {
                textToolbarStatusLabel.text = textToolbarStatusText
                textToolbarStatusLabel.textColor = textToolbarStatusColor
            } else if isInsertedFlash {
                textToolbarStatusLabel.text = insertedStatusTitle
                textToolbarStatusLabel.textColor = isCurrentResultWithoutRefine ? .systemOrange : .systemGreen
            } else if isErrorState {
                textToolbarStatusLabel.text = currentBridgeStatus?.message
                textToolbarStatusLabel.textColor = .systemRed
            } else {
                textToolbarStatusLabel.text = bridgeStatusDisplayMessage
                textToolbarStatusLabel.textColor = .secondaryLabel
            }
        }
        textToolbarStatusLabel.alpha = showsTextToolbarStatus ? 1 : 0
        updateRefineUndoButtons()
        applyTextToolbarRecordingOverlay(
            recording: showsTextToolbarVoicePrint,
            sending: isSendingState || (isErrorState && !isTransientKeyboardErrorState),
            statusOnly: showsTextToolbarStatus
        )
        updateCandidateTextOverlay()
        if isRecordingState {
            let audioLevel = currentBridgeStatus?.audioLevel
            voicePrint.updateLevel(audioLevel)
            topRowVoicePrint.updateLevel(audioLevel)
            textToolbarVoicePrint.updateLevel(audioLevel)
            updatePulseAudioLevel(audioLevel)
            startPulseRings()
        } else {
            stopPulseRings()
        }

        if isRecordingState {
            if recordingElapsedTimer == nil {
                // applyBridgeStatus skips updateUI when only audioLevel moves,
                // so the elapsed text needs its own 1Hz tick.
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !self.voiceDragOutCancelArmed {
                            self.statusLabel.text = self.statusText
                        }
                        if self.textToolbarElapsedLabel.alpha > 0 {
                            self.textToolbarElapsedLabel.text = Self.elapsedOnlyText(startedAt: self.keyboardRecordingStartedAt)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                recordingElapsedTimer = timer
            }
        } else if recordingElapsedTimer != nil {
            recordingElapsedTimer?.invalidate()
            recordingElapsedTimer = nil
        }
        updateTextRecordingStatus(isRecording: isRecordingState, isSending: isSendingState)
    }

    /// updateUI runs on every status transition; the orb icon cycles between
    /// four SF Symbols, so resolve each name once instead of per pass.
    /// Main-thread only.
    private static var symbolImageCache: [String: UIImage] = [:]

    private static func cachedSymbolImage(named name: String) -> UIImage? {
        if let cached = symbolImageCache[name] { return cached }
        guard let image = UIImage(systemName: name) else { return nil }
        symbolImageCache[name] = image
        return image
    }

    private func logSlowUpdateUI(startedAt: CFTimeInterval, animated: Bool, state: KeyboardBridgeState?) {
        let elapsedMS = Int((CACurrentMediaTime() - startedAt) * 1_000)
        guard elapsedMS >= 16 else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastSlowUpdateUILogAt >= 2 else { return }
        lastSlowUpdateUILogAt = now
        kbLog.notice(
            "slow updateUI elapsedMs=\(elapsedMS, privacy: .public), animated=\(animated, privacy: .public), state=\(state?.rawValue ?? "nil", privacy: .public), focus=\(self.keyboardFocus.rawValue, privacy: .public)"
        )
    }

    /// Fades the regular text-toolbar items out while the voiceprint overlay
    /// (recording) or status label (sending / error) takes over. Uses `alpha`
    /// rather than `isHidden` so the UIStackView layout stays put — `isHidden`
    /// removes items from the stack and the right-edge icons reflow.
    private func applyTextToolbarRecordingOverlay(recording: Bool, sending: Bool, statusOnly: Bool) {
        let icons: [UIView] = [
            textToolsButton,
            textStylePickerButton,
            textUndoButton,
            textWandButton,
            textCandidateGridButton,
            textKeyboardSwitchButton,
            textHostSettingsButton,
        ]
        let occupied = recording || sending
        for icon in icons {
            // During recording the undo slot is the ✕ cancel affordance —
            // it must survive the overlay that hides the other icons.
            if recording, icon === textUndoButton { continue }
            icon.alpha = occupied ? 0 : 1
        }
        if recording {
            textUndoButton.isHidden = false
            textUndoButton.alpha = 1
        }
        textToolbarElapsedLabel.alpha = recording ? 1 : 0
        if recording {
            textToolbarElapsedLabel.text = Self.elapsedOnlyText(startedAt: keyboardRecordingStartedAt)
        }
        candidateScrollView.alpha = (occupied || statusOnly) ? 0 : 1
    }

    private func refreshTextRecordingButtons(isRecording: Bool, isSending: Bool) {
        let wandShowsStop = keyboardFocus == .text && isRecording && isCommandPressActive
        let toolsShowsStop = isRecording && !wandShowsStop
        let signature = [
            keyboardFocus.rawValue,
            isRecording ? "recording" : "not-recording",
            isSending ? "sending" : "not-sending",
            wandShowsStop ? "wand-stop" : "wand-idle",
            toolsShowsStop ? "tools-stop" : "tools-idle",
            isKeyboardDark ? "dark" : "light",
        ].joined(separator: ":")
        guard signature != lastTextRecordingButtonsSignature else { return }
        lastTextRecordingButtonsSignature = signature

        configureToolbarIconButton(textWandButton, image: wandShowsStop ? "stop.fill" : "wand.and.stars")
        if wandShowsStop {
            textWandButton.configuration?.baseForegroundColor = UIColor.systemRed
        }
        textWandButton.accessibilityLabel = wandShowsStop
            ? NSLocalizedString("Stop command", comment: "Accessibility label for stopping text command dictation")
            : NSLocalizedString("Command input", comment: "Accessibility label for command/edit-input button")
        textWandButton.isEnabled = wandShowsStop || (!isRecording && !isSending)
        textWandButton.alpha = textWandButton.isEnabled ? 1 : 0.45

        configureToolbarIconButton(textToolsButton, image: toolsShowsStop ? "stop.fill" : "mic.fill")
        if toolsShowsStop {
            textToolsButton.configuration?.baseForegroundColor = UIColor.systemRed
        }
        textToolsButton.accessibilityLabel = toolsShowsStop
            ? NSLocalizedString("Stop dictation", comment: "Accessibility label for stopping keyboard dictation")
            : NSLocalizedString("Dictate", comment: "Accessibility label for keyboard dictation button")
        textToolsButton.isEnabled = toolsShowsStop || (!isRecording && !isSending)
        textToolsButton.alpha = textToolsButton.isEnabled ? 1 : 0.45
    }

    private func updateTextRecordingStatus(isRecording: Bool, isSending: Bool) {
        guard keyboardFocus == .text else {
            isShowingTextRecordingStatus = false
            return
        }
        // Recording / sending status is rendered by the toolbar overlays
        // (voiceprint + textToolbarStatusLabel). The candidate strip just
        // collapses; restore the Rime view when the bridge returns to idle so
        // users see normal candidates again.
        if isRecording || isSending {
            isShowingTextRecordingStatus = true
            setCandidateGridExpanded(false)
            resetCandidateStackForReuse()
            textCandidateGridButton.isHidden = true
            return
        }
        if isShowingTextRecordingStatus {
            isShowingTextRecordingStatus = false
            renderRimeState(rimeInput.state())
            keyboardHaptics.prepareForTextInput()
        }
    }

    private func startPulseRings() {
        let tint = pulseRingColor.cgColor
        for (i, ring) in pulseRings.enumerated() where ring.animation(forKey: "pulse.scale") == nil {
            ring.strokeColor = tint
            ring.opacity = 0

            let begin = CACurrentMediaTime() + Double(i) * 0.6

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.7
            scale.duration = 1.8
            scale.beginTime = begin
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, 0.55, 0.0]
            opacity.keyTimes = [0.0, 0.15, 1.0]
            opacity.duration = 1.8
            opacity.beginTime = begin
            opacity.repeatCount = .infinity

            ring.add(scale, forKey: "pulse.scale")
            ring.add(opacity, forKey: "pulse.opacity")
        }
    }

    private func stopPulseRings() {
        for ring in pulseRings {
            ring.removeAllAnimations()
            ring.opacity = 0
        }
        smoothedAudioLevel = 0
    }

    /// Modulates pulse-ring stroke alpha by a smoothed audio level so the
    /// pulses visibly intensify when the user speaks. The scale-and-fade
    /// CAAnimation in `startPulseRings` provides the rhythm; this provides
    /// the dynamics — important in hold mode where the orb's bars are
    /// hidden behind the finger.
    private func updatePulseAudioLevel(_ newLevel: Float?) {
        let level = max(0, min(1, newLevel ?? 0))
        smoothedAudioLevel = 0.7 * smoothedAudioLevel + 0.3 * level
        let base = pulseRingColor.resolvedColor(with: keyboardTraitCollection)
        // Baseline of 0.30 keeps idle/silence pulses faintly visible — a
        // "still listening" cue — and peaks near 0.95 when speech is loud.
        let modulatedAlpha = min(0.95, 0.30 + CGFloat(smoothedAudioLevel) * 0.65)
        let modulated = base.withAlphaComponent(modulatedAlpha).cgColor
        for ring in pulseRings {
            ring.strokeColor = modulated
        }
    }

    private func attachPressAnimation(_ control: UIControl) {
        control.addTarget(self, action: #selector(controlPressDown(_:)), for: [.touchDown, .touchDragEnter])
        control.addTarget(self, action: #selector(controlPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    private func attachKeyPreview(to button: UIButton, title: String) {
        button.accessibilityValue = title
        button.addTarget(self, action: #selector(keyPreviewPressDown(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(keyPreviewPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    private func attachSpaceCursorGesture(to control: UIControl) {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleTextSpaceCursorGesture(_:)))
        recognizer.minimumPressDuration = 0.32
        recognizer.allowableMovement = 1_000
        recognizer.cancelsTouchesInView = true
        control.addGestureRecognizer(recognizer)
    }

    @objc private func keyPreviewPressDown(_ sender: UIButton) {
        let title = sender.accessibilityValue ?? sender.currentTitle ?? ""
        showKeyPreview(for: sender, title: title)
    }

    @objc private func keyPreviewPressUp(_ sender: UIButton) {
        hideKeyPreview()
    }

    private func showKeyPreview(for control: UIControl, title: String) {
        guard isCharacterPreviewEnabled,
              keyboardFocus == .text,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        keyPreviewBubble.layer.removeAllAnimations()
        keyPreviewLabel.text = title
        // Candidate previews refine the shared label; restore the key look.
        keyPreviewLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        let keyFrame = control.convert(control.bounds, to: view)
        let bubbleWidth = min(max(keyFrame.width + 18, 48), 76)
        let bubbleHeight: CGFloat = 58
        let x = min(
            max(keyFrame.midX - bubbleWidth / 2, 4),
            max(4, view.bounds.width - bubbleWidth - 4)
        )
        let y = max(2, keyFrame.minY - bubbleHeight - 8)
        keyPreviewBubble.frame = CGRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight)
        view.bringSubviewToFront(keyPreviewBubble)
        keyPreviewBubble.isHidden = false
        keyPreviewBubble.alpha = 1
        keyPreviewBubble.transform = .identity
    }

    private func hideKeyPreview() {
        guard !keyPreviewBubble.isHidden else { return }
        keyPreviewBubble.layer.removeAllAnimations()
        keyPreviewBubble.alpha = 0
        keyPreviewBubble.isHidden = true
        keyPreviewBubble.transform = .identity
    }

    @objc private func controlPressDown(_ sender: UIControl) {
        playKeyboardPressFeedbackIfNeeded(for: sender)
        activePressedControls.add(sender)
        schedulePressedControlCleanup(for: sender)
        showKeyPressOverlay(on: sender)
        sender.layer.removeAllAnimations()
        sender.transform = CGAffineTransform(translationX: 0, y: 1.0).scaledBy(x: 0.972, y: 0.972)
    }

    @objc private func controlPressUp(_ sender: UIControl) {
        resetPressedControlState(sender)
    }

    private func schedulePressedControlCleanup(for control: UIControl) {
        let id = ObjectIdentifier(control)
        pressCleanupWorkItems[id]?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak control] in
            guard let self, let control else { return }
            self.resetPressedControlState(control)
        }
        pressCleanupWorkItems[id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func resetPressedControlState(_ control: UIControl) {
        let id = ObjectIdentifier(control)
        pressCleanupWorkItems[id]?.cancel()
        pressCleanupWorkItems[id] = nil
        activePressedControls.remove(control)
        hideKeyPreview()
        hideKeyPressOverlay(on: control)
        control.layer.removeAllAnimations()
        control.transform = .identity
    }

    private func resetAllPressedControlStates(animated: Bool) {
        for control in activePressedControls.allObjects {
            resetPressedControlState(control)
        }
        pressCleanupWorkItems.values.forEach { $0.cancel() }
        pressCleanupWorkItems.removeAll()
    }

    private func showKeyPressOverlay(on control: UIControl) {
        control.viewWithTag(keyPressOverlayTag)?.removeFromSuperview()
        let overlay = UIView(frame: control.bounds)
        overlay.tag = keyPressOverlayTag
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.layer.cornerRadius = 7
        overlay.layer.masksToBounds = true
        control.addSubview(overlay)
        overlay.backgroundColor = UIColor.label.withAlphaComponent(isKeyboardDark ? 0.18 : 0.13)
        overlay.alpha = 1
    }

    private func hideKeyPressOverlay(on control: UIControl) {
        guard let overlay = control.viewWithTag(keyPressOverlayTag) else { return }
        overlay.layer.removeAllAnimations()
        overlay.removeFromSuperview()
    }

    private func playKeyboardPressFeedbackIfNeeded(for control: UIControl) {
        guard control.isDescendant(of: keyRowsStack) else { return }
        keyboardHaptics.playTextKeyPress()
    }

    /// Continuous location tracking alongside the button's target-actions
    /// (cancelsTouchesInView=false, minimumPressDuration=0 — observe-only).
    /// Drives the hold-mode drag-out-to-cancel gesture.
    private func attachDragOutCancelTracker(_ control: UIControl) {
        let tracker = UILongPressGestureRecognizer(target: self, action: #selector(handleDragOutCancelTrack(_:)))
        tracker.minimumPressDuration = 0
        tracker.cancelsTouchesInView = false
        tracker.delegate = self
        control.addGestureRecognizer(tracker)
    }

    @objc private func handleDragOutCancelTrack(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            guard inputMode == .hold,
                  isVoicePressActive || isCommandPressActive,
                  let control = recognizer.view as? UIControl
            else { return }
            let point = recognizer.location(in: view)
            let frame = control.convert(control.bounds, to: view)
            if voiceDragOutCancelArmed {
                let disarmZone = frame.insetBy(
                    dx: -Self.voiceDragOutCancelDisarmInset,
                    dy: -Self.voiceDragOutCancelDisarmInset
                )
                if disarmZone.contains(point) {
                    setVoiceDragOutCancelArmed(false)
                }
            } else {
                let armZone = frame.insetBy(
                    dx: -Self.voiceDragOutCancelArmInset,
                    dy: -Self.voiceDragOutCancelArmInset
                )
                if !armZone.contains(point) {
                    setVoiceDragOutCancelArmed(true)
                }
            }
        default:
            // Gesture recognizers receive the touch before the control's
            // target-actions fire, so the armed flag must survive into
            // endDictationPress/endCommandPress — they consume and reset it.
            break
        }
    }

    private func setVoiceDragOutCancelArmed(_ armed: Bool) {
        guard voiceDragOutCancelArmed != armed else { return }
        voiceDragOutCancelArmed = armed
        keyboardHaptics.playSelectionChanged()
        if armed {
            // The hint and the hold-mode voiceprint share topRow's center —
            // the voiceprint must fully yield or the text is unreadable.
            topRowVoicePrint.alpha = 0
            voiceTitleLabel.text = NSLocalizedString("Release to Cancel", comment: "Hold-to-talk drag-out cancel hint")
            voiceTitleLabel.textColor = .systemRed
            voiceTitleLabel.alpha = 1
            voiceButton.alpha = 0.45
        } else {
            // updateUI restores the voiceprint, title text and color.
            updateUI(animated: false)
        }
    }

    @objc private func voicePressDown() {
        kbLog.debug("voicePressDown fired (bounds=\(NSCoder.string(for: self.voiceButton.bounds), privacy: .public))")
        if styleRewriteCommandID != nil {
            if stopActiveStyleRewriteFromUserAction() {
                lightHaptic()
            }
            return
        }
        if canStopActiveRefine, stopLivePartialRefineFromUserAction() {
            lightHaptic()
            return
        }
        if currentBridgeStatus?.state == .sending,
           !hasRecentProcessingTransportContact {
            isVoicePressActive = false
            openHostForDictation(
                reason: "processing_host_unavailable",
                commandID: currentBridgeStatus?.commandID
            )
            return
        }
        guard !isVoicePressActive else { return }
        isVoicePressActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            self.voiceButton.alpha = 1
        }
        switch inputMode {
        case .hold:
            beginDictationPress()
        case .tap:
            handleTapModePress()
        }
    }

    @objc private func voicePressUp() {
        kbLog.debug("voicePressUp fired")
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = .identity
            self.voiceButton.alpha = 1
        }
        switch inputMode {
        case .hold:
            endDictationPress()
        case .tap:
            isVoicePressActive = false
        }
    }

    @objc private func voicePressCancelled() {
        // Fires for touchUpOutside / touchCancel — user released off-orb or
        // the system interrupted us. Treat the same as `voicePressUp` for
        // hold mode (drag-out no longer cancels; recording always commits).
        kbLog.debug("voicePressCancelled fired")
        let wasActive = isVoicePressActive
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = .identity
            self.voiceButton.alpha = 1
        }
        if wasActive, inputMode == .hold, hasFullAccess {
            endDictationPress()
        }
        isVoicePressActive = false
    }

    @objc private func textVoiceTapped() {
        guard keyboardFocus == .text else { return }
        lightHaptic()

        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            showTextKeyboardStatus(NSLocalizedString("Transcribing", comment: "Inline status after stopping dictation"))
            stopDictationAfterMinimumHoldIfNeeded()
            return
        }

        guard hasFullAccess else {
            openHostForFullAccessSetup(showTextNotice: true)
            return
        }

        guard !isStartRequestInFlight else {
            showTextKeyboardStatus(NSLocalizedString("Opening Typeforme…", comment: "Inline status while dictation handoff is starting"))
            return
        }
        if currentBridgeStatus?.state == .sending {
            if styleRewriteCommandID != nil {
                _ = stopActiveStyleRewriteFromUserAction()
                clearRefineUndoStateForManualEdit()
                return
            }
            if !hasRecentProcessingTransportContact {
                openHostForDictation(
                    reason: "processing_host_unavailable",
                    commandID: currentBridgeStatus?.commandID
                )
                return
            }
            guard stopLivePartialRefineFromUserAction() else {
                showTextKeyboardStatus(sendingStatusTitle)
                return
            }
            clearRefineUndoStateForManualEdit()
        }

        cancelScheduledStop()
        tapRecordingActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        let repairTarget = selectedTextRewriteTarget()
        beginDictationFromKeyboard(
            textEditContext: repairTarget.map { keyboardTextEditContext(intent: .repairSelection, target: $0) },
            target: repairTarget,
            continuesAfterRelease: true
        )
    }

    /// Text-mode wand button: tap once to start recording a voice command,
    /// tap again to end and apply. Reuses the same underlying flow as the
    /// voice-mode commandButton (handleCommandTapModePress / endCommandPress)
    /// but bypasses the user's hold-vs-tap inputMode preference because a
    /// hold gesture on a small toolbar icon while typing is too awkward.
    @objc private func textWandTapped() {
        if isCommandPressActive {
            endCommandPress()
            return
        }
        lightHaptic()
        guard hasFullAccess else {
            openHostForFullAccessSetup(showTextNotice: true)
            return
        }
        guard !isStartRequestInFlight else {
            showTextKeyboardStatus(NSLocalizedString("Opening Typeforme…", comment: "Inline status while dictation handoff is starting"))
            return
        }
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            stopDictationAfterMinimumHoldIfNeeded()
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            showTextKeyboardStatus(sendingStatusTitle)
            return
        }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showMissingCommandTargetError()
            return
        }
        isCommandPressActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        cancelScheduledStop()
        tapRecordingActive = true
        beginDictationFromKeyboard(
            textEditContext: keyboardTextEditContext(intent: .command, target: target),
            target: target,
            continuesAfterRelease: true
        )
    }

    @objc private func commandPressDown() {
        guard !isCommandPressActive else { return }
        let isStoppingActiveCommand = currentBridgeStatus?.state == .recording
            && activeRecordingTextEditIntent == .command
            && inputMode == .tap
        guard (currentBridgeStatus?.state != .recording || isStoppingActiveCommand),
              currentBridgeStatus?.state != .sending,
              !isStartRequestInFlight
        else { return }
        isCommandPressActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.commandButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            self.commandButton.alpha = 0.88
        }
        switch inputMode {
        case .hold:
            beginCommandPress()
        case .tap:
            handleCommandTapModePress()
        }
    }

    @objc private func commandPressUp() {
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.commandButton.transform = .identity
            self.commandButton.alpha = 1
        }
        switch inputMode {
        case .hold:
            endCommandPress()
        case .tap:
            isCommandPressActive = false
        }
    }

    @objc private func commandPressCancelled() {
        let wasActive = isCommandPressActive
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.commandButton.transform = .identity
            self.commandButton.alpha = 1
        }
        if wasActive, inputMode == .hold, hasFullAccess {
            cancelActiveHoldRecording()
        }
        isCommandPressActive = false
    }

    private func beginDictationPress() {
        kbLog.debug("beginDictationPress: fullAccess=\(self.hasFullAccess, privacy: .public), bridgeState=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public), awake=\(self.isBridgeAwake, privacy: .public)")
        lightHaptic()
        guard hasFullAccess else {
            kbLog.notice("beginDictationPress: no full access")
            isVoicePressActive = false
            openHostForFullAccessSetup()
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            kbLog.debug("beginDictationPress: sending in flight, ignore")
            isVoicePressActive = false
            return
        }
        guard currentBridgeStatus?.state != .recording else {
            kbLog.debug("beginDictationPress: already recording; release will stop")
            return
        }
        cancelScheduledStop()
        let repairTarget = selectedTextRewriteTarget()
        beginDictationFromKeyboard(
            textEditContext: repairTarget.map { keyboardTextEditContext(intent: .repairSelection, target: $0) },
            target: repairTarget,
            continuesAfterRelease: false
        )
    }

    private func endDictationPress() {
        guard isVoicePressActive else { return }
        guard hasFullAccess else { return }
        if voiceDragOutCancelArmed {
            voiceDragOutCancelArmed = false
            isVoicePressActive = false
            cancelActiveHoldRecording()
            updateUI(animated: false)
            return
        }
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        guard elapsed >= minimumIntentReleaseDuration else {
            kbLog.debug("endDictationPress: cancelling early release after \(elapsed, privacy: .public)s")
            isVoicePressActive = false
            cancelActiveHoldRecording()
            return
        }

        isVoicePressActive = false
        if isStartRequestInFlight {
            shouldStopWhenStartCompletes = true
            return
        }
        guard currentBridgeStatus?.state == .recording else { return }
        stopDictationAfterMinimumHoldIfNeeded()
    }

    private func handleTapModePress() {
        kbLog.debug("handleTapModePress: fullAccess=\(self.hasFullAccess, privacy: .public), bridgeState=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public), awake=\(self.isBridgeAwake, privacy: .public)")
        lightHaptic()
        guard hasFullAccess else {
            openHostForFullAccessSetup()
            return
        }
        if isStartRequestInFlight {
            kbLog.debug("handleTapModePress: start already in flight; ignoring")
            return
        }
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            kbLog.debug("handleTapModePress: sending .stop command")
            stopDictationAfterMinimumHoldIfNeeded()
            return
        }
        guard currentBridgeStatus?.state != .sending else { return }
        cancelScheduledStop()
        tapRecordingActive = true
        let repairTarget = selectedTextRewriteTarget()
        beginDictationFromKeyboard(
            textEditContext: repairTarget.map { keyboardTextEditContext(intent: .repairSelection, target: $0) },
            target: repairTarget,
            continuesAfterRelease: true
        )
    }

    private func beginCommandPress() {
        lightHaptic()
        guard hasFullAccess else {
            isCommandPressActive = false
            openHostForFullAccessSetup()
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            isCommandPressActive = false
            return
        }
        guard currentBridgeStatus?.state != .recording else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            isCommandPressActive = false
            showMissingCommandTargetError()
            return
        }
        cancelScheduledStop()
        beginDictationFromKeyboard(
            textEditContext: keyboardTextEditContext(intent: .command, target: target),
            target: target,
            continuesAfterRelease: false
        )
    }

    private func endCommandPress() {
        guard isCommandPressActive else { return }
        guard hasFullAccess else { return }
        if voiceDragOutCancelArmed {
            voiceDragOutCancelArmed = false
            isCommandPressActive = false
            cancelActiveHoldRecording()
            updateUI(animated: false)
            return
        }
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        guard elapsed >= minimumIntentReleaseDuration else {
            isCommandPressActive = false
            cancelActiveHoldRecording()
            return
        }

        isCommandPressActive = false
        if isStartRequestInFlight {
            shouldStopWhenStartCompletes = true
            return
        }
        guard currentBridgeStatus?.state == .recording else { return }
        stopDictationAfterMinimumHoldIfNeeded()
    }

    private func handleCommandTapModePress() {
        lightHaptic()
        guard hasFullAccess else {
            openHostForFullAccessSetup()
            return
        }
        if isStartRequestInFlight { return }
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            guard activeRecordingTextEditIntent == .command else { return }
            stopDictationAfterMinimumHoldIfNeeded()
            return
        }
        guard currentBridgeStatus?.state != .sending else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showMissingCommandTargetError()
            return
        }
        cancelScheduledStop()
        tapRecordingActive = true
        beginDictationFromKeyboard(
            textEditContext: keyboardTextEditContext(intent: .command, target: target),
            target: target,
            continuesAfterRelease: true
        )
    }

    private func beginDictationFromKeyboard(
        textEditContext: KeyboardTextEditContext? = nil,
        target: TextRewriteTarget? = nil,
        continuesAfterRelease _: Bool
    ) {
        guard !isStartRequestInFlight else { return }
        startDictationCommand(textEditContext: textEditContext, target: target)
    }

    private func openHostForDictation(reason: String = "bridge_unavailable", commandID: String? = nil) {
        if let commandID {
            guard !hostOpenAttemptedStartCommandIDs.contains(commandID) else {
                kbLog.notice("openHostForDictation: suppressing duplicate host open reason=\(reason, privacy: .public) command_id=\(commandID, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-ui",
                    event: "open_host_suppressed_duplicate_command",
                    fields: [
                        "reason": reason,
                        "command_id": commandID,
                    ]
                )
                updateUI()
                return
            }
            hostOpenAttemptedStartCommandIDs.insert(commandID)
        }
        kbLog.notice("openHostForDictation: bridge unavailable; opening host app reason=\(reason, privacy: .public) command_id=\(commandID ?? "none", privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "open_host_for_dictation",
            fields: [
                "reason": reason,
                "command_id": commandID ?? "none",
            ]
        )
        isStartRequestInFlight = false
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        pendingStartCommandID = nil
        confirmedRecordingCommandID = nil
        activeRecordingCommandID = nil
        cancelStartConfirmationTimeout()
        cancelDarwinStartAckTimeout()
        // Bridge is unreachable — drop the durable awake signal so the next
        // press takes the probe path instead of optimistically fast-pathing.
        lastDarwinAwakeAt = 0
        if inputMode == .tap {
            tapRecordingActive = false
        }
        isVoicePressActive = false
        isCommandPressActive = false
        activeRecordingTextEditIntent = nil
        activeRecordingTextTarget = nil
        cancelScheduledHostOpen()
        // Third-party keyboard extensions cannot keep dictation reachable by
        // themselves. Hand off to the containing app so it can prepare the
        // selected host-owned capture mode.
        openHostAppForKeyboardAction(
            "microphone",
            openingMessage: "Opening Typeforme to prepare dictation."
        )
    }

    private func openStandbyInHostApp() {
        openHostAppForKeyboardAction(
            "standby",
            openingMessage: "Opening Typeforme to prepare dictation."
        )
    }

    private func openHostAppForKeyboardAction(
        _ action: String,
        openingMessage: String
    ) {
        guard hasFullAccess else {
            openHostForFullAccessSetup(showTextNotice: keyboardFocus == .text)
            return
        }
        if isRunningInsideHostApp, action != "standby" {
            kbLog.notice("openHostAppForKeyboardAction: already running inside host app; suppressing self-open")
            cancelHostWakeResetTask()
            openingHostUntil = 0
            bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Ready")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        if action != "standby",
           suppressDuplicateHostOpen(source: "keyboard-action:\(action)") {
            return
        }
        let requestedCorrectionMode = action == "record" ? currentDefaultCorrectionMode() : correctionMode
        kbLog.notice("openHostAppForKeyboardAction: action=\(action, privacy: .public)")
        let handoff = KeyboardHostHandoff(
            action: action,
            correctionMode: requestedCorrectionMode.rawValue
        )
        guard KeyboardSharedDefaults.saveHostHandoff(handoff) else {
            kbLog.error("openHostAppForKeyboardAction: failed to save keyboard handoff")
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Open Typeforme to prepare dictation.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }

        var components = URLComponents()
        components.scheme = "typeforme"
        components.host = action
        components.queryItems = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "handoff_id", value: handoff.id),
        ]
        guard let url = components.url else { return }
        openingHostUntil = Date().timeIntervalSince1970 + 8
        bridgeStatus = KeyboardBridgeStatus(state: .standby, message: openingMessage)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        if keyboardFocus == .text {
            showTextKeyboardStatus(NSLocalizedString("Opening Typeforme…", comment: "Inline status while opening the host app"))
        }
        openHostApp(url) { [weak self] success in
            kbLog.debug("openHostAppForKeyboardAction: open success=\(success, privacy: .public)")
            guard !success else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelHostWakeResetTask()
                self.openingHostUntil = 0
                self.tapRecordingActive = false
                self.bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Open Typeforme to prepare dictation.")
                self.lastBridgeContactAt = Date().timeIntervalSince1970
                self.updateUI()
                if self.keyboardFocus == .text {
                    self.showTextKeyboardStatus(NSLocalizedString("Open Typeforme", comment: "Inline status when host app cannot be opened"))
                }
            }
        }

        // Safety net: if the host wake reports success but the host never
        // finishes booting (or never posts the sessionStarted Darwin notification
        // that would clear the spinner), the keyboard would otherwise show
        // "Opening Typeforme..." forever because UI only re-renders on touch,
        // timer, or notification. After the 8s window expires, force a one-shot
        // redraw and reset bridge state so the user can try again.
        cancelHostWakeResetTask()
        hostWakeResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.hostWakeResetTask = nil
                guard !self.isOpeningHostApp else { return }
                guard self.bridgeStatus?.state == .standby else { return }
                self.bridgeStatus = KeyboardBridgeStatus(state: .idle, message: self.inputMode.idleTitle)
                self.lastBridgeContactAt = 0
                self.updateUI()
                if self.keyboardFocus == .text {
                    self.showTextKeyboardStatus("")
                }
            }
        }
    }

    private func openHostForFullAccessSetup(showTextNotice: Bool = false) {
        showFullAccessRequiredStatus(showTextNotice: showTextNotice)
        guard !isRunningInsideHostApp else {
            kbLog.notice("openHostForFullAccessSetup: already running inside host app; posted full access signal only")
            return
        }
        if suppressDuplicateHostOpen(source: "full-access-setup") { return }

        var components = URLComponents()
        components.scheme = "typeforme"
        components.host = "setup"
        components.queryItems = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "reason", value: "full_access"),
        ]
        guard let url = components.url else { return }
        openingHostUntil = Date().timeIntervalSince1970 + 8
        updateUI()
        openHostApp(url) { [weak self] success in
            kbLog.debug("openHostForFullAccessSetup: open success=\(success, privacy: .public)")
            guard !success else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelHostWakeResetTask()
                self.openingHostUntil = 0
                self.updateUI()
            }
        }
    }

    private func cancelHostWakeResetTask() {
        hostWakeResetTask?.cancel()
        hostWakeResetTask = nil
    }

    private func openHostApp(_ url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        kbLog.debug("openHostApp: opening URL via SwiftUI link opener")
        hostLinkOpener.open(url) { success in
            kbLog.debug("openHostApp: SwiftUI link opener success=\(success, privacy: .public)")
            completion(success)
        }
    }

    private func startDictationCommand(
        textEditContext: KeyboardTextEditContext? = nil,
        target: TextRewriteTarget? = nil
    ) {
        kbLog.notice("beginDictationFromKeyboard: sending .start command")
        if activeMarkedTextOwner == .rimeComposition {
            _ = commitDisplayedRimeCompositionIfNeeded()
        }
        isStartRequestInFlight = true
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        confirmedRecordingCommandID = nil
        pendingCancelCommandID = nil
        let recordingMode = currentDefaultCorrectionMode()
        if correctionMode != recordingMode {
            correctionMode = recordingMode
            lastCorrectionModeButtonSignature = ""
        }
        let dictationContext = textEditContext == nil ? currentDictationContext() : nil
        let command = KeyboardBridgeCommand(
            action: .start,
            correctionMode: recordingMode.rawValue,
            textEditContext: textEditContext,
            dictationContext: dictationContext
        )
        clearLivePartialMarkedTextIfStillOwned(
            commandID: livePartialPreviewState?.commandID,
            reason: "new_command"
        )
        livePartialPreviewState = nil
        activeRecordingCommandID = command.id
        pendingStartCommandID = command.id
        trackedStartCommandIDs.removeAll(keepingCapacity: true)
        rememberStartHandshakeCommand(command.id)
        hostOpenAttemptedStartCommandIDs.removeAll(keepingCapacity: true)
        activeRecordingTextEditIntent = textEditContext?.intent
        activeRecordingTextTarget = target.map {
            PendingRecordingTextTarget(commandID: command.id, target: $0)
        }
        activeDictationInsertionAnchor = textEditContext == nil
            ? PendingDictationInsertionAnchor(
                commandID: command.id,
                contextBefore: limitedContextBefore(textDocumentProxy.documentContextBeforeInput ?? ""),
                contextAfter: limitedContextAfter(textDocumentProxy.documentContextAfterInput ?? "")
            )
            : nil
        logKeyboardStartDiagnostics(commandID: command.id, event: "intent")
        scheduleStartConfirmationTimeout(commandID: command.id)
        sendBridgeCommand(command)
    }

    private func logKeyboardStartDiagnostics(commandID: String, event: String) {
        let now = Date().timeIntervalSince1970
        let bridgeAgeMS = diagnosticAgeMilliseconds(since: lastBridgeContactAt, now: now)
        let darwinAgeMS = diagnosticAgeMilliseconds(since: lastDarwinAwakeAt, now: now)
        let streamAgeMS = diagnosticAgeMilliseconds(since: lastStatusStreamFrameAt, now: now)
        kbLog.notice("keyboard start diagnostic event=\(event, privacy: .public) command_id=\(commandID, privacy: .public) state=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public) bridge_awake=\(self.isBridgeAwake, privacy: .public) presentation_awake=\(self.isBridgeAwakeForPresentation, privacy: .public) opening_host=\(self.isOpeningHostApp, privacy: .public) bridge_age_ms=\(bridgeAgeMS, privacy: .public) darwin_age_ms=\(darwinAgeMS, privacy: .public) stream_age_ms=\(streamAgeMS, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: event,
            fields: [
                "command_id": commandID,
                "state": self.currentBridgeStatus?.state.rawValue ?? "nil",
                "bridge_awake": "\(self.isBridgeAwake)",
                "presentation_awake": "\(self.isBridgeAwakeForPresentation)",
                "opening_host": "\(self.isOpeningHostApp)",
                "bridge_age_ms": "\(bridgeAgeMS)",
                "darwin_age_ms": "\(darwinAgeMS)",
                "stream_age_ms": "\(streamAgeMS)",
            ]
        )
    }

    private func rememberStartHandshakeCommand(
        _ commandID: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard !commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pruneTrackedStartCommands(now: now)
        trackedStartCommandIDs[commandID] = now
    }

    private func forgetStartHandshakeCommand(_ commandID: String?) {
        guard let commandID else { return }
        trackedStartCommandIDs.removeValue(forKey: commandID)
    }

    private func pruneTrackedStartCommands(now: TimeInterval = Date().timeIntervalSince1970) {
        let cutoff = now - Self.startHandshakeCommandTTL
        trackedStartCommandIDs = trackedStartCommandIDs.filter { $0.value >= cutoff }
    }

    private func startHandshakePolicySnapshot(
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> KeyboardStartHandshakePolicy.Snapshot {
        pruneTrackedStartCommands(now: now)
        return KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: isStartRequestInFlight,
            pendingStartCommandID: pendingStartCommandID,
            activeRecordingCommandID: activeRecordingCommandID,
            pendingDarwinStartAckCommandID: pendingDarwinStartAckCommandID,
            trackedStartCommandIDs: Set(trackedStartCommandIDs.keys)
        )
    }

    private func handleCommandReceiptNotification() {
        let now = Date().timeIntervalSince1970
        pruneProcessedCommandReceipts(now: now)
        guard let receipt = KeyboardSharedDefaults.loadCommandReceipt(now: now) else {
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-ui",
                event: "command_receipt_missing_or_expired"
            )
            return
        }
        guard processedCommandReceiptIDs[receipt.id] == nil else { return }
        processedCommandReceiptIDs[receipt.id] = now
        kbLog.notice("command receipt received action=\(receipt.action.rawValue, privacy: .public) phase=\(receipt.phase.rawValue, privacy: .public) command_id=\(receipt.commandID, privacy: .public) reason=\(receipt.reason ?? "none", privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "command_receipt_received",
            fields: [
                "action": receipt.action.rawValue,
                "phase": receipt.phase.rawValue,
                "command_id": receipt.commandID,
                "reason": receipt.reason ?? "none",
            ]
        )
        let matchesActiveStart = KeyboardStartHandshakePolicy.isTrackedStartCommandID(
            receipt.commandID,
            in: startHandshakePolicySnapshot(now: now)
        )
        guard receipt.action == .start, matchesActiveStart else { return }
        rememberStartHandshakeCommand(receipt.commandID, now: now)

        switch receipt.phase {
        case .accepted:
            cancelDarwinStartAckTimeout()
            lastDarwinAwakeAt = now
            openingHostUntil = 0
            if pendingStartCommandID == nil {
                pendingStartCommandID = receipt.commandID
            }
            if activeRecordingCommandID == nil {
                activeRecordingCommandID = receipt.commandID
            }
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "darwin_start_ack_received")
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "start_waiting_recording_after_ack")
            refreshBridgeStatus(captureSelection: false, force: true)
            updateUI()
        case .bridgeReady:
            lastDarwinAwakeAt = now
            refreshBridgeStatus(captureSelection: false, force: true)
        case .bridgeUnavailable:
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "darwin_start_bridge_unavailable")
        case .recordingStarted:
            handleRecordingStartedReceipt(receipt, now: now)
        case .captureNotReady:
            cancelDarwinStartAckTimeout()
            forgetStartHandshakeCommand(receipt.commandID)
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "darwin_start_capture_not_ready_open_host")
            openHostForDictation(
                reason: "capture_not_ready_\(receipt.reason ?? "unknown")",
                commandID: receipt.commandID
            )
        case .failed:
            cancelDarwinStartAckTimeout()
            forgetStartHandshakeCommand(receipt.commandID)
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "darwin_start_failed_open_host")
            openHostForDictation(
                reason: "darwin_start_failed_\(receipt.reason ?? "unknown")",
                commandID: receipt.commandID
            )
        }
    }

    private func handleRecordingStartedReceipt(_ receipt: KeyboardCommandReceipt, now: TimeInterval) {
        guard pendingStopCommandID != receipt.commandID,
              pendingCancelCommandID != receipt.commandID
        else {
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "recording_started_receipt_ignored_after_stop")
            return
        }
        if let current = currentBridgeStatus,
           current.commandID == receipt.commandID,
           current.state == .sending || current.state == .result || current.state == .error || current.state == .idle,
           !isStartRequestInFlight {
            logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "recording_started_receipt_ignored_stale")
            return
        }
        cancelDarwinStartAckTimeout()
        lastDarwinAwakeAt = now
        openingHostUntil = 0
        if pendingStartCommandID == nil {
            pendingStartCommandID = receipt.commandID
        }
        if activeRecordingCommandID == nil {
            activeRecordingCommandID = receipt.commandID
        }
        let status = KeyboardBridgeStatus(
            commandID: receipt.commandID,
            state: .recording,
            message: "Recording",
            defaultCorrectionMode: currentDefaultCorrectionMode().rawValue,
            backendReachable: currentBridgeStatus?.backendReachable
        )
        logKeyboardStartDiagnostics(commandID: receipt.commandID, event: "recording_started_receipt_confirmed")
        applyBridgeStatus(status, recordsLiveContact: false)
        finishStartRequestIfNeeded(status: status)
        refreshBridgeStatusAfterDarwinStartIfNeeded(needsStatusStreamRefreshAfterDarwinStart(now: now))
    }

    private func pruneProcessedCommandReceipts(now: TimeInterval = Date().timeIntervalSince1970) {
        let cutoff = now - Self.processedCommandReceiptTTL
        processedCommandReceiptIDs = processedCommandReceiptIDs.filter { $0.value >= cutoff }
    }

    private func scheduleDarwinStartAckTimeout(commandID: String) {
        cancelDarwinStartAckTimeout()
        pendingDarwinStartAckCommandID = commandID
        darwinStartAckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.darwinStartAckTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.pendingDarwinStartAckCommandID == commandID,
                      self.isStartRequestInFlight,
                      self.pendingStartCommandID == commandID,
                      !self.isCurrentRecordingConfirmed
                else { return }
                self.logKeyboardStartDiagnostics(commandID: commandID, event: "darwin_start_ack_timeout_open_host")
                self.openHostForDictation(reason: "darwin_start_ack_timeout", commandID: commandID)
            }
        }
    }

    private func cancelDarwinStartAckTimeout() {
        darwinStartAckTask?.cancel()
        darwinStartAckTask = nil
        pendingDarwinStartAckCommandID = nil
    }

    private func diagnosticAgeMilliseconds(since timestamp: TimeInterval, now: TimeInterval) -> Int {
        guard timestamp > 0, now >= timestamp else { return -1 }
        return Int((now - timestamp) * 1_000)
    }

    private func finishStartRequestIfNeeded(status: KeyboardBridgeStatus?) {
        let completedCommandID = status?.commandID ?? pendingStartCommandID ?? activeRecordingCommandID
        cancelScheduledHostOpen()
        cancelStartConfirmationTimeout()
        cancelDarwinStartAckTimeout()
        isStartRequestInFlight = false
        pendingStartCommandID = nil
        forgetStartHandshakeCommand(completedCommandID)
        if let status, status.state == .recording {
            confirmedRecordingCommandID = status.commandID ?? activeRecordingCommandID
        }
        if shouldCancelWhenStartCompletes {
            shouldCancelWhenStartCompletes = false
            shouldStopWhenStartCompletes = false
            if isCurrentRecordingConfirmed {
                sendBridgeCommand(.cancel)
            }
            activeRecordingTextEditIntent = nil
            activeRecordingTextTarget = nil
            return
        }
        guard shouldStopWhenStartCompletes else { return }
        shouldStopWhenStartCompletes = false
        if isCurrentRecordingConfirmed {
            stopDictationAfterMinimumHoldIfNeeded()
        }
    }

    private func handleStartCommandResponse(_ status: KeyboardBridgeStatus, commandID: String) {
        guard pendingStartCommandID == commandID || activeRecordingCommandID == commandID else { return }
        if isLiveStartConfirmation(status) {
            applyBridgeStatus(status)
            finishStartRequestIfNeeded(status: status)
            return
        }
        forgetStartHandshakeCommand(commandID)
        isStartRequestInFlight = false
        pendingStartCommandID = nil
        confirmedRecordingCommandID = nil
        activeRecordingCommandID = nil
        activeRecordingTextEditIntent = nil
        activeRecordingTextTarget = nil
        tapRecordingActive = false
        isVoicePressActive = false
        isCommandPressActive = false
        cancelStartConfirmationTimeout()
        cancelDarwinStartAckTimeout()
        if status.state == .recording {
            bridgeStatus = KeyboardBridgeStatus(
                commandID: status.commandID ?? commandID,
                state: .error,
                message: "Typeforme is already recording."
            )
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        applyBridgeStatus(status)
        updateUI()
    }

    private func handleReachableStartWithoutStatus(commandID: String) {
        guard pendingStartCommandID == commandID || activeRecordingCommandID == commandID else { return }
        isStartRequestInFlight = true
        pendingStartCommandID = commandID
        if activeRecordingCommandID == nil {
            activeRecordingCommandID = commandID
        }
        if currentBridgeStatus?.commandID != commandID || currentBridgeStatus?.state != .standby {
            bridgeStatus = KeyboardBridgeStatus(
                commandID: commandID,
                state: .standby,
                message: "Starting recording"
            )
        }
        lastBridgeContactAt = Date().timeIntervalSince1970
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "start_pending_confirmation",
            fields: ["command_id": commandID]
        )
        updateUI()
    }

    private func failStartConfirmation(commandID: String, message: String) {
        guard pendingStartCommandID == commandID || activeRecordingCommandID == commandID else { return }
        forgetStartHandshakeCommand(commandID)
        isStartRequestInFlight = false
        pendingStartCommandID = nil
        confirmedRecordingCommandID = nil
        activeRecordingCommandID = nil
        activeRecordingTextEditIntent = nil
        activeRecordingTextTarget = nil
        tapRecordingActive = false
        isVoicePressActive = false
        isCommandPressActive = false
        cancelStartConfirmationTimeout()
        cancelDarwinStartAckTimeout()
        bridgeStatus = KeyboardBridgeStatus(
            commandID: commandID,
            state: .error,
            message: message
        )
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
    }

    private func scheduleStartConfirmationTimeout(commandID: String) {
        cancelStartConfirmationTimeout()
        startConfirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startConfirmationTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let shouldProbe = await MainActor.run {
                guard !Task.isCancelled,
                      self.isStartRequestInFlight,
                      self.pendingStartCommandID == commandID,
                      !self.isCurrentRecordingConfirmed
                else { return false }
                self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_confirmation_timeout_probe_begin")
                if self.pendingDarwinStartAckCommandID == nil {
                    self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_recording_timeout_after_ack")
                }
                return true
            }
            guard shouldProbe, !Task.isCancelled else { return }
            let bridgeToken = await MainActor.run { self.hostKeyboardBridgeToken }
            let probe = await self.localClient.probeStatus(
                bridgeToken: bridgeToken,
                helloTimeout: Self.startProbeHelloTimeout,
                statusTimeout: Self.startProbeStatusTimeout
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.isStartRequestInFlight,
                      self.pendingStartCommandID == commandID,
                      !self.isCurrentRecordingConfirmed
                else { return }
                switch probe {
                case .unreachable:
                    self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_confirmation_timeout_unreachable_open_host")
                    self.openHostForDictation(reason: "start_confirmation_timeout_unreachable", commandID: commandID)
                case .reachable(let status):
                    if let status, self.isLiveStartConfirmation(status) {
                        self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_confirmation_timeout_status_recording")
                        self.applyBridgeStatus(status)
                        self.finishStartRequestIfNeeded(status: status)
                    } else if let status, status.state == .recording {
                        self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_confirmation_timeout_status_other_recording")
                        self.handleStartCommandResponse(status, commandID: commandID)
                    } else if let status, status.state == .error {
                        self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_confirmation_timeout_status_error")
                        self.handleStartCommandResponse(status, commandID: commandID)
                    } else {
                        self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_confirmation_timeout_no_recording")
                        self.failStartConfirmation(
                            commandID: commandID,
                            message: "Recording did not start. Try again."
                        )
                    }
                }
            }
        }
    }

    private func cancelStartConfirmationTimeout() {
        startConfirmationTask?.cancel()
        startConfirmationTask = nil
    }

    private var isCurrentRecordingConfirmed: Bool {
        guard let status = currentBridgeStatus else { return false }
        return isConfirmedRecordingStatus(status)
    }

    private func isConfirmedRecordingStatus(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording,
              let commandID = status.commandID
        else { return false }
        return commandID == confirmedRecordingCommandID
    }

    private func cancelActiveRecordingForKeyboardDismissal() {
        let shouldCancel = isStartRequestInFlight
            || tapRecordingActive
            || isVoicePressActive
            || isCommandPressActive
            || activeRecordingCommandID != nil
            || activeRecordingTextTarget != nil
            || pendingStopCommandID != nil
            || currentBridgeStatus?.state == .recording
            || currentBridgeStatus?.state == .sending
        guard shouldCancel else { return }

        if isOpeningHostApp, isStartRequestInFlight {
            kbLog.notice("keyboard disappearing during host handoff with start pending; leaving host recording active")
            cancelScheduledStop()
            shouldStopWhenStartCompletes = false
            shouldCancelWhenStartCompletes = false
            isVoicePressActive = false
            isCommandPressActive = false
            tapRecordingActive = false
            return
        }

        kbLog.notice("keyboard disappearing during dictation; canceling host recording")
        cancelScheduledStop()
        shouldStopWhenStartCompletes = false
        isVoicePressActive = false
        isCommandPressActive = false
        tapRecordingActive = false
        pendingStartCommandID = nil
        confirmedRecordingCommandID = nil
        cancelStartConfirmationTimeout()
        cancelDarwinStartAckTimeout()
        cancelScheduledHostOpen()
        shouldCancelWhenStartCompletes = isStartRequestInFlight
        let commandID = activeRecordingCommandID
            ?? activeRecordingTextTarget?.commandID
            ?? pendingStopCommandID
            ?? UUID().uuidString
        let command = KeyboardBridgeCommand(
            id: commandID,
            action: .cancel,
            correctionMode: correctionMode.rawValue
        )
        sendBridgeCommand(command)

        // The extension may be suspended before its local request completes.
        // Send the same command id through Darwin as a one-shot backup; Host
        // treats the duplicate delivery idempotently.
        let savedForDarwin = KeyboardSharedDefaults.saveDarwinCommand(command)
        let postedDarwin = postAuthenticatedKeyboardRequest(
            KeyboardDarwinNotificationName.requestCancelDictation
        )
        kbLog.notice("keyboard dismissal cancel backup saved=\(savedForDarwin, privacy: .public) posted=\(postedDarwin, privacy: .public) command_id=\(commandID, privacy: .public)")
    }

    private func cancelActiveHoldRecording() {
        tapRecordingActive = false
        isCommandPressActive = false
        if isStartRequestInFlight {
            shouldCancelWhenStartCompletes = true
            shouldStopWhenStartCompletes = false
            return
        }
        if currentBridgeStatus?.state == .recording {
            sendBridgeCommand(.cancel)
        }
        activeRecordingTextTarget = nil
        activeRecordingTextEditIntent = nil
        activeRecordingCommandID = nil
        pendingStartCommandID = nil
        confirmedRecordingCommandID = nil
        cancelStartConfirmationTimeout()
        cancelDarwinStartAckTimeout()
        pendingStopCommandID = nil
        livePartialPreviewState = nil
    }

    private func stopDictationAfterMinimumHoldIfNeeded() {
        cancelScheduledStop()
        tapRecordingActive = false
        isCommandPressActive = false
        guard currentBridgeStatus?.state == .recording else { return }
        guard isCurrentRecordingConfirmed else { return }
        let now = Date().timeIntervalSince1970
        let startedAt = keyboardRecordingStartedAt > 0 ? keyboardRecordingStartedAt : voicePressBeganAt
        let elapsed = now - startedAt
        let delay = max(0, minimumHoldRecordingDuration - elapsed)
        guard delay > 0 else {
            kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: sending .stop command")
            sendBridgeCommand(.stop)
            return
        }

        kbLog.debug("stopDictationAfterMinimumHoldIfNeeded: delaying stop by \(delay, privacy: .public)s")
        scheduledStopTask = Task { [weak self] in
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await MainActor.run {
                guard let self, self.currentBridgeStatus?.state == .recording else { return }
                guard self.isCurrentRecordingConfirmed else { return }
                self.scheduledStopTask = nil
                kbLog.debug("stopDictationAfterMinimumHoldIfNeeded: delayed .stop command")
                self.sendBridgeCommand(.stop)
            }
        }
    }

    private func cancelScheduledStop() {
        scheduledStopTask?.cancel()
        scheduledStopTask = nil
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
    }

    @objc private func openHostFromSettingsButton() {
        lightHaptic()
        openStandbyInHostApp()
    }

    @objc private func selectCorrectionModeButton(_ sender: UIButton) {
        guard let preset = correctionModeButtons.first(where: { $0.button === sender })?.preset else { return }
        lightHaptic()
        // Close the popover before kicking off the rewrite so the user sees
        // the orb again immediately rather than the popover lingering.
        hideCorrectionPopover()
        rewriteCurrentInputOrPasteboard(using: preset)
    }

    @objc private func undoRefineTapped() {
        // While recording, this button morphs into the cancel affordance —
        // tap mode has no held finger to slide up with. Keep discard on an
        // explicit tap only; release-outside would turn normal finger drift
        // into a hidden cancel gesture.
        if currentBridgeStatus?.state == .recording {
            lightHaptic()
            cancelActiveHoldRecording()
            updateUI(animated: false)
            return
        }
        lightHaptic()
        guard let undo = freshRefineUndoState(),
              replaceRefineUndoTarget(undo.current, with: undo.restoredText)
        else {
            clearRefineUndoState(updateButtons: false)
            showTextKeyboardStatus(
                NSLocalizedString("Undo unavailable", comment: "Inline status when refine undo cannot be applied"),
                color: .systemRed
            )
            updateUI()
            return
        }

        clearRefineUndoState(updateButtons: false)
        recentSelectionTarget = nil
        defaults.removeObject(forKey: lastInsertedCommandIDKey)
        showTextKeyboardStatus(
            NSLocalizedString("Restored", comment: "Inline status after undoing a refine"),
            color: .secondaryLabel
        )
        updateUI()
    }

    @objc private func toggleCorrectionPopover() {
        // Same gating as the popover buttons themselves — if rewriting is
        // disabled there's nothing the popover could usefully do.
        let canOpen = currentBridgeStatus?.state != .recording
            && currentBridgeStatus?.state != .sending
            && !isStartRequestInFlight
            && styleRewriteCommandID == nil
        if isCorrectionPopoverVisible {
            hideCorrectionPopover()
        } else if canOpen {
            showCorrectionPopover()
        }
    }

    private func showCorrectionPopover() {
        guard !isCorrectionPopoverVisible else { return }
        isCorrectionPopoverVisible = true
        lightHaptic()
        updateKeyboardOverlayOrdering()
        view.bringSubviewToFront(correctionPopoverDismissOverlay)
        view.bringSubviewToFront(correctionPopover)
        correctionPopoverDismissOverlay.isHidden = false
        correctionPopover.isHidden = false
        correctionPopover.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.correctionPopoverDismissOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.18)
            self.correctionPopover.alpha = 1
            self.correctionPopover.transform = .identity
        }
    }

    @objc private func hideCorrectionPopover() {
        guard isCorrectionPopoverVisible else { return }
        isCorrectionPopoverVisible = false
        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction],
            animations: {
                self.correctionPopoverDismissOverlay.backgroundColor = UIColor.black.withAlphaComponent(0)
                self.correctionPopover.alpha = 0
                self.correctionPopover.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            },
            completion: { [weak self] _ in
                guard let self else { return }
                // Guard against the popover being re-opened mid-animation.
                if !self.isCorrectionPopoverVisible {
                    self.correctionPopoverDismissOverlay.isHidden = true
                    self.correctionPopover.isHidden = true
                    self.correctionPopover.transform = .identity
                    self.updateKeyboardOverlayOrdering()
                }
            }
        )
    }

    private func updateCorrectionModeButtons() {
        let isEnabled = currentBridgeStatus?.state != .recording
            && currentBridgeStatus?.state != .sending
            && !isStartRequestInFlight
            && styleRewriteCommandID == nil
        let signature = [
            correctionMode.rawValue,
            isEnabled ? "enabled" : "disabled",
            isKeyboardDark ? "dark" : "light",
            correctionModeOptions.map(\.rawValue).joined(separator: ","),
        ].joined(separator: ":")
        guard signature != lastCorrectionModeButtonSignature else { return }
        lastCorrectionModeButtonSignature = signature
        for item in correctionModeButtons {
            let isAvailable = isCorrectionModeAvailable(item.preset)
            let isSelected = item.preset == correctionMode
            let configuration = correctionModeButtonConfiguration(title: item.preset.title, selected: isSelected)
            item.button.configuration = configuration
            item.button.isHidden = !isAvailable
            // Configuration recreates internal layout — re-apply line-wrap
            // constraints so "Structure+" doesn't wrap after each refresh.
            item.button.titleLabel?.numberOfLines = 1
            item.button.titleLabel?.lineBreakMode = .byTruncatingTail
            item.button.titleLabel?.adjustsFontSizeToFitWidth = true
            item.button.titleLabel?.minimumScaleFactor = 0.7
            item.button.isEnabled = isEnabled && isAvailable
            item.button.alpha = isEnabled && isAvailable ? 1 : 0.45
            item.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        applyCorrectionTriggerConfiguration(isEnabled: isEnabled)
        if !isEnabled, isCorrectionPopoverVisible {
            hideCorrectionPopover()
        }
    }

    private func updateRefineUndoButtons() {
        let isBlocked = currentBridgeStatus?.state == .recording
            || currentBridgeStatus?.state == .sending
            || isStartRequestInFlight
            || styleRewriteCommandID != nil
        let canUndo = !isBlocked && freshRefineUndoState() != nil
        if canUndo {
            textUndoButton.isHidden = false
        }
        // Recording morphs the undo slots into ✕ cancel — but only where no
        // held finger exists to drag out with: voice TAP mode and the text
        // keyboard (whose mic/wand are tap-toggles). Hold mode cancels by
        // dragging off the orb, so the ✕ would be dead weight there.
        let isRecordingNow = currentBridgeStatus?.state == .recording
        let showsCancel = isRecordingNow && inputMode == .tap
        if showsCancel != voiceUndoShowsCancel {
            voiceUndoShowsCancel = showsCancel
            configureCapsuleButton(
                voiceUndoButton,
                title: "",
                image: showsCancel ? "xmark" : "arrow.uturn.backward",
                style: .utility
            )
            voiceUndoButton.accessibilityLabel = showsCancel
                ? NSLocalizedString("Cancel dictation", comment: "Accessibility label for cancelling the active recording")
                : NSLocalizedString("Undo refine", comment: "Accessibility label for undoing the latest refine")
        }
        if showsCancel {
            voiceUndoButton.isEnabled = true
            voiceUndoButton.alpha = 1
        } else {
            voiceUndoButton.isEnabled = canUndo
            voiceUndoButton.alpha = canUndo ? 1 : 0.45
        }
        let textShowsCancel = isRecordingNow && keyboardFocus == .text
        if textShowsCancel != textUndoShowsCancel {
            textUndoShowsCancel = textShowsCancel
            configureToolbarIconButton(textUndoButton, image: textShowsCancel ? "xmark" : "arrow.uturn.backward")
            if textShowsCancel {
                textUndoButton.configuration?.baseForegroundColor = .systemRed
            }
            textUndoButton.accessibilityLabel = textShowsCancel
                ? NSLocalizedString("Cancel dictation", comment: "Accessibility label for cancelling the active recording")
                : NSLocalizedString("Undo refine", comment: "Accessibility label for undoing the latest refine")
        }
        if textShowsCancel {
            textUndoButton.isHidden = false
            textUndoButton.isEnabled = true
            textUndoButton.alpha = 1
        } else {
            textUndoButton.isEnabled = canUndo
            textUndoButton.alpha = isBlocked ? 0 : (canUndo ? 1 : 0.35)
        }
    }

    private func clearRefineUndoStateForManualEdit() {
        guard refineUndoState != nil || defaults.data(forKey: refineUndoStateKey) != nil else { return }
        clearRefineUndoState(updateButtons: false)
        updateRefineUndoButtons()
    }

    private func clearRefineUndoState(updateButtons: Bool = true) {
        refineUndoState = nil
        defaults.removeObject(forKey: refineUndoStateKey)
        if updateButtons {
            updateRefineUndoButtons()
        }
    }

    /// Builds the trigger button's compact "current preset + chevron"
    /// configuration. Shares the `capsuleButtonConfiguration` factory used
    /// by the bottom utility row so the Refine chip's frosted-glass blur,
    /// stroke, capsule shape, and contrast match paste / space / delete /
    /// return exactly. The chevron sits on the TRAILING side (matches
    /// iOS picker affordance); the dynamic title is the current mode.
    private func applyCorrectionTriggerConfiguration(isEnabled: Bool) {
        var configuration = capsuleButtonConfiguration(
            title: correctionMode.title,
            image: "chevron.up.chevron.down",
            style: .utility
        )
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        correctionModeTrigger.configuration = configuration
        correctionModeTrigger.titleLabel?.numberOfLines = 1
        correctionModeTrigger.titleLabel?.lineBreakMode = .byTruncatingTail
        correctionModeTrigger.titleLabel?.adjustsFontSizeToFitWidth = true
        correctionModeTrigger.titleLabel?.minimumScaleFactor = 0.7
        correctionModeTrigger.isEnabled = isEnabled
        correctionModeTrigger.alpha = isEnabled ? 1 : 0.45
        let modeLabelFormat = NSLocalizedString("Refine mode: %@", comment: "Accessibility label for the mode trigger")
        correctionModeTrigger.accessibilityLabel = String(format: modeLabelFormat, correctionMode.title)
        correctionModeTrigger.accessibilityHint = NSLocalizedString("Double tap to choose another mode", comment: "Accessibility hint for mode trigger")
    }

    private func rewriteCurrentInputOrPasteboard(using preset: CorrectionMode) {
        guard isCorrectionModeAvailable(preset) else { return }
        guard hasFullAccess else {
            openHostForFullAccessSetup()
            return
        }
        guard styleRewriteCommandID == nil,
              currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending
        else { return }
        correctionMode = preset
        pendingDefaultCorrectionMode = preset
        lastCorrectionModeButtonSignature = ""
        updateCorrectionModeButtons()
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            saveCorrectionModeForNextRecording(using: preset)
            return
        }

        let command = KeyboardBridgeCommand(
            action: .refineText,
            correctionMode: preset.rawValue,
            text: target.text
        )
        styleRewriteCommandID = command.id
        bridgeStatus = KeyboardBridgeStatus(
            commandID: command.id,
            state: .sending,
            message: "Refining",
            processingStage: .refining
        )
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        showTextKeyboardStatus(NSLocalizedString("Refining", comment: "Inline status while refining recent text"))

        styleRewriteTask?.cancel()
        let bridgeToken = hostKeyboardBridgeToken
        styleRewriteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(
                    command,
                    bridgeToken: bridgeToken,
                    timeout: KeyboardBridgeCommandAction.refineText.requestTimeout
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.styleRewriteTask = nil
                    self.finishStyleRewrite(status: status, target: target, commandID: command.id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.styleRewriteTask = nil
                    guard self.styleRewriteCommandID == command.id else { return }
                    self.styleRewriteCommandID = nil
                    self.bridgeStatus = KeyboardBridgeStatus(commandID: command.id, state: .error, message: "Open Typeforme once to prepare rewriting.")
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
    }

    private func saveCorrectionModeForNextRecording(using preset: CorrectionMode) {
        let command = KeyboardBridgeCommand(action: .configure, correctionMode: preset.rawValue)
        showTextKeyboardStatus(NSLocalizedString("Style saved", comment: "Inline status after choosing a style without rewrite text"))

        styleConfigureTask?.cancel()
        let bridgeToken = hostKeyboardBridgeToken
        styleConfigureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(
                    command,
                    bridgeToken: bridgeToken,
                    timeout: KeyboardBridgeCommandAction.configure.requestTimeout
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.styleConfigureTask = nil
                    self.applyBridgeStatus(status)
                    self.showTextKeyboardStatus(NSLocalizedString("Style saved", comment: "Inline status after choosing a style without rewrite text"))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.styleConfigureTask = nil
                    guard self.pendingDefaultCorrectionMode == preset else { return }
                    kbLog.notice("style configure deferred: \(error.localizedDescription, privacy: .public)")
                    self.updateUI()
                }
            }
        }
    }

    private func currentTextRewriteTarget() -> TextRewriteTarget? {
        currentWholeInputRewriteTarget()
    }

    private func currentWholeInputRewriteTarget() -> TextRewriteTarget? {
        prepareWholeInputRewriteTargetCapture()
        guard let contextTarget = currentExpandedContextRewriteTarget() else { return nil }
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "whole_input_rewrite_target_captured",
            fields: contextTarget.diagnosticFields
        )
        return contextTarget
    }

    private func prepareWholeInputRewriteTargetCapture() {
        if keyboardFocus == .text {
            pendingTextTouchCorrection = nil
            acceptPendingTextTouchIfSurvived()
            commitDisplayedRimeCompositionIfNeeded()
        }
        if activeMarkedTextOwner == .rimeComposition {
            replaceMarkedText("")
        }
    }

    private func currentTextRewriteTargetFromActiveRefineUndo() -> TextRewriteTarget? {
        guard let undo = freshRefineUndoState(),
              let target = textRewriteTarget(matching: undo.current)
        else { return nil }
        kbLog.debug("using active refine undo target for chained rewrite")
        return target
    }

    private func textRewriteTarget(matching target: RefineUndoTarget) -> TextRewriteTarget? {
        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentAfter = textDocumentProxy.documentContextAfterInput ?? ""

        if textDocumentProxy.selectedText == target.text,
           currentBefore == target.contextBefore,
           currentAfter.hasPrefix(target.contextAfter) {
            return .selection(
                text: target.text,
                contextBefore: target.contextBefore,
                contextAfter: target.contextAfter
            )
        }

        if currentBefore == target.contextBefore + target.text,
           currentAfter.hasPrefix(target.contextAfter) {
            switch target.scope {
            case .selection:
                return .selection(
                    text: target.text,
                    contextBefore: target.contextBefore,
                    contextAfter: target.contextAfter
                )
            case .context:
                return .context(before: target.text, after: "")
            }
        }

        if currentBefore == target.contextBefore,
           currentAfter.hasPrefix(target.text + target.contextAfter) {
            switch target.scope {
            case .selection:
                return .selection(
                    text: target.text,
                    contextBefore: target.contextBefore,
                    contextAfter: target.contextAfter
                )
            case .context:
                return .context(before: "", after: target.text)
            }
        }

        return nil
    }

    private func currentExpandedContextRewriteTarget() -> TextRewriteTarget? {
        let initialBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let initialAfter = textDocumentProxy.documentContextAfterInput ?? ""
        guard !(initialBefore + initialAfter).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let before = expandedContextBefore(startingWith: initialBefore)
        let after = expandedContextAfter(startingWith: initialAfter)
        kbLog.debug("context rewrite target captured: initialBeforeLen=\(initialBefore.count, privacy: .public), initialAfterLen=\(initialAfter.count, privacy: .public), beforeLen=\(before.count, privacy: .public), afterLen=\(after.count, privacy: .public)")
        return .context(before: before, after: after)
    }

    private func expandedContextBefore(startingWith initialBefore: String) -> String {
        var before = initialBefore
        var chunk = initialBefore
        var moved = 0
        var steps = 0

        while !chunk.isEmpty,
              before.count < Self.textRewriteContextExpansionLimit,
              steps < Self.textRewriteContextExpansionMaxSteps {
            let snapshotBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let snapshotAfter = textDocumentProxy.documentContextAfterInput ?? ""
            let offset = -chunk.count
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            moved += chunk.count
            let nextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let nextAfter = textDocumentProxy.documentContextAfterInput ?? ""
            guard nextBefore != snapshotBefore || nextAfter != snapshotAfter else { break }

            steps += 1
            chunk = nextBefore
            guard !chunk.isEmpty else { break }
            before = chunk + before
            if before.count > Self.textRewriteContextExpansionLimit {
                before = String(before.suffix(Self.textRewriteContextExpansionLimit))
                break
            }
        }

        if moved > 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: moved)
        }
        return before
    }

    private func expandedContextAfter(startingWith initialAfter: String) -> String {
        var after = initialAfter
        var chunk = initialAfter
        var moved = 0
        var steps = 0

        while !chunk.isEmpty,
              after.count < Self.textRewriteContextExpansionLimit,
              steps < Self.textRewriteContextExpansionMaxSteps {
            let snapshotBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let snapshotAfter = textDocumentProxy.documentContextAfterInput ?? ""
            textDocumentProxy.adjustTextPosition(byCharacterOffset: chunk.count)
            moved += chunk.count
            let nextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let nextAfter = textDocumentProxy.documentContextAfterInput ?? ""
            guard nextBefore != snapshotBefore || nextAfter != snapshotAfter else { break }

            steps += 1
            chunk = nextAfter
            guard !chunk.isEmpty else { break }
            after += chunk
            if after.count > Self.textRewriteContextExpansionLimit {
                after = String(after.prefix(Self.textRewriteContextExpansionLimit))
                break
            }
        }

        if moved > 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: -moved)
        }
        return after
    }

    private func selectedTextRewriteTarget() -> TextRewriteTarget? {
        if let selected = textDocumentProxy.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return captureSelectionTarget(selected)
        }

        if let recentSelection = recentSelectionTargetIfFresh() {
            kbLog.debug("using cached selection target for repair")
            return recentSelection
        }
        return nil
    }

    private func captureSelectionTarget(_ selected: String) -> TextRewriteTarget {
        let target = TextRewriteTarget.selection(
            text: selected,
            contextBefore: textDocumentProxy.documentContextBeforeInput ?? "",
            contextAfter: textDocumentProxy.documentContextAfterInput ?? ""
        )
        recentSelectionTarget = target
        recentSelectionCapturedAt = Date().timeIntervalSince1970
        return target
    }

    private func refreshSelectionSnapshot() {
        guard let selected = textDocumentProxy.selectedText,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        _ = captureSelectionTarget(selected)
    }

    private func recentSelectionTargetIfFresh() -> TextRewriteTarget? {
        guard let recentSelectionTarget else { return nil }
        guard Date().timeIntervalSince1970 - recentSelectionCapturedAt <= selectionSnapshotTTL else {
            return nil
        }
        return recentSelectionTarget
    }

    private func keyboardTextEditContext(
        intent: TextEditIntent,
        target: TextRewriteTarget
    ) -> KeyboardTextEditContext {
        switch target {
        case .selection(let text, let contextBefore, let contextAfter):
            return KeyboardTextEditContext(
                intent: intent,
                contextBefore: contextBefore,
                targetText: text,
                contextAfter: contextAfter
            )
        case .context(let before, let after):
            return KeyboardTextEditContext(
                intent: intent,
                contextBefore: "",
                targetText: before + after,
                contextAfter: ""
            )
        }
    }

    private func currentDictationContext() -> KeyboardDictationContext? {
        let before = limitedContextBefore(textDocumentProxy.documentContextBeforeInput ?? "")
        let after = limitedContextAfter(textDocumentProxy.documentContextAfterInput ?? "")
        guard !(before + after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return KeyboardDictationContext(contextBefore: before, contextAfter: after)
    }

    private func matchesCurrentInsertionAnchor(_ anchor: PendingDictationInsertionAnchor) -> Bool {
        guard !anchor.contextBefore.isEmpty || !anchor.contextAfter.isEmpty else {
            return false
        }
        let before = limitedContextBefore(textDocumentProxy.documentContextBeforeInput ?? "")
        let after = limitedContextAfter(textDocumentProxy.documentContextAfterInput ?? "")
        return before == anchor.contextBefore && after == anchor.contextAfter
    }

    private func limitedContextBefore(_ text: String) -> String {
        guard text.count > Self.dictationContextLimit else { return text }
        return String(text.suffix(Self.dictationContextLimit))
    }

    private func limitedContextAfter(_ text: String) -> String {
        guard text.count > Self.dictationContextLimit else { return text }
        return String(text.prefix(Self.dictationContextLimit))
    }

    private func finishStyleRewrite(status: KeyboardBridgeStatus, target: TextRewriteTarget, commandID: String) {
        guard styleRewriteCommandID == commandID else { return }
        styleRewriteCommandID = nil
        guard status.state == .result,
              let text = status.resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            bridgeStatus = status.state == .error
                ? status
                : KeyboardBridgeStatus(commandID: commandID, state: .error, message: status.message)
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }

        guard applyRewrittenText(text, replacing: target) else {
            copyFallbackText(text)
            bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Input changed; result copied.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        recordRefineUndoState(originalTarget: target, rewrittenText: text)
        defaults.set(commandID, forKey: lastInsertedCommandIDKey)
        recentSelectionTarget = nil
        applyDefaultCorrectionModeFromHost(status.defaultCorrectionMode)
        let resultMessage = status.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("without refine")
            ? status.message
            : "Refined"
        bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .result, message: resultMessage, resultText: text)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
    }

    @discardableResult
    private func applyRewrittenText(_ text: String, replacing target: TextRewriteTarget) -> Bool {
        // If a live partial is still showing as marked text, clear it before
        // performing selection / context replacement. Both downstream paths
        // assume the field has no active composition.
        if !activeMarkedText.isEmpty {
            replaceMarkedText("")
        }
        let didApply: Bool
        switch target {
        case .selection(let original, let contextBefore, let contextAfter):
            didApply = applySelectionReplacement(
                text,
                replacing: original,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
        case .context(let before, let after):
            didApply = replaceContextText(text, before: before, after: after)
        }
        var fields = target.diagnosticFields
        fields["replacement_chars"] = "\(text.count)"
        fields["current_before_chars"] = "\(textDocumentProxy.documentContextBeforeInput?.count ?? 0)"
        fields["current_after_chars"] = "\(textDocumentProxy.documentContextAfterInput?.count ?? 0)"
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: didApply ? "rewrite_target_replaced" : "rewrite_target_replace_failed",
            fields: fields
        )
        return didApply
    }

    private func freshRefineUndoState() -> RefineUndoState? {
        let now = Date().timeIntervalSince1970
        if let undo = refineUndoState {
            guard now - undo.updatedAt <= refineUndoStateTTL else {
                clearRefineUndoState(updateButtons: false)
                return nil
            }
            return undo
        }

        guard let data = defaults.data(forKey: refineUndoStateKey) else { return nil }
        guard let undo = try? JSONDecoder().decode(RefineUndoState.self, from: data) else {
            defaults.removeObject(forKey: refineUndoStateKey)
            return nil
        }
        guard now - undo.updatedAt <= refineUndoStateTTL else {
            defaults.removeObject(forKey: refineUndoStateKey)
            return nil
        }
        refineUndoState = undo
        return undo
    }

    private func recordRefineUndoState(originalTarget: TextRewriteTarget, rewrittenText: String) {
        let now = Date().timeIntervalSince1970
        let current = currentRefineUndoTarget(
            for: rewrittenText,
            scope: originalTarget.refineUndoScope
        )
            ?? expectedRefineUndoTarget(originalTarget: originalTarget, rewrittenText: rewrittenText)

        let restoredText: String
        if let previous = freshRefineUndoState(),
           targetsBelongToSameRefineSession(previous.current, originalTarget) {
            restoredText = previous.restoredText
        } else {
            restoredText = originalTarget.text
        }

        let next = RefineUndoState(
            restoredText: restoredText,
            current: current,
            updatedAt: now
        )
        refineUndoState = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: refineUndoStateKey)
        }
        updateRefineUndoButtons()
    }

    private func expectedRefineUndoTarget(
        originalTarget: TextRewriteTarget,
        rewrittenText: String
    ) -> RefineUndoTarget {
        switch originalTarget {
        case .selection(_, let contextBefore, let contextAfter):
            return RefineUndoTarget(
                scope: .selection,
                text: rewrittenText,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
        case .context:
            return RefineUndoTarget(
                scope: .context,
                text: rewrittenText,
                contextBefore: "",
                contextAfter: ""
            )
        }
    }

    private func currentRefineUndoTarget(for text: String, scope: RefineUndoScope) -> RefineUndoTarget? {
        if textDocumentProxy.selectedText == text {
            return RefineUndoTarget(
                scope: scope,
                text: text,
                contextBefore: textDocumentProxy.documentContextBeforeInput ?? "",
                contextAfter: textDocumentProxy.documentContextAfterInput ?? ""
            )
        }

        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        guard currentBefore.hasSuffix(text) else {
            kbLog.notice("refine undo skipped: rewritten text is not anchored at cursor")
            return nil
        }

        return RefineUndoTarget(
            scope: scope,
            text: text,
            contextBefore: String(currentBefore.dropLast(text.count)),
            contextAfter: textDocumentProxy.documentContextAfterInput ?? ""
        )
    }

    private func targetsBelongToSameRefineSession(_ lhs: RefineUndoTarget, _ rhs: TextRewriteTarget) -> Bool {
        guard lhs.scope == rhs.refineUndoScope,
              lhs.text == rhs.text
        else { return false }
        switch rhs {
        case .selection(_, let contextBefore, let contextAfter):
            return lhs.contextBefore == contextBefore && lhs.contextAfter == contextAfter
        case .context(let before, let after):
            return lhs.text == before + after
        }
    }

    private func replaceRefineUndoTarget(_ target: RefineUndoTarget, with text: String) -> Bool {
        if !activeMarkedText.isEmpty {
            replaceMarkedText("")
        }

        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentAfter = textDocumentProxy.documentContextAfterInput ?? ""

        if textDocumentProxy.selectedText == target.text,
           currentBefore == target.contextBefore,
           currentAfter.hasPrefix(target.contextAfter) {
            textDocumentProxy.insertText(text)
            return true
        }

        if currentBefore == target.contextBefore + target.text,
           currentAfter.hasPrefix(target.contextAfter) {
            return replaceTextBeforeCursor(target.text, with: text)
        }

        if replaceTextBeforeCursorAllowingTruncatedContext(
            target.text,
            with: text,
            contextBefore: target.contextBefore,
            contextAfter: target.contextAfter,
            currentBefore: currentBefore,
            currentAfter: currentAfter
        ) {
            return true
        }

        if currentBefore == target.contextBefore,
           currentAfter.hasPrefix(target.text + target.contextAfter) {
            return replaceContextText(text, before: "", after: target.text)
        }

        kbLog.notice("refine undo skipped: current text no longer matches undo target")
        return false
    }

    private func replaceTextBeforeCursorAllowingTruncatedContext(
        _ target: String,
        with replacement: String,
        contextBefore: String,
        contextAfter: String,
        currentBefore: String,
        currentAfter: String
    ) -> Bool {
        guard !target.isEmpty, !currentBefore.isEmpty else { return false }
        let expectedBefore = contextBefore + target
        guard currentBefore.count < expectedBefore.count,
              expectedBefore.hasSuffix(currentBefore),
              target.hasSuffix(currentBefore) || currentBefore.hasSuffix(target)
        else { return false }

        let afterStillCompatible = contextAfter.isEmpty
            || currentAfter.isEmpty
            || currentAfter.hasPrefix(contextAfter)
            || contextAfter.hasPrefix(currentAfter)
        guard afterStillCompatible else { return false }

        deleteBackward(characterCount: target.count)
        textDocumentProxy.insertText(replacement)
        return true
    }

    private func copyFallbackText(_ text: String) {
        guard hasFullAccess else { return }
        UIPasteboard.general.string = text
    }

    private func applySelectionReplacement(
        _ text: String,
        replacing original: String,
        contextBefore: String,
        contextAfter: String
    ) -> Bool {
        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentAfter = textDocumentProxy.documentContextAfterInput ?? ""

        if textDocumentProxy.selectedText == original {
            guard currentBefore == contextBefore,
                  currentAfter.hasPrefix(contextAfter)
            else {
                kbLog.notice("selection replacement skipped: selected text matched but context changed")
                return false
            }
            textDocumentProxy.insertText(text)
            return true
        }

        if currentBefore == contextBefore + original,
           currentAfter.hasPrefix(contextAfter) {
            return replaceTextBeforeCursor(original, with: text)
        }

        if currentBefore == contextBefore,
           currentAfter.hasPrefix(original + contextAfter) {
            return replaceContextText(text, before: "", after: original)
        }

        kbLog.notice("selection replacement skipped: originalLen=\(original.count, privacy: .public), beforeLen=\(currentBefore.count, privacy: .public), afterLen=\(currentAfter.count, privacy: .public)")
        return false
    }

    private func replaceContextText(_ text: String, before: String, after: String) -> Bool {
        guard !after.isEmpty else {
            return replaceTextBeforeCursor(before, with: text)
        }

        guard (textDocumentProxy.documentContextAfterInput ?? "").hasPrefix(after) else {
            return false
        }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: after.count)
        guard (textDocumentProxy.documentContextBeforeInput ?? "").hasSuffix(before + after) else {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: -after.count)
            return false
        }
        return replaceTextBeforeCursor(before + after, with: text)
    }

    private func replaceTextBeforeCursor(_ target: String, with replacement: String) -> Bool {
        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        guard currentBefore.hasSuffix(target) else { return false }
        let expectedPrefix = String(currentBefore.dropLast(target.count))

        deleteBackward(characterCount: target.count)
        var afterDelete = textDocumentProxy.documentContextBeforeInput ?? ""
        if afterDelete != expectedPrefix {
            guard afterDelete.hasPrefix(expectedPrefix) else { return false }
            let leftover = String(afterDelete.dropFirst(expectedPrefix.count))
            guard !leftover.isEmpty, target.hasPrefix(leftover) else { return false }
            deleteBackward(characterCount: leftover.count)
            afterDelete = textDocumentProxy.documentContextBeforeInput ?? ""
        }

        guard afterDelete == expectedPrefix else { return false }
        textDocumentProxy.insertText(replacement)
        return true
    }

    private func deleteBackward(characterCount: Int) {
        guard characterCount > 0 else { return }
        for _ in 0..<characterCount {
            textDocumentProxy.deleteBackward()
        }
    }

    private func correctionModeButtonConfiguration(title: String, selected: Bool) -> UIButton.Configuration {
        var configuration: UIButton.Configuration = .filled()
        configuration.title = title
        configuration.cornerStyle = .capsule
        // Horizontal insets tightened to 4pt so the longest label ("Structure+")
        // fits on a single line at 11pt semibold within the per-button slot.
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        configuration.baseBackgroundColor = selected
            ? UIColor.label.withAlphaComponent(0.92)
            : UIColor.systemBackground.withAlphaComponent(isKeyboardDark ? 0.16 : 0.54)
        configuration.baseForegroundColor = selected ? .systemBackground : .secondaryLabel
        return configuration
    }

    private func selectInputMode(_ rawValue: String) {
        guard currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending,
              !isStartRequestInFlight,
              styleRewriteCommandID == nil
        else { return }
        guard let nextMode = VoiceInputMode(rawValue: rawValue) else { return }
        guard nextMode != inputMode else { return }
        inputMode = nextMode
        defaults.set(inputMode.rawValue, forKey: inputModeKey)
        lightHaptic()
        updateUI()
    }

    @objc private func toggleKeyboardFocus() {
        switch keyboardFocus {
        case .voice:
            setKeyboardFocus(.text, animated: true)
        case .text:
            setKeyboardFocus(.voice, animated: true)
        }
    }

    @objc private func showVoiceFocus() {
        setKeyboardFocus(.voice, animated: true)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === candidateScrollTapRecognizer || gestureRecognizer === candidateGridTapRecognizer {
            guard let touchedView = touch.view else { return true }
            if let control = containingControl(of: touchedView),
               control.isDescendant(of: candidateScrollView) || control.isDescendant(of: candidateGridScrollView) {
                let point = touch.location(in: control)
                return !control.point(inside: point, with: nil)
            }
            return true
        }

        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if (gestureRecognizer === candidateGridTapRecognizer && otherGestureRecognizer === candidateGridScrollView.panGestureRecognizer)
            || (otherGestureRecognizer === candidateGridTapRecognizer && gestureRecognizer === candidateGridScrollView.panGestureRecognizer)
            || (gestureRecognizer === candidateScrollTapRecognizer && otherGestureRecognizer === candidateScrollView.panGestureRecognizer)
            || (otherGestureRecognizer === candidateScrollTapRecognizer && gestureRecognizer === candidateScrollView.panGestureRecognizer) {
            return true
        }
        return false
    }

    fileprivate func switchKeyboardFocusFromFallbackSwipe(deltaX: CGFloat) {
        performKeyboardFocusSwipe(horizontalIntent: deltaX)
    }

    fileprivate func keyboardFocusSwipeIntent(start: CGPoint, current: CGPoint) -> CGFloat? {
        KeyboardFocusPager.horizontalIntent(start: start, current: current)
    }

    private func performKeyboardFocusSwipe(horizontalIntent: CGFloat) {
        guard !isTextSpaceCursorTracking,
              currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending,
              !isStartRequestInFlight
        else { return }
        let now = CACurrentMediaTime()
        guard now >= keyboardFocusSwipeHandledUntil else { return }
        guard let target = keyboardFocusTarget(forHorizontalIntent: horizontalIntent) else { return }
        keyboardFocusSwipeHandledUntil = now + KeyboardFocusPager.handledCooldown
        suppressTextKeyCommitUntil = now + KeyboardFocusPager.commitSuppressionDuration
        pendingKeyboardFocusAnimationIntent = horizontalIntent
        setKeyboardFocus(target, animated: true)
    }

    private func keyboardFocusTarget(forHorizontalIntent horizontalIntent: CGFloat) -> KeyboardFocus? {
        KeyboardFocusPager.target(from: keyboardFocus, horizontalIntent: horizontalIntent)
    }

    private func setKeyboardFocus(_ focus: KeyboardFocus, animated: Bool) {
        guard keyboardFocus != focus else { return }
        resetAllPressedControlStates(animated: false)
        if keyboardFocus == .text {
            commitDisplayedRimeCompositionIfNeeded()
            resetQuoteParity()
        }
        clearTextShiftState()
        keyboardFocus = focus
        defaults.set(focus.rawValue, forKey: keyboardFocusKey)
        updateKeyboardFocus(animated: animated)
        lightHaptic()
    }

    private func updateKeyboardFocus(animated: Bool = true) {
        let isTextFocus = keyboardFocus == .text
        // Apply IME state before swap so composing residue / ASCII mode flip
        // is committed before the slide begins.
        if isTextFocus {
            applyTextInputOptionsToRime()
        } else {
            pendingTextTouchCorrection = nil
            acceptPendingTextTouchIfSurvived()
            replaceMarkedText("")
        }

        guard animated, view.bounds.width > 0 else {
            applyKeyboardFocusChanges(isTextFocus: isTextFocus)
            return
        }

        // Snapshot the current state, apply the change, then slide the
        // snapshot off one edge while sliding the new content in from the
        // other. Gesture-initiated changes follow the user's swipe direction;
        // button-initiated changes use a stable fallback direction.
        let snapshot = rootStack.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = rootStack.convert(rootStack.bounds, to: view)
            snapshot.translatesAutoresizingMaskIntoConstraints = true
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            view.addSubview(snapshot)
        }

        applyKeyboardFocusChanges(isTextFocus: isTextFocus)
        view.layoutIfNeeded()

        let width = view.bounds.width
        let targetFocus: KeyboardFocus = isTextFocus ? .text : .voice
        let animationIntent = pendingKeyboardFocusAnimationIntent
        pendingKeyboardFocusAnimationIntent = nil
        let enteringFrom = KeyboardFocusPager.enteringOffset(
            horizontalIntent: animationIntent,
            fallbackTarget: targetFocus,
            width: width
        )
        let leavingTo = KeyboardFocusPager.leavingOffset(
            horizontalIntent: animationIntent,
            fallbackTarget: targetFocus,
            width: width
        )
        let focusName = isTextFocus ? "text" : "voice"
        let animationStartedAt = Date()

        rootStack.transform = CGAffineTransform(translationX: enteringFrom, y: 0)

        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
            animations: {
                snapshot?.transform = CGAffineTransform(translationX: leavingTo, y: 0)
                self.rootStack.transform = .identity
            },
            completion: { _ in
                snapshot?.removeFromSuperview()
                let elapsedMS = Date().timeIntervalSince(animationStartedAt) * 1000
                kbLog.debug("Keyboard focus \(focusName, privacy: .public) animation completed in \(elapsedMS, privacy: .public) ms")
            }
        )
    }

    private func applyKeyboardFocusChanges(isTextFocus: Bool) {
        topRow.isHidden = isTextFocus
        orbContainer.isHidden = isTextFocus
        utilityRow.isHidden = isTextFocus
        textKeyboardContainer.isHidden = !isTextFocus
        updateKeyboardSurfaceMask()
        updateKeyboardOverlayOrdering()
        keyboardFocusButton.configuration?.image = UIImage(systemName: isTextFocus ? "mic.fill" : "keyboard")
        keyboardFocusButton.accessibilityLabel = isTextFocus
            ? NSLocalizedString("Show voice input", comment: "Accessibility label for showing voice input")
            : NSLocalizedString("Show keyboard", comment: "Accessibility label for showing the screen keyboard")
        voiceTitleLabel.text = isTextFocus
            ? NSLocalizedString("中文键盘", comment: "Title for Chinese keyboard focus")
            : voiceTitle
        if isTextFocus {
            keyboardHaptics.prepareForTextInput()
        } else {
            keyboardHaptics.prepareForKeyboardReady()
        }
    }

    @objc private func toggleSymbolKeyboard() {
        clearTransientKeyboardErrorIfShowing()
        if isRenderedNumericTextKeyboard {
            showsStandardLayoutForNumericTraits = true
            rebuildTextKeyboardRows(layoutKind: .standard)
            updateKeyboardSurfaceMask()
            return
        }
        if showsStandardLayoutForNumericTraits,
           isCurrentTextInputNumericTrait {
            showsStandardLayoutForNumericTraits = false
            clearNumericIncompatibleCompositionState()
            rebuildTextKeyboardRows(layoutKind: textKeyboardLayoutKindForCurrentTraits)
            updateKeyboardSurfaceMask()
            return
        }
        if isSymbolKeyboard {
            isSymbolKeyboard = false
            isAlternateSymbolKeyboard = false
        } else {
            isSymbolKeyboard = true
            isAlternateSymbolKeyboard = false
        }
        rebuildTextKeyboardRows()
    }

    @objc private func toggleAlternateSymbolKeyboard() {
        guard isSymbolKeyboard, !isRenderedNumericTextKeyboard else { return }
        clearTransientKeyboardErrorIfShowing()
        isAlternateSymbolKeyboard.toggle()
        rebuildTextKeyboardRows()
    }

    @objc private func togglePhoneSymbolKeyboard() {
        guard isRenderedNumericTextKeyboard else { return }
        clearTransientKeyboardErrorIfShowing()
        isPhoneSymbolKeyboard.toggle()
        rebuildTextKeyboardRows()
    }

    @objc private func toggleTextShift() {
        guard !isSymbolKeyboard, !isRenderedNumericTextKeyboard else { return }
        clearTransientKeyboardErrorIfShowing()
        // Stray second contact from a fat press on the a↔shift seam: the routed
        // character already committed on touch-down, so this shift touch-up is
        // the same press's other contact. Ignore it so "a + shift" can't both
        // fire. A deliberate shift tap comes well after the last commit.
        if CACurrentMediaTime() - lastTextKeyCommitAt < Self.adjacentKeyGuardWindow {
            kbLog.debug("ignored shift toggle adjacent to recent text-key commit")
            return
        }
        let now = CACurrentMediaTime()
        let autoCap = shouldAutoCapitalizeNextEnglishLetter()
        let isDoubleTap = now - lastShiftTapTime <= 0.42
        if isTextShiftLocked {
            isTextShiftEnabled = false
            isTextShiftLocked = false
            isTextAutoCapitalizationSuppressed = autoCap
        } else if isDoubleTap && (isTextShiftEnabled || autoCap) {
            isTextShiftEnabled = true
            isTextShiftLocked = true
            isTextAutoCapitalizationSuppressed = false
        } else if isTextShiftEnabled {
            isTextShiftEnabled = false
            isTextShiftLocked = false
            isTextAutoCapitalizationSuppressed = autoCap
        } else if autoCap {
            isTextAutoCapitalizationSuppressed.toggle()
        } else {
            isTextShiftEnabled = true
            isTextShiftLocked = false
            isTextAutoCapitalizationSuppressed = false
        }
        lastShiftTapTime = now
        refreshShiftButtonImage()
        refreshLetterCasing()
    }

    @objc private func toggleTextInputLanguage() {
        guard isChineseInputEnabled else { return }
        clearTransientKeyboardErrorIfShowing()
        if textInputLanguage == .chinese {
            commitDisplayedRimeCompositionIfNeeded()
            textInputLanguage = .english
        } else {
            textInputLanguage = .chinese
        }
        resetQuoteParity()
        clearTextShiftState()
        syncPrimaryLanguage()
        defaults.set(textInputLanguage.rawValue, forKey: textInputLanguageKey)
        refreshTextControlTitles()
        rebuildTextKeyboardRows()
        applyTextInputOptionsToRime()
    }

    private func refreshTextControlTitles() {
        let modeTitle: String
        if isRenderedNumericTextKeyboard {
            modeTitle = "ABC"
        } else if showsStandardLayoutForNumericTraits,
                  isCurrentTextInputNumericTrait {
            modeTitle = "123"
        } else {
            modeTitle = isSymbolKeyboard ? "ABC" : "123"
        }
        configureTextControlButton(textModeButton, title: modeTitle, image: nil)
        if isRenderedNumericTextKeyboard {
            textModeButton.accessibilityLabel = NSLocalizedString("Show text keyboard", comment: "Accessibility label for switching from numeric keypad to text keyboard")
        } else if showsStandardLayoutForNumericTraits, isCurrentTextInputNumericTrait {
            textModeButton.accessibilityLabel = NSLocalizedString("Show numeric keypad", comment: "Accessibility label for returning to numeric keypad")
        } else {
            textModeButton.accessibilityLabel = NSLocalizedString("Show numbers and symbols", comment: "Accessibility label for switching to numbers and symbols")
        }
        configureTextControlButton(textAlternateSymbolButton, title: isAlternateSymbolKeyboard ? "123" : "#+=", image: nil)
        configureTextControlButton(textGlobeButton, title: "", image: "globe")
        textGlobeButton.accessibilityLabel = NSLocalizedString("Next keyboard", comment: "Accessibility label for switching to the next keyboard")
        refreshInputModeSwitchKeyVisibility()
        let isRecording = currentBridgeStatus?.state == .recording
        let isSending = currentBridgeStatus?.state == .sending
        refreshTextRecordingButtons(isRecording: isRecording, isSending: isSending)
        configureCandidateExpandButton(isExpanded: isCandidateGridExpanded)
        configureCandidateGridCollapseButton(isExpanded: isCandidateGridExpanded)
        textCandidateGridButton.accessibilityLabel = isCandidateGridExpanded
            ? NSLocalizedString("Hide candidates", comment: "Accessibility label for collapsing candidate list")
            : NSLocalizedString("Show more candidates", comment: "Accessibility label for expanding candidate list")
        candidateGridCollapseButton.accessibilityLabel = textCandidateGridButton.accessibilityLabel
        configureTextLanguageButton()
        refreshReturnKeyTitle()
    }

    private func refreshInputModeSwitchKeyVisibility() {
        textGlobeButton.isHidden = !needsInputModeSwitchKey
    }

    private func refreshShiftButtonImage() {
        guard let textShiftButton else { return }
        let autoCap = shouldAutoCapitalizeNextEnglishLetter()
        let isShiftActive = effectiveTextShiftActive(autoCap: autoCap)
        textShiftButton.isSelected = isShiftActive || isTextShiftLocked
        configureTextKeyButton(
            textShiftButton,
            title: "",
            image: isTextShiftLocked ? "capslock.fill" : (isShiftActive ? "shift.fill" : "shift"),
            weight: .utility
        )
        textShiftButton.accessibilityLabel = isTextShiftLocked
            ? NSLocalizedString("Caps Lock on", comment: "Accessibility label for active Caps Lock key")
            : (isShiftActive
                ? NSLocalizedString("Shift on", comment: "Accessibility label for active Shift key")
                : NSLocalizedString("Shift", comment: "Accessibility label for Shift key"))
    }

    private func effectiveTextShiftActive(autoCap: Bool) -> Bool {
        isTextShiftLocked
            || isTextShiftEnabled
            || (textInputLanguage == .english && autoCap && !isTextAutoCapitalizationSuppressed)
    }

    private func refreshLetterCasing() {
        guard !isSymbolKeyboard else { return }
        let autoCap = shouldAutoCapitalizeNextEnglishLetter()
        if !autoCap, isTextAutoCapitalizationSuppressed {
            isTextAutoCapitalizationSuppressed = false
        }
        let isShiftActive = effectiveTextShiftActive(autoCap: autoCap)
        let nextSnapshot = LetterCasingSnapshot(
            shift: isShiftActive,
            autoCap: autoCap,
            language: textInputLanguage
        )
        guard nextSnapshot != lastLetterCasingSnapshot else { return }
        lastLetterCasingSnapshot = nextSnapshot
        for (key, button) in letterButtonMap {
            let title = displayTitle(forTextKey: key, autoCap: autoCap)
            configureTextKeyButton(button, title: title, image: nil, weight: .normal)
            button.accessibilityValue = title
        }
    }

    @discardableResult
    private func resetShiftIfSticky() -> Bool {
        guard isTextShiftEnabled, !isTextShiftLocked else { return false }
        isTextShiftEnabled = false
        refreshShiftButtonImage()
        refreshLetterCasing()
        return true
    }

    private func clearTextShiftState() {
        guard isTextShiftEnabled || isTextShiftLocked || isTextAutoCapitalizationSuppressed else { return }
        isTextShiftEnabled = false
        isTextShiftLocked = false
        isTextAutoCapitalizationSuppressed = false
        lastShiftTapTime = 0
        refreshShiftButtonImage()
        refreshLetterCasing()
    }

    private func configureTextLanguageButton() {
        // Apply the standard utility key chrome so the button is visible
        // (solid background + 1pt shadow) like other bottom-row keys. Then
        // overlay textLanguageLabel on top with the attributed "中/英" text.
        textLanguageButton.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            let control = button
            let isPressed = control.isHighlighted
            button.configuration = self.textKeyConfiguration(title: "", image: nil, weight: .utility, isPressed: isPressed, isSelected: false)
            self.applyTextKeyLayerStyle(to: button, weight: .utility, isPressed: isPressed, isSelected: false)
        }
        textLanguageButton.configuration = textKeyConfiguration(title: "", image: nil, weight: .utility, isPressed: false, isSelected: false)
        applyTextKeyLayerStyle(to: textLanguageButton, weight: .utility, isPressed: false, isSelected: false)

        let activeTitle = textInputLanguage == .chinese ? "中" : "英"
        let inactiveTitle = textInputLanguage == .chinese ? "英" : "中"
        let text = NSMutableAttributedString(
            string: activeTitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.label,
            ]
        )
        text.append(NSAttributedString(
            string: "/",
            attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: UIColor.tertiaryLabel,
            ]
        ))
        text.append(NSAttributedString(
            string: inactiveTitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel,
            ]
        ))
        textLanguageLabel.attributedText = text
        if textLanguageLabel.superview != nil {
            textLanguageButton.bringSubviewToFront(textLanguageLabel)
        }
        textLanguageButton.accessibilityLabel = textInputLanguage == .chinese
            ? NSLocalizedString("Chinese active, switch to English", comment: "Accessibility label for language toggle")
            : NSLocalizedString("English active, switch to Chinese", comment: "Accessibility label for language toggle")
    }

    @discardableResult
    private func handleTextCharacter(_ character: String) -> Bool {
        guard keyboardFocus == .text,
              CACurrentMediaTime() >= suppressTextKeyCommitUntil,
              currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending
        else {
            return false
        }

        clearTransientKeyboardErrorIfShowing()

        if isRenderedNumericTextKeyboard {
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(character)
            renderRefineSuggestionsIfIdle()
            return true
        }

        if textInputLanguage == .english {
            commitDisplayedRimeCompositionIfNeeded()
            let isAlphabetic = isAlphabeticTextKey(character)
            let shouldCapitalize = isAlphabetic
                && effectiveTextShiftActive(autoCap: shouldAutoCapitalizeNextEnglishLetter())
            let output = shouldCapitalize
                ? character.uppercased()
                : character
            let consumesAutoCapSuppression = isAlphabetic && isTextAutoCapitalizationSuppressed
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(output)
            if consumesAutoCapSuppression {
                isTextAutoCapitalizationSuppressed = false
            }
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            return true
        }

        guard isAlphabeticTextKey(character) else {
            insertChineseDirectTextKey(character)
            return true
        }

        if isTextShiftEnabled {
            processChineseRimeTextKey(character.uppercased(), resetShiftAfterInput: true)
            return true
        }

        processChineseRimeTextKey(character)
        return true
    }

    private func processChineseRimeTextKey(_ character: String, resetShiftAfterInput: Bool = false) {
        defer {
            if resetShiftAfterInput {
                resetShiftIfSticky()
            }
        }
        prepareRimeInputTargetForCurrentDocument()
        let processResult = rimeInput.processCharacterIfReady(
            character,
            asciiPunctuation: chinesePunctuationStyle == .english,
            asciiMode: false
        )
        switch processResult {
        case .notReady(let state) where state.errorMessage != nil:
            pendingRimeCharacters.removeAll()
            pendingRimeDirectTextKeys.removeAll()
            applyRimeState(state)
            renderRefineSuggestionsIfIdle()
        case .notReady(let state):
            queuePendingRimeCharacter(character, state: state)
        case .processed(let state):
            applyRimeState(state)
        }
    }

    private func currentRimeInputTarget() -> RimeInputTarget {
        var contextBefore = textDocumentProxy.documentContextBeforeInput
        if activeMarkedTextOwner == .rimeComposition,
           !activeMarkedText.isEmpty,
           let currentBefore = contextBefore,
           currentBefore.hasSuffix(activeMarkedText) {
            contextBefore = String(currentBefore.dropLast(activeMarkedText.count))
        }
        return RimeInputTarget(
            textInputIdentity: currentTextInputIdentity,
            contextBefore: contextBefore,
            contextAfter: textDocumentProxy.documentContextAfterInput
        )
    }

    private func rimeInputTargetIsCurrent() -> Bool {
        guard let rimeInputTarget else { return false }
        let current = currentRimeInputTarget()
        return current.textInputIdentity == rimeInputTarget.textInputIdentity
            && current.contextBefore == rimeInputTarget.contextBefore
            && current.contextAfter == rimeInputTarget.contextAfter
    }

    private func prepareRimeInputTargetForCurrentDocument() {
        if rimeInputTarget != nil, !rimeInputTargetIsCurrent() {
            discardStaleRimeInput()
        }
        if rimeInputTarget == nil {
            rimeInputTarget = currentRimeInputTarget()
        }
    }

    private func discardRimeInputIfTargetChanged() {
        guard rimeInputTarget != nil, !rimeInputTargetIsCurrent() else { return }
        discardStaleRimeInput()
    }

    private func discardStaleRimeInput() {
        guard !isDiscardingStaleRimeInput else { return }
        isDiscardingStaleRimeInput = true
        defer { isDiscardingStaleRimeInput = false }
        pendingRimeCharacters.removeAll()
        pendingRimeDirectTextKeys.removeAll()
        rimeInputTarget = nil
        let clearedState = rimeInput.clearComposition()
        clearLocalMarkedTextState()
        renderRimeState(clearedState)
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "rime_input_discarded_target_changed"
        )
    }

    private func validateRimeInputTargetForMutation() -> Bool {
        guard rimeInputTarget != nil, rimeInputTargetIsCurrent() else {
            discardStaleRimeInput()
            return false
        }
        return true
    }

    private func queuePendingRimeCharacter(_ character: String, state: RimeKeyboardState) {
        guard pendingRimeDirectTextKeys.isEmpty else {
            pendingRimeDirectTextKeys.append(character)
            applyReadyRimeStateOrRender(state)
            return
        }
        pendingRimeCharacters.append(character)
        applyRimeState(state)
    }

    private func queuePendingRimeDirectTextKey(_ text: String, state: RimeKeyboardState) {
        pendingRimeDirectTextKeys.append(text)
        applyReadyRimeStateOrRender(state)
    }

    private func applyReadyRimeStateOrRender(_ state: RimeKeyboardState) {
        let hasOwnedInput = !pendingRimeCharacters.isEmpty
            || !pendingRimeDirectTextKeys.isEmpty
            || state.isComposing
            || !state.commitText.isEmpty
            || activeMarkedTextOwner == .rimeComposition
        if hasOwnedInput, !validateRimeInputTargetForMutation() {
            return
        }
        guard state.isReady else {
            applyRimeState(state)
            return
        }
        guard !pendingRimeCharacters.isEmpty else {
            let queuedDirectText = pendingRimeDirectTextKeys.joined()
            pendingRimeDirectTextKeys.removeAll()
            applyRimeState(state)
            guard !queuedDirectText.isEmpty else { return }
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(queuedDirectText)
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            renderRefineSuggestionsIfIdle()
            return
        }

        let queuedCharacters = pendingRimeCharacters
        let queuedDirectText = pendingRimeDirectTextKeys.joined()
        pendingRimeCharacters.removeAll()
        pendingRimeDirectTextKeys.removeAll()
        var replayState = state
        var replayFailed = false
        for character in queuedCharacters {
            replayState = rimeInput.processCharacter(
                character,
                asciiPunctuation: chinesePunctuationStyle == .english,
                asciiMode: false
            )
            if !replayState.isReady || replayState.errorMessage != nil {
                replayFailed = true
                break
            }
        }
        guard !replayFailed else {
            applyRimeState(replayState)
            return
        }
        if !queuedDirectText.isEmpty {
            if replayState.isComposing {
                applyRimeState(rimeInput.commitComposition())
            } else {
                applyRimeState(replayState)
            }
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(queuedDirectText)
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            renderRefineSuggestionsIfIdle()
        } else {
            applyRimeState(replayState)
        }
    }

    private func handleTextBackspace() {
        guard keyboardFocus == .text else {
            guard currentBridgeStatus?.state != .recording,
                  currentBridgeStatus?.state != .sending
            else { return }
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            return
        }
        // Recording locks regular keys; only space (stop-and-send) is live.
        if currentBridgeStatus?.state == .recording || currentBridgeStatus?.state == .sending { return }

        clearTransientKeyboardErrorIfShowing()
        discardRimeInputIfTargetChanged()

        if !pendingRimeCharacters.isEmpty || !pendingRimeDirectTextKeys.isEmpty {
            beginTextTouchCorrectionFromBackspace(compositionActive: true)
            if !pendingRimeDirectTextKeys.isEmpty {
                pendingRimeDirectTextKeys.removeLast()
            } else {
                pendingRimeCharacters.removeLast()
            }
            applyRimeState(rimeInput.state())
            return
        }

        let currentState = rimeInput.state()
        if currentState.isComposing {
            beginTextTouchCorrectionFromBackspace(compositionActive: true)
            applyRimeState(rimeInput.processKeyCode(0xFF08))
            resetShiftIfSticky()
        } else {
            beginTextTouchCorrectionFromBackspace(compositionActive: false)
            replaceMarkedText("")
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            renderRefineSuggestionsIfIdle()
        }
    }

    private func handleTextSpace() {
        guard keyboardFocus == .text else {
            guard currentBridgeStatus?.state != .recording,
                  currentBridgeStatus?.state != .sending
            else { return }
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(" ")
            return
        }

        // Space ends an in-progress text-keyboard dictation (replaces the
        // tap-toggle mic; the user types and stays on the keys).
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            showTextKeyboardStatus(NSLocalizedString("Transcribing", comment: "Inline status after stopping dictation"))
            stopDictationAfterMinimumHoldIfNeeded()
            return
        }
        if currentBridgeStatus?.state == .sending {
            if stopActiveRefineFromUserAction() {
                clearRefineUndoStateForManualEdit()
            }
            return
        }

        clearTransientKeyboardErrorIfShowing()
        discardRimeInputIfTargetChanged()

        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()

        if textInputLanguage == .english {
            commitDisplayedRimeCompositionIfNeeded()
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(" ")
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            return
        }

        let currentState = rimeInput.state()
        if shouldCommitRawRimeInputBeforeSeparator(currentState) {
            commitRawRimeInput(currentState.input, appending: " ")
            resetShiftIfSticky()
            renderRefineSuggestionsIfIdle()
            return
        }

        let result = rimeInput.processKeyCode(
            32,
            asciiPunctuation: chinesePunctuationStyle == .english,
            asciiMode: false
        )
        let state = result.state
        applyRimeState(state)
        if !result.wasComposing, state.commitText.isEmpty, !state.isComposing {
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText(" ")
        }
        resetShiftIfSticky()
    }

    private func handleTextReturn() {
        guard keyboardFocus == .text else {
            if currentBridgeStatus?.state == .recording { return }
            if currentBridgeStatus?.state == .sending { return }
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText("\n")
            return
        }
        if currentBridgeStatus?.state == .recording { return }
        if currentBridgeStatus?.state == .sending { return }

        clearTransientKeyboardErrorIfShowing()
        discardRimeInputIfTargetChanged()

        let currentState = rimeInput.state()
        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()
        if textInputLanguage == .english {
            if currentState.isComposing {
                applyRimeState(rimeInput.clearComposition())
            }
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText("\n")
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            return
        }

        let state = commitDisplayedRimeCompositionIfNeeded(from: currentState)
        if state.commitText.isEmpty {
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.insertText("\n")
        }
        if !resetShiftIfSticky() {
            refreshEnglishLetterCasingIfNeeded()
        }
    }

    private func applyRimeState(_ state: RimeKeyboardState) {
        let composingText = rimeMarkedText(for: state)
        let mutatesProxy = !state.commitText.isEmpty
            || !composingText.isEmpty
            || activeMarkedTextOwner == .rimeComposition
        if mutatesProxy, !validateRimeInputTargetForMutation() {
            return
        }
        if !state.commitText.isEmpty {
            acceptPendingTextTouchIfSurvived()
            resetQuoteParity()
            clearRefineUndoStateForManualEdit()
            commitTextReplacingMarkedText(state.commitText, reason: .rimeCommit)
            clearLocalMarkedTextState()
            if rimeProfile.learningEnabled {
                chineseLearningRecorder.recordCommit(state.commitText)
            }
        }

        if composingText.isEmpty {
            clearMarkedText(ifOwnedBy: .rimeComposition)
        } else {
            replaceMarkedText(composingText, owner: .rimeComposition)
        }

        renderRimeState(state)
        if composingText.isEmpty,
           pendingRimeCharacters.isEmpty,
           pendingRimeDirectTextKeys.isEmpty {
            rimeInputTarget = nil
        }
    }

    private func commitRawRimeInput(_ rawInput: String, appending suffix: String = "") {
        let text = rawInput + suffix
        guard !text.isEmpty else { return }
        acceptPendingTextTouchIfSurvived()
        resetQuoteParity()
        clearRefineUndoStateForManualEdit()
        commitTextReplacingMarkedText(text, reason: .rimeRaw)
        clearLocalMarkedTextState()
        applyRimeState(rimeInput.clearComposition())
    }

    @discardableResult
    private func commitDisplayedRimeCompositionIfNeeded(from currentState: RimeKeyboardState? = nil) -> RimeKeyboardState {
        let state = currentState ?? rimeInput.state()
        guard state.isComposing else { return state }
        // Commit text differs from the DISPLAYED marked text: the preedit's
        // syllable separators ("c laude") are display-only and must not be
        // written into the document.
        let text = state.committableCompositionText(
            preferRawInput: shouldUseRawRimeInputAsMarkedText(state.input)
        )
        let committedState = rimeInput.commitVisibleComposition(text)
        applyRimeState(committedState)
        return committedState
    }

    private func returnToAlphabetKeyboardAfterSymbolInput() {
        isSymbolKeyboard = false
        isAlternateSymbolKeyboard = false
        rebuildTextKeyboardRows()
    }

    private func shouldReturnToAlphabetKeyboardAfterSymbolInput(_ character: String) -> Bool {
        guard isSymbolKeyboard else { return false }
        if isDigitTextKey(character) { return false }
        if shouldStayOnSymbolKeyboardAfterSymbolInput(character) { return false }
        return shouldSymbolInputReturnToAlphabet(character)
    }

    private func isDigitTextKey(_ character: String) -> Bool {
        guard character.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    private func shouldStayOnSymbolKeyboardAfterSymbolInput(_ character: String) -> Bool {
        if character == "." || character == "," {
            return symbolInputContinuesNumber(character)
        }
        if character == ":" {
            return symbolInputContinuesURLSchemeOrTime()
        }

        switch character {
        case "-", "/", "$", "¥", "€", "£", "&", "#", "%", "^", "*", "+", "=",
             "_", "\\", "|", "~", "<", ">", "•", "[", "]", "{", "}":
            return true
        default:
            return false
        }
    }

    private func shouldSymbolInputReturnToAlphabet(_ character: String) -> Bool {
        switch character {
        case ".", ",", "?", "!", "'", "\"", ";", ":", "@",
             "。", "，", "、", "？", "！", "；", "：", "“", "”", "‘", "’":
            return true
        default:
            return false
        }
    }

    private func symbolInputContinuesNumber(_ character: String) -> Bool {
        guard character == "." || character == "," else { return false }
        guard let previous = textDocumentProxy.documentContextBeforeInput?.unicodeScalars.last else {
            return false
        }
        return CharacterSet.decimalDigits.contains(previous)
    }

    private func symbolInputContinuesURLSchemeOrTime() -> Bool {
        if let previous = textDocumentProxy.documentContextBeforeInput?.unicodeScalars.last,
           CharacterSet.decimalDigits.contains(previous) {
            return true
        }
        let currentInput = rimeInput.state().input
        let prefix = currentInput.isEmpty ? (literalAsciiTokenPrefixBeforeInput ?? "") : currentInput
        return ["http", "https", "ftp", "mailto"].contains(prefix.lowercased())
    }

    private func rimeMarkedText(for state: RimeKeyboardState) -> String {
        guard allowsRimeMarkedText else { return "" }
        return state.visibleCompositionText(preferRawInput: shouldUseRawRimeInputAsMarkedText(state.input))
    }

    private var allowsRimeMarkedText: Bool {
        textInputLanguage == .chinese
            && !isRenderedNumericTextKeyboard
    }

    private func shouldUseRawRimeInputAsMarkedText(_ input: String) -> Bool {
        guard textInputLanguage == .chinese,
              !input.isEmpty,
              isRawLatinInput(input)
        else { return false }
        return isLiteralAsciiTextInputContext
            || isContinuingLiteralAsciiTokenContext
            || isRawRimeInputLiteralToken(input)
            || isShortLiteralLatinComposition(input)
    }

    private func isShortLiteralLatinComposition(_ input: String) -> Bool {
        let lowercased = input.lowercased()
        let length = lowercased.unicodeScalars.count
        guard length >= 2, length <= 6 else { return false }
        return lowercased.contains("v")
    }

    private func renderRimeState(_ state: RimeKeyboardState) {
        // Wrapping in CATransaction + performWithoutAnimation eliminates the
        // perceptible candidate-swap animation, BUT if we run it before the
        // root view has a non-zero size (during the keyboard's initial
        // appearance) the chained layoutIfNeeded calls commit a 0-sized
        // intermediate layout that the system then has to "jump" out of.
        // Only use the fast path once layout is established.
        if view.bounds.width > 0 {
            performCandidateRefreshWithoutAnimation {
                renderRimeStateImmediately(state)
            }
        } else {
            renderRimeStateImmediately(state)
        }
    }

    private func renderRimeStateImmediately(_ state: RimeKeyboardState) {
        if !state.isComposing {
            setCandidateGridExpanded(false, state: state)
        }

        resetCandidateStackForReuse()
        updateCandidateToolbarControls(for: state)
        textToolbar.setNeedsLayout()
        textToolbar.layoutIfNeeded()
        updateCandidateScrollViewport()

        if let errorMessage = state.errorMessage {
            addCandidateStatus(errorMessage, color: .systemOrange)
            return
        }

        if !state.isReady {
            guard hasPresentedInitialFrame else { return }
            addCandidateStatus(NSLocalizedString("Chinese preparing…", comment: "Rime preparing status"), color: .secondaryLabel)
            return
        }

        guard !state.candidates.isEmpty else {
            renderCandidateGrid(state)
            return
        }

        // iOS-native top bar: ALL candidates stay reachable by scrolling, but
        // only a window is materialized per keystroke. Configuring every cell
        // (attributed title + width measurement + configuration assignment)
        // for the full 60-candidate pool made each Chinese keystroke pay for
        // ~50 cells the user can't see; the remainder appends on demand as
        // scrolling approaches the rendered edge (scrollViewDidScroll).
        pendingInlineCandidates = state.candidates
        renderedInlineCandidateCount = 0
        appendInlineCandidates(upTo: Self.candidateInlineRenderChunkCount)
        candidateScrollView.setContentOffset(.zero, animated: false)
        renderCandidateGrid(state)
    }

    private func performCandidateRefreshWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            updates()
            candidateStack.setNeedsLayout()
            candidateStack.layoutIfNeeded()
            candidateScrollView.setNeedsLayout()
            candidateScrollView.layoutIfNeeded()
            candidateGridStack.setNeedsLayout()
            candidateGridStack.layoutIfNeeded()
            candidateGridScrollView.setNeedsLayout()
            candidateGridScrollView.layoutIfNeeded()
            textToolbar.setNeedsLayout()
            textToolbar.layoutIfNeeded()
            updateCandidateScrollViewport()
            updateKeyboardSurfaceMask()
            updateCandidateTextOverlay()
            removeCandidateRefreshAnimations()
        }
        CATransaction.commit()
    }

    private func removeCandidateRefreshAnimations() {
        let containers: [UIView] = [
            candidateStack,
            candidateScrollView,
            candidateGridStack,
            candidateGridScrollView,
            textCandidateGridButton,
            candidateGridCollapseButton,
            candidateTrailingSpacer,
            candidateTextOverlay,
            textToolbar,
        ]
        for container in containers {
            removeAnimationsRecursively(from: container)
        }
    }

    private func removeAnimationsRecursively(from view: UIView) {
        view.layer.removeAllAnimations()
        for subview in view.subviews {
            removeAnimationsRecursively(from: subview)
        }
    }

    private func resetCandidateStackForReuse() {
        activeCandidateSeparatorIndex = 0
        activeCandidateStatusLabelIndex = 0
        pendingInlineCandidates.removeAll()
        renderedInlineCandidateCount = 0
        candidateStack.arrangedSubviews.forEach { view in
            candidateStack.removeArrangedSubview(view)
            view.isHidden = true
        }
        hideCandidateTextOverlay()
    }

    /// Materializes inline candidate cells up to `targetCount`, keeping the
    /// flexible trailing spacer last in the stack — it absorbs unused width
    /// when the rendered cells are narrower than the scroll view (see
    /// `candidateTrailingSpacer`).
    private func appendInlineCandidates(upTo targetCount: Int) {
        let target = min(targetCount, pendingInlineCandidates.count)
        guard target > renderedInlineCandidateCount else { return }
        candidateStack.removeArrangedSubview(candidateTrailingSpacer)
        candidateTrailingSpacer.isHidden = true
        for index in renderedInlineCandidateCount..<target {
            let candidate = pendingInlineCandidates[index]
            let button = reusableCandidateButton(at: index)
            configureCandidateButton(
                button,
                candidate: candidate,
                displayIndex: index,
                selectionIndex: candidate.selectionIndex
            )
            addCandidateArrangedView(button)
        }
        renderedInlineCandidateCount = target
        addCandidateArrangedView(candidateTrailingSpacer)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === candidateScrollView {
            appendInlineCandidatesForScrollPositionIfNeeded()
            updateCandidateTextOverlay()
        } else if scrollView === candidateGridScrollView {
            updateCandidateTextOverlay()
        }
    }

    private func appendInlineCandidatesForScrollPositionIfNeeded() {
        guard renderedInlineCandidateCount < pendingInlineCandidates.count else { return }
        let visibleTrailingEdge = candidateScrollView.contentOffset.x + candidateScrollView.bounds.width
        // One extra screen of headroom so a fling decelerates into rendered
        // cells instead of blank track.
        guard visibleTrailingEdge + candidateScrollView.bounds.width >= candidateScrollView.contentSize.width else {
            return
        }
        performCandidateRefreshWithoutAnimation {
            appendInlineCandidates(upTo: renderedInlineCandidateCount + Self.candidateInlineRenderChunkCount)
        }
    }

    private func addCandidateArrangedView(_ view: UIView) {
        view.isHidden = false
        candidateStack.addArrangedSubview(view)
    }

    private func updateCandidateToolbarControls(for state: RimeKeyboardState) {
        guard !isRenderedNumericTextKeyboard else {
            attachNumericTextToolbarControls()
            return
        }

        let isComposing = state.isComposing
        let hasCandidates = !state.candidates.isEmpty

        // Grid expand chevron only when there are candidates to expand.
        textCandidateGridButton.isHidden = !(isComposing && hasCandidates)
        configureCandidateExpandButton(isExpanded: isCandidateGridExpanded)
        configureCandidateGridCollapseButton(isExpanded: isCandidateGridExpanded)
        textCandidateGridButton.accessibilityLabel = isCandidateGridExpanded
            ? NSLocalizedString("Hide candidates", comment: "Accessibility label for collapsing candidate list")
            : NSLocalizedString("Show more candidates", comment: "Accessibility label for expanding candidate list")
        candidateGridCollapseButton.accessibilityLabel = textCandidateGridButton.accessibilityLabel

        // Idle full toolbar; collapses to make room for the candidate strip
        // once Rime has candidates.
        let showAllIdleIcons = !isComposing && !hasCandidates
        textWandButton.isHidden = !showAllIdleIcons
        textToolsButton.isHidden = !showAllIdleIcons // mic
        textStylePickerButton.isHidden = !showAllIdleIcons
        textUndoButton.isHidden = !(showAllIdleIcons || freshRefineUndoState() != nil)
        textKeyboardSwitchButton.isHidden = !showAllIdleIcons
        textHostSettingsButton.isHidden = !showAllIdleIcons
    }

    private func updateCandidateScrollViewport() {
        candidateScrollView.contentInset.right = 0
        candidateScrollView.horizontalScrollIndicatorInsets.right = 0
        candidateScrollView.layer.mask = nil
    }

    private func updateCandidateTextOverlay() {
        guard isViewLoaded,
              keyboardFocus == .text,
              candidateTextOverlay.bounds.width > 0,
              candidateTextOverlay.bounds.height > 0
        else {
            hideCandidateTextOverlay()
            return
        }

        let sourceButtons: [UIButton]
        let viewport: CGRect
        if isCandidateGridExpanded {
            guard !candidateGridScrollView.isHidden,
                  candidateGridScrollView.bounds.width > 0,
                  candidateGridScrollView.bounds.height > 0
            else {
                hideCandidateTextOverlay()
                return
            }
            sourceButtons = candidateGridStack.arrangedSubviews
                .compactMap { $0 as? UIStackView }
                .flatMap { row in row.arrangedSubviews.compactMap { $0 as? UIButton } }
            viewport = candidateGridScrollView.convert(candidateGridScrollView.bounds, to: candidateTextOverlay)
        } else {
            guard !candidateScrollView.isHidden,
                  !textCandidateGridButton.isHidden,
                  candidateScrollView.bounds.width > 0,
                  candidateScrollView.bounds.height > 0
            else {
                hideCandidateTextOverlay()
                return
            }
            sourceButtons = candidateStack.arrangedSubviews.compactMap { $0 as? UIButton }
            viewport = candidateScrollView.convert(candidateScrollView.bounds, to: candidateTextOverlay)
        }

        let safeViewport = candidateTextOverlaySafeViewport(for: viewport)
        guard !safeViewport.isNull, !sourceButtons.isEmpty else {
            hideCandidateTextOverlay()
            return
        }

        var visibleLabelCount = 0
        let visibleBounds = safeViewport.insetBy(dx: -2, dy: -2)
        for button in sourceButtons {
            guard !button.isHidden,
                  button.alpha > 0.01,
                  button.bounds.width > 0,
                  button.bounds.height > 0,
                  let text = button.accessibilityLabel,
                  !text.isEmpty
            else { continue }

            let frame = button.convert(button.bounds, to: candidateTextOverlay)
            guard frame.intersects(visibleBounds),
                  frame.maxX <= safeViewport.maxX + 0.5
            else { continue }

            let label = candidateTextOverlayLabel(at: visibleLabelCount)
            label.text = text
            label.font = candidateFont(weight: .regular)
            label.textColor = .label
            label.frame = frame
            label.isHidden = false
            visibleLabelCount += 1
        }

        for index in visibleLabelCount..<reusableCandidateTextOverlayLabels.count {
            reusableCandidateTextOverlayLabels[index].isHidden = true
        }
        candidateTextOverlay.isHidden = visibleLabelCount == 0
    }

    private func candidateTextOverlaySafeViewport(for viewport: CGRect) -> CGRect {
        var safeViewport = viewport.intersection(candidateTextOverlay.bounds)
        guard !safeViewport.isNull else { return .null }

        let actionFrame = candidateActionColumnFrame()
        guard !actionFrame.isNull else { return safeViewport }

        let overlayActionFrame = candidateTextOverlay.convert(actionFrame, from: view)
        guard overlayActionFrame.intersects(safeViewport) else { return safeViewport }

        safeViewport.size.width = max(0, overlayActionFrame.minX - safeViewport.minX)
        return safeViewport.width > 1 ? safeViewport : .null
    }

    private func candidateTextOverlayLabel(at index: Int) -> UILabel {
        while reusableCandidateTextOverlayLabels.count <= index {
            let label = UILabel()
            label.isUserInteractionEnabled = false
            label.isOpaque = false
            label.backgroundColor = .clear
            label.textAlignment = .center
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.layer.shadowOpacity = 0
            label.layer.shadowRadius = 0
            label.layer.shadowOffset = .zero
            candidateTextOverlay.addSubview(label)
            reusableCandidateTextOverlayLabels.append(label)
        }
        return reusableCandidateTextOverlayLabels[index]
    }

    private func hideCandidateTextOverlay() {
        candidateTextOverlay.isHidden = true
        for label in reusableCandidateTextOverlayLabels {
            label.isHidden = true
        }
    }

    private var isRunningInsideHostApp: Bool {
        KeyboardSharedDefaults.isHostForegroundActive()
    }

    private func addCandidateSeparator() {
        let separator: UIView
        if activeCandidateSeparatorIndex < reusableCandidateSeparators.count {
            separator = reusableCandidateSeparators[activeCandidateSeparatorIndex]
        } else {
            separator = UIView()
            separator.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
            separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
            separator.setContentHuggingPriority(.required, for: .horizontal)
            separator.setContentCompressionResistancePriority(.required, for: .horizontal)
            reusableCandidateSeparators.append(separator)
        }
        activeCandidateSeparatorIndex += 1
        separator.backgroundColor = UIColor.separator.withAlphaComponent(isKeyboardDark ? 0.42 : 0.26)
        addCandidateArrangedView(separator)
    }

    @objc private func toggleCandidateGrid() {
        let state = rimeInput.state()
        guard state.isComposing, !state.candidates.isEmpty else {
            setCandidateGridExpanded(false, state: state)
            return
        }
        setCandidateGridExpanded(!isCandidateGridExpanded, state: state)
        lightHaptic()
    }

    @objc private func handleCandidateScrollTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: view)
        if candidateActionColumnFrame().contains(point) {
            toggleCandidateGrid()
            return
        }
        guard let button = candidateScrollHitTarget(at: point) else { return }
        candidateButtonTapped(button)
    }

    @objc private func handleCandidateLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: view)
        switch recognizer.state {
        case .began, .changed:
            guard let button = candidateScrollHitTarget(at: point) else {
                hideCandidatePreview()
                return
            }
            if candidatePreviewTarget !== button {
                if candidatePreviewTarget == nil {
                    keyboardHaptics.playControlTap()
                } else {
                    keyboardHaptics.playSelectionChanged()
                }
                candidatePreviewTarget = button
                showCandidatePreview(for: button)
            }
        case .ended:
            let target = candidatePreviewTarget
            hideCandidatePreview()
            if let target {
                candidateButtonTapped(target)
            }
        default:
            hideCandidatePreview()
        }
    }

    private func candidateText(of button: UIButton) -> String {
        if let text = button.accessibilityLabel,
           !text.isEmpty {
            return text
        }
        if let attributed = button.configuration?.attributedTitle {
            return String(attributed.characters)
        }
        return button.currentTitle ?? ""
    }

    /// Magnifier bubble for a held candidate. Keyboard extensions cannot draw
    /// outside their own bounds, so the bubble sits BELOW the strip (over the
    /// top key row) instead of above the finger like character previews.
    private func showCandidatePreview(for button: UIButton) {
        let text = candidateText(of: button)
        guard !text.isEmpty else {
            hideCandidatePreview()
            return
        }
        keyPreviewBubble.layer.removeAllAnimations()
        keyPreviewLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        keyPreviewLabel.text = text
        let buttonFrame = button.convert(button.bounds, to: view)
        let textWidth = ceil((text as NSString).size(withAttributes: [
            .font: keyPreviewLabel.font as Any,
        ]).width)
        let bubbleWidth = min(max(textWidth + 24, 56), view.bounds.width - 8)
        let bubbleHeight: CGFloat = 44
        let x = min(
            max(buttonFrame.midX - bubbleWidth / 2, 4),
            max(4, view.bounds.width - bubbleWidth - 4)
        )
        let y = buttonFrame.maxY + 6
        keyPreviewBubble.frame = CGRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight)
        view.bringSubviewToFront(keyPreviewBubble)
        keyPreviewBubble.isHidden = false
        keyPreviewBubble.alpha = 1
        keyPreviewBubble.transform = .identity
    }

    private func hideCandidatePreview() {
        candidatePreviewTarget = nil
        hideKeyPreview()
    }

    // MARK: - Toolbar hints
    //
    // The toolbar icons (wand / style / undo / mic / keyboard-switch / gear)
    // have no labels and `help()` does nothing inside a keyboard extension,
    // so their meaning was only discoverable in the host app's Guide. Holding
    // an icon now shows its accessibility label in the preview bubble without
    // triggering the action (the recognizer cancels the button's touch).

    private func attachToolbarHints() {
        [
            settingsButton,
            keyboardFocusButton,
            textWandButton,
            textStylePickerButton,
            textUndoButton,
            textToolsButton,
            textKeyboardSwitchButton,
            textHostSettingsButton,
        ].forEach(attachToolbarHint)
    }

    private func attachToolbarHint(_ button: UIButton) {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleToolbarHintLongPress(_:)))
        recognizer.minimumPressDuration = 0.45
        recognizer.cancelsTouchesInView = true
        button.addGestureRecognizer(recognizer)
    }

    @objc private func handleToolbarHintLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? UIButton else { return }
        switch recognizer.state {
        case .began:
            let text = button.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            keyboardHaptics.playSelectionChanged()
            presentToolbarHintBubble(text: text, below: button)
        case .ended, .cancelled, .failed:
            hideKeyPreview()
        default:
            break
        }
    }

    private func presentToolbarHintBubble(text: String, below control: UIControl) {
        keyPreviewBubble.layer.removeAllAnimations()
        keyPreviewLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        keyPreviewLabel.text = text
        let controlFrame = control.convert(control.bounds, to: view)
        let textWidth = ceil((text as NSString).size(withAttributes: [
            .font: keyPreviewLabel.font as Any,
        ]).width)
        let bubbleWidth = min(textWidth + 24, view.bounds.width - 8)
        let bubbleHeight: CGFloat = 32
        let x = min(
            max(controlFrame.midX - bubbleWidth / 2, 4),
            max(4, view.bounds.width - bubbleWidth - 4)
        )
        keyPreviewBubble.frame = CGRect(x: x, y: controlFrame.maxY + 6, width: bubbleWidth, height: bubbleHeight)
        view.bringSubviewToFront(keyPreviewBubble)
        keyPreviewBubble.isHidden = false
        keyPreviewBubble.alpha = 1
        keyPreviewBubble.transform = .identity
    }

    @objc private func handleCandidateGridTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: view)
        if candidateActionColumnFrame().contains(point) {
            toggleCandidateGrid()
            return
        }
        guard let button = candidateGridHitTarget(at: point) else { return }
        candidateGridButtonTapped(button)
    }

    private func candidateActionColumnFrame() -> CGRect {
        if isCandidateGridExpanded, !candidateGridCollapseButton.isHidden {
            return candidateGridCollapseButton.convert(candidateGridCollapseButton.bounds, to: view)
                .insetBy(dx: -Self.candidateActionColumnGap, dy: -16)
        }
        guard !textCandidateGridButton.isHidden else { return .null }
        let buttonFrame = textCandidateGridButton.convert(textCandidateGridButton.bounds, to: view)
        let toolbarFrame = textToolbar.convert(textToolbar.bounds, to: view)
        var frame = buttonFrame.insetBy(dx: -Self.candidateActionColumnGap, dy: -Self.candidateExpandTouchOverflowY)
        frame.origin.x = max(buttonFrame.minX - Self.candidateActionColumnGap, view.bounds.minX)
        frame.size.width = max(buttonFrame.width + Self.candidateActionColumnGap, view.bounds.maxX - frame.minX)
        frame.origin.y = min(frame.minY, toolbarFrame.minY)
        if !isCandidateGridExpanded, !keyRowsStack.isHidden {
            let keyRowsFrame = keyRowsStack.convert(keyRowsStack.bounds, to: view)
            let minimumBottom = toolbarFrame.minY + Self.candidateExpandActionHeight
            let bottom = min(max(frame.maxY, minimumBottom), keyRowsFrame.minY - 2)
            frame.size.height = max(0, bottom - frame.minY)
        }
        return frame
    }

    private func updateCandidateGridCollapseButtonFrame() {
        let shouldShow = keyboardFocus == .text
            && isCandidateGridExpanded
            && !candidateGridScrollView.isHidden
            && candidateGridScrollView.bounds.width > 0
            && candidateGridScrollView.bounds.height > 0
        candidateGridCollapseButton.isHidden = !shouldShow
        guard shouldShow else { return }

        let gridFrame = candidateGridScrollView.convert(candidateGridScrollView.bounds, to: view)
        let buttonHeight = min(Self.candidateToolbarHeight, gridFrame.height)
        candidateGridCollapseButton.frame = CGRect(
            x: max(view.bounds.minX, view.bounds.maxX - Self.rootHorizontalInset - Self.candidateExpandButtonWidth),
            y: gridFrame.minY,
            width: Self.candidateExpandButtonWidth,
            height: buttonHeight
        )
        view.bringSubviewToFront(candidateGridCollapseButton)
        view.bringSubviewToFront(keyPreviewBubble)
    }

    private func updateKeyboardOverlayOrdering() {
        view.bringSubviewToFront(keyboardContentView)
        view.bringSubviewToFront(candidateTextOverlay)
        view.bringSubviewToFront(keyboardTouchOverlay)
        view.bringSubviewToFront(correctionPopoverDismissOverlay)
        view.bringSubviewToFront(correctionPopover)
        view.bringSubviewToFront(candidateGridCollapseButton)
        view.bringSubviewToFront(keyPreviewBubble)
    }

    private func setCandidateGridExpanded(_ expanded: Bool, state: RimeKeyboardState? = nil) {
        let next = expanded && (state?.isComposing ?? rimeInput.state().isComposing)
        guard isCandidateGridExpanded != next else {
            if next, let state {
                renderCandidateGrid(state)
                updateCandidateGridCollapseButtonFrame()
            }
            updateKeyboardOverlayOrdering()
            return
        }
        isCandidateGridExpanded = next
        textToolbar.isHidden = next
        keyRowsStack.isHidden = next
        candidateGridScrollView.isHidden = !next
        candidateGridCollapseButton.isHidden = !next
        configureCandidateExpandButton(isExpanded: next)
        configureCandidateGridCollapseButton(isExpanded: next)
        textCandidateGridButton.accessibilityLabel = next
            ? NSLocalizedString("Hide candidates", comment: "Accessibility label for collapsing candidate list")
            : NSLocalizedString("Show more candidates", comment: "Accessibility label for expanding candidate list")
        candidateGridCollapseButton.accessibilityLabel = textCandidateGridButton.accessibilityLabel
        if next, let state {
            renderCandidateGrid(state)
        }
        // Force a layout pass so candidateGridScrollView.bounds is populated
        // before we compute the collapse button's frame. Otherwise the
        // `bounds.width > 0` guard in updateCandidateGridCollapseButtonFrame
        // hides the button on the same frame the user expanded, leaving them
        // looking at a grid with no visible way out.
        view.layoutIfNeeded()
        updateCandidateGridCollapseButtonFrame()
        updateKeyboardSurfaceMask()
        updateCandidateTextOverlay()
        updateKeyboardOverlayOrdering()
    }

    private func renderCandidateGrid(_ state: RimeKeyboardState) {
        candidateGridStack.arrangedSubviews.forEach { row in
            candidateGridStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        guard isCandidateGridExpanded, state.isComposing, !state.candidates.isEmpty else { return }

        // iOS-native expanded panel: compact length-aware rows with
        // single-line labels. The list starts from the first candidate so the
        // selection index sent to Rime matches displayed absolute index.
        let availableWidth = candidateGridContentWidth()
        let columnCount = candidateGridColumnCount(for: availableWidth)
        let columnWidth = availableWidth / CGFloat(columnCount)
        var currentRow: UIStackView?
        var usedColumns = 0
        var didAddRow = false

        func finishCurrentRow() {
            guard let row = currentRow else { return }
            if usedColumns < columnCount {
                addCandidateGridTrailingSpacer(to: row)
            }
            currentRow = nil
            usedColumns = 0
        }

        for index in state.candidates.indices {
            let candidate = state.candidates[index]
            let columnSpan = candidateGridColumnSpan(
                for: candidateGridNaturalCellWidth(for: candidate),
                columnWidth: columnWidth,
                columnCount: columnCount
            )
            if currentRow != nil,
               usedColumns + columnSpan > columnCount {
                finishCurrentRow()
            }
            if currentRow == nil {
                if didAddRow {
                    addCandidateGridRowSeparator(width: availableWidth)
                }
                let nextRow = makeTextKeyRow()
                nextRow.spacing = 0
                nextRow.distribution = .fill
                nextRow.alignment = .fill
                nextRow.widthAnchor.constraint(equalToConstant: availableWidth).isActive = true
                candidateGridStack.addArrangedSubview(nextRow)
                currentRow = nextRow
                didAddRow = true
            }
            let button = makeCandidateGridButton(
                candidate: candidate,
                selectionIndex: candidate.selectionIndex,
                width: columnWidth * CGFloat(columnSpan)
            )
            currentRow?.addArrangedSubview(button)
            usedColumns += columnSpan
            if usedColumns >= columnCount {
                finishCurrentRow()
            }
        }

        // Partial final rows stay left-aligned; full rows already occupy all
        // grid columns exactly.
        finishCurrentRow()
        candidateGridScrollView.setContentOffset(.zero, animated: false)
    }

    private func candidateGridContentWidth() -> CGFloat {
        let fullWidth = candidateGridScrollView.bounds.width > 0
            ? candidateGridScrollView.bounds.width
            : view.bounds.width - Self.rootHorizontalInset * 2
        let gridMinX = candidateGridScrollView.bounds.width > 0
            ? candidateGridScrollView.convert(candidateGridScrollView.bounds, to: view).minX
            : Self.rootHorizontalInset
        let actionLeft = view.bounds.width > 0
            ? view.bounds.maxX - Self.rootHorizontalInset - Self.candidateExpandButtonWidth - Self.candidateActionColumnGap
            : gridMinX + fullWidth
        return min(fullWidth, max(140, actionLeft - gridMinX))
    }

    private func candidateGridColumnCount(for available: CGFloat) -> Int {
        min(
            Self.candidateGridMaximumColumnCount,
            max(1, Int((available / Self.candidateGridPreferredCellWidth).rounded()))
        )
    }

    private func candidateGridColumnSpan(
        for naturalWidth: CGFloat,
        columnWidth: CGFloat,
        columnCount: Int
    ) -> Int {
        guard columnWidth > 0 else { return 1 }
        let adjustedWidth = max(0, naturalWidth - Self.candidateGridColumnSpanTolerance)
        return min(columnCount, max(1, Int(ceil(adjustedWidth / columnWidth))))
    }

    private func candidateGridNaturalCellWidth(for candidate: RimeKeyboardCandidate) -> CGFloat {
        let font = candidateFont(weight: .regular)
        let textWidth = ceil((candidate.text as NSString).size(withAttributes: [.font: font]).width)
        let characterCount = candidate.text.count
        let minimumWidth = characterCount == 2
            ? Self.candidateGridTwoCharacterMinimumCellWidth
            : Self.candidateGridMinimumCellWidth
        return max(minimumWidth, textWidth + Self.candidateInlineCellHorizontalPadding)
    }

    private func addCandidateGridTrailingSpacer(to row: UIStackView) {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
    }

    private func addCandidateGridRowSeparator(width: CGFloat) {
        let separator = UIView()
        separator.backgroundColor = UIColor.separator.withAlphaComponent(isKeyboardDark ? 0.42 : 0.32)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
        separator.widthAnchor.constraint(equalToConstant: width).isActive = true
        candidateGridStack.addArrangedSubview(separator)
    }

    private func makeCandidateGridButton(
        candidate: RimeKeyboardCandidate,
        selectionIndex: Int,
        width: CGFloat
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = selectionIndex
        // Expanded candidate grid cells are visual targets only. The scroll
        // view owns touch delivery so vertical drags always scroll; taps are
        // resolved by candidateGridTapRecognizer using the same row-local
        // hit bands. Accessibility opts back in so VoiceOver can reach them.
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityLabel = candidate.text
        button.heightAnchor.constraint(equalToConstant: Self.candidateGridRowHeight).isActive = true
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.configuration = candidateTextlessButtonConfiguration()
        button.layer.borderWidth = 0
        button.layer.borderColor = UIColor.clear.cgColor
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        return button
    }

    @objc private func candidateGridButtonTapped(_ sender: UIButton) {
        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()
        setCandidateGridExpanded(false)
        if sender.tag == RimeKeyboardCandidate.literalSelectionIndex {
            commitRawRimeInput(rimeInput.state().input)
            return
        }
        applyRimeState(rimeInput.selectCandidate(at: sender.tag))
    }

    private func reusableCandidateButton(at index: Int) -> UIButton {
        if index < reusableCandidateButtons.count {
            return reusableCandidateButtons[index]
        }
        // Top-row candidates mirror the grid: visual only, no UIControl touch
        // tracking. `candidateScrollTapRecognizer` resolves taps via
        // `candidateScrollHitTarget`, and the scroll view's panGestureRecognizer
        // owns all drags uncontested. This avoids the "must press a candidate
        // before scrolling" feel where the button's touchDown would compete
        // with the scroll view's pan recognizer.
        let button = UIButton(type: .system)
        button.isUserInteractionEnabled = false
        // Taps resolve through the scroll view's gesture recognizer, so the
        // disabled-interaction cells must opt back into accessibility or
        // VoiceOver users cannot reach candidates at all. VoiceOver's
        // activation tap lands at the element's center and flows through the
        // same recognizer path.
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.heightAnchor.constraint(equalToConstant: Self.candidateToolbarHeight).isActive = true
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: 58)
        widthConstraint.isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        reusableCandidateButtons.append(button)
        candidateButtonWidthConstraints.append(widthConstraint)
        return button
    }

    private func configureCandidateButton(
        _ button: UIButton,
        candidate: RimeKeyboardCandidate,
        displayIndex: Int,
        selectionIndex: Int
    ) {
        button.tag = selectionIndex
        button.configuration = candidateTextlessButtonConfiguration()
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.accessibilityLabel = candidate.text
        candidateButtonWidthConstraints[displayIndex].constant = candidateButtonMinimumWidth(for: candidate)
    }

    private func candidateTextlessButtonConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = nil
        configuration.subtitle = nil
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.cornerStyle = .fixed
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .clear
        configuration.background.cornerRadius = 0
        configuration.background.backgroundColor = .clear
        return configuration
    }

    @objc private func candidateButtonTapped(_ sender: UIButton) {
        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()
        if sender.tag == RimeKeyboardCandidate.literalSelectionIndex {
            commitRawRimeInput(rimeInput.state().input)
            return
        }
        applyRimeState(rimeInput.selectCandidate(at: sender.tag))
    }

    private func candidateButtonMinimumWidth(for candidate: RimeKeyboardCandidate) -> CGFloat {
        // Native collapsed Chinese candidates are text-width adaptive:
        // single characters are ~41pt wide and "是很舒服" is ~97pt, both
        // matching text width + about 20pt of total horizontal padding.
        let titleFont = candidateFont(weight: .regular)
        let titleWidth = ceil((candidate.text as NSString).size(withAttributes: [.font: titleFont]).width)
        return max(Self.candidateInlineMinimumCellWidth, titleWidth + Self.candidateInlineCellHorizontalPadding)
    }

    private func candidateFont(weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: Self.candidateTextFontSize, weight: weight)
    }

    private func addCandidateStatus(_ text: String, color: UIColor, emphasized: Bool = false) {
        let label: UILabel
        if activeCandidateStatusLabelIndex < reusableCandidateStatusLabels.count {
            label = reusableCandidateStatusLabels[activeCandidateStatusLabelIndex]
        } else {
            label = UILabel()
            label.textAlignment = .center
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            reusableCandidateStatusLabels.append(label)
        }
        activeCandidateStatusLabelIndex += 1
        label.text = text
        label.font = .systemFont(ofSize: emphasized ? 15 : 13, weight: emphasized ? .semibold : .medium)
        label.textColor = color
        addCandidateArrangedView(label)
        let labelID = ObjectIdentifier(label)
        let widthConstraint: NSLayoutConstraint
        if let existingConstraint = candidateStatusLabelWidthConstraints[labelID] {
            widthConstraint = existingConstraint
        } else {
            widthConstraint = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
            widthConstraint.isActive = true
            candidateStatusLabelWidthConstraints[labelID] = widthConstraint
        }
        widthConstraint.constant = max(72, candidateScrollView.bounds.width)
    }

    private func renderRefineSuggestionsIfIdle() {
        guard keyboardFocus == .text else { return }
        renderRimeState(RimeKeyboardState(
            isReady: true,
            isComposing: false,
            input: "",
            preedit: "",
            candidates: [],
            candidateOffset: 0,
            hasPreviousPage: false,
            hasNextPage: false,
            commitText: "",
            errorMessage: nil
        ))
    }

    private func showMissingCommandTargetError() {
        let message = NSLocalizedString("Nothing to refine.", comment: "Inline status when command edit has no input text")
        showTransientKeyboardError(message)
    }

    private func showTransientKeyboardError(_ message: String) {
        let isReplacingTransientError = isShowingTransientKeyboardError
        let priorStatus = isReplacingTransientError ? transientKeyboardErrorPriorStatus : currentBridgeStatus
        let priorLastBridgeContactAt = isReplacingTransientError
            ? transientKeyboardErrorPriorLastBridgeContactAt
            : lastBridgeContactAt
        let wasBridgeAwake = isReplacingTransientError ? transientKeyboardErrorWasBridgeAwake : isBridgeAwake
        let priorBackendReachable = isReplacingTransientError
            ? transientKeyboardErrorPriorBackendReachable
            : priorStatus?.backendReachable

        transientKeyboardErrorClearWorkItem?.cancel()
        transientKeyboardErrorGeneration &+= 1
        let generation = transientKeyboardErrorGeneration
        transientKeyboardErrorPriorStatus = priorStatus
        transientKeyboardErrorPriorLastBridgeContactAt = priorLastBridgeContactAt
        transientKeyboardErrorWasBridgeAwake = wasBridgeAwake
        transientKeyboardErrorPriorBackendReachable = priorBackendReachable
        transientKeyboardErrorMessage = message

        bridgeStatus = KeyboardBridgeStatus(state: .error, message: message)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.transientKeyboardErrorGeneration == generation
            else { return }
            self.transientKeyboardErrorClearWorkItem = nil
            self.clearTransientKeyboardErrorRestoreState()

            let stillShowingTransientError = self.currentBridgeStatus?.state == .error
                && self.currentBridgeStatus?.commandID == nil
                && self.currentBridgeStatus?.message == message
            if stillShowingTransientError {
                self.restoreBridgeStatusAfterTransientError(
                    priorStatus: priorStatus,
                    priorLastBridgeContactAt: priorLastBridgeContactAt,
                    wasBridgeAwake: wasBridgeAwake,
                    priorBackendReachable: priorBackendReachable
                )
            }

            self.updateUI(animated: false)
        }
        transientKeyboardErrorClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transientKeyboardErrorDuration, execute: workItem)
    }

    private var isShowingTransientKeyboardError: Bool {
        currentBridgeStatus?.state == .error
            && currentBridgeStatus?.commandID == nil
            && currentBridgeStatus?.message == transientKeyboardErrorMessage
    }

    @discardableResult
    private func clearTransientKeyboardErrorIfShowing() -> Bool {
        guard isShowingTransientKeyboardError else { return false }
        transientKeyboardErrorClearWorkItem?.cancel()
        transientKeyboardErrorClearWorkItem = nil
        transientKeyboardErrorGeneration &+= 1

        let priorStatus = transientKeyboardErrorPriorStatus
        let priorLastBridgeContactAt = transientKeyboardErrorPriorLastBridgeContactAt
        let wasBridgeAwake = transientKeyboardErrorWasBridgeAwake
        let priorBackendReachable = transientKeyboardErrorPriorBackendReachable
        clearTransientKeyboardErrorRestoreState()

        restoreBridgeStatusAfterTransientError(
            priorStatus: priorStatus,
            priorLastBridgeContactAt: priorLastBridgeContactAt,
            wasBridgeAwake: wasBridgeAwake,
            priorBackendReachable: priorBackendReachable
        )
        updateUI(animated: false)
        return true
    }

    private func clearTransientKeyboardErrorRestoreState() {
        transientKeyboardErrorPriorStatus = nil
        transientKeyboardErrorPriorLastBridgeContactAt = 0
        transientKeyboardErrorWasBridgeAwake = false
        transientKeyboardErrorPriorBackendReachable = nil
        transientKeyboardErrorMessage = nil
    }

    private func restoreBridgeStatusAfterTransientError(
        priorStatus: KeyboardBridgeStatus?,
        priorLastBridgeContactAt: TimeInterval,
        wasBridgeAwake: Bool,
        priorBackendReachable: Bool?
    ) {
        if let priorStatus,
           priorStatus.state == .idle || priorStatus.state == .standby || priorStatus.state == .error {
            bridgeStatus = priorStatus
            lastBridgeContactAt = priorLastBridgeContactAt
            return
        }

        if applySharedBridgeStatusSnapshot() {
            return
        }

        bridgeStatus = KeyboardBridgeStatus(
            state: wasBridgeAwake ? .standby : .idle,
            message: wasBridgeAwake ? "Ready" : inputMode.idleTitle,
            backendReachable: priorBackendReachable
        )
        lastBridgeContactAt = wasBridgeAwake ? priorLastBridgeContactAt : 0
    }

    private func showTextKeyboardStatus(
        _ text: String,
        color: UIColor = .secondaryLabel,
        duration: TimeInterval? = nil
    ) {
        guard keyboardFocus == .text else { return }
        textToolbarStatusClearTask?.cancel()
        textToolbarStatusClearTask = nil
        guard hasPresentedInitialFrame || text.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            textToolbarStatusText = nil
            updateUI(animated: false)
            return
        }

        insertedFlashClearTask?.cancel()
        insertedFlashClearTask = nil
        insertedFlashUntil = 0
        textToolbarStatusText = text
        textToolbarStatusColor = color
        updateUI(animated: false)

        let statusDuration = duration ?? Self.textToolbarStatusDuration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.textToolbarStatusText == text else { return }
            self.textToolbarStatusClearTask = nil
            self.textToolbarStatusText = nil
            self.updateUI(animated: false)
        }
        textToolbarStatusClearTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + statusDuration, execute: workItem)
    }

    private func replaceMarkedText(_ text: String, owner: MarkedTextOwner? = nil) {
        let nextOwner = text.isEmpty ? nil : owner
        guard activeMarkedText != text || activeMarkedTextOwner != nextOwner else { return }
        if !text.isEmpty {
            let cursor = (text as NSString).length
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: cursor, length: 0))
        } else if !activeMarkedText.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        }
        activeMarkedText = text
        activeMarkedTextOwner = nextOwner
    }

    private func clearLocalMarkedTextState() {
        activeMarkedText = ""
        activeMarkedTextOwner = nil
    }

    private func clearMarkedText(ifOwnedBy owner: MarkedTextOwner) {
        guard activeMarkedTextOwner == owner else { return }
        replaceMarkedText("")
    }

    private func commitTextReplacingMarkedText(
        _ text: String,
        reason: MarkedTextCommitReason = .generic
    ) {
        guard !text.isEmpty else { return }
        let plan = markedTextCommitPlan()
        executeMarkedTextCommitPlan(plan, text: text, reason: reason)
    }

    private func markedTextCommitPlan() -> MarkedTextCommitPlan {
        guard !activeMarkedText.isEmpty else {
            return .plainInsert
        }
        guard let owner = activeMarkedTextOwner else {
            return .staleMarkedState
        }
        return .ownedMarked(owner)
    }

    private func executeMarkedTextCommitPlan(
        _ plan: MarkedTextCommitPlan,
        text: String,
        reason: MarkedTextCommitReason
    ) {
        switch plan {
        case .plainInsert:
            textDocumentProxy.insertText(text)
        case .ownedMarked(let owner):
            commitOwnedMarkedText(text, owner: owner, reason: reason, plan: plan)
        case .staleMarkedState:
            let staleMarkedCount = activeMarkedText.count
            clearLocalMarkedTextState()
            textDocumentProxy.insertText(text)
            kbLog.notice(
                "marked text commit applied plan=\(plan.logName, privacy: .public) reason=\(reason.rawValue, privacy: .public) stale_marked_chars=\(staleMarkedCount, privacy: .public) commit_chars=\(text.count, privacy: .public)"
            )
        }
    }

    private func commitOwnedMarkedText(
        _ text: String,
        owner: MarkedTextOwner,
        reason: MarkedTextCommitReason,
        plan: MarkedTextCommitPlan
    ) {
        let markedCount = activeMarkedText.count
        let cursor = (text as NSString).length
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: cursor, length: 0))
        textDocumentProxy.unmarkText()
        clearLocalMarkedTextState()
        kbLog.notice(
            "marked text commit applied plan=\(plan.logName, privacy: .public) reason=\(reason.rawValue, privacy: .public) owner=\(owner.logName, privacy: .public) marked_chars=\(markedCount, privacy: .public) commit_chars=\(text.count, privacy: .public)"
        )
    }

    private func commitLivePartialMarkedTextAsPreview(_ preview: String, commandID: String?) {
        guard !preview.isEmpty else { return }
        let cursor = (preview as NSString).length
        textDocumentProxy.setMarkedText(preview, selectedRange: NSRange(location: cursor, length: 0))
        textDocumentProxy.unmarkText()
        kbLog.notice(
            "live partial preview committed by stop refine command_id=\(commandID ?? "none", privacy: .public) preview_chars=\(preview.count, privacy: .public)"
        )
    }

    private func effectiveLivePartialCommandID(_ explicitCommandID: String? = nil) -> String? {
        explicitCommandID
            ?? currentBridgeStatus?.commandID
            ?? pendingStopCommandID
            ?? activeRecordingCommandID
            ?? activeRecordingTextTarget?.commandID
            ?? livePartialPreviewState?.commandID
    }

    private func livePartialPreviewAnchor(excludingVisiblePreview preview: String? = nil) -> LivePartialPreviewAnchor {
        var contextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let contextAfter = textDocumentProxy.documentContextAfterInput ?? ""
        if let preview,
           !preview.isEmpty,
           contextBefore.hasSuffix(preview) {
            contextBefore = String(contextBefore.dropLast(preview.count))
        }
        return LivePartialPreviewAnchor(contextBefore: contextBefore, contextAfter: contextAfter)
    }

    private func currentLivePartialPreviewAnchor() -> LivePartialPreviewAnchor {
        let visiblePreview = activeMarkedTextOwner == .livePartial ? activeMarkedText : nil
        return livePartialPreviewAnchor(excludingVisiblePreview: visiblePreview)
    }

    private func recordLivePartialPreview(
        commandID: String,
        text: String,
        anchor explicitAnchor: LivePartialPreviewAnchor? = nil
    ) {
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return }
        if var state = livePartialPreviewState, state.commandID == commandID {
            guard !state.consumedByUser, !state.ownershipInvalidated else { return }
            state.text = preview
            livePartialPreviewState = state
        } else {
            let anchor = explicitAnchor ?? livePartialPreviewAnchor(excludingVisiblePreview: preview)
            livePartialPreviewState = LivePartialPreviewState(
                commandID: commandID,
                text: preview,
                contextBefore: anchor.contextBefore,
                contextAfter: anchor.contextAfter,
                textInputIdentity: currentTextInputIdentity,
                consumedByUser: false,
                ownershipInvalidated: false
            )
        }
    }

    private func canPresentLivePartialPreview(commandID: String, text: String) -> Bool {
        if var state = livePartialPreviewState {
            guard state.commandID == commandID else { return false }
            guard !state.consumedByUser, !state.ownershipInvalidated else { return false }
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            let after = textDocumentProxy.documentContextAfterInput ?? ""
            guard canCommitOwnedLivePartialMarkedText(state, before: before, after: after) else {
                state.ownershipInvalidated = true
                livePartialPreviewState = state
                if activeMarkedTextOwner == .livePartial {
                    clearLocalMarkedTextState()
                }
                return false
            }
            return true
        }

        guard activeMarkedTextOwner == nil, activeMarkedText.isEmpty else {
            let anchor = currentLivePartialPreviewAnchor()
            livePartialPreviewState = LivePartialPreviewState(
                commandID: commandID,
                text: text,
                contextBefore: anchor.contextBefore,
                contextAfter: anchor.contextAfter,
                textInputIdentity: currentTextInputIdentity,
                consumedByUser: false,
                ownershipInvalidated: true
            )
            return false
        }
        return true
    }

    private func clearLivePartialMarkedTextIfStillOwned(commandID: String?, reason: String) {
        guard activeMarkedTextOwner == .livePartial else { return }
        if let commandID,
           let state = livePartialPreviewState,
           state.commandID != commandID {
            return
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        guard let state = livePartialPreviewState,
              commandID == nil || state.commandID == commandID,
              canCommitOwnedLivePartialMarkedText(state, before: before, after: after)
        else {
            if var state = livePartialPreviewState {
                state.ownershipInvalidated = true
                livePartialPreviewState = state
            }
            clearLocalMarkedTextState()
            kbLog.notice("live partial clear skipped because ownership changed reason=\(reason, privacy: .public)")
            return
        }
        replaceMarkedText("")
    }

    @discardableResult
    private func markLivePartialPreviewConsumed(commandID explicitCommandID: String? = nil) -> Bool {
        let commandID = effectiveLivePartialCommandID(explicitCommandID)
        if let commandID, var state = livePartialPreviewState, state.commandID == commandID {
            guard !state.consumedByUser else { return false }
            state.consumedByUser = true
            livePartialPreviewState = state
            return true
        }
        guard let commandID,
              activeMarkedTextOwner == .livePartial,
              !activeMarkedText.isEmpty
        else { return false }
        let anchor = currentLivePartialPreviewAnchor()
        livePartialPreviewState = LivePartialPreviewState(
            commandID: commandID,
            text: activeMarkedText.trimmingCharacters(in: .whitespacesAndNewlines),
            contextBefore: anchor.contextBefore,
            contextAfter: anchor.contextAfter,
            textInputIdentity: currentTextInputIdentity,
            consumedByUser: true,
            ownershipInvalidated: false
        )
        return true
    }

    private func clearLivePartialPreview(commandID: String? = nil) {
        guard let commandID else {
            livePartialPreviewState = nil
            return
        }
        if livePartialPreviewState?.commandID == commandID {
            livePartialPreviewState = nil
        }
    }

    private var canStopActiveRefine: Bool {
        guard currentBridgeStatus?.state == .sending else { return false }
        guard currentBridgeStatus?.processingStage == .refining || styleRewriteCommandID != nil else {
            return false
        }
        return hasActiveRefineStopTarget
    }

    private var hasActiveRefineStopTarget: Bool {
        if styleRewriteCommandID != nil { return true }
        if activeMarkedTextOwner == .livePartial,
           !activeMarkedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let state = livePartialPreviewState,
           !state.consumedByUser,
           !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    @discardableResult
    private func stopActiveRefineFromUserAction(commandID explicitCommandID: String? = nil) -> Bool {
        guard canStopActiveRefine else { return false }
        if stopLivePartialRefineFromUserAction(commandID: explicitCommandID) {
            return true
        }
        return stopActiveStyleRewriteFromUserAction()
    }

    @discardableResult
    private func stopLivePartialRefineFromUserAction(commandID explicitCommandID: String? = nil) -> Bool {
        let commandID = effectiveLivePartialCommandID(explicitCommandID)
        let didCommit = commitLivePartialBeforeHostReturnIfNeeded(commandID: commandID)
        guard didCommit else { return false }
        _ = markLivePartialPreviewConsumed(commandID: commandID)

        let consumedCommandID = commandID ?? currentBridgeStatus?.commandID ?? pendingStopCommandID
        if let consumedCommandID {
            suppressRefineResult(commandID: consumedCommandID, reason: "live_partial_stop")
        }
        if currentBridgeStatus?.state == .sending {
            finishStoppedLivePartialRefine(commandID: consumedCommandID)
        }
        return true
    }

    private func finishStoppedLivePartialRefine(commandID: String?) {
        clearLivePartialPreview(commandID: commandID)
        if let commandID {
            bridgeCommandTasks[commandID]?.cancel()
            bridgeCommandTasks[commandID] = nil
        }
        pendingStopCommandID = nil
        activeRecordingCommandID = nil
        activeRecordingTextEditIntent = nil
        activeRecordingTextTarget = nil
        bridgeStatus = KeyboardBridgeStatus(
            commandID: commandID,
            state: .result,
            message: "Inserted without refine",
            backendReachable: currentBridgeStatus?.backendReachable
        )
        lastBridgeContactAt = Date().timeIntervalSince1970
        if keyboardFocus == .text {
            beginInsertedFlash()
        }
        updateUI()
    }

    @discardableResult
    private func stopActiveStyleRewriteFromUserAction() -> Bool {
        guard let commandID = styleRewriteCommandID else { return false }
        suppressRefineResult(commandID: commandID, reason: "style_rewrite_stop")
        styleRewriteCommandID = nil
        styleRewriteTask?.cancel()
        styleRewriteTask = nil
        bridgeStatus = KeyboardBridgeStatus(
            commandID: commandID,
            state: .standby,
            message: "Ready",
            backendReachable: currentBridgeStatus?.backendReachable
        )
        lastBridgeContactAt = Date().timeIntervalSince1970
        showTextKeyboardStatus(NSLocalizedString("No refine", comment: "Inline status after skipping an active refine"), color: .systemOrange)
        updateUI()
        return true
    }

    private func suppressRefineResult(commandID: String?, reason: String) {
        guard let commandID else { return }
        let now = Date().timeIntervalSince1970
        pruneSuppressedRefineResultCommandIDs(now: now)
        suppressedRefineResultCommandIDs[commandID] = now
        defaults.set(commandID, forKey: lastInsertedCommandIDKey)
        kbLog.notice("suppressing refine result command_id=\(commandID, privacy: .public) reason=\(reason, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "refine_result_suppressed",
            fields: [
                "command_id": commandID,
                "reason": reason,
            ]
        )
    }

    private func pruneSuppressedRefineResultCommandIDs(now: TimeInterval = Date().timeIntervalSince1970) {
        let cutoff = now - Self.suppressedRefineResultTTL
        suppressedRefineResultCommandIDs = suppressedRefineResultCommandIDs.filter { $0.value >= cutoff }
    }

    private func shouldIgnoreSuppressedRefineStatus(_ status: KeyboardBridgeStatus) -> Bool {
        guard let commandID = status.commandID else { return false }
        let now = Date().timeIntervalSince1970
        pruneSuppressedRefineResultCommandIDs(now: now)
        guard suppressedRefineResultCommandIDs[commandID] != nil else { return false }
        kbLog.notice("ignoring suppressed refine status command_id=\(commandID, privacy: .public) state=\(status.state.rawValue, privacy: .public)")
        return true
    }

    @discardableResult
    private func commitLivePartialBeforeHostReturnIfNeeded(commandID explicitCommandID: String? = nil) -> Bool {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        guard let commandID = effectiveLivePartialCommandID(explicitCommandID),
              let previewState = livePartialPreviewState,
              previewState.commandID == commandID,
              canCommitOwnedLivePartialMarkedText(previewState, before: before, after: after)
        else { return false }
        let preview = activeMarkedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else {
            replaceMarkedText("")
            return false
        }
        let anchor = currentLivePartialPreviewAnchor()
        commitLivePartialMarkedTextAsPreview(preview, commandID: commandID)
        clearLocalMarkedTextState()
        recordLivePartialPreview(commandID: commandID, text: preview, anchor: anchor)
        return true
    }

    private func applyFinalResultForLivePartialPreview(
        _ preview: LivePartialPreviewState,
        finalText: String
    ) -> Bool {
        defer {
            clearLivePartialPreview(commandID: preview.commandID)
        }
        let plan = livePartialFinalCommitPlan(for: preview)
        return executeLivePartialFinalCommitPlan(plan, preview: preview, finalText: finalText)
    }

    private func livePartialFinalCommitPlan(for preview: LivePartialPreviewState) -> LivePartialFinalCommitPlan {
        if preview.consumedByUser {
            return .consumed
        }
        if preview.ownershipInvalidated {
            return .missingAnchor
        }

        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        if canCommitOwnedLivePartialMarkedText(preview, before: before, after: after) {
            return .ownedMarked
        }
        return .missingAnchor
    }

    private func executeLivePartialFinalCommitPlan(
        _ plan: LivePartialFinalCommitPlan,
        preview: LivePartialPreviewState,
        finalText: String
    ) -> Bool {
        switch plan {
        case .consumed:
            kbLog.notice(
                "live preview final commit skipped plan=\(plan.logName, privacy: .public) command_id=\(preview.commandID, privacy: .public) preview_chars=\(preview.text.count, privacy: .public) final_chars=\(finalText.count, privacy: .public)"
            )
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-ui",
                event: "live_preview_final_commit_skipped",
                fields: livePreviewFinalCommitFields(plan: plan, preview: preview, finalText: finalText)
            )
            if activeMarkedTextOwner == .livePartial {
                _ = commitLivePartialBeforeHostReturnIfNeeded(commandID: preview.commandID)
            }
            return true

        case .ownedMarked:
            return commitOwnedLivePartialMarkedTextAsFinal(finalText, preview: preview, plan: plan)

        case .missingAnchor:
            logLivePartialFinalCommitMiss(plan: plan, preview: preview, finalText: finalText)
            // The proxy target can no longer be proven. Forget only our local
            // ownership; operating on the current marked text could corrupt a
            // Rime composition in another target.
            if activeMarkedTextOwner == .livePartial {
                clearLocalMarkedTextState()
            }
            return false
        }
    }

    private func commitOwnedLivePartialMarkedTextAsFinal(
        _ finalText: String,
        preview: LivePartialPreviewState,
        plan: LivePartialFinalCommitPlan
    ) -> Bool {
        let markedText = activeMarkedText
        let cursor = (finalText as NSString).length
        textDocumentProxy.setMarkedText(finalText, selectedRange: NSRange(location: cursor, length: 0))
        textDocumentProxy.unmarkText()
        clearLocalMarkedTextState()
        kbLog.notice(
            "live preview final commit applied plan=\(plan.logName, privacy: .public) command_id=\(preview.commandID, privacy: .public) marked_chars=\(markedText.count, privacy: .public) preview_chars=\(preview.text.count, privacy: .public) final_chars=\(finalText.count, privacy: .public)"
        )
        var fields = livePreviewFinalCommitFields(plan: plan, preview: preview, finalText: finalText)
        fields["marked_chars"] = "\(markedText.count)"
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "live_preview_final_commit_applied",
            fields: fields
        )
        return true
    }

    private func logLivePartialFinalCommitMiss(
        plan: LivePartialFinalCommitPlan,
        preview: LivePartialPreviewState,
        finalText: String
    ) {
        let beforeCount = textDocumentProxy.documentContextBeforeInput?.count ?? 0
        let afterCount = textDocumentProxy.documentContextAfterInput?.count ?? 0
        let activeMarkedCount = activeMarkedText.count
        kbLog.notice(
            "live preview final commit skipped plan=\(plan.logName, privacy: .public) command_id=\(preview.commandID, privacy: .public) active_marked_chars=\(activeMarkedCount, privacy: .public) before_chars=\(beforeCount, privacy: .public) after_chars=\(afterCount, privacy: .public) preview_chars=\(preview.text.count, privacy: .public) final_chars=\(finalText.count, privacy: .public)"
        )
        var fields = livePreviewFinalCommitFields(plan: plan, preview: preview, finalText: finalText)
        fields["active_marked_chars"] = "\(activeMarkedCount)"
        fields["current_before_chars"] = "\(beforeCount)"
        fields["current_after_chars"] = "\(afterCount)"
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "live_preview_final_commit_failed",
            fields: fields
        )
    }

    private func livePreviewFinalCommitFields(
        plan: LivePartialFinalCommitPlan,
        preview: LivePartialPreviewState,
        finalText: String
    ) -> [String: String] {
        [
            "command_id": preview.commandID,
            "plan": plan.logName,
            "preview_chars": "\(preview.text.count)",
            "final_chars": "\(finalText.count)",
            "anchor_before_chars": "\(preview.contextBefore.count)",
            "anchor_after_chars": "\(preview.contextAfter.count)",
        ]
    }

    private func canCommitOwnedLivePartialMarkedText(
        _ preview: LivePartialPreviewState,
        before: String,
        after: String
    ) -> Bool {
        guard activeMarkedTextOwner == .livePartial,
              !activeMarkedText.isEmpty,
              activeMarkedText == preview.text
        else { return false }
        if let capturedIdentity = preview.textInputIdentity,
           let currentTextInputIdentity,
           capturedIdentity != currentTextInputIdentity {
            return false
        }
        return KeyboardMarkedTextOwnershipPolicy.contextsMatch(
            before: before,
            after: after,
            markedText: activeMarkedText,
            anchorBefore: preview.contextBefore,
            anchorAfter: preview.contextAfter
        )
    }

    private func isAlphabeticTextKey(_ character: String) -> Bool {
        guard character.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.uppercaseLetters.contains(scalar)
    }

    private func shouldAutoCapitalizeNextEnglishLetter() -> Bool {
        shouldAutoCapitalizeNextEnglishLetterDecision().outcome
    }

    private struct AutocapDecision {
        let outcome: Bool
        let reason: String
    }

    private func shouldAutoCapitalizeNextEnglishLetterDecision() -> AutocapDecision {
        guard isAutoCapitalizationEnabled else {
            return AutocapDecision(outcome: false, reason: "disabled")
        }
        guard textInputLanguage == .english else {
            return AutocapDecision(outcome: false, reason: "not-english")
        }

        switch textDocumentProxy.keyboardType {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .twitter, .webSearch, .asciiCapableNumberPad:
            return AutocapDecision(outcome: false, reason: "kbtype-excluded")
        default:
            break
        }

        let capitalizationPolicy = textDocumentProxy.autocapitalizationType ?? .sentences
        switch capitalizationPolicy {
        case .none:
            return AutocapDecision(outcome: false, reason: "policy-none")
        case .allCharacters:
            return AutocapDecision(outcome: true, reason: "policy-all")
        case .words:
            guard let context = textDocumentProxy.documentContextBeforeInput else {
                return AutocapDecision(outcome: true, reason: "policy-words-ctx-nil-boundary")
            }
            let yes = context.isEmpty || context.last?.isWhitespace == true
            return AutocapDecision(outcome: yes, reason: yes ? "policy-words-boundary" : "policy-words-midword")
        case .sentences:
            break
        @unknown default:
            break
        }

        guard let context = textDocumentProxy.documentContextBeforeInput else {
            return AutocapDecision(outcome: true, reason: "sentences-ctx-nil-boundary")
        }
        guard !context.isEmpty else {
            return AutocapDecision(outcome: true, reason: "sentences-empty-context")
        }

        var sawTrailingWhitespace = false
        var crossedLineBreak = false
        let characters = Array(context)
        var index = characters.count - 1
        while index >= 0 {
            let character = characters[index]
            let text = String(character)
            if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                sawTrailingWhitespace = true
                if text.rangeOfCharacter(from: .newlines) != nil {
                    crossedLineBreak = true
                }
                index -= 1
                continue
            }
            guard sawTrailingWhitespace else {
                return AutocapDecision(outcome: false, reason: "sentences-no-word-boundary")
            }
            if crossedLineBreak {
                return AutocapDecision(outcome: true, reason: "sentences-after-newline")
            }
            while index >= 0, "\"'”’)]}）】》」』".contains(characters[index]) {
                index -= 1
            }
            guard index >= 0 else {
                return AutocapDecision(outcome: false, reason: "sentences-after-closing-only")
            }
            let isSentenceEnd = ".!?。？！".contains(characters[index])
            return AutocapDecision(
                outcome: isSentenceEnd,
                reason: isSentenceEnd ? "sentences-after-punct" : "sentences-mid-sentence"
            )
        }
        return AutocapDecision(outcome: true, reason: "sentences-whitespace-only")
    }

    private func refreshEnglishLetterCasingIfNeeded() {
        guard textInputLanguage == .english,
              !isSymbolKeyboard,
              keyboardFocus == .text
        else { return }
        refreshShiftButtonImage()
        refreshLetterCasing()
    }

    private func chinesePunctuationDisplayTitle(for character: String) -> String {
        switch character {
        case ",": return "，"
        case ".": return "。"
        case "?": return "？"
        case "!": return "！"
        case ":": return "："
        case ";": return "；"
        case "(": return "（"
        case ")": return "）"
        case "\"": return "”"
        case "'": return "’"
        case "/": return "、"
        case "\\": return "—"
        case "|": return "·"
        case "`": return "｀"
        case "~": return "～"
        case "$": return "￥"
        case "^": return "……"
        case "<": return "《"
        case ">": return "》"
        case "[": return "【"
        case "]": return "】"
        case "{": return "「"
        case "}": return "」"
        default: return character
        }
    }

    private func chineseDirectText(for character: String) -> String {
        guard !isSymbolKeyboard else { return character }
        guard chinesePunctuationStyle == .chinese,
              isChinesePunctuationContext
        else { return character }
        switch character {
        case "\"":
            let quote = doubleQuoteOpen ? "\u{201C}" : "\u{201D}"
            doubleQuoteOpen.toggle()
            return quote
        case "'":
            let quote = singleQuoteOpen ? "\u{2018}" : "\u{2019}"
            singleQuoteOpen.toggle()
            return quote
        default:
            return chinesePunctuationDisplayTitle(for: character)
        }
    }

    private func resetQuoteParity() {
        doubleQuoteOpen = true
        singleQuoteOpen = true
    }

    /// `false` when the host field hints it wants literal ASCII (URLs,
    /// emails, numeric input, etc.). Mirrors iOS system Simplified Chinese
    /// keyboard: in these field types, Chinese punctuation conversion is
    /// entirely suppressed so you can type "https://example.com" or "3.14"
    /// directly without leaving the keyboard.
    private var isChinesePunctuationContext: Bool {
        switch textDocumentProxy.keyboardType {
        case .URL, .emailAddress, .numberPad, .phonePad,
             .decimalPad, .twitter, .webSearch, .asciiCapableNumberPad:
            return false
        default:
            return true
        }
    }

    private var isSearchTextInputContext: Bool {
        switch textDocumentProxy.keyboardType {
        case .webSearch:
            return true
        default:
            break
        }
        switch textDocumentProxy.returnKeyType {
        case .search, .google, .yahoo:
            return true
        default:
            return false
        }
    }

    private func insertChineseDirectTextKey(_ character: String) {
        discardRimeInputIfTargetChanged()
        let currentState = rimeInput.state()
        if shouldProcessChineseDirectTextKeyInRime(character, state: currentState) {
            processChineseRimeTextKey(character)
            resetShiftIfSticky()
            renderRefineSuggestionsIfIdle()
            return
        }
        let directText = chineseDirectText(for: character)
        if !pendingRimeCharacters.isEmpty || !pendingRimeDirectTextKeys.isEmpty {
            queuePendingRimeDirectTextKey(directText, state: currentState)
            resetShiftIfSticky()
            renderRefineSuggestionsIfIdle()
            return
        }
        if currentState.isComposing {
            if let literalText = latinLiteralCommitTextBeforeDirectKey(currentState, character: character) {
                commitRawRimeInput(literalText, appending: directText)
                resetShiftIfSticky()
                renderRefineSuggestionsIfIdle()
                return
            }
            applyRimeState(rimeInput.commitComposition())
        } else {
            replaceMarkedText("")
        }
        clearRefineUndoStateForManualEdit()
        textDocumentProxy.insertText(directText)
        resetShiftIfSticky()
        renderRefineSuggestionsIfIdle()
    }

    private func latinLiteralCommitTextBeforeDirectKey(
        _ state: RimeKeyboardState,
        character: String
    ) -> String? {
        guard textInputLanguage == .chinese,
              state.isComposing,
              isRawLatinInput(state.input),
              isLiteralAsciiDirectKeyContinuation(character),
              character != "@"
        else { return nil }

        let lowercasedInput = state.input.lowercased()
        if isLiteralAsciiTextInputContext
            || isContinuingLiteralAsciiTokenContext
            || isRawRimeInputLiteralToken(state.input)
            || (character == "." && lowercasedInput == "www")
            || (character == ":" && ["http", "https", "ftp", "mailto"].contains(lowercasedInput)) {
            return state.input
        }

        return exactLatinCandidateBeforeNonLatinCandidates(in: state)?.text
    }

    private func shouldProcessChineseDirectTextKeyInRime(
        _ character: String,
        state: RimeKeyboardState
    ) -> Bool {
        guard textInputLanguage == .chinese,
              !isRenderedNumericTextKeyboard,
              isLiteralAsciiDirectKeyContinuation(character)
        else { return false }

        if !pendingRimeCharacters.isEmpty,
           pendingRimeDirectTextKeys.isEmpty {
            let pendingInput = pendingRimeCharacters.joined()
            return shouldContinueLiteralAsciiComposition(input: pendingInput, appending: character)
        }

        guard state.isComposing,
              isRawLatinInput(state.input)
        else { return false }
        return shouldContinueLiteralAsciiComposition(input: state.input, appending: character)
    }

    private func shouldContinueLiteralAsciiComposition(
        input: String,
        appending character: String
    ) -> Bool {
        guard !input.isEmpty,
              isRawLatinInput(input)
        else { return false }

        let lowercasedInput = input.lowercased()
        if character == "@" { return true }
        if isLiteralAsciiTextInputContext { return true }
        if isContinuingLiteralAsciiTokenContext { return true }
        if isRawRimeInputLiteralToken(input) { return true }
        if isURLSchemeLiteralPrefix(lowercasedInput) { return true }
        if character == ".", lowercasedInput == "www" { return true }
        if character == ":", Self.literalURLSchemes.contains(lowercasedInput) { return true }
        return false
    }

    private func isLiteralAsciiDirectKeyContinuation(_ character: String) -> Bool {
        guard character.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return isASCIIAlphanumeric(scalar) || Self.literalAsciiContinuationScalars.contains(scalar)
    }

    private func exactLatinCandidateBeforeNonLatinCandidates(in state: RimeKeyboardState) -> RimeKeyboardCandidate? {
        let lowercasedInput = state.input.lowercased()
        for candidate in state.candidates {
            if candidate.text.lowercased() == lowercasedInput,
               isRawLatinInput(candidate.text) {
                return candidate
            }
            if !isRawLatinInput(candidate.text) {
                return nil
            }
        }
        return nil
    }

    private static let literalAsciiContinuationScalars = Set(".@_+-':/#%?=&".unicodeScalars)
    private static let literalURLSchemes: Set<String> = ["http", "https", "ftp", "mailto", "file"]
    private static let literalURLSchemePrefixes = ["http:", "https:", "ftp:", "mailto:", "file:"]

    private func shouldCommitRawRimeInputBeforeSeparator(_ state: RimeKeyboardState) -> Bool {
        guard textInputLanguage == .chinese,
              state.isComposing,
              isRawLatinInput(state.input)
        else { return false }
        return isDedicatedLiteralAsciiTextInputContext
            || isContinuingLiteralAsciiTokenContext
            || isRawRimeInputLiteralToken(state.input)
            || exactLatinCandidateBeforeNonLatinCandidates(in: state) != nil
    }

    private func isRawLatinInput(_ input: String) -> Bool {
        guard !input.isEmpty else { return false }
        return input.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphanumeric(scalar)
                || Self.literalAsciiContinuationScalars.contains(scalar)
        }
    }

    private func isRawRimeInputLiteralToken(_ input: String) -> Bool {
        let lowercasedInput = input.lowercased()
        return lowercasedInput.contains("@")
            || lowercasedInput.contains("://")
            || lowercasedInput.hasPrefix("www.")
            || isURLSchemeLiteralPrefix(lowercasedInput)
    }

    private func isURLSchemeLiteralPrefix(_ input: String) -> Bool {
        let lowercasedInput = input.lowercased()
        return Self.literalURLSchemePrefixes.contains { prefix in
            lowercasedInput.hasPrefix(prefix)
        }
    }

    private func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        scalar.value <= 0x7F && CharacterSet.alphanumerics.contains(scalar)
    }

    private var isLiteralAsciiTextInputContext: Bool {
        isDedicatedLiteralAsciiTextInputContext || isSearchTextInputContext
    }

    private var isDedicatedLiteralAsciiTextInputContext: Bool {
        switch textDocumentProxy.keyboardType {
        case .URL, .emailAddress, .twitter:
            return true
        default:
            return false
        }
    }

    private var isContinuingLiteralAsciiTokenContext: Bool {
        guard let token = literalAsciiTokenPrefixBeforeInput else { return false }
        let lowercasedToken = token.lowercased()
        return lowercasedToken.contains("@")
            || lowercasedToken.contains("://")
            || lowercasedToken.hasPrefix("www.")
            || isURLSchemeLiteralPrefix(lowercasedToken)
            || lowercasedToken.hasPrefix("@")
            || lowercasedToken.hasPrefix("#")
    }

    private var literalAsciiTokenPrefixBeforeInput: String? {
        guard let context = textDocumentProxy.documentContextBeforeInput,
              !context.isEmpty
        else { return nil }
        let scalars = Array(context.unicodeScalars.suffix(96))
        var tokenScalars: [UnicodeScalar] = []
        for scalar in scalars.reversed() {
            if isASCIIAlphanumeric(scalar)
                || Self.literalAsciiContinuationScalars.contains(scalar) {
                tokenScalars.append(scalar)
            } else {
                break
            }
        }
        guard !tokenScalars.isEmpty else { return nil }
        return String(String.UnicodeScalarView(tokenScalars.reversed()))
    }

    @objc private func deletePressDown() {
        guard deleteRepeatTask == nil else { return }
        handleTextBackspace()
        let startedAt = Date()
        deleteRepeatTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.deleteRepeatInitialDelay)
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                await MainActor.run {
                    if self.rimeInput.state().isComposing {
                        self.handleTextBackspace()
                    } else if elapsed >= 1.5 {
                        self.deleteBackwardToLineBoundary()
                    } else if elapsed >= 0.5 {
                        self.deleteBackwardToWordBoundary()
                    } else {
                        self.handleTextBackspace()
                    }
                }
                let interval: UInt64 = elapsed >= 1.5 ? 150_000_000 : (elapsed >= 0.5 ? 120_000_000 : self.deleteRepeatInterval)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    @objc private func deletePressUp() {
        stopDeleteRepeat()
    }

    private func stopDeleteRepeat() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    private func deleteBackwardToWordBoundary() {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let count = deletionCountToWordBoundary(in: context)
        guard count > 0 else {
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            return
        }
        clearRefineUndoStateForManualEdit()
        deleteBackward(characterCount: count)
    }

    private func deleteBackwardToLineBoundary() {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let count = deletionCountToLineBoundary(in: context)
        guard count > 0 else {
            clearRefineUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            return
        }
        clearRefineUndoStateForManualEdit()
        deleteBackward(characterCount: count)
    }

    private func deletionCountToWordBoundary(in context: String) -> Int {
        guard !context.isEmpty else { return 0 }
        var count = 0
        var consumedNonWhitespace = false
        for character in context.reversed() {
            if character.isWhitespace {
                if consumedNonWhitespace { break }
                count += 1
            } else {
                consumedNonWhitespace = true
                count += 1
            }
        }
        return count
    }

    private func deletionCountToLineBoundary(in context: String) -> Int {
        guard !context.isEmpty else { return 0 }
        var count = 0
        for character in context.reversed() {
            count += 1
            if character.isNewline { break }
        }
        return count
    }

    @objc private func insertSpace() {
        handleTextSpace()
    }

    @objc private func textSpaceTapped() {
        guard Date().timeIntervalSince1970 >= suppressTextSpaceTapUntil else { return }
        handleTextSpace()
    }

    @objc private func handleTextSpaceCursorGesture(_ recognizer: UILongPressGestureRecognizer) {
        guard keyboardFocus == .text,
              let keyView = recognizer.view
        else { return }

        let location = recognizer.location(in: textKeyboardContainer)
        switch recognizer.state {
        case .began:
            isTextSpaceCursorTracking = true
            suppressTextSpaceTapUntil = Date().timeIntervalSince1970 + 0.35
            activeTrackpadSourceView = keyView
            textSpaceCursorStartX = location.x
            textTrackpadLastStepX = 0
            if rimeInput.state().isComposing {
                commitDisplayedRimeCompositionIfNeeded()
            }
            keyboardHaptics.playSelectionChanged()
            setTextTrackpadMode(true)
            keyView.layer.removeAllAnimations()
            keyView.alpha = 0.72
            keyView.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        case .changed:
            guard isTextSpaceCursorTracking else { return }
            updateTrackpadCursorPosition(deltaX: location.x - textSpaceCursorStartX)
        case .ended, .cancelled, .failed:
            endTextSpaceCursorTracking(keyView)
        default:
            break
        }
    }

    private func endTextSpaceCursorTracking(_ keyView: UIView) {
        guard isTextSpaceCursorTracking else { return }
        isTextSpaceCursorTracking = false
        suppressTextSpaceTapUntil = Date().timeIntervalSince1970 + 0.20
        activeTrackpadSourceView = nil
        keyView.layer.removeAllAnimations()
        keyView.alpha = 1
        keyView.transform = .identity
        setTextTrackpadMode(false)
        renderRefineSuggestionsIfIdle()
    }

    private func setTextTrackpadMode(_ enabled: Bool) {
        textTrackpadPanRecognizer.isEnabled = enabled
        if !enabled {
            textTrackpadLastStepX = 0
        }
        for button in textKeyboardButtons {
            button.isUserInteractionEnabled = !enabled || button === activeTrackpadSourceView
        }
        keyRowsStack.layer.removeAllAnimations()
        candidateScrollView.layer.removeAllAnimations()
        keyRowsStack.alpha = enabled ? 0.25 : 1
        candidateScrollView.alpha = enabled ? 0.38 : 1
    }

    @objc private func handleTextTrackpadPan(_ recognizer: UIPanGestureRecognizer) {
        guard isTextSpaceCursorTracking else { return }
        let translation = recognizer.translation(in: textKeyboardContainer)
        switch recognizer.state {
        case .changed:
            updateTrackpadCursorPosition(deltaX: translation.x)
        case .ended, .cancelled, .failed:
            if let source = activeTrackpadSourceView {
                endTextSpaceCursorTracking(source)
            } else {
                setTextTrackpadMode(false)
            }
        default:
            break
        }
    }

    private func updateTrackpadCursorPosition(deltaX: CGFloat) {
        let stepX = Int(deltaX / 8)
        let deltaStepX = stepX - textTrackpadLastStepX
        if deltaStepX != 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: deltaStepX)
            textTrackpadLastStepX = stepX
        }
    }

    @objc private func insertReturn() {
        handleTextReturn()
    }

    private func lightHaptic() {
        keyboardHaptics.playControlTap()
    }

    private var currentBridgeStatus: KeyboardBridgeStatus? {
        bridgeStatus
    }

    private func reportKeyboardIssueToHostIfNeeded(_ status: KeyboardBridgeStatus) {
        guard !isApplyingHostBridgeStatus else { return }
        guard status.state == .error else {
            lastReportedKeyboardIssueSignature = ""
            return
        }
        guard status.commandID != nil else { return }
        let message = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let signature = "\(status.commandID ?? "")|\(message)"
        guard signature != lastReportedKeyboardIssueSignature else { return }
        lastReportedKeyboardIssueSignature = signature

        let issue = KeyboardHostIssueReport(commandID: status.commandID, message: message)
        guard KeyboardSharedDefaults.saveKeyboardHostIssue(issue) else {
            kbLog.error(
                "failed to persist keyboard issue for host command_id=\(status.commandID ?? "none", privacy: .public) message=\(message, privacy: .public)"
            )
            return
        }
        kbLog.error(
            "reported keyboard issue to host command_id=\(status.commandID ?? "none", privacy: .public) message=\(issue.message, privacy: .public)"
        )
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.keyboardIssueReported)
    }

    @discardableResult
    private func applySharedBridgeStatusSnapshot(allowActiveState: Bool = false) -> Bool {
        guard let status = KeyboardSharedDefaults.loadStatusSnapshot(),
              isUsableSharedBridgeStatusSnapshot(status, allowActiveState: allowActiveState)
        else { return false }
        applyBridgeStatus(status, recordsLiveContact: false)
        return true
    }

    @discardableResult
    private func applySharedStandbySnapshotForFastStart() -> Bool {
        guard let status = KeyboardSharedDefaults.loadStatusSnapshot(),
              status.state == .standby
        else { return false }
        let age = Date().timeIntervalSince1970 - status.updatedAt
        guard age >= 0, age <= Self.sharedStandbyLivenessSnapshotMaxAge else { return false }
        applyBridgeStatus(status, recordsLiveContact: false)
        return true
    }

    @discardableResult
    private func applySharedStandbySnapshotForPresentation() -> Bool {
        guard currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending,
              let status = KeyboardSharedDefaults.loadStatusSnapshot(),
              status.state == .standby
        else { return false }
        let age = Date().timeIntervalSince1970 - status.updatedAt
        guard age >= 0, age <= Self.sharedStandbyPresentationSnapshotMaxAge else { return false }
        applyBridgeStatus(status, recordsLiveContact: false)
        return true
    }

    private func isUsableSharedBridgeStatusSnapshot(
        _ status: KeyboardBridgeStatus,
        allowActiveState: Bool
    ) -> Bool {
        let age = Date().timeIntervalSince1970 - status.updatedAt
        guard age >= 0 else { return false }
        switch status.state {
        case .recording, .sending:
            return allowActiveState && age <= Self.sharedActiveStatusSnapshotMaxAge
        case .idle, .standby, .error:
            return age <= Self.sharedStatusSnapshotMaxAge
        case .result:
            // Shared snapshots redact text payloads. Applying one as a real
            // result would mark the command complete before the status stream can
            // deliver the text that replaces the live preview.
            guard age <= Self.sharedStatusSnapshotMaxAge,
                  let commandID = status.commandID,
                  status.resultText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else { return false }
            return expectedRecordingResultCommandIDs().contains(commandID)
                || styleRewriteCommandID == commandID
        }
    }

    private var hasActiveKeyboardRecordingOrStopIntent: Bool {
        isVoicePressActive
            || isCommandPressActive
            || tapRecordingActive
            || activeRecordingCommandID != nil
            || activeRecordingTextTarget != nil
            || pendingStopCommandID != nil
    }

    private var isOpeningHostApp: Bool {
        openingHostUntil > Date().timeIntervalSince1970
    }

    private func suppressDuplicateHostOpen(source: String) -> Bool {
        guard isOpeningHostApp else { return false }
        kbLog.notice("openHostApp: host open already pending; suppressing duplicate source=\(source, privacy: .public)")
        updateUI()
        return true
    }

    private func showFullAccessRequiredStatus(showTextNotice: Bool = false) {
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.fullAccessRequired)
        bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
        lastBridgeContactAt = Date().timeIntervalSince1970
        if showTextNotice {
            showTextKeyboardStatus(NSLocalizedString("Enable Full Access", comment: "Inline status when keyboard full access is missing"))
        }
        updateUI()
    }

    private var isBridgeAwake: Bool {
        // Strongest signal: a Darwin notification from the host process. Set
        // by sessionStarted/dictationStarted/dictationStopped, cleared by
        // sessionEnded. This proves the host bridge is alive regardless of
        // whether the keyboard's localhost status probe has had time to land,
        // so a mic press right after the keyboard reattaches (or right after
        // a previous dictation finishes) can skip the 0.9s probe.
        if lastDarwinAwakeAt > 0 {
            return true
        }
        guard let status = currentBridgeStatus else { return false }
        if Date().timeIntervalSince1970 - lastBridgeContactAt < 3 {
            return status.state != .idle
        }
        // A fresh standby snapshot is enough after host handoff: the host may
        // prepare audio before the keyboard receives a Darwin echo. Older
        // standby snapshots still expire so a killed host does not stay green
        // indefinitely.
        switch status.state {
        case .standby:
            return Date().timeIntervalSince1970 - status.updatedAt <= Self.sharedStandbyLivenessSnapshotMaxAge
        case .sending:
            return hasRecentProcessingTransportContact
        case .recording, .result:
            return true
        default:
            return false
        }
    }

    private var hasRecentProcessingTransportContact: Bool {
        guard lastBridgeContactAt > 0 else { return false }
        let maximumAge = Self.activeStatusStreamStaleAge + Self.activeBridgeStatusReconcileInterval + 1
        return Date().timeIntervalSince1970 - lastBridgeContactAt <= maximumAge
    }

    private var isBridgeAwakeForPresentation: Bool {
        if isBridgeAwake {
            return true
        }
        guard let status = currentBridgeStatus,
              status.state == .standby
        else { return false }
        let age = Date().timeIntervalSince1970 - status.updatedAt
        return age >= 0 && age <= Self.sharedStandbyPresentationSnapshotMaxAge
    }

    /// One short line, under the orb. Doubles as the only verbal hint — the
    /// orb's color and pulse rings carry the rest of the state.
    private var voiceTitle: String {
        if !hasFullAccess { return NSLocalizedString("Enable Full Access", comment: "Voice title when keyboard full access is missing") }
        if isOpeningHostApp { return NSLocalizedString("Opening Typeforme…", comment: "Voice title when host is launching") }
        switch currentBridgeStatus?.state {
        case .recording: return inputMode.recordingTitle
        case .sending: return sendingStatusTitle
        case .result: return insertedStatusTitle
        default: return inputMode.idleTitle
        }
    }

    private var voiceTitleColor: UIColor {
        return .label
    }

    private var pulseRingColor: UIColor {
        switch currentBridgeStatus?.state {
        case .recording: return UIColor.systemRed.withAlphaComponent(0.65)
        case .sending: return UIColor.systemIndigo.withAlphaComponent(0.5)
        default: return UIColor.systemBlue.withAlphaComponent(0.5)
        }
    }

    private var voiceIconName: String {
        guard hasFullAccess else { return "gearshape.fill" }
        switch currentBridgeStatus?.state {
        case .recording: return "stop.fill"
        case .sending: return canStopActiveRefine ? "arrow.up" : "hourglass"
        default: return "mic.fill"
        }
    }

    /// Vertical gradient: top color slightly lighter than bottom for soft
    /// depth. Returned as `[UIColor]`; the layer converts to `CGColor`.
    private var voiceGradientColors: [UIColor] {
        let (top, bottom) = gradientStops
        return [top, bottom]
    }

    private var voiceShadowColor: UIColor {
        gradientStops.bottom
    }

    private var gradientStops: (top: UIColor, bottom: UIColor) {
        let preset = gradientPreset
        return (preset.top, preset.bottom)
    }

    /// Mirrors `gradientStops` selection but returns the semantic preset for
    /// reuse — `DesignTokens.OrbGradient` is the single source of truth for
    /// orb colors across iOS host and keyboard.
    private var gradientPreset: OrbGradient {
        guard hasFullAccess else { return .blocked }
        if isOpeningHostApp { return .sending }
        switch currentBridgeStatus?.state {
        case .recording: return .recording
        case .sending:   return .sending
        case .error:     return isBridgeAwake ? .blocked : .idle
        default:         return .idle
        }
    }

    /// Common look for readiness dots: filled circle + thin white ring so the
    /// badge stays legible over toolbar material and light/dark backgrounds.
    private func configureReadyDot(_ dot: UIView, diameter: CGFloat, borderWidth: CGFloat) {
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isUserInteractionEnabled = false
        dot.layer.cornerRadius = diameter / 2
        dot.layer.cornerCurve = .continuous
        dot.layer.borderWidth = borderWidth
        dot.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        dot.backgroundColor = .systemGray3
    }

    /// Four-state readiness signal layered most-blocking-first:
    ///   🔴 systemRed   — Full Access missing (setup, not connectivity).
    ///   ⚪️ systemGray3 — Host iOS app not reachable (need wake).
    ///   🟡 systemOrange— Host alive but last Mac probe failed (will retry on press; may fail).
    ///   🟢 systemGreen — Host alive AND last Mac probe succeeded OR no probe yet (optimistic).
    ///
    /// `backendReachable == nil` (never probed this host session) maps to
    /// green per the agreed UX — the orb's failure path will reveal a real
    /// outage if the optimism is wrong, and the dot will flip amber on the
    /// next status stream update. Avoids flashing amber on every cold keyboard open.
    private var readyDotColor: UIColor {
        guard hasFullAccess else { return .systemRed }
        guard isBridgeAwakeForPresentation else { return .systemGray3 }
        if currentBridgeStatus?.backendReachable == false { return .systemOrange }
        return .systemGreen
    }

    private var statusDotColor: UIColor {
        if isOpeningHostApp { return .systemBlue }
        if isStartRequestInFlight { return .systemBlue }
        switch currentBridgeStatus?.state {
        case .recording: return .systemRed
        case .sending: return .systemBlue
        case .error where isBridgeAwake: return .systemOrange
        case .error: return .systemRed
        case .result: return .systemGreen
        default: return .clear
        }
    }

    private var shouldShowStatusGroup: Bool {
        if !hasFullAccess || isOpeningHostApp || isStartRequestInFlight { return true }
        switch currentBridgeStatus?.state {
        case .recording, .sending, .result, .error:
            return true
        case .idle, .standby, .none:
            return false
        }
    }

    /// Top-left status pill is a *bridge session indicator*: a coarse-grained
    /// view of where the keyboard session is in its lifecycle. Detailed
    /// processing stages belong to the center voice title / text toolbar.
    private var statusText: String {
        if !hasFullAccess {
            return NSLocalizedString("Full Access", comment: "Status when keyboard full access is missing")
        }
        if isOpeningHostApp {
            return NSLocalizedString("Opening", comment: "Status while host opens")
        }
        if isStartRequestInFlight {
            return NSLocalizedString("Starting", comment: "Status while keyboard asks host to start recording")
        }
        guard let status = currentBridgeStatus else { return "" }
        switch status.state {
        case .standby:
            return ""
        case .recording:
            return Self.recordingStatusText(startedAt: keyboardRecordingStartedAt)
        case .sending:
            return processingVoiceTitle
        case .result:
            return NSLocalizedString("Inserted", comment: "Status after result inserted")
        case .error:
            return isBridgeAwake
                ? NSLocalizedString("Issue", comment: "Status when bridge errored")
                : readinessStatusText
        case .idle:
            return ""
        }
    }

    /// Recording already has the red dot and voiceprint. Keep this strip to a
    /// timer only, so we do not show a second textual "Recording" state.
    private static func recordingStatusText(startedAt: TimeInterval) -> String {
        elapsedOnlyText(startedAt: startedAt) ?? ""
    }

    private static func elapsedOnlyText(startedAt: TimeInterval) -> String? {
        guard startedAt > 0 else { return nil }
        let total = max(0, Int(Date().timeIntervalSince1970 - startedAt))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var readinessStatusText: String {
        if !isBridgeAwakeForPresentation {
            return NSLocalizedString("Open app", comment: "Status when host app is not reachable")
        }
        if currentBridgeStatus?.backendReachable == false {
            return NSLocalizedString("Mac offline", comment: "Status when paired Mac Bridge is not reachable")
        }
        return NSLocalizedString("Ready", comment: "Status idle/standby")
    }

    private var sendingStatusTitle: String {
        if currentBridgeStatus?.state == .sending,
           !hasRecentProcessingTransportContact {
            return NSLocalizedString("Open Typeforme", comment: "Bridge processing lost contact with host")
        }
        let message = bridgeStatusDisplayMessage
        if !message.isEmpty { return message }
        return NSLocalizedString("Transcribing", comment: "Bridge job stage")
    }

    private var bridgeStatusDisplayMessage: String {
        // The host publishes the curated stage label (Transcribing / Refining /
        // Inserted / error text) directly in `status.message`. Only append the
        // local stop-refine affordance when the keyboard can actually accept it.
        let message = currentBridgeStatus?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard canStopActiveRefine else { return message }
        let suffix = "click to send"
        guard !message.lowercased().contains(suffix) else { return message }
        return message.isEmpty ? suffix : "\(message) · \(suffix)"
    }

    private var processingVoiceTitle: String {
        if currentBridgeStatus?.state == .sending,
           !hasRecentProcessingTransportContact {
            return NSLocalizedString("Open Typeforme", comment: "Voice title when processing lost contact with host")
        }
        return NSLocalizedString("Processing", comment: "Voice title while dictation is processing")
    }

    private var stopProcessingStatusTitle: String {
        activeRecordingTextEditIntent == .command
            ? NSLocalizedString("Understanding", comment: "Bridge job stage while understanding a voice command")
            : NSLocalizedString("Transcribing", comment: "Bridge job stage")
    }

    private var isCurrentResultWithoutRefine: Bool {
        guard currentBridgeStatus?.state == .result else { return false }
        let message = currentBridgeStatus?.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return message.contains("without refine")
            || message.contains("refine timeout")
            || message.contains("refine error")
    }

    private var insertedStatusTitle: String {
        guard isCurrentResultWithoutRefine else {
            return NSLocalizedString("Inserted", comment: "Bridge job stage")
        }
        let message = currentBridgeStatus?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = message.lowercased()
        if normalized.hasPrefix("inserted without refine") {
            return message
        }
        if normalized.contains("refine timeout") {
            return NSLocalizedString("Inserted without refine: refine timeout", comment: "Bridge result when inserted after refine timeout")
        }
        if normalized.contains("refine error") {
            return NSLocalizedString("Inserted without refine: refine error", comment: "Bridge result when inserted after refine error")
        }
        return NSLocalizedString("Inserted without refine", comment: "Bridge result when inserted without refinement")
    }

    private func syncKeyboardSettingsToHost() {
        guard hasFullAccess, isBridgeAwake else { return }
        sendBridgeCommand(.configure)
    }

    private func sendBridgeCommand(_ action: KeyboardBridgeCommandAction) {
        let commandID: String
        if (action == .stop || action == .cancel),
           let activeCommandID = activeRecordingCommandID
            ?? activeRecordingTextTarget?.commandID
            ?? pendingStopCommandID {
            commandID = activeCommandID
        } else {
            commandID = UUID().uuidString
        }
        let command = KeyboardBridgeCommand(
            id: commandID,
            action: action,
            correctionMode: correctionMode.rawValue
        )
        sendBridgeCommand(command)
    }

    private func sendBridgeCommand(_ command: KeyboardBridgeCommand) {
        let action = command.action
        if action != .configure {
            if action == .start {
                sendDarwinBridgeCommand(command)
                return
            }
            if action == .stop || action == .cancel {
                sendLocalBridgeCommand(command)
                return
            }
            sendDarwinBridgeCommand(action, commandID: command.id)
            return
        }

        sendLocalBridgeCommand(command)
    }

    private func sendLocalBridgeCommand(_ command: KeyboardBridgeCommand) {
        if command.action == .start {
            sendDarwinBridgeCommand(command)
            return
        }
        if command.action == .stop || command.action == .cancel {
            tapRecordingActive = false
            isCommandPressActive = false
            if command.action == .stop {
                pendingStopCommandID = command.id
            }
            if command.action == .cancel {
                pendingCancelCommandID = command.id
                pendingStopCommandID = nil
                activeRecordingCommandID = nil
                activeRecordingTextEditIntent = nil
                activeRecordingTextTarget = nil
                activeDictationInsertionAnchor = nil
                livePartialPreviewState = nil
                cancelScheduledHostOpen()
            }
            let message: String
            switch command.action {
            case .start:
                message = "Starting recording"
            case .cancel:
                message = "Ready"
            case .stop:
                message = stopProcessingStatusTitle
            case .configure, .refineText:
                message = "Ready"
            }
            let status = KeyboardBridgeStatus(
                commandID: command.id,
                state: command.action == .start ? .standby : (command.action == .cancel ? .standby : .sending),
                message: message
            )
            bridgeStatus = status
            updateActiveStatusReconcileLoop(for: status)
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        let bridgeToken = hostKeyboardBridgeToken
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(
                    command,
                    bridgeToken: bridgeToken,
                    timeout: command.action.requestTimeout
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.bridgeCommandTasks[command.id] = nil
                    self.applyBridgeStatus(status)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.bridgeCommandTasks[command.id] = nil
                    if command.action == .stop || command.action == .cancel {
                        kbLog.notice("local bridge command failed; falling back to Darwin action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public)")
                        KeyboardDiagnosticEventLog.record(
                            source: "keyboard-ui",
                            event: "local_bridge_command_failed_fallback_darwin",
                            fields: [
                                "action": command.action.rawValue,
                                "command_id": command.id,
                                "error": error.localizedDescription,
                            ]
                        )
                        self.sendDarwinBridgeCommand(command)
                        return
                    }
                    if command.action == .configure {
                        kbLog.notice("local bridge configure deferred command_id=\(command.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        KeyboardDiagnosticEventLog.record(
                            source: "keyboard-ui",
                            event: "local_bridge_configure_deferred",
                            fields: [
                                "command_id": command.id,
                                "error": error.localizedDescription,
                            ]
                        )
                        return
                    }
                    self.bridgeStatus = KeyboardBridgeStatus(
                        commandID: command.id,
                        state: .error,
                        message: "Open Typeforme once to prepare dictation."
                    )
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
        bridgeCommandTasks[command.id] = task
    }

    private func sendDarwinBridgeCommand(_ action: KeyboardBridgeCommandAction, commandID: String) {
        let command = KeyboardBridgeCommand(
            id: commandID,
            action: action,
            correctionMode: correctionMode.rawValue
        )
        sendDarwinBridgeCommand(command)
    }

    private func sendDarwinBridgeCommand(_ command: KeyboardBridgeCommand) {
        let action = command.action
        let commandID = command.id
        if action == .start || action == .stop {
            if action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if action == .stop {
                tapRecordingActive = false
                isCommandPressActive = false
                pendingStopCommandID = commandID
            }
            let status = KeyboardBridgeStatus(
                commandID: commandID,
                state: action == .start ? .standby : .sending,
                message: action == .start ? "Starting recording" : stopProcessingStatusTitle
            )
            bridgeStatus = status
            updateActiveStatusReconcileLoop(for: status)
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        switch action {
        case .start:
            logKeyboardStartDiagnostics(commandID: commandID, event: "darwin_send_begin")
            isStartRequestInFlight = true
            pendingStartCommandID = commandID
            if activeRecordingCommandID == nil {
                activeRecordingCommandID = commandID
            }
            rememberStartHandshakeCommand(commandID)
            guard KeyboardSharedDefaults.saveDarwinCommand(command) else {
                kbLog.notice("darwin start save failed command_id=\(commandID, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-ui",
                    event: "darwin_start_save_failed",
                    fields: ["command_id": commandID]
                )
                isStartRequestInFlight = false
                pendingStartCommandID = nil
                activeRecordingCommandID = nil
                forgetStartHandshakeCommand(commandID)
                cancelStartConfirmationTimeout()
                cancelDarwinStartAckTimeout()
                openHostForDictation(reason: "darwin_start_save_failed", commandID: commandID)
                return
            }
            if postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestStartDictation) {
                scheduleDarwinStartAckTimeout(commandID: commandID)
                kbLog.notice("darwin start posted command_id=\(commandID, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-ui",
                    event: "darwin_start_posted",
                    fields: ["command_id": commandID]
                )
            } else {
                kbLog.notice("darwin start post failed command_id=\(commandID, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-ui",
                    event: "darwin_start_post_failed",
                    fields: ["command_id": commandID]
                )
                isStartRequestInFlight = false
                pendingStartCommandID = nil
                activeRecordingCommandID = nil
                forgetStartHandshakeCommand(commandID)
                cancelStartConfirmationTimeout()
                cancelDarwinStartAckTimeout()
                openHostForDictation(reason: "darwin_start_post_failed", commandID: commandID)
            }
        case .stop:
            kbLog.notice("darwin stop dispatch command_id=\(commandID, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-ui",
                event: "darwin_stop_dispatch",
                fields: ["command_id": commandID]
            )
            _ = KeyboardSharedDefaults.saveDarwinCommand(command)
            if !postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestStopDictation) {
                pendingStopCommandID = nil
                bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Open Typeforme once to prepare dictation.")
                lastBridgeContactAt = 0
                updateUI()
            }
        case .cancel:
            kbLog.notice("darwin cancel dispatch command_id=\(commandID, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-ui",
                event: "darwin_cancel_dispatch",
                fields: ["command_id": commandID]
            )
            tapRecordingActive = false
            pendingCancelCommandID = commandID
            pendingStopCommandID = nil
            activeRecordingCommandID = nil
            activeRecordingTextEditIntent = nil
            activeRecordingTextTarget = nil
            activeDictationInsertionAnchor = nil
            livePartialPreviewState = nil
            cancelScheduledHostOpen()
            _ = KeyboardSharedDefaults.saveDarwinCommand(command)
            _ = postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestCancelDictation)
        case .configure, .refineText:
            break
        }
    }

    @discardableResult
    private func postAuthenticatedKeyboardRequest(_ name: String) -> Bool {
        guard let requestName = KeyboardDarwinNotificationName.authenticatedRequest(
            name,
            token: hostKeyboardBridgeToken
        ) else { return false }
        KeyboardDarwinBridge.post(requestName)
        return true
    }

    private func finishStoppedNotification() {
        cancelScheduledHostOpen()
        guard isStartRequestInFlight else { return }
        let commandID = pendingStartCommandID ?? activeRecordingCommandID
        isStartRequestInFlight = false
        pendingStartCommandID = nil
        confirmedRecordingCommandID = nil
        forgetStartHandshakeCommand(commandID)
        cancelStartConfirmationTimeout()
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        isVoicePressActive = false
        isCommandPressActive = false
        tapRecordingActive = false
        activeRecordingCommandID = nil
        activeRecordingTextEditIntent = nil
        activeRecordingTextTarget = nil
        pendingStopCommandID = nil
        pendingCancelCommandID = nil
    }

    private func recoverStoppedStartStatusOrOpenHost() {
        let bridgeToken = hostKeyboardBridgeToken
        kbLog.notice("recover stopped start status: probing bridge")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "recover_stopped_start_probe"
        )
        Task { [weak self] in
            guard let self else { return }
            let probe = await self.localClient.probeStatus(
                bridgeToken: bridgeToken,
                helloTimeout: Self.startProbeHelloTimeout,
                statusTimeout: Self.startProbeStatusTimeout
            )
            await MainActor.run {
                guard !self.isStartRequestInFlight else { return }
                switch probe {
                case .unreachable:
                    kbLog.notice("recover stopped start status: probe unreachable; opening host")
                    KeyboardDiagnosticEventLog.record(
                        source: "keyboard-ui",
                        event: "recover_stopped_start_probe_unreachable_open_host"
                    )
                    self.openHostForDictation(reason: "stopped_start_probe_unreachable")
                case .reachable(let status):
                    kbLog.notice("recover stopped start status: probe reachable state=\(status?.state.rawValue ?? "none", privacy: .public) command_id=\(status?.commandID ?? "none", privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "keyboard-ui",
                        event: "recover_stopped_start_probe_reachable",
                        fields: [
                            "state": status?.state.rawValue ?? "none",
                            "command_id": status?.commandID ?? "none",
                        ]
                    )
                    if let status {
                        self.applyBridgeStatus(status)
                    } else if self.currentBridgeStatus?.state != .recording,
                              self.currentBridgeStatus?.state != .sending,
                              self.currentBridgeStatus?.state != .result {
                        self.bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Ready")
                        self.lastBridgeContactAt = Date().timeIntervalSince1970
                    }
                    self.updateUI()
                }
            }
        }
    }

    private func scheduleHostOpenIfStartStalls(commandID: String) {
        cancelScheduledHostOpen()
        kbLog.notice("start stall watcher scheduled command_id=\(commandID, privacy: .public) timeout_ms=\(Int(Self.startConfirmationTimeout * 1_000), privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "start_stall_watcher_scheduled",
            fields: [
                "command_id": commandID,
                "timeout_ms": "\(Int(Self.startConfirmationTimeout * 1_000))",
            ]
        )
        scheduledHostOpenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startConfirmationTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let shouldRecover = await MainActor.run {
                guard self.isStartRequestInFlight,
                      self.pendingStartCommandID == commandID,
                      !self.isCurrentRecordingConfirmed,
                      !self.isOpeningHostApp
                else { return false }
                return true
            }
            guard shouldRecover, !Task.isCancelled else { return }

            let bridgeToken = await MainActor.run { self.hostKeyboardBridgeToken }
            await MainActor.run {
                self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_stall_probe_begin")
            }
            let probe = await self.localClient.probeStatus(
                bridgeToken: bridgeToken,
                helloTimeout: Self.startProbeHelloTimeout,
                statusTimeout: Self.startProbeStatusTimeout
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.isStartRequestInFlight,
                      self.pendingStartCommandID == commandID,
                      !self.isCurrentRecordingConfirmed,
                      !self.isOpeningHostApp
                else { return }
                switch probe {
                case .unreachable:
                    self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_stall_probe_unreachable_open_host")
                    self.isStartRequestInFlight = false
                    self.pendingStartCommandID = nil
                    self.activeRecordingCommandID = nil
                    self.activeRecordingTextEditIntent = nil
                    self.activeRecordingTextTarget = nil
                    self.openHostForDictation(reason: "start_stall_probe_unreachable", commandID: commandID)
                case .reachable(let recoveredStatus):
                    guard let recoveredStatus else {
                        self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_stall_probe_reachable_no_status")
                        self.handleReachableStartWithoutStatus(commandID: commandID)
                        return
                    }
                    self.logKeyboardStartDiagnostics(commandID: commandID, event: "start_stall_probe_status_\(recoveredStatus.state.rawValue)")
                    self.handleStartCommandResponse(recoveredStatus, commandID: commandID)
                }
            }
        }
    }

    private func cancelScheduledHostOpen() {
        scheduledHostOpenTask?.cancel()
        scheduledHostOpenTask = nil
    }

    private func cancelBridgeCommandTasks() {
        bridgeCommandTasks.values.forEach { $0.cancel() }
        bridgeCommandTasks.removeAll()
        cancelDarwinStartAckTimeout()
    }

    private func stopBridgeStatusStream() {
        statusStreamGeneration &+= 1
        statusStreamBridgeToken = nil
        lastStatusStreamFrameAt = 0
        let client = localClient
        statusStreamStopTask = Task {
            await client.shutdown()
        }
    }

    private func updateActiveStatusReconcileLoopForCurrentStatus() {
        guard let status = currentBridgeStatus else {
            cancelActiveStatusReconcileLoop()
            return
        }
        updateActiveStatusReconcileLoop(for: status)
    }

    private func updateActiveStatusReconcileLoop(for status: KeyboardBridgeStatus) {
        guard status.state == .recording || status.state == .sending else {
            cancelActiveStatusReconcileLoop()
            return
        }
        guard activeStatusReconcileTask == nil else { return }
        activeStatusReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.activeBridgeStatusReconcileInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.reconcileActiveBridgeStatusIfNeeded()
            }
        }
    }

    private func cancelActiveStatusReconcileLoop() {
        activeStatusReconcileTask?.cancel()
        activeStatusReconcileTask = nil
    }

    @MainActor
    private func reconcileActiveBridgeStatusIfNeeded() async {
        guard shouldRecoverActiveBridgeStatus else {
            cancelActiveStatusReconcileLoop()
            return
        }
        let now = Date().timeIntervalSince1970
        let statusStreamAge = lastStatusStreamFrameAt > 0 ? now - lastStatusStreamFrameAt : .infinity
        let statusStreamIsStale = statusStreamAge > Self.activeStatusStreamStaleAge
        if statusStreamIsStale {
            logActiveStatusReconcileIfNeeded(statusStreamAge: statusStreamAge)
            refreshBridgeStatus(captureSelection: false, force: true)
        }

        guard currentBridgeStatus?.state == .sending || statusStreamIsStale else { return }
        let expectedCommandID = activeBridgeResultCommandID
        _ = await recoverBridgeStatusSnapshot(expectedCommandID: expectedCommandID)
        if shouldRecoverActiveBridgeStatus, statusStreamIsStale {
            refreshBridgeStatus(captureSelection: false, force: true)
        }
    }

    private func logActiveStatusReconcileIfNeeded(statusStreamAge: TimeInterval) {
        let now = Date().timeIntervalSince1970
        guard now - lastActiveStatusReconcileLogAt >= 5 else { return }
        lastActiveStatusReconcileLogAt = now
        let ageMs = statusStreamAge.isFinite ? Int(statusStreamAge * 1_000) : -1
        kbLog.notice("reconciling active keyboard status stream_age_ms=\(ageMs, privacy: .public)")
    }

    private func scheduleSessionStatusChallengeTimeout(sentAt: TimeInterval) {
        sessionStatusChallengeGeneration &+= 1
        let generation = sessionStatusChallengeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self,
                  self.view.window != nil,
                  self.sessionStatusChallengeGeneration == generation,
                  self.lastDarwinAwakeAt < sentAt,
                  !self.hasActiveKeyboardRecordingOrStopIntent,
                  self.currentBridgeStatus?.state != .recording,
                  self.currentBridgeStatus?.state != .sending
            else { return }
            self.lastDarwinAwakeAt = 0
            guard Date().timeIntervalSince1970 - self.lastBridgeContactAt >= 3 else {
                self.updateUI()
                return
            }
            if let status = self.currentBridgeStatus,
               status.state == .standby,
               Date().timeIntervalSince1970 - status.updatedAt <= Self.sharedStandbyLivenessSnapshotMaxAge {
                self.updateUI()
                return
            }
            if self.currentBridgeStatus?.state == .standby {
                self.bridgeStatus = KeyboardBridgeStatus(
                    state: .idle,
                    message: self.inputMode.idleTitle,
                    backendReachable: self.currentBridgeStatus?.backendReachable
                )
            }
            self.updateUI()
        }
    }

    private func scheduleDeferredStartupProbe() {
        deferredStartupWorkItem?.cancel()
        hasPresentedInitialFrame = false
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.view.window != nil else { return }
            _ = self.applySharedBridgeStatusSnapshot()
            if self.currentBridgeStatus?.state == .recording
                || self.currentBridgeStatus?.state == .sending
                || self.pendingStopCommandID != nil {
                self.refreshBridgeStatus(captureSelection: false, force: true)
                self.requestSessionStatusChallenge()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self, self.view.window != nil else { return }
                self.hasPresentedInitialFrame = true
            }
        }
        deferredStartupWorkItem = workItem

        // Let iOS draw the first keyboard frame before touching localhost,
        // Darwin notifications, or textDocumentProxy selection APIs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func requestSessionStatusChallenge() {
        let sentAt = Date().timeIntervalSince1970
        if postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestSessionStatus) {
            scheduleSessionStatusChallengeTimeout(sentAt: sentAt)
        }
    }

    private func refreshBridgeStatus(captureSelection: Bool = true, force: Bool = false) {
        guard hasFullAccess else {
            stopBridgeStatusStream()
            return
        }
        if captureSelection {
            refreshSelectionSnapshot()
        }
        let bridgeToken = hostKeyboardBridgeToken
        guard force || statusStreamBridgeToken != bridgeToken else { return }
        statusStreamGeneration &+= 1
        let generation = statusStreamGeneration
        statusStreamBridgeToken = bridgeToken
        let client = localClient
        let pendingStop = statusStreamStopTask
        Task { [weak self] in
            await pendingStop?.value
            await client.startStatusStream(
                bridgeToken: bridgeToken,
                onStatus: { [weak self] status in
                    await MainActor.run {
                        guard let self,
                              self.statusStreamGeneration == generation
                        else { return }
                        self.lastStatusStreamFrameAt = Date().timeIntervalSince1970
                        let shouldFinishStart = self.isStartRequestInFlight
                            && self.isLiveStartConfirmation(status)
                        self.applyBridgeStatus(status)
                        if shouldFinishStart {
                            self.finishStartRequestIfNeeded(status: status)
                        }
	                    }
	                },
	                onFailure: { [weak self] error in
	                    await MainActor.run {
	                        guard let self,
	                              self.statusStreamGeneration == generation
	                        else { return }
	                        self.statusStreamBridgeToken = nil
	                        self.lastStatusStreamFrameAt = 0
	                        let hadRecentBridgeContact = self.lastBridgeContactAt > 0
	                        self.lastBridgeContactAt = 0
	                        self.logStatusStreamFailureIfNeeded(error)
	                        self.recoverBridgeStatusAfterStreamFailure(generation: generation)
	                        if hadRecentBridgeContact {
	                            self.updateUI()
	                        }
	                    }
	                },
	                force: force
	            )
        }
	    }

    private func needsStatusStreamRefreshAfterDarwinStart(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard hasFullAccess else { return false }
        guard statusStreamBridgeToken == hostKeyboardBridgeToken else { return true }
        guard lastStatusStreamFrameAt > 0 else { return true }
        return now - lastStatusStreamFrameAt > Self.statusStreamFreshnessAfterDarwinStart
    }

    private func refreshBridgeStatusAfterDarwinStartIfNeeded(_ shouldRefresh: Bool) {
        guard shouldRefresh else { return }
        refreshBridgeStatus(captureSelection: false, force: true)
    }

    @MainActor
    private func recoverBridgeStatusAfterStreamFailure(generation: UInt64) {
        guard shouldRecoverActiveBridgeStatus else { return }
        let expectedCommandID = activeBridgeResultCommandID
        Task { [weak self] in
            guard let self else { return }
            _ = await self.recoverBridgeStatusSnapshot(
                expectedCommandID: expectedCommandID,
                statusStreamGeneration: generation
            )
            await MainActor.run {
                guard self.statusStreamGeneration == generation,
                      self.shouldRecoverActiveBridgeStatus
                else { return }
                self.refreshBridgeStatus(captureSelection: false, force: true)
            }
        }
    }

    @MainActor
    private func recoverBridgeStatusSnapshotForActiveCommand() {
        let expectedCommandID = activeBridgeResultCommandID
        Task { [weak self] in
            _ = await self?.recoverBridgeStatusSnapshot(expectedCommandID: expectedCommandID)
        }
    }

    @MainActor
    private func recoverBridgeStatusSnapshot(
        expectedCommandID: String?,
        statusStreamGeneration expectedGeneration: UInt64? = nil
    ) async -> Bool {
        guard hasFullAccess else { return false }
        let bridgeToken = hostKeyboardBridgeToken
        do {
            let status = try await localClient.statusSnapshot(bridgeToken: bridgeToken, timeout: 1.2)
            if let expectedGeneration,
               statusStreamGeneration != expectedGeneration {
                return false
            }
            if let expectedCommandID,
               status.commandID != expectedCommandID {
                return false
            }
            applyBridgeStatus(status, recordsLiveContact: true)
            return true
        } catch {
            logStatusStreamFailureIfNeeded(error)
            return false
        }
    }

    private var shouldRecoverActiveBridgeStatus: Bool {
        guard hasFullAccess else { return false }
        guard let status = currentBridgeStatus else {
            return pendingStopCommandID != nil || activeRecordingCommandID != nil || activeRecordingTextTarget != nil
        }
        return status.state == .recording || status.state == .sending
            || pendingStopCommandID != nil
            || activeRecordingCommandID != nil
            || activeRecordingTextTarget != nil
    }

    private var activeBridgeResultCommandID: String? {
        pendingStopCommandID
            ?? activeRecordingCommandID
            ?? activeRecordingTextTarget?.commandID
            ?? currentBridgeStatus?.commandID
            ?? styleRewriteCommandID
    }

    private func logStatusStreamFailureIfNeeded(_ error: Error) {
        let now = Date().timeIntervalSince1970
        guard now - lastStatusStreamFailureLogAt >= 2 else { return }
        lastStatusStreamFailureLogAt = now
        kbLog.notice("status stream failed: \(error.localizedDescription, privacy: .public)")
    }

    private func beginInsertedFlash() {
        insertedFlashClearTask?.cancel()
        textToolbarStatusClearTask?.cancel()
        textToolbarStatusClearTask = nil
        textToolbarStatusText = nil
        insertedFlashUntil = Date().timeIntervalSince1970 + Self.insertedFlashDuration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.insertedFlashUntil = 0
            self.updateUI(animated: false)
        }
        insertedFlashClearTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.insertedFlashDuration, execute: work)
    }

    private func applyBridgeStatus(_ status: KeyboardBridgeStatus, recordsLiveContact: Bool = true) {
        if shouldIgnoreStatusDuringStartHandshake(status) {
            return
        }
        if shouldIgnoreStaleIdleStatus(status) {
            return
        }
        if shouldIgnoreSuppressedRefineStatus(status) {
            return
        }
        if shouldIgnoreStaleResultStatus(status) {
            return
        }
        if shouldIgnoreRecordingStatusAfterStop(status) {
            return
        }
        if shouldIgnoreRecordingStatusAfterCancel(status) {
            return
        }
        if shouldIgnoreAlreadyInsertedActiveStatus(status) {
            return
        }
        let isMatchedStartTerminal = isStartRequestInFlight
            && (status.state == .result
                || status.state == .error
                || status.state == .idle
                || status.state == .standby)
            && status.commandID.map {
                KeyboardStartHandshakePolicy.isTrackedStartCommandID(
                    $0,
                    in: startHandshakePolicySnapshot()
                )
            } == true
        if isStartRequestInFlight,
           status.state == .standby,
           activeRecordingCommandID != nil,
           !isMatchedStartTerminal {
            return
        }
        if isMatchedStartTerminal {
            finishStartRequestIfNeeded(status: status)
        }
        if isLiveStartConfirmation(status) {
            confirmedRecordingCommandID = status.commandID
        } else if status.state == .recording,
                  isStartRequestInFlight || pendingStartCommandID != nil {
            return
        }
        let isConfirmedRecording = isConfirmedRecordingStatus(status)
        if status.state == .recording, !isConfirmedRecording {
            return
        }
        if status.state == .recording, currentBridgeStatus?.state != .recording {
            keyboardRecordingStartedAt = Date().timeIntervalSince1970
            livePartialPreviewState = nil
        } else if status.state != .recording {
            keyboardRecordingStartedAt = 0
        }
        if status.state != .idle {
            cancelHostWakeResetTask()
            openingHostUntil = 0
        }
        if status.state == .recording, inputMode == .tap {
            tapRecordingActive = true
        } else if status.state != .recording && status.state != .sending {
            tapRecordingActive = false
        }
        if status.state == .recording, let commandID = status.commandID {
            activeRecordingCommandID = commandID
        } else if status.state != .recording {
            activeRecordingCommandID = nil
        }
        if status.state == .result || status.state == .error || status.state == .idle || status.state == .standby {
            pendingStopCommandID = nil
            pendingCancelCommandID = nil
            pendingStartCommandID = nil
            confirmedRecordingCommandID = nil
            cancelStartConfirmationTimeout()
            cancelDarwinStartAckTimeout()
        }
        if status.state == .result, currentBridgeStatus?.state != .result, keyboardFocus == .text {
            beginInsertedFlash()
        }
        // Live partial preview owns only the marked text it created. Rime
        // composition also uses marked text; bridge idle frames must not clear
        // the user's in-progress Pinyin preedit.
        let partial = status.livePartialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suppressesPartialPreview = suppressesLivePartialPreview(for: status)
        let preservesLivePartialAfterHostRefineFailure = shouldPreserveLivePartialPreviewAfterHostRefineFailure(for: status)
        let showsPartial = !suppressesPartialPreview
            && (status.state == .recording || status.state == .sending)
            && !partial.isEmpty
        if suppressesPartialPreview, activeMarkedTextOwner == .livePartial {
            clearLivePartialMarkedTextIfStillOwned(commandID: status.commandID, reason: "status_suppressed")
        } else if showsPartial {
            if let commandID = effectiveLivePartialCommandID(status.commandID),
               canPresentLivePartialPreview(commandID: commandID, text: partial) {
                recordLivePartialPreview(commandID: commandID, text: partial, anchor: currentLivePartialPreviewAnchor())
                replaceMarkedText(partial, owner: .livePartial)
            }
        } else if status.state != .result, activeMarkedTextOwner == .livePartial {
            // .result is handled below — don't clear here or the commit step
            // would have no marked text to replace.
            if status.state != .sending {
                if preservesLivePartialAfterHostRefineFailure {
                    _ = commitLivePartialBeforeHostReturnIfNeeded(commandID: status.commandID)
                } else {
                    clearLivePartialMarkedTextIfStillOwned(commandID: status.commandID, reason: "status_terminal")
                }
            }
        }
        isApplyingHostBridgeStatus = true
        bridgeStatus = status
        isApplyingHostBridgeStatus = false
        updateActiveStatusReconcileLoop(for: status)
        if recordsLiveContact {
            lastBridgeContactAt = Date().timeIntervalSince1970
        }
        if styleRewriteCommandID == nil {
            applyDefaultCorrectionModeFromHost(status.defaultCorrectionMode)
        }
        if status.state == .result,
           status.commandID != styleRewriteCommandID,
           let commandID = status.commandID,
           defaults.string(forKey: lastInsertedCommandIDKey) != commandID,
           let text = status.resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let didApply: Bool
            let appliedRewriteTarget: TextRewriteTarget?
            if let pendingTarget = activeRecordingTextTarget,
               pendingTarget.commandID == commandID {
                didApply = applyRewrittenText(text, replacing: pendingTarget.target)
                appliedRewriteTarget = pendingTarget.target
                activeRecordingTextTarget = nil
                activeRecordingTextEditIntent = nil
            } else if activeRecordingTextTarget != nil {
                didApply = false
                appliedRewriteTarget = nil
            } else if let preview = livePartialPreviewState,
                      preview.commandID == commandID {
                didApply = applyFinalResultForLivePartialPreview(preview, finalText: text)
                appliedRewriteTarget = nil
            } else if activeMarkedTextOwner != nil || !activeMarkedText.isEmpty {
                // No command-scoped preview owns this marked text. In
                // particular, never replace an active Rime composition with a
                // delayed bridge result.
                didApply = false
                appliedRewriteTarget = nil
            } else if let anchor = activeDictationInsertionAnchor,
                      anchor.commandID == commandID,
                      matchesCurrentInsertionAnchor(anchor) {
                commitTextReplacingMarkedText(text, reason: .bridgeResult)
                clearLocalMarkedTextState()
                didApply = true
                appliedRewriteTarget = nil
            } else {
                didApply = false
                appliedRewriteTarget = nil
            }
            if didApply {
                if let appliedRewriteTarget {
                    recordRefineUndoState(originalTarget: appliedRewriteTarget, rewrittenText: text)
                } else {
                    clearRefineUndoState(updateButtons: false)
                }
                defaults.set(commandID, forKey: lastInsertedCommandIDKey)
                recentSelectionTarget = nil
            } else {
                defaults.set(commandID, forKey: lastInsertedCommandIDKey)
                copyFallbackText(text)
                bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Input changed; result copied.")
            }
            if activeRecordingTextTarget?.commandID == commandID {
                activeRecordingTextTarget = nil
            }
            if activeDictationInsertionAnchor?.commandID == commandID {
                activeDictationInsertionAnchor = nil
            }
            activeRecordingTextEditIntent = nil
        }

        if status.state == .error || status.state == .idle {
            activeRecordingTextTarget = nil
            activeRecordingTextEditIntent = nil
            if !preservesLivePartialAfterHostRefineFailure {
                livePartialPreviewState = nil
            }
            recentSelectionTarget = nil
        }

        if status.state == .recording {
            // The signature check below skips updateUI() when only audioLevel
            // changed (host's `withAudioLevel` preserves updatedAt), so the
            // visible meters in hold mode would stay stale if we only pushed
            // the level inside updateUI(). Drive them here for every sample.
            voicePrint.updateLevel(status.audioLevel)
            topRowVoicePrint.updateLevel(status.audioLevel)
            textToolbarVoicePrint.updateLevel(status.audioLevel)
            updatePulseAudioLevel(status.audioLevel)
            if status.audioLevel == nil {
                let now = Date().timeIntervalSince1970
                if now - lastMissingAudioLevelLogAt > 2 {
                    lastMissingAudioLevelLogAt = now
                    kbLog.debug("recording status has no audioLevel; using local voiceprint animation")
                }
            } else {
                lastMissingAudioLevelLogAt = 0
            }
        }

        // livePartialTranscript is intentionally absent: partial-only changes
        // are already rendered above via marked text and the voiceprint level,
        // so they must not trigger a full updateUI pass (which reconfigures
        // every key button) several times a second while the user speaks.
        let signature = [
            status.commandID ?? "",
            status.state.rawValue,
            String(Int(status.updatedAt)),
            status.message,
            status.defaultCorrectionMode ?? "",
            status.audioDurationSeconds.map { String(format: "%.2f", $0) } ?? "",
            status.rawTranscriptLength.map(String.init) ?? "",
        ].joined(separator: ":")
        guard signature != lastStatusSignature else { return }
        lastStatusSignature = signature
        updateUI(animated: hasPresentedInitialFrame)
    }

    private func suppressesLivePartialPreview(for status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording || status.state == .sending else { return false }
        guard let activeRecordingTextTarget else { return false }
        guard let commandID = status.commandID else { return true }
        return commandID == activeRecordingTextTarget.commandID
    }

    private func isLiveStartConfirmation(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording else { return false }
        guard let commandID = status.commandID else { return false }
        return commandID == activeRecordingCommandID
            || commandID == pendingStartCommandID
            || commandID == activeRecordingTextTarget?.commandID
            || KeyboardStartHandshakePolicy.isTrackedStartCommandID(
                commandID,
                in: startHandshakePolicySnapshot()
            )
    }

    private func shouldIgnoreStatusDuringStartHandshake(_ status: KeyboardBridgeStatus) -> Bool {
        let policyState: KeyboardStartHandshakePolicy.StatusState
        switch status.state {
        case .idle:
            policyState = .idle
        case .standby:
            policyState = .standby
        case .recording:
            policyState = .recording
        case .sending:
            policyState = .sending
        case .result:
            policyState = .result
        case .error:
            policyState = .error
        }
        guard KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
            state: policyState,
            commandID: status.commandID,
            snapshot: startHandshakePolicySnapshot()
        ) else {
            return false
        }
        let commandID = status.commandID ?? "none"
        let expectedCommandID = pendingStartCommandID
            ?? activeRecordingCommandID
            ?? pendingDarwinStartAckCommandID
            ?? "none"
        kbLog.notice("ignoring start handshake status state=\(status.state.rawValue, privacy: .public) command_id=\(commandID, privacy: .public) expected=\(expectedCommandID, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-ui",
            event: "start_handshake_status_ignored",
            fields: [
                "state": status.state.rawValue,
                "command_id": commandID,
                "expected_command_id": expectedCommandID,
            ]
        )
        return true
    }

    private func shouldPreserveLivePartialPreviewAfterHostRefineFailure(for status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .error,
              status.processingStage == .refining,
              let commandID = status.commandID
        else { return false }
        if activeMarkedTextOwner == .livePartial,
           !activeMarkedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let preview = livePartialPreviewState,
              preview.commandID == commandID
        else { return false }
        return !preview.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldIgnoreRecordingStatusAfterStop(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording,
              let pendingStopCommandID
        else { return false }
        guard status.commandID == nil || status.commandID == pendingStopCommandID else {
            return false
        }
        return true
    }

    private func shouldIgnoreRecordingStatusAfterCancel(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording,
              let pendingCancelCommandID
        else { return false }
        guard status.commandID == nil || status.commandID == pendingCancelCommandID else {
            return false
        }
        return true
    }

    private func shouldIgnoreAlreadyInsertedActiveStatus(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording || status.state == .sending,
              let commandID = status.commandID,
              defaults.string(forKey: lastInsertedCommandIDKey) == commandID,
              !hasActiveBridgeCommandID(commandID)
        else { return false }
        kbLog.notice(
            "ignoring already inserted active status id=\(commandID, privacy: .public) state=\(status.state.rawValue, privacy: .public)"
        )
        return true
    }

    private func hasActiveBridgeCommandID(_ commandID: String) -> Bool {
        pendingStopCommandID == commandID
            || activeRecordingCommandID == commandID
            || activeRecordingTextTarget?.commandID == commandID
            || styleRewriteCommandID == commandID
    }

    private func shouldIgnoreStaleIdleStatus(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .standby || status.state == .idle else { return false }

        if let pendingStopCommandID {
            return status.commandID != pendingStopCommandID
        }

        guard currentBridgeStatus?.state == .recording else { return false }
        return status.commandID == nil
            || status.commandID == activeRecordingCommandID
            || status.commandID == activeRecordingTextTarget?.commandID
    }

    private func shouldIgnoreStaleResultStatus(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .result,
              let commandID = status.commandID
        else { return false }
        guard commandID != styleRewriteCommandID else { return false }

        let expectedIDs = expectedRecordingResultCommandIDs()
        guard !expectedIDs.isEmpty else {
            kbLog.notice("ignoring result without active command id=\(commandID, privacy: .public)")
            return true
        }
        guard !expectedIDs.contains(commandID) else { return false }

        kbLog.notice(
            "ignoring stale result id=\(commandID, privacy: .public) expected=\(expectedIDs.joined(separator: ","), privacy: .public)"
        )
        return true
    }

    private func expectedRecordingResultCommandIDs() -> Set<String> {
        var ids = Set<String>()
        if let pendingStopCommandID {
            ids.insert(pendingStopCommandID)
        }
        if let activeRecordingCommandID {
            ids.insert(activeRecordingCommandID)
        }
        if let commandID = activeRecordingTextTarget?.commandID {
            ids.insert(commandID)
        }
        if currentBridgeStatus?.state == .sending,
           let commandID = currentBridgeStatus?.commandID {
            ids.insert(commandID)
        }
        if let commandID = livePartialPreviewState?.commandID {
            ids.insert(commandID)
        }
        return ids
    }
}

// MARK: - Voice Controls

private final class VoiceOrbButton: UIButton {
    private let hitOutset: CGFloat = 10

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }
}

/// Vertical-bars voiceprint driven by Core Animation. The keyboard extension
/// can have an unreliable app run loop while hosted inside another app, so the
/// recording affordance must not depend on per-frame `CADisplayLink` updates.
/// Host audio levels only adjust animation intensity and speed.
private final class VoicePrintView: UIView {
    var level: Float = 0 {
        didSet {
            targetLevel = max(0, min(1, level))
            applyLiveLevel()
        }
    }

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    var tint: UIColor = .white {
        didSet { barLayers.forEach { $0.backgroundColor = tint.cgColor } }
    }

    func updateLevel(_ level: Float?) {
        guard let level else { return }
        self.level = level
    }

    private let barCount = 9
    private var barLayers: [CALayer] = []
    private var targetLevel: Float = 0
    private var isAnimatingBars = false
    private var animationLevelBucket = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        setupBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    isolated deinit {
        stopBarAnimations()
    }

    private func setupBars() {
        for _ in 0..<barCount {
            let layer = CALayer()
            layer.backgroundColor = tint.cgColor
            layer.opacity = 1
            layer.cornerRadius = 2.5
            layer.cornerCurve = .continuous
            self.layer.addSublayer(layer)
            barLayers.append(layer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func layoutBars() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let barW: CGFloat = 5
        let totalBars = CGFloat(barCount)
        let gap = (w - totalBars * barW) / (totalBars + 1)
        let centerY = h / 2
        let baseHeight = max(6, h * 0.12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in barLayers.enumerated() {
            let x = gap + CGFloat(i) * (barW + gap)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.bounds = CGRect(x: 0, y: 0, width: barW, height: baseHeight)
            layer.position = CGPoint(x: x + barW / 2, y: centerY)
        }
        CATransaction.commit()
        if isActive {
            restartBarAnimations()
        }
    }

    private func start() {
        animationLevelBucket = -1
        setNeedsLayout()
        layoutIfNeeded()
        startBarAnimations()
    }

    private func stop() {
        stopBarAnimations()
        targetLevel = 0
        animationLevelBucket = -1
        layoutBars()
    }

    private func startBarAnimations() {
        guard !isAnimatingBars else { return }
        isAnimatingBars = true
        installBarAnimations(level: targetLevel)
    }

    private func restartBarAnimations() {
        guard isAnimatingBars else { return }
        installBarAnimations(level: targetLevel)
    }

    private func installBarAnimations(level: Float) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let bucket = Int((max(0, min(1, level)) * 6).rounded())
        guard bucket != animationLevelBucket || barLayers.contains(where: { $0.animation(forKey: "voiceprint.breathe") == nil }) else {
            return
        }
        animationLevelBucket = bucket
        let normalizedLevel = CGFloat(bucket) / 6.0
        let now = CACurrentMediaTime()
        for (i, layer) in barLayers.enumerated() {
            layer.removeAnimation(forKey: "voiceprint.breathe")
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            let duration: CFTimeInterval = 1.08
            let sampleCount = 18
            animation.values = (0..<sampleCount).map { sample in
                let t = Double(sample) / Double(sampleCount - 1)
                return NSNumber(value: Double(Self.barHeight(
                    index: i,
                    barCount: barCount,
                    containerHeight: bounds.height,
                    level: normalizedLevel,
                    phase: t * duration
                )))
            }
            animation.keyTimes = (0..<sampleCount).map { sample in
                NSNumber(value: Double(sample) / Double(sampleCount - 1))
            }
            animation.duration = duration
            animation.beginTime = now
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.calculationMode = .linear
            layer.add(animation, forKey: "voiceprint.breathe")
        }
    }

    private func stopBarAnimations() {
        guard isAnimatingBars else { return }
        isAnimatingBars = false
        for layer in barLayers {
            layer.removeAnimation(forKey: "voiceprint.breathe")
            layer.transform = CATransform3DIdentity
            layer.speed = 1
        }
    }

    private func applyLiveLevel() {
        guard isActive else { return }
        installBarAnimations(level: targetLevel)
    }

    private static func barHeight(
        index: Int,
        barCount: Int,
        containerHeight: CGFloat,
        level: CGFloat,
        phase: CFTimeInterval
    ) -> CGFloat {
        let minH = max(6, containerHeight * 0.12)
        let maxH = containerHeight * 0.95
        let centerBias = abs(Double(index) - Double(barCount - 1) / 2.0) / (Double(barCount - 1) / 2.0)
        let centerBoost = 1.0 - centerBias * 0.30
        let bandPhase = Double(index) * 0.55
        let s = sin(phase * 5.4 + bandPhase) * 0.55 + sin(phase * 11.1 + bandPhase * 2.3) * 0.45
        let waveform = CGFloat((s + 1) / 2)
        let envelope = min(1.0, 0.22 + level * 1.05)
        let modulation = envelope * CGFloat(centerBoost) * (0.35 + 0.65 * waveform)
        return max(minH, min(maxH, minH + (maxH - minH) * modulation))
    }
}

private final class VoiceInputModeSwitch: UIControl {
    var onSelection: ((String) -> Void)?

    var mode: String = "hold" {
        didSet {
            guard mode != oldValue else { return }
            updateAppearance(animated: true)
        }
    }

    private let trackView = UIView()
    private let thumbView = UIView()
    private let holdButton = UIButton(type: .system)
    private let tapButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isHighlighted: Bool {
        didSet {
            updateHighlight()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 68, height: 82)
    }

    private func configure() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        trackView.isUserInteractionEnabled = false
        trackView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        trackView.layer.borderWidth = 0.5
        trackView.layer.borderColor = UIColor.separator.cgColor
        trackView.layer.shadowColor = UIColor.black.cgColor
        trackView.layer.shadowOpacity = 0.10
        trackView.layer.shadowRadius = 8
        trackView.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(trackView)

        thumbView.isUserInteractionEnabled = false
        thumbView.backgroundColor = .label
        addSubview(thumbView)

        configureButton(holdButton, title: "Hold", action: #selector(selectHold))
        configureButton(tapButton, title: "Tap", action: #selector(selectTap))
        addSubview(holdButton)
        addSubview(tapButton)
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.accessibilityLabel = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.frame = bounds
        trackView.layer.cornerRadius = bounds.width / 2
        trackView.layer.cornerCurve = .continuous

        let inset: CGFloat = 4
        let segmentHeight = (bounds.height - inset * 2) / 2
        let thumbY = mode == "tap" ? inset + segmentHeight : inset
        thumbView.frame = CGRect(
            x: inset,
            y: thumbY,
            width: bounds.width - inset * 2,
            height: segmentHeight
        )
        thumbView.layer.cornerRadius = min(thumbView.bounds.width, thumbView.bounds.height) / 2
        thumbView.layer.cornerCurve = .continuous

        holdButton.frame = CGRect(x: 6, y: inset, width: bounds.width - 12, height: segmentHeight)
        tapButton.frame = CGRect(x: 6, y: inset + segmentHeight, width: bounds.width - 12, height: segmentHeight)
        applyColors()
    }

    private func updateAppearance(animated: Bool) {
        let apply = {
            self.applyColors()
            self.accessibilityValue = self.mode == "tap" ? "Tap" : "Hold"
            self.setNeedsLayout()
        }
        if animated, window != nil {
            apply()
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layoutIfNeeded()
            }
        } else {
            apply()
        }
    }

    private func applyColors() {
        holdButton.configuration?.baseForegroundColor = mode == "hold" ? .systemBackground : .secondaryLabel
        tapButton.configuration?.baseForegroundColor = mode == "tap" ? .systemBackground : .secondaryLabel
        holdButton.isUserInteractionEnabled = isEnabled
        tapButton.isUserInteractionEnabled = isEnabled
    }

    func refreshAppearance(style: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = style
        trackView.overrideUserInterfaceStyle = style
        thumbView.overrideUserInterfaceStyle = style
        holdButton.overrideUserInterfaceStyle = style
        tapButton.overrideUserInterfaceStyle = style
        trackView.backgroundColor = UIColor.secondarySystemBackground
            .withAlphaComponent(style == .dark ? 0.30 : 0.72)
        thumbView.backgroundColor = .label
        trackView.layer.borderColor = UIColor.separator
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .cgColor
        holdButton.setNeedsUpdateConfiguration()
        tapButton.setNeedsUpdateConfiguration()
        applyColors()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        holdButton.isEnabled = enabled
        tapButton.isEnabled = enabled
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = enabled ? 1 : 0.45
        }
        updateAppearance(animated: false)
    }

    private func updateHighlight() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        }
    }

    @objc private func selectHold() {
        onSelection?("hold")
    }

    @objc private func selectTap() {
        onSelection?("tap")
    }
}

/// Tracks recently committed Chinese phrases and mirrors them to the App
/// Group so the host can show what rime's self-learning is being fed — the
/// librime user dictionary itself lives inside the extension sandbox and is
/// not enumerable from the host. Phrases of ≥2 CJK characters only: those
/// are the user-dictionary learning signal; single characters would flood
/// the capped list with noise.
private final class ChineseLearningRecorder {
    private struct Entry {
        var count: Int
        var lastUsedAt: TimeInterval
    }

    private static let maxEntries = 200
    private static let persistDebounce: TimeInterval = 0.6

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var pendingPersist: DispatchWorkItem?

    func recordCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.unicodeScalars.allSatisfy(Self.isCJKScalar)
        else { return }
        loadIfNeeded()
        var entry = entries[trimmed] ?? Entry(count: 0, lastUsedAt: 0)
        entry.count += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        entries[trimmed] = entry
        trimIfNeeded()
        schedulePersist()
    }

    func reset() {
        pendingPersist?.cancel()
        pendingPersist = nil
        entries = [:]
        loaded = true
        KeyboardSharedDefaults.clearChineseLearningSnapshot()
    }

    func flush() {
        guard pendingPersist != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = nil
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let snapshot = KeyboardSharedDefaults.loadChineseLearningSnapshot() else { return }
        for entry in snapshot.entries {
            entries[entry.text] = Entry(count: entry.count, lastUsedAt: entry.lastUsedAt)
        }
    }

    private func trimIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let overflow = entries.count - Self.maxEntries
        let oldestKeys = entries
            .sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            entries.removeValue(forKey: key)
        }
    }

    private func schedulePersist() {
        guard pendingPersist == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPersist = nil
            self?.persist()
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDebounce, execute: work)
    }

    private func persist() {
        let snapshotEntries = entries
            .map { KeyboardChineseLearningEntry(text: $0.key, count: $0.value.count, lastUsedAt: $0.value.lastUsedAt) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        KeyboardSharedDefaults.saveChineseLearningSnapshot(KeyboardChineseLearningSnapshot(
            updatedAt: Date().timeIntervalSince1970,
            entries: snapshotEntries
        ))
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

private final class TextKeyTouchLearner {
    enum SampleKind {
        case accepted
        case correction

        var logName: String {
            switch self {
            case .accepted:
                return "accepted"
            case .correction:
                return "correction"
            }
        }
    }

    enum CandidateSide: String {
        case left
        case right
    }

    struct Candidate {
        let character: String
        let frame: CGRect
    }

    struct Decision {
        let side: CandidateSide
        let leftSamples: Double
        let rightSamples: Double
        let margin: Double
    }

    private struct StoredState: Codable {
        var version: Int
        var keys: [String: KeyStats]
    }

    private struct KeyStats: Codable {
        var sampleCount: Double
        var meanX: Double
        var meanY: Double
        var updatedAt: TimeInterval
    }

    private static let storageVersion = 1
    private static let maxEffectiveSamples = 800.0
    private static let minimumDecisionSamples = KeyboardTouchGapPolicy.minimumDecisionSamples
    private static let decisionMargin = 0.28
    private static let correctionWeight = 3.0
    private static let acceptedWeight = 1.0
    private static let sigmaX = 0.34
    // Horizontal pairs usually share midY, but each key can learn a different
    // vertical mean; keep sigmaY active for that bias and future row-adjacent routing.
    private static let sigmaY = 0.70
    private static let maxObservationX = 0.75
    private static let maxObservationY = 0.75
    private static let maxMeanY = 0.28
    private static let persistDebounceInterval: TimeInterval = 0.5
    private static let persistSampleBatchSize = 5
    private static let sharedSnapshotDebounceInterval: TimeInterval = 30
    private static let sharedSnapshotSampleBatchSize = 50

    private let defaults: UserDefaults
    private let storageKey: String
    private var state: StoredState
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var pendingSharedSnapshotWorkItem: DispatchWorkItem?
    private var dirtySampleCount = 0
    private var dirtySharedSnapshotSampleCount = 0

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.state = Self.loadState(defaults: defaults, storageKey: storageKey)
    }

    deinit {
        flush()
    }

    func reset() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        pendingSharedSnapshotWorkItem?.cancel()
        pendingSharedSnapshotWorkItem = nil
        dirtySampleCount = 0
        dirtySharedSnapshotSampleCount = 0
        state = StoredState(version: Self.storageVersion, keys: [:])
        defaults.removeObject(forKey: storageKey)
        KeyboardSharedDefaults.clearTouchLearningSnapshot()
    }

    func flush() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        pendingSharedSnapshotWorkItem?.cancel()
        pendingSharedSnapshotWorkItem = nil
        persistIfNeeded()
        publishSharedSnapshotIfNeeded(force: true)
    }

    func areHorizontalNeighbors(_ first: CGRect, _ second: CGRect) -> Bool {
        guard first.width > 1,
              first.height > 1,
              second.width > 1,
              second.height > 1
        else { return false }
        let verticalTolerance = max(first.height, second.height) * 0.55
        guard abs(first.midY - second.midY) <= verticalTolerance else { return false }
        let maxWidth = max(first.width, second.width)
        return abs(first.midX - second.midX) <= maxWidth * 1.65
    }

    func recordTouch(
        touchPoint: CGPoint,
        intendedFrame: CGRect,
        character: String,
        kind: SampleKind
    ) {
        guard let offset = normalizedOffset(touchPoint, in: intendedFrame) else { return }
        let weight = kind == .correction ? Self.correctionWeight : Self.acceptedWeight
        let observedX = Self.clamp(offset.x, min: -Self.maxObservationX, max: Self.maxObservationX)
        let observedY = Self.clamp(offset.y, min: -Self.maxObservationY, max: Self.maxObservationY)
        var stats = state.keys[character] ?? KeyStats(
            sampleCount: 0,
            meanX: 0,
            meanY: 0,
            updatedAt: 0
        )
        let currentCount = min(stats.sampleCount, Self.maxEffectiveSamples)
        let nextCount = min(currentCount + weight, Self.maxEffectiveSamples)
        let alpha = weight / max(nextCount, weight)
        stats.meanX = Self.clamp(
            stats.meanX + (observedX - stats.meanX) * alpha,
            min: -KeyboardTouchGapPolicy.maxMeanX,
            max: KeyboardTouchGapPolicy.maxMeanX
        )
        stats.meanY = Self.clamp(
            stats.meanY + (observedY - stats.meanY) * alpha,
            min: -Self.maxMeanY,
            max: Self.maxMeanY
        )
        stats.sampleCount = nextCount
        stats.updatedAt = Date().timeIntervalSince1970
        state.keys[character] = stats
        let sampleCount = Int(stats.sampleCount.rounded())
        let dxPercent = Int((observedX * 100).rounded())
        let dyPercent = Int((observedY * 100).rounded())
        kbLog.debug("touch gaussian learn kind=\(kind.logName, privacy: .public) key=\(character, privacy: .private) samples=\(sampleCount, privacy: .public) dxPct=\(dxPercent, privacy: .public) dyPct=\(dyPercent, privacy: .public)")
        schedulePersist(immediate: kind == .correction)
        scheduleSharedSnapshotPublish(immediate: false)
    }

    func gutterWinner(
        left: Candidate,
        right: Candidate,
        touchPoint: CGPoint
    ) -> Decision? {
        guard areHorizontalNeighbors(left.frame, right.frame),
              let leftOffset = normalizedOffset(touchPoint, in: left.frame),
              let rightOffset = normalizedOffset(touchPoint, in: right.frame)
        else { return nil }

        let leftStats = state.keys[left.character]
        let rightStats = state.keys[right.character]
        let leftSamples = leftStats?.sampleCount ?? 0
        let rightSamples = rightStats?.sampleCount ?? 0
        let maxSamples = max(leftSamples, rightSamples)
        guard maxSamples >= Self.minimumDecisionSamples else { return nil }

        let leftScore = score(offset: leftOffset, stats: leftStats)
        let rightScore = score(offset: rightOffset, stats: rightStats)
        let difference = leftScore - rightScore
        guard abs(difference) >= Self.decisionMargin else { return nil }
        return Decision(
            side: difference > 0 ? .left : .right,
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            margin: abs(difference)
        )
    }

    func gapWinner(
        left: Candidate,
        right: Candidate
    ) -> Decision? {
        guard areHorizontalNeighbors(left.frame, right.frame),
              left.frame.maxX <= right.frame.minX
        else { return nil }

        let leftStats = state.keys[left.character]
        let rightStats = state.keys[right.character]
        guard let decision = KeyboardTouchGapPolicy.decide(
            left: Self.gapPolicyStats(leftStats),
            right: Self.gapPolicyStats(rightStats)
        ) else { return nil }
        return Decision(
            side: decision.side == .left ? .left : .right,
            leftSamples: decision.leftSamples,
            rightSamples: decision.rightSamples,
            margin: decision.margin
        )
    }

    private func score(offset: (x: Double, y: Double), stats: KeyStats?) -> Double {
        let meanX = effectiveMeanX(stats)
        let meanY = effectiveMeanY(stats)
        let dx = offset.x - meanX
        let dy = offset.y - meanY
        return -((dx * dx) / (2 * Self.sigmaX * Self.sigmaX)
            + (dy * dy) / (2 * Self.sigmaY * Self.sigmaY))
    }

    private func effectiveMeanX(_ stats: KeyStats?) -> Double {
        KeyboardTouchGapPolicy.effectiveMeanX(Self.gapPolicyStats(stats))
    }

    private func effectiveMeanY(_ stats: KeyStats?) -> Double {
        let confidence = min(1, (stats?.sampleCount ?? 0) / KeyboardTouchGapPolicy.fullConfidenceSamples)
        return Self.clamp((stats?.meanY ?? 0) * confidence, min: -Self.maxMeanY, max: Self.maxMeanY)
    }

    private static func gapPolicyStats(_ stats: KeyStats?) -> KeyboardTouchGapPolicy.KeyStats? {
        guard let stats else { return nil }
        return KeyboardTouchGapPolicy.KeyStats(sampleCount: stats.sampleCount, meanX: stats.meanX)
    }

    private func normalizedOffset(_ point: CGPoint, in frame: CGRect) -> (x: Double, y: Double)? {
        guard frame.width > 1, frame.height > 1 else { return nil }
        return (
            x: Double((point.x - frame.midX) / frame.width),
            y: Double((point.y - frame.midY) / frame.height)
        )
    }

    private func schedulePersist(immediate: Bool) {
        dirtySampleCount += 1
        if immediate || dirtySampleCount >= Self.persistSampleBatchSize {
            pendingPersistWorkItem?.cancel()
            pendingPersistWorkItem = nil
            persistIfNeeded()
            return
        }
        guard pendingPersistWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPersistWorkItem = nil
            self?.persistIfNeeded()
        }
        pendingPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDebounceInterval, execute: work)
    }

    private func persistIfNeeded() {
        guard dirtySampleCount > 0 else { return }
        persist()
        dirtySampleCount = 0
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func scheduleSharedSnapshotPublish(immediate: Bool) {
        dirtySharedSnapshotSampleCount += 1
        if immediate || dirtySharedSnapshotSampleCount >= Self.sharedSnapshotSampleBatchSize {
            pendingSharedSnapshotWorkItem?.cancel()
            pendingSharedSnapshotWorkItem = nil
            publishSharedSnapshotIfNeeded(force: true)
            return
        }
        guard pendingSharedSnapshotWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSharedSnapshotWorkItem = nil
            self?.publishSharedSnapshotIfNeeded(force: false)
        }
        pendingSharedSnapshotWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sharedSnapshotDebounceInterval, execute: work)
    }

    private func publishSharedSnapshotIfNeeded(force: Bool) {
        guard force || dirtySharedSnapshotSampleCount > 0 else { return }
        publishSharedSnapshot()
        dirtySharedSnapshotSampleCount = 0
    }

    /// Mirror into the App Group (best-effort; requires Full Access) so the
    /// host app's Keyboard Settings can show what has been learned. Keep this
    /// lower-frequency than the internal learner persist because App Group
    /// writes are only for inspection, not for routing live touches.
    private func publishSharedSnapshot() {
        var keys: [String: KeyboardTouchLearningKeyStats] = [:]
        for (character, stats) in state.keys {
            keys[character] = KeyboardTouchLearningKeyStats(
                sampleCount: stats.sampleCount,
                meanX: stats.meanX,
                meanY: stats.meanY,
                updatedAt: stats.updatedAt
            )
        }
        KeyboardSharedDefaults.saveTouchLearningSnapshot(KeyboardTouchLearningSnapshot(
            version: Self.storageVersion,
            updatedAt: Date().timeIntervalSince1970,
            keys: keys
        ))
    }

    private static func loadState(defaults: UserDefaults, storageKey: String) -> StoredState {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(StoredState.self, from: data),
              stored.version == storageVersion
        else {
            return StoredState(version: storageVersion, keys: [:])
        }
        return stored
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }
}

/// UIInputView subclass opting into system keyboard clicks —
/// UIDevice.playInputClick() is a no-op unless the active input view conforms
/// to UIInputViewAudioFeedback. The system additionally gates the sound on
/// the user's keyboard-click setting, matching the native keyboard.
final class ClickFeedbackInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Backing surface for blank keyboard hit regions. The owning controller paints
/// it with `keyboardTouchableBackgroundColor` (0.01 alpha) and masks it to the
/// active touch geometry. iOS custom keyboards also consider rendered pixel
/// alpha for hit-test eligibility, so `point(inside:)` alone is not enough to
/// stop gap touches from leaking to the host app.
final class KeyboardSurfaceView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.contains(point)
    }
}

/// UIButton whose direct control target can extend beyond its visible bounds.
/// Character keys do not use this; their gaps and row margins are owned by
/// KeyboardTouchOverlayView so there is only one text-key routing path.
final class HitInsetButton: UIButton {
    var hitInsets: UIEdgeInsets = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.inset(by: hitInsets).contains(point)
    }
}

/// Full-keyboard overlay that owns routed key touches without taking over the
/// system-provided UIInputView size. Empty areas can still resolve to nearby
/// keys, while real controls below the overlay receive direct touches.
final class KeyboardTouchOverlayView: UIView {
    weak var hitController: KeyboardViewController?

    private struct ActiveKeyboardTouch {
        let target: KeyboardTouchTarget
        let startPoint: CGPoint
        /// Character keys commit on touch-down; a focus swipe that grows out
        /// of this touch must undo that commit before switching surfaces.
        let didCommitTextKey: Bool
    }

    private var activeTouches: [UITouch: ActiveKeyboardTouch] = [:]
    private var pendingActivationTarget: KeyboardTouchTarget?
    private var pendingActivationPoint: CGPoint?
    private var pendingActivationResolvedAt: CFTimeInterval = 0
    private var lastTouchCommitTime: CFTimeInterval = 0
    private static let pendingActivationReuseWindow: CFTimeInterval = 0.12
    private static let pendingActivationPointTolerance: CGFloat = 1.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        isAccessibilityElement = false
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else {
            clearPendingActivation()
            return nil
        }
        guard let hitController else {
            clearPendingActivation()
            return nil
        }

        let controllerPoint = convert(point, to: hitController.view)
        let target = resolveTouchTarget(at: controllerPoint, hitController: hitController)
        hitController.logKeyboardTouchEvent("hitTest", target: target, point: controllerPoint)
        switch target {
        case .textKey, .candidateAction, .focusSurface:
            pendingActivationTarget = target
            pendingActivationPoint = controllerPoint
            pendingActivationResolvedAt = CACurrentMediaTime()
            return self
        case .none:
            clearPendingActivation()
            return nil
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let hitController else {
            super.touchesBegan(touches, with: event)
            return
        }

        var handledAnyTouch = false
        for touch in orderedTouches(touches) {
            let controllerPoint = touch.location(in: hitController.view)
            guard let target = resolveTouchTarget(at: controllerPoint, hitController: hitController) else { continue }
            releaseExistingTouchIfNeeded(for: target)
            clearPendingActivation()
            let didCommit = hitController.pressKeyboardTouchTarget(target, point: controllerPoint)
            if didCommit {
                lastTouchCommitTime = CACurrentMediaTime()
            }
            activeTouches[touch] = ActiveKeyboardTouch(
                target: target,
                startPoint: controllerPoint,
                didCommitTextKey: didCommit
            )
            handledAnyTouch = true
        }
        if !handledAnyTouch {
            super.touchesBegan(touches, with: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let hitController else {
            super.touchesMoved(touches, with: event)
            return
        }

        var handledAnyTouch = false
        for touch in orderedTouches(touches) {
            guard let active = activeTouches[touch] else { continue }
            handledAnyTouch = true
            let controllerPoint = touch.location(in: hitController.view)
            guard active.target.allowsKeyboardFocusSwipe,
                  let horizontalIntent = hitController.keyboardFocusSwipeIntent(
                    start: active.startPoint,
                    current: controllerPoint
                  )
            else { continue }

            hitController.cancelKeyboardTouchTarget(active.target, point: controllerPoint)
            if active.didCommitTextKey {
                hitController.undoTextKeyCommitForFocusSwipe()
            }
            hitController.logKeyboardTouchEvent(
                "swipe",
                target: active.target,
                point: controllerPoint,
                intent: horizontalIntent
            )
            hitController.switchKeyboardFocusFromFallbackSwipe(deltaX: horizontalIntent)
            activeTouches.removeValue(forKey: touch)
        }
        if !handledAnyTouch {
            super.touchesMoved(touches, with: event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let hitController else {
            super.touchesEnded(touches, with: event)
            return
        }

        var handledAnyTouch = false
        for touch in orderedTouches(touches) {
            guard let active = activeTouches[touch] else { continue }
            let point = touch.location(in: hitController.view)
            hitController.releaseKeyboardTouchTarget(active.target, point: point)
            activeTouches.removeValue(forKey: touch)
            handledAnyTouch = true
        }
        if !handledAnyTouch {
            super.touchesEnded(touches, with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let hitController else {
            activeTouches.removeAll()
            super.touchesCancelled(touches, with: event)
            return
        }

        var handledAnyTouch = false
        for touch in orderedTouches(touches) {
            guard let active = activeTouches[touch] else { continue }
            // System-cancelled touches keep their committed character (the
            // commit happened at touch-down, matching native behavior); only
            // the pressed visual is reset.
            hitController.cancelKeyboardTouchTarget(active.target, point: touch.location(in: hitController.view))
            activeTouches.removeValue(forKey: touch)
            handledAnyTouch = true
        }
        if !handledAnyTouch {
            super.touchesCancelled(touches, with: event)
        }
    }

    override func accessibilityActivate() -> Bool {
        activatePendingTarget()
        return pendingActivationTarget == nil
    }

    @objc private func activatePendingTarget() {
        guard activeTouches.isEmpty,
              CACurrentMediaTime() - lastTouchCommitTime > 0.18,
              let hitController,
              let target = pendingActivationTarget,
              let point = pendingActivationPoint
        else { return }

        hitController.logKeyboardTouchEvent("activate", target: target, point: point)
        if hitController.pressKeyboardTouchTarget(target, point: point) {
            lastTouchCommitTime = CACurrentMediaTime()
        }
        hitController.releaseKeyboardTouchTarget(target, point: point)
        clearPendingActivation()
    }

    private func resolveTouchTarget(
        at controllerPoint: CGPoint,
        hitController: KeyboardViewController
    ) -> KeyboardTouchTarget? {
        if let target = reusablePendingActivationTarget(at: controllerPoint) {
            return target
        }
        return hitController.keyboardOverlayTouchTarget(at: controllerPoint)
    }

    private func reusablePendingActivationTarget(at controllerPoint: CGPoint) -> KeyboardTouchTarget? {
        guard let target = pendingActivationTarget,
              let point = pendingActivationPoint,
              CACurrentMediaTime() - pendingActivationResolvedAt <= Self.pendingActivationReuseWindow,
              abs(point.x - controllerPoint.x) <= Self.pendingActivationPointTolerance,
              abs(point.y - controllerPoint.y) <= Self.pendingActivationPointTolerance
        else { return nil }
        return target
    }

    private func clearPendingActivation() {
        pendingActivationTarget = nil
        pendingActivationPoint = nil
        pendingActivationResolvedAt = 0
    }

    private func releaseExistingTouchIfNeeded(for target: KeyboardTouchTarget) {
        guard let hitController,
              case .textKey(let button) = target,
              let existing = activeTouches.first(where: { _, active in
                if case .textKey(let activeButton) = active.target {
                    return activeButton === button
                }
                return false
              })
        else { return }

        hitController.cancelKeyboardTouchTarget(existing.value.target, point: existing.key.location(in: self))
        activeTouches.removeValue(forKey: existing.key)
    }

    private func orderedTouches(_ touches: Set<UITouch>) -> [UITouch] {
        touches.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            let leftPoint = lhs.location(in: self)
            let rightPoint = rhs.location(in: self)
            if leftPoint.y != rightPoint.y {
                return leftPoint.y < rightPoint.y
            }
            if leftPoint.x != rightPoint.x {
                return leftPoint.x < rightPoint.x
            }
            return ObjectIdentifier(lhs).hashValue < ObjectIdentifier(rhs).hashValue
        }
    }
}
