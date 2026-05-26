import UIKit
import Darwin
import ObjectiveC
import OSLog
import QuartzCore

private let kbLog = Logger(subsystem: "com.example.typeforme.keyboard", category: "ui")

private typealias CorrectionModePreset = CorrectionMode

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

private extension CorrectionModePreset {
    var title: String {
        switch self {
        case .clean:         return NSLocalizedString("Clean", comment: "Correction mode")
        case .polish:        return NSLocalizedString("Polish", comment: "Correction mode")
        case .polishPlus:    return NSLocalizedString("Polish+", comment: "Correction mode")
        case .structurePlus: return NSLocalizedString("Structure+", comment: "Correction mode")
        case .formalPlus:    return NSLocalizedString("Formal+", comment: "Correction mode")
        }
    }
}

final class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate {
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
        // Drag-to-correct: small finger jitter keeps the originally pressed key
        // (first-touch sticking), but a deliberate drag past this distance that
        // ends on a different text key commits the new key instead.
        static let dragRescueThreshold: CGFloat = 14
        // Tap within this distance of a key/key midpoint triggers a librime
        // probe between the two candidate letters; outside the gutter we keep
        // the unambiguous midpoint resolution.
        static let gutterRadius: CGFloat = 6
    }

    private struct TextKeyboardLayoutModel {
        static let keyHorizontalGap: CGFloat = 6
        static let keyVerticalGap: CGFloat = 11
        static let utilityKeyWidthMultiplier: CGFloat = 1.34
        static let utilityLetterGap: CGFloat = 44.0 / 3.0
        static let bottomModeKeyWidth: CGFloat = 50
        static let bottomGlobeKeyWidth: CGFloat = 50
        static let bottomLanguageKeyWidth: CGFloat = 52
        static let bottomReturnKeyWidth: CGFloat = 108
        static let keyIconPointSize: CGFloat = 16
        static let compactUtilityTitleFontSize: CGFloat = 20
        static var utilityLetterSpacerWidth: CGFloat {
            max(0, utilityLetterGap - keyHorizontalGap * 2)
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

    private enum HostDefaultTextInputLanguage: String {
        case lastUsed = "last_used"
        case chinese
        case english

        var textInputLanguage: TextInputLanguage? {
            switch self {
            case .lastUsed:
                return nil
            case .chinese:
                return .chinese
            case .english:
                return .english
            }
        }
    }

    private enum ChinesePunctuationStyle: String {
        case chinese
        case english
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
    }

    private struct PendingRecordingTextTarget {
        let commandID: String
        let target: TextRewriteTarget
    }

    private struct RestyleUndoTarget {
        let text: String
        let contextBefore: String
        let contextAfter: String
    }

    private struct RestyleUndoState {
        let restoredText: String
        let current: RestyleUndoTarget
        let updatedAt: TimeInterval
    }

    private enum MarkedTextOwner {
        case rimeComposition
        case livePartial
    }

    private let defaults = UserDefaults.standard
    private let localClient = KeyboardLocalClient()
    private let inputModeKey = "keyboard.inputMode"
    private let keyboardFocusKey = "keyboard.focus"
    private let textInputLanguageKey = "keyboard.textInputLanguage"
    private let hostDefaultTextInputLanguageKey = "keyboard.hostDefaultTextInputLanguage"
    private let rimeLearningResetGenerationKey = "keyboard.rimeLearningResetGeneration"
    private let touchLearningResetGenerationKey = "keyboard.touchLearningResetGeneration"
    private let rimeUserPhrasesRevisionKey = "keyboard.rimeUserPhrasesRevision"
    private let lastInsertedTextKey = "keyboard.lastInsertedText"
    private let lastInsertedCommandIDKey = "keyboard.lastInsertedCommandID"
    private let textTouchLearningStatsKey = "keyboard.textTouchGaussianStats.v1"
    private let keyboardTouchTraceEnabledKey = "keyboard.touchTraceEnabled"
    private let keyPressOverlayTag = 0x74797065

    private var correctionMode: CorrectionModePreset = .polish
    private var pendingDefaultCorrectionMode: CorrectionModePreset?
    private var inputMode: VoiceInputMode = .hold
    private var keyboardFocus: KeyboardFocus = .voice
    private var textInputLanguage: TextInputLanguage = .chinese
    private var rimeProfile = RimeKeyboardProfile()
    private var rimeUserPhrasesRevision = ""
    private var isSymbolKeyboard = false
    private var isAlternateSymbolKeyboard = false
    private var isAutoCapitalizationEnabled = true
    private var isCharacterPreviewEnabled = false
    private var chinesePunctuationStyle: ChinesePunctuationStyle = .chinese
    private let rimeInput = RimeInputController()
    private lazy var textTouchLearner = TextKeyTouchLearner(
        defaults: defaults,
        storageKey: textTouchLearningStatsKey
    )
    private var pendingRimeCharacters: [String] = []
    private var activeMarkedText = ""
    private var activeMarkedTextOwner: MarkedTextOwner?
    private var heightConstraint: NSLayoutConstraint?
    private var inputModeSwitchActivationAllowedAt: CFTimeInterval = 0
    private var didSuppressInitialInputModeSwitchEvent = false
    private var isHoldingKeyboardPresentationUntilStable = true
    private var didCompleteKeyboardViewAppearForPresentation = false
    private var lastPresentationGateLogKey = ""
    private var orbContainerHeightConstraint: NSLayoutConstraint?
    private var textKeyboardContainerHeightConstraint: NSLayoutConstraint?
    private var statusTimer: Timer?
    private var statusTimerInterval: TimeInterval = 0
    private var lastStatusSignature = ""
    private var lastMissingAudioLevelLogAt: TimeInterval = 0
    private var bridgeStatus: KeyboardBridgeStatus?
    private var lastBridgeContactAt: TimeInterval = 0
    /// Wall-clock deadline for the post-insert "Inserted" flash on the text
    /// toolbar. While in window, the status label displays the inserted hint
    /// (green) in place of the normal toolbar icons, then auto-clears.
    private var insertedFlashUntil: TimeInterval = 0
    private var insertedFlashClearTask: DispatchWorkItem?
    private static let insertedFlashDuration: TimeInterval = 1.2
    /// Set whenever the host posts a Darwin signal that proves the bridge is
    /// alive (sessionStarted, dictationStarted, dictationStopped). Cleared by
    /// `sessionEnded` or by a confirmed `.start` failure. This is a durable
    /// liveness signal independent of `lastBridgeContactAt`'s 3s freshness
    /// window, so a mic press right after a finished dictation skips the
    /// 0.9s probe even if the keyboard hasn't received a fresh status frame.
    private var lastDarwinAwakeAt: TimeInterval = 0
    private var openingHostUntil: TimeInterval = 0
    private var appliedKeyboardInterfaceStyle: UIUserInterfaceStyle?
    private var lastCorrectionModeButtonSignature = ""
    private var lastTextRecordingButtonsSignature = ""
    private var hasPresentedInitialFrame = false
    private var isVoicePressActive = false
    /// Hold-mode "release-to-cancel" zone: set when the user drags the
    /// finger off the orb mid-press, cleared if they drag back in. Lift
    /// while true => cancel; lift while false => commit.
    private var voicePressBeganAt: TimeInterval = 0
    private var isStartRequestInFlight = false
    private var shouldStopWhenStartCompletes = false
    private var shouldCancelWhenStartCompletes = false
    private var tapRecordingActive = false
    private var isCommandPressActive = false
    private var activeRecordingCommandID: String?
    private var activeRecordingTextTarget: PendingRecordingTextTarget?
    private var pendingStopCommandID: String?
    private var recentSelectionTarget: TextRewriteTarget?
    private var recentSelectionCapturedAt: TimeInterval = 0
    private var restyleUndoState: RestyleUndoState?
    private var styleRewriteCommandID: String?
    private var isTextSpaceCursorTracking = false
    private var textSpaceCursorStartX: CGFloat = 0
    private var suppressTextSpaceTapUntil: TimeInterval = 0
    private var scheduledHostOpenTask: Task<Void, Never>?
    private var scheduledStopTask: Task<Void, Never>?
    private var hostWakeResetTask: Task<Void, Never>?
    private var hostBundleWakeFallbackTask: Task<Void, Never>?
    private var startupHostWakeTask: Task<Void, Never>?
    private var deleteRepeatTask: Task<Void, Never>?
    private var bridgeProbeTask: Task<Void, Never>?
    private var statusRefreshTask: Task<Void, Never>?
    private var statusRefreshGeneration: UInt64 = 0
    private var statusRefreshStartedAt: TimeInterval = 0
    private var bridgeCommandTasks: [String: Task<Void, Never>] = [:]
    private var styleRewriteTask: Task<Void, Never>?
    private var styleConfigureTask: Task<Void, Never>?
    private var pendingTextTouchSample: TextKeyTouchSample?
    private var pendingTextTouchCorrection: PendingTextTouchCorrection?
    private var deferredStartupWorkItem: DispatchWorkItem?
    private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    private let minimumHoldRecordingDuration: TimeInterval = 0.55
    /// Hold-mode releases shorter than this are treated as accidental brushes
    /// and cancel the in-flight start. iOS system mic accepts very short taps,
    /// so this should be just long enough to reject finger-brushes (~100ms)
    /// rather than reject deliberate quick taps.
    private let minimumIntentReleaseDuration: TimeInterval = 0.10
    private let selectionSnapshotTTL: TimeInterval = 1.25
    private let restyleUndoStateTTL: TimeInterval = 10 * 60
    private static let dictationContextLimit = 600
    private static let textRewriteContextExpansionLimit = 2_000
    private static let textRewriteContextExpansionMaxSteps = 40
    private static let textTouchCorrectionWindow: TimeInterval = 2.25
    private static let textTouchPositiveTTL: TimeInterval = 12
    private static let statusRefreshStaleTimeout: TimeInterval = 1.0
    private static let fastStatusPollingInterval: TimeInterval = 0.12
    private static let activeStatusPollingInterval: TimeInterval = 0.35
    private static let idleStatusPollingInterval: TimeInterval = 1.0
    private static let textSpaceCursorPointsPerCharacter: CGFloat = 9
    private static let containingAppBundleIdentifier = "com.example.typeforme"
    private let deleteRepeatInitialDelay: UInt64 = 450_000_000
    private let deleteRepeatInterval: UInt64 = 70_000_000

    private let rootStack = UIStackView()
    private let keyboardSurfaceView = KeyboardSurfaceView()
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
    private var correctionModeButtons: [(preset: CorrectionModePreset, button: UIButton)] = []
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
    /// Overlay shown on the text-keyboard toolbar during sending/error. Mirrors
    /// the voiceprint's location and surfaces the bridge `status.message`
    /// (Audio received → Transcribing → Refining → …) plus terminal errors.
    private let textToolbarStatusLabel = UILabel()
    /// Smoothed audioLevel driving pulse-ring brightness — louder voice =
    /// brighter rings, visible at the orb's edges even when a finger covers
    /// the rest of the orb.
    private var smoothedAudioLevel: Float = 0
    private let voiceSpinner = UIActivityIndicatorView(style: .large)
    private let voiceTitleLabel = UILabel()
    private let inputModeSwitch = VoiceInputModeSwitch()
    /// Driving-safe "send" button on the voice keyboard's left column,
    /// above the Restyle trigger. Tapping inserts "\n" via the host text
    /// document proxy — in chat apps (iMessage / WhatsApp / WeChat) that
    /// triggers the send action. Bigger and more obvious than the host
    /// app's own send button so it's easier to hit one-handed.
    private let voiceSendButton = HitInsetButton(frame: .zero)
    private static let orbDiameter: CGFloat = 132
    private static let portraitKeyboardContentHeight: CGFloat = 258
    private static let compactKeyboardContentHeight: CGFloat = 244
    private static let rootHorizontalInset: CGFloat = 20.0 / 3.0
    private static let rootVerticalInset: CGFloat = 4
    private static let stackSpacing: CGFloat = 4
    /// 0.01-alpha is required: iOS custom-keyboard extensions probe pixel
    /// alpha for hit-test eligibility, so `.clear` lets gap touches leak to
    /// the host app even when `point(inside:)` returns true.
    private static let keyboardTouchableBackgroundColor = UIColor.white.withAlphaComponent(0.01)
    private static let candidateExpandButtonWidth: CGFloat = 45
    private static let candidateToolbarHeight: CGFloat = 25
    private static let toolbarIconVerticalOffset: CGFloat = -2
    private static let textKeyboardTopProtectionInset: CGFloat = 2
    private static let textKeyboardToolbarKeyGap: CGFloat = 10
    private static let candidateInlineMinimumCellWidth: CGFloat = 41
    private static let candidateInlineCellHorizontalPadding: CGFloat = 20
    private static let candidateTextFontSize: CGFloat = 20
    /// The native Chinese expanded candidate panel uses compact 45pt rows and
    /// length-aware cells: short candidates fill six even columns, while long
    /// candidates reduce the row count and get wider cells.
    private static let candidateGridRowHeight: CGFloat = 45
    private static let candidateGridPreferredCellWidth: CGFloat = 66
    private static let candidateGridMinimumCellWidth: CGFloat = 59
    private static let candidateGridTwoCharacterMinimumCellWidth: CGFloat = 64
    private static let candidateActionColumnGap: CGFloat = 6
    private static let candidateExpandTouchOverflowY: CGFloat = 24
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
    private let keyPreviewBubble = UIView()
    private let keyPreviewLabel = UILabel()
    private lazy var textTrackpadPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTextTrackpadPan(_:)))
    private lazy var candidateScrollTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleCandidateScrollTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
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
    private var lastShiftTapTime: TimeInterval = 0
    private var doubleQuoteOpen = true
    private var singleQuoteOpen = true
    private weak var activeTrackpadSourceView: UIView?
    private var textTrackpadLastStepX = 0
    // Keyboard feedback needs to be crisp without feeling like a full control
    // tap. .medium/0.9 was too strong; .soft/0.4 was too easy to miss.
    private lazy var keyboardHapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private var lastKeyboardFeedbackTime: CFTimeInterval = 0
    private var keyboardFocusSwipeHandledUntil: CFTimeInterval = 0
    private var suppressTextKeyCommitUntil: CFTimeInterval = 0
    private var pendingKeyboardFocusAnimationIntent: CGFloat?
    private var isShowingTextRecordingStatus = false
    private var lastTouchSurfaceLayoutLogKey = ""
    private var lastKeyboardPresentationLayoutLogKey = ""
    private var keyboardPresentationLayoutLogCount = 0
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
        let initialHeight = currentKeyboardContentHeight + Self.topChromeCoverHeight
        inputModeSwitchActivationAllowedAt = CACurrentMediaTime() + 0.45
        didSuppressInitialInputModeSwitchEvent = false
        isHoldingKeyboardPresentationUntilStable = true
        didCompleteKeyboardViewAppearForPresentation = false
        let rootView = UIInputView(
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
        rootView.alpha = 0
        let initialHeightConstraint = rootView.heightAnchor.constraint(equalToConstant: initialHeight)
        // 999 (not .required): system inputView transition constraints win the
        // first-frame race at .required, briefly clipping the toolbar top.
        initialHeightConstraint.priority = UILayoutPriority(999)
        initialHeightConstraint.isActive = true
        heightConstraint = initialHeightConstraint
        inputView = rootView
        view = rootView
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
            return nil
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
            spaceButton,
            deleteButton,
            returnButton,
            textCandidateGridButton,
            candidateGridCollapseButton,
            textWandButton,
            textStylePickerButton,
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

    fileprivate func beginKeyboardTouchTarget(_ target: KeyboardTouchTarget, point: CGPoint) {
        logKeyboardTouchEvent("begin", target: target, point: point)
        switch target {
        case .textKey(let button):
            controlPressDown(button)
            let title = button.accessibilityValue ?? button.currentTitle ?? ""
            showKeyPreview(for: button, title: title)
        case .candidateAction, .focusSurface:
            break
        }
    }

    fileprivate func commitKeyboardTouchTarget(
        _ target: KeyboardTouchTarget,
        point: CGPoint,
        touchPoint: CGPoint? = nil
    ) {
        logKeyboardTouchEvent("commit", target: target, point: point)
        switch target {
        case .textKey(let button):
            resetPressedControlState(button)
            guard let character = textKeyCommitCharacters[ObjectIdentifier(button)] else { return }
            let sample = textKeyTouchSample(
                button: button,
                character: character,
                touchPoint: touchPoint ?? textCharacterIntentPoint(from: point)
            )
            if handleTextCharacter(character) {
                if let sample {
                    registerCommittedTextTouch(sample)
                } else {
                    finishNonLearnableTextTouch()
                }
            }
        case .candidateAction, .focusSurface:
            break
        }
    }

    fileprivate func commitTextKeyTouchWithDragRescue(
        activeTarget: KeyboardTouchTarget,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) {
        let resolvedTarget = dragRescuedTarget(
            activeTarget: activeTarget,
            startPoint: startPoint,
            endPoint: endPoint
        )
        if case .textKey(let activeButton) = activeTarget,
           case .textKey(let resolvedButton) = resolvedTarget,
           ObjectIdentifier(activeButton) != ObjectIdentifier(resolvedButton) {
            resetPressedControlState(activeButton)
        }
        let touchPoint = keyboardTouchLearningPoint(
            activeTarget: activeTarget,
            resolvedTarget: resolvedTarget,
            startPoint: startPoint,
            endPoint: endPoint
        )
        commitKeyboardTouchTarget(resolvedTarget, point: endPoint, touchPoint: touchPoint)
    }

    private func keyboardTouchLearningPoint(
        activeTarget: KeyboardTouchTarget,
        resolvedTarget: KeyboardTouchTarget,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) -> CGPoint {
        guard case .textKey(let activeButton) = activeTarget,
              case .textKey(let resolvedButton) = resolvedTarget,
              ObjectIdentifier(activeButton) != ObjectIdentifier(resolvedButton)
        else {
            return textCharacterIntentPoint(from: startPoint)
        }
        return textCharacterIntentPoint(from: endPoint)
    }

    private func dragRescuedTarget(
        activeTarget: KeyboardTouchTarget,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) -> KeyboardTouchTarget {
        guard case .textKey(let activeButton) = activeTarget else {
            return activeTarget
        }
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let threshold = TextKeyboardTouchModel.dragRescueThreshold
        guard dx * dx + dy * dy > threshold * threshold else {
            return activeTarget
        }
        guard let endTarget = keyboardOverlayTouchTarget(at: endPoint),
              case .textKey(let endButton) = endTarget,
              ObjectIdentifier(endButton) != ObjectIdentifier(activeButton)
        else {
            return activeTarget
        }
        return endTarget
    }

    fileprivate func cancelKeyboardTouchTarget(_ target: KeyboardTouchTarget, point: CGPoint) {
        logKeyboardTouchEvent("cancel", target: target, point: point)
        switch target {
        case .textKey(let button):
            resetPressedControlState(button)
        case .candidateAction, .focusSurface:
            break
        }
    }

    private func isCandidateScrollableSurfacePoint(_ point: CGPoint) -> Bool {
        if expandedFrame(of: candidateGridScrollView, dx: 0, dy: 4).contains(point) {
            return true
        }
        guard expandedFrame(of: candidateScrollView, dx: 0, dy: 4).contains(point) else {
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
            textWandButton,
            textStylePickerButton,
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
            topLimit = max(
                firstRow.frame.minY - TextKeyboardTouchModel.rowTopOverflow,
                textToolbar.convert(textToolbar.bounds, to: view).maxY + 2
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
        guard scrollFrame.insetBy(dx: 0, dy: -4).contains(point) else { return nil }
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

    private func resolveGutterCandidate(
        buttons: [TextKeyboardHitButton],
        index: Int,
        leftBoundary: CGFloat,
        rightBoundary: CGFloat,
        point: CGPoint
    ) -> UIButton {
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
        kbLog.info("touch gaussian pick side=\(decision.side.rawValue, privacy: .public) leftSamples=\(leftSamples, privacy: .public) rightSamples=\(rightSamples, privacy: .public) marginPct=\(marginPercent, privacy: .public)")
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
                    kbLog.info("touch gaussian learn skipped reason=center distance=\(distance, privacy: .public) threshold=\(threshold, privacy: .public)")
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
        configureKeyPreview()
        configureTopRow()
        configureVoiceButton()
        configureUtilityRow()
        configureTextKeyboard()
        configureKeyboardDarwinBridge()
        applyKeyboardInterfaceStyle(force: true)
        updateKeyboardFocus(animated: false)
        _ = rimeInput.startIfNeeded()
        updateUI(animated: false)
        // Keyboard extensions receive the active input scene's appearance as
        // traits. Re-apply concrete colors whenever those traits move; layer
        // colors don't update automatically like UIColor-backed views do.
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _) in
                self.refreshDynamicAppearance()
            }
        }
        kbLog.notice("viewDidLoad complete; voiceButton enabled=\(self.voiceButton.isEnabled, privacy: .public), fullAccess=\(self.hasFullAccess, privacy: .public)")
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
        inputModeSwitchActivationAllowedAt = CACurrentMediaTime() + 0.45
        didSuppressInitialInputModeSwitchEvent = false
        isHoldingKeyboardPresentationUntilStable = true
        didCompleteKeyboardViewAppearForPresentation = false
        setKeyboardContentVisible(false)
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
        logKeyboardPresentationLayout("viewWillAppear", force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didCompleteKeyboardViewAppearForPresentation = true
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        disableGestureRecognizerDelays()
        revealKeyboardContentIfPresentationStable()
        logKeyboardPresentationLayout("viewDidAppear", force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.disableGestureRecognizerDelays()
            self?.revealKeyboardContentIfPresentationStable()
            self?.logKeyboardPresentationLayout("viewDidAppear+100ms", force: true)
        }
        scheduleDeferredStartupProbe()
    }

    override func handleInputModeList(from view: UIView, with event: UIEvent) {
        let now = CACurrentMediaTime()
        guard now >= inputModeSwitchActivationAllowedAt else {
            if !didSuppressInitialInputModeSwitchEvent {
                didSuppressInitialInputModeSwitchEvent = true
                kbLog.notice("suppressed initial input-mode switch event during keyboard activation")
            }
            return
        }
        super.handleInputModeList(from: view, with: event)
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
        refreshInputModeSwitchKeyVisibility()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshInputModeSwitchKeyVisibility()
        refreshReturnKeyTitle()
        refreshEnglishLetterCasingIfNeeded()
    }

    deinit {
        deferredStartupWorkItem?.cancel()
        scheduledHostOpenTask?.cancel()
        scheduledStopTask?.cancel()
        hostWakeResetTask?.cancel()
        hostBundleWakeFallbackTask?.cancel()
        startupHostWakeTask?.cancel()
        stopStatusPolling()
        textTouchLearner.flush()
        rimeInput.onStateChange = nil
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        bridgeProbeTask?.cancel()
        cancelStatusRefresh()
        cancelBridgeCommandTasks()
        styleRewriteTask?.cancel()
        styleConfigureTask?.cancel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resetAllPressedControlStates(animated: false)
        if keyboardFocus == .text {
            pendingRimeCharacters.removeAll()
            applyRimeState(rimeInput.commitComposition())
        }
        textTouchLearner.flush()
        stopDeleteRepeat()
        clearTextShiftState()
        cancelHostWakeResetTask()
        cancelHostBundleWakeFallback()
        cancelStartupHostWake()
        rimeInput.onStateChange = nil
        deferredStartupWorkItem?.cancel()
        deferredStartupWorkItem = nil
        bridgeProbeTask?.cancel()
        bridgeProbeTask = nil
        cancelStatusRefresh()
        cancelActiveRecordingForKeyboardDismissal()
        cancelBridgeCommandTasks()
        restyleUndoState = nil
        styleRewriteTask?.cancel()
        styleRewriteTask = nil
        styleConfigureTask?.cancel()
        styleConfigureTask = nil
        cancelScheduledHostOpen()
        stopStatusPolling()
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        keyboardDarwinObservers = []
        voicePrint.isActive = false
        topRowVoicePrint.isActive = false
        textToolbarVoicePrint.isActive = false
        stopPulseRings()
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
        correctionMode = defaultCorrectionModeFromHost() ?? .polish
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
        rimeUserPhrasesRevision = defaults.string(forKey: rimeUserPhrasesRevisionKey) ?? ""
        refreshKeyboardPreferencesFromHost(
            rebuildIfNeeded: false,
            applyDefaultTextInputLanguageIfNeeded: !hasSavedTextInputLanguage,
            applyRimeChanges: false
        )
        defaults.removeObject(forKey: "keyboard.pendingAutoStartUntil")
    }

    private func syncPrimaryLanguage() {
        primaryLanguage = textInputLanguage == .chinese ? "zh-Hans" : "en-US"
    }

    private func applyTextInputOptionsToRime() {
        _ = rimeInput.setProfile(rimeProfile)
        applyRimeState(
            rimeInput.applyOptions(
                asciiPunctuation: chinesePunctuationStyle == .english,
                asciiMode: textInputLanguage == .english
            )
        )
    }

    private func resetCorrectionModeToDefault() {
        correctionMode = currentDefaultCorrectionMode()
        lastCorrectionModeButtonSignature = ""
    }

    private func applyDefaultCorrectionModeFromHost(_ rawValue: String?) {
        guard let rawValue,
              let defaultMode = CorrectionModePreset(rawValue: rawValue)
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

    private func currentDefaultCorrectionMode() -> CorrectionModePreset {
        pendingDefaultCorrectionMode ?? defaultCorrectionModeFromHost() ?? .polish
    }

    private func defaultCorrectionModeFromHost() -> CorrectionModePreset? {
        guard let raw = hostKeyboardDefaultsPayload()?["correction_mode"] as? String else {
            return nil
        }
        return CorrectionModePreset(rawValue: raw)
    }

    private func refreshKeyboardPreferencesFromHost(
        rebuildIfNeeded: Bool,
        applyDefaultTextInputLanguageIfNeeded: Bool = false,
        applyRimeChanges: Bool = true
    ) {
        guard let payload = hostKeyboardDefaultsPayload() else { return }
        let previousAutoCapitalization = isAutoCapitalizationEnabled
        let previousCharacterPreview = isCharacterPreviewEnabled
        let previousPunctuationStyle = chinesePunctuationStyle
        let previousRimeProfile = rimeProfile
        let previousRimeUserPhrasesRevision = rimeUserPhrasesRevision
        let previousTextInputLanguage = textInputLanguage

        if let enabled = payload["auto_capitalization_enabled"] as? Bool {
            isAutoCapitalizationEnabled = enabled
        }
        if let enabled = payload["character_preview_enabled"] as? Bool {
            isCharacterPreviewEnabled = enabled
        }
        if let raw = payload["chinese_punctuation_style"] as? String,
           let style = ChinesePunctuationStyle(rawValue: raw) {
            chinesePunctuationStyle = style
        }
        if let raw = payload["rime_dictionary_tier"] as? String,
           let tier = RimeKeyboardDictionaryTier(rawValue: raw) {
            rimeProfile.dictionaryTier = tier
        }
        if let enabled = payload["rime_correction_enabled"] as? Bool {
            rimeProfile.correctionEnabled = enabled
        }
        let hostRimeUserPhrases = payload["rime_user_phrases"] as? [String] ?? []
        let hostRimeUserPhrasesRevision = payload["rime_user_phrases_revision"] as? String ?? ""
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
        if let raw = payload["default_text_input_language"] as? String,
           let hostDefaultLanguage = HostDefaultTextInputLanguage(rawValue: raw) {
            let previousHostDefault = defaults.string(forKey: hostDefaultTextInputLanguageKey)
            let shouldApplyDefault = applyDefaultTextInputLanguageIfNeeded || previousHostDefault != raw
            defaults.set(raw, forKey: hostDefaultTextInputLanguageKey)
            if shouldApplyDefault,
               let defaultLanguage = hostDefaultLanguage.textInputLanguage {
                if textInputLanguage == .chinese, defaultLanguage == .english {
                    applyRimeState(rimeInput.commitComposition())
                }
                textInputLanguage = defaultLanguage
                defaults.set(defaultLanguage.rawValue, forKey: textInputLanguageKey)
                syncPrimaryLanguage()
                clearTextShiftState()
            }
        }

        if applyRimeChanges,
           previousPunctuationStyle != chinesePunctuationStyle
            || previousRimeProfile != rimeProfile
            || previousTextInputLanguage != textInputLanguage {
            resetQuoteParity()
            applyTextInputOptionsToRime()
        }
        if applyRimeChanges, userPhrasesChanged {
            applyRimeState(userPhraseState)
        }
        if applyRimeChanges,
           let generation = payload["rime_learning_reset_generation"] as? Int,
           generation > defaults.integer(forKey: rimeLearningResetGenerationKey) {
            defaults.set(generation, forKey: rimeLearningResetGenerationKey)
            applyRimeState(rimeInput.resetUserData())
        }
        if let generation = payload["touch_learning_reset_generation"] as? Int,
           generation > defaults.integer(forKey: touchLearningResetGenerationKey) {
            defaults.set(generation, forKey: touchLearningResetGenerationKey)
            resetTextTouchLearning()
        }
        guard rebuildIfNeeded else { return }
        let changed = previousAutoCapitalization != isAutoCapitalizationEnabled
            || previousCharacterPreview != isCharacterPreviewEnabled
            || previousPunctuationStyle != chinesePunctuationStyle
            || previousRimeProfile != rimeProfile
            || previousRimeUserPhrasesRevision != rimeUserPhrasesRevision
            || previousTextInputLanguage != textInputLanguage
        guard changed else { return }

        if keyboardFocus == .text {
            rebuildTextKeyboardRows()
        }
    }

    private func hostKeyboardDefaultsPayload() -> [String: Any]? {
        guard hasFullAccess else { return nil }
        if let payload = KeyboardSharedDefaults.loadPayload() {
            return payload
        }
        return bootstrapKeyboardDefaultsPayload()
    }

    private func bootstrapKeyboardDefaultsPayload() -> [String: Any]? {
        let hostDefaultLanguage = defaults.string(forKey: hostDefaultTextInputLanguageKey)
            .flatMap(HostDefaultTextInputLanguage.init(rawValue:)) ?? .lastUsed
        let payload: [String: Any] = [
            "version": 1,
            "bridge_token": KeyboardSharedDefaults.makeBridgeToken(),
            "correction_mode": correctionMode.rawValue,
            "auto_capitalization_enabled": isAutoCapitalizationEnabled,
            "character_preview_enabled": isCharacterPreviewEnabled,
            "chinese_punctuation_style": chinesePunctuationStyle.rawValue,
            "rime_dictionary_tier": rimeProfile.dictionaryTier.rawValue,
            "rime_correction_enabled": rimeProfile.correctionEnabled,
            "rime_user_phrases": [],
            "rime_user_phrases_revision": "",
            "default_text_input_language": hostDefaultLanguage.rawValue,
            "rime_learning_reset_generation": defaults.integer(forKey: rimeLearningResetGenerationKey),
            "touch_learning_reset_generation": defaults.integer(forKey: touchLearningResetGenerationKey),
            "updated_at": Date().timeIntervalSince1970,
        ]
        guard KeyboardSharedDefaults.savePayload(payload) else { return nil }
        return payload
    }

    private var hostKeyboardBridgeToken: String? {
        guard let token = hostKeyboardDefaultsPayload()?["bridge_token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return token
    }

    private func configureRoot() {
        refreshKeyboardBackground()

        keyboardSurfaceView.translatesAutoresizingMaskIntoConstraints = true
        keyboardSurfaceView.isUserInteractionEnabled = false
        keyboardSurfaceView.isOpaque = true
        keyboardSurfaceView.backgroundColor = Self.keyboardTouchableBackgroundColor

        keyboardContentView.translatesAutoresizingMaskIntoConstraints = true
        keyboardContentView.backgroundColor = .clear
        keyboardContentView.clipsToBounds = false

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
        view.addSubview(keyboardTouchOverlay)
        setKeyboardContentVisible(false)

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
            self.view.alpha = visible ? 1 : 0
            self.keyboardContentView.alpha = visible ? 1 : 0
            self.keyboardTouchOverlay.alpha = visible ? 1 : 0
        }
        CATransaction.commit()
    }

    private func revealKeyboardContentIfPresentationStable() {
        guard isHoldingKeyboardPresentationUntilStable else { return }
        guard didCompleteKeyboardViewAppearForPresentation else { return }
        let gate = keyboardPresentationGateState()
        guard gate.isStable else {
            if gate.logKey != lastPresentationGateLogKey {
                lastPresentationGateLogKey = gate.logKey
                kbLog.notice("waiting keyboard presentation gate: \(gate.reason, privacy: .public)")
            }
            return
        }
        isHoldingKeyboardPresentationUntilStable = false
        lastPresentationGateLogKey = ""
        setKeyboardContentVisible(true)
        kbLog.notice("revealed keyboard content after stable presentation height")
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
        if keyboardTouchOverlay.frame != frame {
            keyboardTouchOverlay.frame = frame
        }
        let contentHeight = max(1, frame.height - Self.topChromeCoverHeight)
        textKeyboardContainerHeightConstraint?.constant = Self.textKeyboardBodyHeight(for: contentHeight)
        orbContainerHeightConstraint?.constant = Self.orbContainerHeight(for: contentHeight)
        keyboardContentView.setNeedsLayout()
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
                    self.cancelHostWakeResetTask()
                    self.cancelHostBundleWakeFallback()
                    self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                    if !self.hasActiveKeyboardRecordingOrStopIntent,
                       self.currentBridgeStatus?.state != .recording,
                       self.currentBridgeStatus?.state != .sending {
                        self.applyBridgeStatus(KeyboardBridgeStatus(state: .standby, message: "Ready"))
                    } else {
                        self.openingHostUntil = 0
                        self.lastBridgeContactAt = Date().timeIntervalSince1970
                        self.updateUI()
                    }
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.sessionEnded) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.currentBridgeStatus?.state == .sending || self.pendingStopCommandID != nil {
                        self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                        self.updateUI()
                        return
                    }
                    self.cancelScheduledHostOpen()
                    self.cancelHostWakeResetTask()
                    self.cancelHostBundleWakeFallback()
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
                    let status = KeyboardBridgeStatus(state: .recording, message: "Recording")
                    self.cancelScheduledHostOpen()
                    self.cancelHostWakeResetTask()
                    self.cancelHostBundleWakeFallback()
                    self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                    self.applyBridgeStatus(status)
                    self.finishStartRequestIfNeeded(status: status)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStopped) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let wasStarting = self.isStartRequestInFlight
                    self.lastDarwinAwakeAt = Date().timeIntervalSince1970
                    self.finishStoppedNotification()
                    if wasStarting {
                        self.openHostForDictation()
                        return
                    }
                    if self.currentBridgeStatus?.state != .result,
                       self.currentBridgeStatus?.state != .sending {
                        self.bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Ready")
                        self.updateUI()
                    }
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.transcriptionReady) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshBridgeStatus()
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
            statusGroup.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            statusGroup.trailingAnchor.constraint(lessThanOrEqualTo: voiceTitleLabel.leadingAnchor, constant: -8),

            voiceTitleLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            voiceTitleLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            voiceTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topRow.leadingAnchor, constant: 88),
            voiceTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyboardFocusButton.leadingAnchor, constant: -8),

            topRowVoicePrint.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            topRowVoicePrint.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            topRowVoicePrint.widthAnchor.constraint(equalToConstant: 160),
            topRowVoicePrint.heightAnchor.constraint(equalToConstant: 24),

            // Inter-icon spacing 4pt and right margin 0 from topRow trailing
            // (topRow is already inset by rootHorizontalInset). Matches the
            // text-mode toolbar so the keyboard-switch and settings icons
            // land in the same X positions across modes.
            keyboardFocusButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            keyboardFocusButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            settingsButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
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
    /// frosted Restyle picker directly below it. The two stacked buttons
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
        clearRestyleUndoStateForManualEdit()
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

        for preset in CorrectionModePreset.allCases {
            let button = UIButton(type: .system)
            configureCorrectionModeButton(button, preset: preset)
            button.addTarget(self, action: #selector(selectCorrectionModeButton(_:)), for: .touchUpInside)
            attachPressAnimation(button)
            correctionModeButtons.append((preset, button))
            correctionPopoverStack.addArrangedSubview(button)
        }
        updateCorrectionModeButtons()
    }

    private func configureCorrectionModeButton(_ button: UIButton, preset: CorrectionModePreset) {
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
            ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))).cgPath
        }
        updateCandidateScrollViewport()
        updateCandidateGridCollapseButtonFrame()
        applyToolbarIconLayoutTweaks()
        updateKeyboardOverlayOrdering()
        revealKeyboardContentIfPresentationStable()
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
            textCandidateGridButton,
        ].forEach { button in
            button.imageView?.transform = toolbarIconTransform
        }
        candidateGridCollapseButton.imageView?.transform = .identity
    }

    private func logKeyboardTouchSurfaceLayoutIfNeeded() {
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

    private func logKeyboardPresentationLayout(_ event: String, force: Bool = false) {
        guard isViewLoaded else { return }

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
        commandButton.accessibilityLabel = NSLocalizedString("Command selected text", comment: "Accessibility label for command/edit-selection button")
        commandButton.addTarget(self, action: #selector(commandPressDown), for: [.touchDown, .touchDragEnter])
        commandButton.addTarget(self, action: #selector(commandPressUp), for: .touchUpInside)
        commandButton.addTarget(self, action: #selector(commandPressCancelled), for: [.touchUpOutside, .touchCancel, .touchDragExit])

        configureCapsuleButton(voiceUndoButton, title: "", image: "arrow.uturn.backward", style: .utility)
        voiceUndoButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        voiceUndoButton.accessibilityLabel = NSLocalizedString("Undo restyle", comment: "Accessibility label for undoing the latest restyle")
        voiceUndoButton.addTarget(self, action: #selector(undoRestyleTapped), for: .touchUpInside)
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

        // Wand (voice-command edit selected/recent text) — text-mode users
        // already have fingers on keys, so press-and-hold is awkward. Use
        // tap-toggle instead: first tap starts the command recording, second
        // tap ends it. The voice-mode commandButton keeps its hold contract.
        configureToolbarIconButton(textWandButton, image: "wand.and.stars")
        textWandButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textWandButton.accessibilityLabel = NSLocalizedString("Command selected text", comment: "Accessibility label for command/edit-selection button")
        textWandButton.addTarget(self, action: #selector(textWandTapped), for: .touchUpInside)
        attachPressAnimation(textWandButton)

        // Preset picker — opens the same correctionPopover as the voice-mode
        // correctionModeTrigger, so text-mode users have on-demand access to
        // the 5 style chips (Clean / Polish / Polish+ / Structure+ / Formal+)
        // without having to dictate first. Paint-brush icon distinguishes it
        // from the wand (wand = free-form voice command, picker = preset).
        configureToolbarIconButton(textStylePickerButton, image: "paintbrush")
        textStylePickerButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textStylePickerButton.accessibilityLabel = NSLocalizedString("Pick refine style", comment: "Accessibility label for text-mode style preset picker")
        textStylePickerButton.addTarget(self, action: #selector(toggleCorrectionPopover), for: .touchUpInside)
        attachPressAnimation(textStylePickerButton)

        configureToolbarIconButton(textUndoButton, image: "arrow.uturn.backward")
        textUndoButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textUndoButton.accessibilityLabel = NSLocalizedString("Undo restyle", comment: "Accessibility label for undoing the latest restyle")
        textUndoButton.addTarget(self, action: #selector(undoRestyleTapped), for: .touchUpInside)
        attachPressAnimation(textUndoButton)

        configureToolbarIconButton(textToolsButton, image: "mic.fill")
        textToolsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        textToolsButton.accessibilityLabel = NSLocalizedString("Dictate", comment: "Accessibility label for keyboard dictation button")
        textToolsButton.addTarget(self, action: #selector(textVoiceTapped), for: .touchUpInside)
        textToolsButton.showsMenuAsPrimaryAction = false
        attachPressAnimation(textToolsButton)

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
        candidateScrollView.addGestureRecognizer(candidateScrollTapRecognizer)
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

        // Status label shown during sending/error. Same slot as the voiceprint.
        textToolbarStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        textToolbarStatusLabel.isUserInteractionEnabled = false
        textToolbarStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        textToolbarStatusLabel.textColor = .secondaryLabel
        textToolbarStatusLabel.textAlignment = .center
        textToolbarStatusLabel.adjustsFontSizeToFitWidth = true
        textToolbarStatusLabel.minimumScaleFactor = 0.7
        textToolbarStatusLabel.alpha = 0
        textToolbar.addSubview(textToolbarStatusLabel)
        NSLayoutConstraint.activate([
            textToolbarStatusLabel.leadingAnchor.constraint(equalTo: textToolbar.leadingAnchor, constant: 12),
            textToolbarStatusLabel.trailingAnchor.constraint(equalTo: textToolbar.trailingAnchor, constant: -12),
            textToolbarStatusLabel.centerYAnchor.constraint(equalTo: textToolbar.centerYAnchor),
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

    private func rebuildTextKeyboardRows() {
        resetAllPressedControlStates(animated: false)
        isCandidateGridExpanded = false
        textToolbar.isHidden = false
        keyRowsStack.isHidden = false
        candidateGridScrollView.isHidden = true
        candidateGridCollapseButton.isHidden = true
        NSLayoutConstraint.deactivate(keyboardRowConstraints)
        keyboardRowConstraints.removeAll()
        keyRowsStack.arrangedSubviews.forEach { row in
            keyRowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        textKeyboardButtons.removeAll()
        textKeyboardHitRows.removeAll()
        letterButtonMap.removeAll()
        textKeyCommitCharacters.removeAll()
        lastLetterCasingSnapshot = nil
        textShiftButton = nil
        textSpaceKeyButton = nil

        if isSymbolKeyboard {
            let rows = symbolRowsForCurrentLanguage()
            addTextKeyRow(rows[0])
            addTextKeyRow(rows[1])
            addTextKeyRow(rows[2], includeAlternateSymbols: true, includeDelete: true)
        } else {
            addTextKeyRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
            addTextKeyRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"], usesHalfKeyHorizontalOffset: true)
            addTextKeyRow(["z", "x", "c", "v", "b", "n", "m"], includeShift: true, includeDelete: true)
        }
        addTextBottomRow()
        refreshTextControlTitles()
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
        let button = makeTextKeyButton(title: "", image: isTextShiftEnabled ? "shift.fill" : "shift", weight: .utility)
        button.isSelected = isTextShiftEnabled || isTextShiftLocked
        button.setNeedsUpdateConfiguration()
        button.accessibilityLabel = isTextShiftEnabled
            ? NSLocalizedString("Shift on", comment: "Accessibility label for active Shift key")
            : NSLocalizedString("Shift", comment: "Accessibility label for Shift key")
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
           isTextShiftEnabled || (textInputLanguage == .english && (autoCap ?? shouldAutoCapitalizeNextEnglishLetter())) {
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

        row.addArrangedSubview(textLanguageButton)
        textKeyboardButtons.append(textLanguageButton)

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
        registerTextKeyboardHitRow(
            row,
            routedButtons: [],
            directButtons: [textModeButton, textGlobeButton, textLanguageButton, spaceKey, returnKey],
            boundaryButtons: [textModeButton, textGlobeButton, textLanguageButton, spaceKey, returnKey],
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
    private func updateSpaceKeyTitleForRecording(_ recording: Bool) {
        guard let spaceKey = textSpaceKeyButton else { return }
        let title = recording
            ? NSLocalizedString("点击发送", comment: "Space key label during text-keyboard dictation")
            : spaceKeyTitle
        configureTextKeyButton(spaceKey, title: title, image: nil, weight: .primary)
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
            pointSize: isExpanded ? 22 : 18,
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
        let isCompactUtilityTitle = weight == .utility
            && image == nil
            && (title == "123" || title == "ABC" || title == "#+=")
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
                ? .systemFont(ofSize: 25, weight: .regular)
                : (isCompactUtilityTitle
                    ? .systemFont(ofSize: TextKeyboardLayoutModel.compactUtilityTitleFontSize, weight: .regular)
                    : .systemFont(ofSize: isShortGlyph ? 22 : 15, weight: isShortGlyph ? .regular : .medium))
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
        voiceUndoButton.configuration = capsuleButtonConfiguration(title: "", image: "arrow.uturn.backward", style: .utility)
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
        updateCorrectionModeButtons()
        configureInputModeSwitch()

        let state = currentBridgeStatus?.state
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
            self.statusDot.backgroundColor = self.statusColor

            if self.keyboardFocus == .text {
                self.voiceTitleLabel.text = NSLocalizedString("中文键盘", comment: "Title for Chinese keyboard focus")
                self.voiceTitleLabel.textColor = .label
                self.voiceTitleLabel.alpha = 1
            } else {
                self.voiceTitleLabel.text = self.voiceTitle
                self.voiceTitleLabel.textColor = self.voiceTitleColor
                self.voiceTitleLabel.alpha = isHoldRecording ? 0 : 1
            }
            self.voiceIconView.image = UIImage(systemName: self.voiceIconName)
            let showsSpinner = isSendingState || (!isRecordingState && (self.isStartRequestInFlight || self.isOpeningHostApp))
            self.voiceIconView.alpha = (isRecordingState || showsSpinner) ? 0 : 1
            self.voicePrint.alpha = showsInOrbVoicePrint ? 1 : 0
            self.topRowVoicePrint.alpha = (self.keyboardFocus == .text ? false : showsTopRowVoicePrint) ? 1 : 0
            self.voiceButton.alpha = 1
            self.voiceSpinner.alpha = showsSpinner ? 1 : 0

            let acceptsVoiceTouch = !isSendingState || self.isVoicePressActive
            self.voiceButton.isEnabled = acceptsVoiceTouch
            self.voiceButton.accessibilityValue = self.inputMode.title
            self.commandButton.isEnabled = !isSendingState || self.isCommandPressActive
            self.commandButton.alpha = self.commandButton.isEnabled ? 1 : 0.45
            self.inputModeSwitch.setEnabled(!isRecordingState && !isSendingState && !self.isStartRequestInFlight)
            let locksTextRows = self.keyboardFocus == .text && (isRecordingState || isSendingState)
            // Keep keys touchable during recording so the space key can act as
            // the stop-and-send affordance; per-handler guards swallow the
            // other keys. Sending blocks everything until the bridge returns
            // to result / error / idle.
            self.keyRowsStack.isUserInteractionEnabled = !(self.keyboardFocus == .text && isSendingState)
            // Dim per-key (not the whole stack) so the space key, which stays
            // the live stop-and-send affordance during recording, can render
            // at full opacity. UIView.alpha cascades multiplicatively, so we
            // can't set the stack to 0.48 and the space child back to 1.
            self.keyRowsStack.alpha = 1
            let recordingDim = isRecordingState && self.keyboardFocus == .text
            for button in self.textKeyboardButtons {
                if recordingDim {
                    button.alpha = button === self.textSpaceKeyButton ? 1 : 0.48
                } else {
                    button.alpha = locksTextRows ? 0.48 : 1
                }
            }
            self.updateSpaceKeyTitleForRecording(recordingDim)
            self.candidateScrollView.alpha = locksTextRows ? 0.62 : 1
            self.refreshTextRecordingButtons(isRecording: isRecordingState, isSending: isSendingState)
            // Voice-orb mode: dim the correction mode chip during recording /
            // sending so its disabled state reads visually. The mic + send
            // buttons stay at full opacity because they're the only live
            // affordances during dictation.
            let voiceModeDim = (isRecordingState || isSendingState) && self.keyboardFocus == .voice
            self.correctionModePanel.alpha = voiceModeDim ? 0.48 : 1
            self.voiceButton.layer.shadowColor = self.voiceShadowColor.cgColor

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
        let isInsertedFlash = keyboardFocus == .text
            && Date().timeIntervalSince1970 < insertedFlashUntil
        let showsTextToolbarStatus = keyboardFocus == .text
            && (isSendingState || isErrorState || isInsertedFlash)
        voicePrint.isActive = showsInOrbVoicePrint
        topRowVoicePrint.isActive = isHoldRecording
        textToolbarVoicePrint.isActive = showsTextToolbarVoicePrint
        textToolbarVoicePrint.alpha = showsTextToolbarVoicePrint ? 1 : 0
        if showsTextToolbarStatus {
            if isInsertedFlash {
                textToolbarStatusLabel.text = NSLocalizedString("Inserted", comment: "Bridge job stage")
                textToolbarStatusLabel.textColor = .systemGreen
            } else if isErrorState {
                textToolbarStatusLabel.text = currentBridgeStatus?.message
                textToolbarStatusLabel.textColor = .systemRed
            } else {
                textToolbarStatusLabel.text = currentBridgeStatus?.message
                textToolbarStatusLabel.textColor = .secondaryLabel
            }
        }
        textToolbarStatusLabel.alpha = showsTextToolbarStatus ? 1 : 0
        applyTextToolbarRecordingOverlay(
            recording: showsTextToolbarVoicePrint,
            sending: showsTextToolbarStatus
        )
        updateRestyleUndoButtons()
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

        let desiredInterval = statusPollingInterval(for: currentBridgeStatus?.state)
        if statusTimer != nil, abs(statusTimerInterval - desiredInterval) > 0.01 {
            stopStatusPolling()
            startStatusPolling(interval: desiredInterval)
        }
        updateTextRecordingStatus(isRecording: isRecordingState, isSending: isSendingState)
    }

    /// Fades the regular text-toolbar items out while the voiceprint overlay
    /// (recording) or status label (sending / error) takes over. Uses `alpha`
    /// rather than `isHidden` so the UIStackView layout stays put — `isHidden`
    /// removes items from the stack and the right-edge icons reflow.
    private func applyTextToolbarRecordingOverlay(recording: Bool, sending: Bool) {
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
        icons.forEach { $0.alpha = occupied ? 0 : 1 }
        candidateScrollView.alpha = occupied ? 0 : 1
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
            : NSLocalizedString("Command selected text", comment: "Accessibility label for command/edit-selection button")
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
        // Recording / sending status is now rendered in the top-toolbar
        // overlay (voiceprint + textToolbarStatusLabel). The candidate strip
        // just collapses; restore the Rime view when the bridge returns to
        // idle so users see normal candidates again.
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
        guard control.isDescendant(of: textKeyboardContainer) else { return }
        let now = CACurrentMediaTime()
        guard now - lastKeyboardFeedbackTime > 0.035 else { return }
        lastKeyboardFeedbackTime = now
        keyboardHapticGenerator.impactOccurred(intensity: 0.74)
        keyboardHapticGenerator.prepare()
    }

    @objc private func voicePressDown() {
        kbLog.notice("voicePressDown fired (bounds=\(NSCoder.string(for: self.voiceButton.bounds), privacy: .public))")
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
        kbLog.notice("voicePressUp fired")
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
        kbLog.notice("voicePressCancelled fired")
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
            cancelScheduledStop()
            tapRecordingActive = false
            showTextKeyboardNotice(NSLocalizedString("Transcribing", comment: "Inline status after stopping dictation"))
            sendBridgeCommand(.stop)
            return
        }

        guard hasFullAccess else {
            openHostForFullAccessSetup(showTextNotice: true)
            return
        }

        guard !isStartRequestInFlight else {
            showTextKeyboardNotice(NSLocalizedString("Opening Typeforme…", comment: "Inline status while dictation handoff is starting"))
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            showTextKeyboardNotice(NSLocalizedString("Transcribing", comment: "Inline status while dictation result is being processed"))
            return
        }

        cancelScheduledStop()
        tapRecordingActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        showTextKeyboardNotice(NSLocalizedString("Recording", comment: "Inline status after starting keyboard dictation"))
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
        isCommandPressActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        handleCommandTapModePress()
    }

    @objc private func commandPressDown() {
        guard !isCommandPressActive else { return }
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
        kbLog.notice("beginDictationPress: fullAccess=\(self.hasFullAccess, privacy: .public), bridgeState=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public), awake=\(self.isBridgeAwake, privacy: .public)")
        lightHaptic()
        guard hasFullAccess else {
            kbLog.notice("beginDictationPress: no full access")
            isVoicePressActive = false
            openHostForFullAccessSetup()
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            kbLog.notice("beginDictationPress: sending in flight, ignore")
            isVoicePressActive = false
            return
        }
        guard currentBridgeStatus?.state != .recording else {
            kbLog.notice("beginDictationPress: already recording; release will stop")
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
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        guard elapsed >= minimumIntentReleaseDuration else {
            kbLog.notice("endDictationPress: cancelling early release after \(elapsed, privacy: .public)s")
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
        kbLog.notice("handleTapModePress: fullAccess=\(self.hasFullAccess, privacy: .public), bridgeState=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public), awake=\(self.isBridgeAwake, privacy: .public)")
        lightHaptic()
        guard hasFullAccess else {
            openHostForFullAccessSetup()
            return
        }
        if isStartRequestInFlight {
            kbLog.notice("handleTapModePress: start already in flight; ignoring")
            return
        }
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            cancelScheduledStop()
            tapRecordingActive = false
            kbLog.notice("handleTapModePress: sending .stop command")
            sendBridgeCommand(.stop)
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
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Select text first.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
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
            cancelScheduledStop()
            tapRecordingActive = false
            sendBridgeCommand(.stop)
            return
        }
        guard currentBridgeStatus?.state != .sending else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Select text first.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
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
        continuesAfterRelease: Bool
    ) {
        guard !isStartRequestInFlight else { return }
        if canStartFromPreparedHostSession(textEditContext: textEditContext) {
            startDictationCommand(textEditContext: textEditContext, target: target)
            return
        }
        guard isBridgeAwake else {
            probeBridgeThenBeginDictation(
                textEditContext: textEditContext,
                target: target,
                continuesAfterRelease: continuesAfterRelease
            )
            return
        }

        startDictationCommand(textEditContext: textEditContext, target: target)
    }

    private func canStartFromPreparedHostSession(textEditContext: KeyboardTextEditContext?) -> Bool {
        guard textEditContext == nil else { return false }
        switch currentBridgeStatus?.state {
        case .standby, .recording, .result:
            return true
        default:
            return false
        }
    }

    private func probeBridgeThenBeginDictation(
        textEditContext: KeyboardTextEditContext?,
        target: TextRewriteTarget?,
        continuesAfterRelease: Bool
    ) {
        kbLog.notice("probeBridgeThenBeginDictation: checking local keyboard server")
        isStartRequestInFlight = true
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Checking Typeforme")
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()

        bridgeProbeTask?.cancel()
        let bridgeToken = hostKeyboardBridgeToken
        bridgeProbeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.status(bridgeToken: bridgeToken, timeout: 0.9)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.isStartRequestInFlight = false
                    self.bridgeStatus = status
                    self.lastBridgeContactAt = Date().timeIntervalSince1970

                    guard status.state != .idle else {
                        guard self.shouldContinueAfterBridgeProbe(continuesAfterRelease: continuesAfterRelease) else {
                            self.updateUI()
                            return
                        }
                        self.openHostForDictation()
                        return
                    }

                    if status.state == .recording {
                        if self.inputMode == .tap {
                            self.tapRecordingActive = false
                            self.sendBridgeCommand(.stop)
                        } else if !self.isVoicePressActive {
                            if self.shouldCancelWhenStartCompletes {
                                self.shouldCancelWhenStartCompletes = false
                                self.sendBridgeCommand(.cancel)
                            } else if self.shouldStopWhenStartCompletes {
                                self.shouldStopWhenStartCompletes = false
                                self.stopDictationAfterMinimumHoldIfNeeded()
                            } else {
                                self.updateUI()
                            }
                        } else {
                            self.updateUI()
                        }
                        return
                    }

                    guard self.shouldContinueAfterBridgeProbe(continuesAfterRelease: continuesAfterRelease) else {
                        self.updateUI()
                        return
                    }
                    self.startDictationCommand(textEditContext: textEditContext, target: target)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.isStartRequestInFlight = false
                    guard self.shouldContinueAfterBridgeProbe(continuesAfterRelease: continuesAfterRelease) else {
                        self.updateUI()
                        return
                    }
                    self.openHostForDictation()
                }
            }
        }
    }

    private func shouldContinueAfterBridgeProbe(continuesAfterRelease: Bool) -> Bool {
        if continuesAfterRelease { return true }
        guard inputMode == .hold else { return true }
        if isVoicePressActive || isCommandPressActive { return true }
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        tapRecordingActive = false
        activeRecordingTextTarget = nil
        return false
    }

    private func openHostForDictation() {
        kbLog.notice("openHostForDictation: bridge unavailable; opening host app")
        isStartRequestInFlight = false
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        // Bridge is unreachable — drop the durable awake signal so the next
        // press takes the probe path instead of optimistically fast-pathing.
        lastDarwinAwakeAt = 0
        if inputMode == .tap {
            tapRecordingActive = false
        }
        isVoicePressActive = false
        isCommandPressActive = false
        activeRecordingTextTarget = nil
        cancelScheduledHostOpen()
        // Intentional product workaround: third-party keyboard extensions
        // cannot capture microphone audio. When the local bridge is not already
        // awake, the only usable flow is to wake the containing app, let it
        // request/own microphone permission, then best-effort return the user
        // to the previous typing app.
        openHostAppForKeyboardAction(
            "microphone",
            returnToKeyboard: true,
            openingMessage: "Opening Typeforme for microphone access."
        )
    }

    private func openStandbyInHostApp(
        returnToKeyboard: Bool = true,
        allowBundleFallback: Bool = true
    ) {
        openHostAppForKeyboardAction(
            "standby",
            returnToKeyboard: returnToKeyboard,
            openingMessage: "Opening Typeforme to prepare dictation.",
            allowBundleFallback: allowBundleFallback
        )
    }

    private func openHostAppForKeyboardAction(
        _ action: String,
        returnToKeyboard: Bool,
        openingMessage: String,
        allowBundleFallback: Bool = true
    ) {
        guard hasFullAccess else {
            openHostForFullAccessSetup(showTextNotice: keyboardFocus == .text)
            return
        }
        if isRunningInsideHostApp {
            kbLog.notice("openHostAppForKeyboardAction: already running inside host app; suppressing self-open")
            cancelHostWakeResetTask()
            cancelHostBundleWakeFallback()
            openingHostUntil = 0
            bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Ready")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        let requestedCorrectionMode = action == "record" ? currentDefaultCorrectionMode() : correctionMode
        let handoff = KeyboardHostHandoff(
            action: action,
            shouldReturnToKeyboard: returnToKeyboard,
            correctionMode: requestedCorrectionMode.rawValue,
            returnBundleID: returnToKeyboard ? currentHostBundleID : nil,
            returnProcessID: returnToKeyboard ? currentHostProcessID : nil
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
            showTextKeyboardNotice(NSLocalizedString("Opening Typeforme…", comment: "Inline status while opening the host app"))
        }
        openHostApp(url, allowBundleFallback: allowBundleFallback) { [weak self] success in
            kbLog.notice("openHostAppForKeyboardAction: open success=\(success, privacy: .public)")
            guard let self, !success else { return }
            self.cancelHostWakeResetTask()
            self.openingHostUntil = 0
            self.tapRecordingActive = false
            self.bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Open Typeforme to prepare dictation.")
            self.lastBridgeContactAt = Date().timeIntervalSince1970
            self.updateUI()
            if self.keyboardFocus == .text {
                self.showTextKeyboardNotice(NSLocalizedString("Open Typeforme", comment: "Inline status when host app cannot be opened"))
            }
        }

        // Safety net: if the host wake "succeeded" from LSApplicationWorkspace's
        // perspective but the host never finishes booting (or never posts the
        // sessionStarted Darwin notification that would clear the spinner),
        // the keyboard would otherwise show "Opening Typeforme…" forever
        // because UI only re-renders on touch, timer, or notification. After
        // the 8s window expires, force a one-shot redraw and reset bridge
        // state so the user can try again.
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
                    self.showTextKeyboardNotice("")
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
            kbLog.notice("openHostForFullAccessSetup: open success=\(success, privacy: .public)")
            guard let self, !success else { return }
            self.cancelHostWakeResetTask()
            self.openingHostUntil = 0
            self.updateUI()
        }
    }

    private func cancelHostWakeResetTask() {
        hostWakeResetTask?.cancel()
        hostWakeResetTask = nil
    }

    private func cancelHostBundleWakeFallback() {
        hostBundleWakeFallbackTask?.cancel()
        hostBundleWakeFallbackTask = nil
    }

    private func openHostApp(
        _ url: URL,
        allowBundleFallback: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        // Non-public but deliberate: custom keyboards do not get a supported
        // "open containing app" API for this microphone handoff. Keep all
        // host-wake reflection in this method so an App Store build can replace
        // it with a manual "open Typeforme" fallback without touching the
        // dictation state machine.
        kbLog.notice("openHostApp: opening URL via LSApplicationWorkspace")
        let didRequestURL = openHostAppViaApplicationWorkspace(url)
        if didRequestURL {
            completion(true)
            if allowBundleFallback {
                scheduleHostBundleWakeFallback()
            }
            return
        }

        guard allowBundleFallback else {
            kbLog.notice("openHostApp: URL open unavailable; bundle id fallback disabled")
            completion(false)
            return
        }

        kbLog.notice("openHostApp: URL open unavailable; opening bundle id fallback")
        completion(openHostAppViaBundleIdentifier())
    }

    private func scheduleHostBundleWakeFallback() {
        cancelHostBundleWakeFallback()
        hostBundleWakeFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.hostBundleWakeFallbackTask = nil
                guard self.isOpeningHostApp,
                      self.lastDarwinAwakeAt == 0,
                      self.currentBridgeStatus?.state == .standby
                else { return }
                kbLog.notice("openHostApp: URL wake did not signal; opening bundle id fallback")
                _ = self.openHostAppViaBundleIdentifier()
            }
        }
    }

    private func openHostAppViaApplicationWorkspace(_ url: URL) -> Bool {
        guard let workspaceClass = objc_getClass("LSApplicationWorkspace") as? AnyObject else {
            kbLog.notice("openHostAppViaApplicationWorkspace: LSApplicationWorkspace unavailable")
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject else {
            kbLog.notice("openHostAppViaApplicationWorkspace: defaultWorkspace unavailable")
            return false
        }

        let openSensitiveSelector = NSSelectorFromString("openSensitiveURL:withOptions:")
        guard workspace.responds(to: openSensitiveSelector),
              let imp = workspace.method(for: openSensitiveSelector)
        else {
            kbLog.notice("openHostAppViaApplicationWorkspace: openSensitiveURL unavailable")
            return false
        }

        kbLog.notice("openHostAppViaApplicationWorkspace: opening URL via openSensitiveURL")
        typealias OpenSensitiveURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary) -> Void
        let openSensitiveURL = unsafeBitCast(imp, to: OpenSensitiveURL.self)
        openSensitiveURL(workspace, openSensitiveSelector, url as NSURL, NSDictionary())
        return true
    }

    private func openHostAppViaBundleIdentifier() -> Bool {
        guard let workspaceClass = objc_getClass("LSApplicationWorkspace") as? AnyObject else {
            kbLog.notice("openHostAppViaBundleIdentifier: LSApplicationWorkspace unavailable")
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject else {
            kbLog.notice("openHostAppViaBundleIdentifier: defaultWorkspace unavailable")
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector),
              let imp = workspace.method(for: openSelector)
        else {
            kbLog.notice("openHostAppViaBundleIdentifier: openApplicationWithBundleID unavailable")
            return false
        }

        typealias OpenApplication = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let openApplication = unsafeBitCast(imp, to: OpenApplication.self)
        let didOpen = openApplication(
            workspace,
            openSelector,
            Self.containingAppBundleIdentifier as NSString
        )
        kbLog.notice("openHostAppViaBundleIdentifier: result=\(didOpen, privacy: .public)")
        return didOpen
    }

    private var currentHostBundleID: String? {
        currentTextHostBundleID.flatMap { isUsableReturnBundleID($0) ? $0 : nil }
    }

    private var currentTextHostBundleID: String? {
        // Non-public host discovery. This exists only to make the microphone
        // handoff feel like a keyboard action on device and to avoid opening
        // Typeforme from inside Typeforme. Removing it makes host return
        // manual; keeping it is not appropriate for an App Store-safe build.
        if let id = privateStringValue(named: "_hostApplicationBundleIdentifier", from: self) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if isBundleIdentifierShape(trimmed) {
                return trimmed
            }
        }
        if let id = privateStringValue(named: "_hostBundleID", from: parent) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if isBundleIdentifierShape(trimmed) {
                return trimmed
            }
        }
        guard let pid = currentHostProcessID else { return nil }
        let hostPID: AnyObject = NSNumber(value: pid)
        return currentHostBundleIDFromXPC(hostPID: hostPID).flatMap { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return isBundleIdentifierShape(trimmed) ? trimmed : nil
        }
    }

    private var currentHostProcessID: Int32? {
        if let number = privateIntMethodValue(named: "_hostProcessIdentifier", from: self),
           number.int32Value > 0 {
            return number.int32Value
        }
        guard let hostPID = privateObjectValue(named: "_hostPID", from: parent),
              let pid = intValue(from: hostPID),
              pid > 0
        else { return nil }
        return pid
    }

    private func currentHostBundleIDFromXPC(hostPID: AnyObject) -> String? {
        guard let serviceClass = NSClassFromString("PKService") else { return nil }
        let serviceObject = serviceClass as AnyObject
        let defaultServiceSelector = NSSelectorFromString("defaultService")
        guard serviceObject.responds(to: defaultServiceSelector),
              let service = serviceObject.perform(defaultServiceSelector)?.takeUnretainedValue() as? NSObject
        else { return nil }

        let personalitiesSelector = NSSelectorFromString("personalities")
        guard service.responds(to: personalitiesSelector),
              let personalities = service.perform(personalitiesSelector)?.takeUnretainedValue() as? NSDictionary
        else { return nil }

        let extensionBundleIDs = [
            Bundle.main.bundleIdentifier,
            Bundle(for: type(of: self)).bundleIdentifier,
        ].compactMap { $0 }

        for extensionBundleID in extensionBundleIDs {
            guard let infos = personalities.object(forKey: extensionBundleID) as? NSDictionary,
                  let info = infos.object(forKey: hostPID) as? NSObject,
                  let connection = privateObjectValue(named: "connection", from: info),
                  let xpcConnection = privateObjectValue(named: "_xpcConnection", from: connection),
                  let bundleID = copyBundleID(fromXPCConnection: xpcConnection)
            else { continue }
            return bundleID
        }
        return nil
    }

    private func copyBundleID(fromXPCConnection connection: AnyObject) -> String? {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "xpc_connection_copy_bundle_id")
        else { return nil }
        typealias CopyBundleID = @convention(c) (AnyObject) -> UnsafeMutablePointer<CChar>?
        let copyBundleID = unsafeBitCast(symbol, to: CopyBundleID.self)
        guard let cString = copyBundleID(connection) else { return nil }
        defer { free(cString) }
        return String(cString: cString)
    }

    private func intValue(from object: AnyObject) -> Int32? {
        if let number = object as? NSNumber {
            return number.int32Value
        }
        return Int32(String(describing: object).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isUsableReturnBundleID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "<null>" else { return false }
        guard isBundleIdentifierShape(trimmed) else { return false }
        guard trimmed != Bundle.main.bundleIdentifier else { return false }
        guard !trimmed.hasPrefix("com.example.typeforme") else { return false }
        return true
    }

    private func isBundleIdentifierShape(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private func privateStringValue(named name: String, from object: AnyObject?) -> String? {
        guard let value = privateObjectValue(named: name, from: object) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        let text = String(describing: value)
        return text == "<null>" ? nil : text
    }

    private func privateObjectValue(named name: String, from object: AnyObject?) -> AnyObject? {
        guard let object else { return nil }
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector) {
            if let returnTypeText = methodReturnType(named: selector, from: object) {
                if returnTypeText.hasPrefix("@") || returnTypeText == "#" {
                    return object.perform(selector)?.takeUnretainedValue()
                }
                return privateIntMethodValue(named: name, from: object)
            }
            return object.perform(selector)?.takeUnretainedValue()
        }

        var nextClass: AnyClass? = object_getClass(object)
        while let currentClass = nextClass {
            if let ivar = class_getInstanceVariable(currentClass, name) {
                return privateIvarValue(ivar, from: object)
            }
            nextClass = class_getSuperclass(currentClass)
        }
        return nil
    }

    private func privateIntMethodValue(named name: String, from object: AnyObject?) -> NSNumber? {
        guard let object else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let returnTypeText = methodReturnType(named: selector, from: object),
              let imp = object.method(for: selector)
        else { return nil }

        switch returnTypeText {
        case "i":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        case "I":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        case "q":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        case "Q":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        case "s":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int16
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        case "S":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt16
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        case "c", "B":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return NSNumber(value: unsafeBitCast(imp, to: Getter.self)(object, selector))
        default:
            return nil
        }
    }

    private func methodReturnType(named selector: Selector, from object: AnyObject) -> String? {
        guard let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2
        else { return nil }
        let returnType = method_copyReturnType(method)
        let returnTypeText = String(cString: returnType)
        free(returnType)
        return returnTypeText
    }

    private func privateIvarValue(_ ivar: Ivar, from object: AnyObject) -> AnyObject? {
        guard let typeEncoding = ivar_getTypeEncoding(ivar) else { return nil }
        let type = String(cString: typeEncoding)
        if type.hasPrefix("@") {
            return object_getIvar(object, ivar) as AnyObject?
        }

        let offset = ivar_getOffset(ivar)
        let rawPointer = Unmanaged.passUnretained(object).toOpaque().advanced(by: offset)
        switch type {
        case "i": return NSNumber(value: rawPointer.load(as: Int32.self))
        case "I": return NSNumber(value: rawPointer.load(as: UInt32.self))
        case "q": return NSNumber(value: rawPointer.load(as: Int64.self))
        case "Q": return NSNumber(value: rawPointer.load(as: UInt64.self))
        case "s": return NSNumber(value: rawPointer.load(as: Int16.self))
        case "S": return NSNumber(value: rawPointer.load(as: UInt16.self))
        case "c", "B": return NSNumber(value: rawPointer.load(as: Bool.self))
        default: return nil
        }
    }

    private func startDictationCommand(
        textEditContext: KeyboardTextEditContext? = nil,
        target: TextRewriteTarget? = nil
    ) {
        kbLog.notice("beginDictationFromKeyboard: sending .start command")
        isStartRequestInFlight = true
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        let recordingMode = currentDefaultCorrectionMode()
        if correctionMode != recordingMode {
            correctionMode = recordingMode
            lastCorrectionModeButtonSignature = ""
        }
        let command = KeyboardBridgeCommand(
            action: .start,
            correctionMode: recordingMode.rawValue,
            textEditContext: textEditContext,
            dictationContext: textEditContext == nil ? currentDictationContext() : nil
        )
        activeRecordingCommandID = command.id
        activeRecordingTextTarget = target.map {
            PendingRecordingTextTarget(commandID: command.id, target: $0)
        }
        sendBridgeCommand(command)
    }

    private func finishStartRequestIfNeeded(status: KeyboardBridgeStatus?) {
        isStartRequestInFlight = false
        if shouldCancelWhenStartCompletes {
            shouldCancelWhenStartCompletes = false
            shouldStopWhenStartCompletes = false
            if status?.state == .recording || currentBridgeStatus?.state == .recording {
                sendBridgeCommand(.cancel)
            }
            activeRecordingTextTarget = nil
            return
        }
        guard shouldStopWhenStartCompletes else { return }
        shouldStopWhenStartCompletes = false
        if status?.state == .recording || currentBridgeStatus?.state == .recording {
            stopDictationAfterMinimumHoldIfNeeded()
        }
    }

    private func cancelActiveRecordingForKeyboardDismissal() {
        let shouldCancel = isStartRequestInFlight
            || tapRecordingActive
            || isVoicePressActive
            || isCommandPressActive
            || currentBridgeStatus?.state == .recording
        guard shouldCancel else { return }

        let commandID = activeRecordingCommandID
            ?? activeRecordingTextTarget?.commandID
            ?? currentBridgeStatus?.commandID
            ?? UUID().uuidString
        let command = KeyboardBridgeCommand(
            id: commandID,
            action: .cancel,
            correctionMode: correctionMode.rawValue
        )
        kbLog.notice("keyboard disappearing during dictation; sending .cancel command")
        cancelScheduledStop()
        isStartRequestInFlight = false
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        isVoicePressActive = false
        isCommandPressActive = false
        tapRecordingActive = false
        activeRecordingCommandID = nil
        activeRecordingTextTarget = nil
        pendingStopCommandID = nil
        cancelScheduledHostOpen()
        _ = postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestCancelDictation)

        guard hasFullAccess else { return }
        let bridgeToken = hostKeyboardBridgeToken
        let localClient = self.localClient
        Task {
            _ = try? await localClient.send(
                command,
                bridgeToken: bridgeToken,
                timeout: KeyboardBridgeCommandAction.cancel.requestTimeout
            )
        }
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
        activeRecordingCommandID = nil
        pendingStopCommandID = nil
    }

    private func stopDictationAfterMinimumHoldIfNeeded() {
        cancelScheduledStop()
        tapRecordingActive = false
        isCommandPressActive = false
        guard currentBridgeStatus?.state == .recording else { return }
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        let delay = max(0, minimumHoldRecordingDuration - elapsed)
        guard delay > 0 else {
            kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: sending .stop command")
            sendBridgeCommand(.stop)
            return
        }

        kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: delaying stop by \(delay, privacy: .public)s")
        scheduledStopTask = Task { [weak self] in
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await MainActor.run {
                guard let self, self.currentBridgeStatus?.state == .recording else { return }
                self.scheduledStopTask = nil
                kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: delayed .stop command")
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
        openStandbyInHostApp(returnToKeyboard: false)
    }

    @objc private func selectCorrectionModeButton(_ sender: UIButton) {
        guard let preset = correctionModeButtons.first(where: { $0.button === sender })?.preset else { return }
        lightHaptic()
        // Close the popover before kicking off the rewrite so the user sees
        // the orb again immediately rather than the popover lingering.
        hideCorrectionPopover()
        rewriteCurrentInputOrPasteboard(using: preset)
    }

    @objc private func undoRestyleTapped() {
        lightHaptic()
        guard let undo = restyleUndoState,
              canApplyRestyleUndo,
              replaceRestyleUndoTarget(undo.current, with: undo.restoredText)
        else {
            showTextKeyboardNotice(
                NSLocalizedString("Undo unavailable", comment: "Inline status when restyle undo cannot be applied"),
                color: .systemRed
            )
            updateUI()
            return
        }

        restyleUndoState = nil
        recentSelectionTarget = nil
        defaults.removeObject(forKey: lastInsertedCommandIDKey)
        defaults.removeObject(forKey: lastInsertedTextKey)
        showTextKeyboardNotice(
            NSLocalizedString("Restored", comment: "Inline status after undoing a restyle"),
            color: .systemGreen
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
        ].joined(separator: ":")
        guard signature != lastCorrectionModeButtonSignature else { return }
        lastCorrectionModeButtonSignature = signature
        for item in correctionModeButtons {
            let isSelected = item.preset == correctionMode
            let configuration = correctionModeButtonConfiguration(title: item.preset.title, selected: isSelected)
            item.button.configuration = configuration
            // Configuration recreates internal layout — re-apply line-wrap
            // constraints so "Structure+" doesn't wrap after each refresh.
            item.button.titleLabel?.numberOfLines = 1
            item.button.titleLabel?.lineBreakMode = .byTruncatingTail
            item.button.titleLabel?.adjustsFontSizeToFitWidth = true
            item.button.titleLabel?.minimumScaleFactor = 0.7
            item.button.isEnabled = isEnabled
            item.button.alpha = isEnabled ? 1 : 0.45
            item.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        applyCorrectionTriggerConfiguration(isEnabled: isEnabled)
        if !isEnabled, isCorrectionPopoverVisible {
            hideCorrectionPopover()
        }
    }

    private func updateRestyleUndoButtons() {
        let isBlocked = currentBridgeStatus?.state == .recording
            || currentBridgeStatus?.state == .sending
            || isStartRequestInFlight
            || styleRewriteCommandID != nil
        let canUndo = !isBlocked && canApplyRestyleUndo
        voiceUndoButton.isEnabled = canUndo
        voiceUndoButton.alpha = canUndo ? 1 : 0.45
        textUndoButton.isEnabled = canUndo
        textUndoButton.alpha = isBlocked ? 0 : (canUndo ? 1 : 0.35)
    }

    private func clearRestyleUndoStateForManualEdit() {
        guard restyleUndoState != nil else { return }
        restyleUndoState = nil
        updateRestyleUndoButtons()
    }

    /// Builds the trigger button's compact "current preset + chevron"
    /// configuration. Shares the `capsuleButtonConfiguration` factory used
    /// by the bottom utility row so the Restyle chip's frosted-glass blur,
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

    private func rewriteCurrentInputOrPasteboard(using preset: CorrectionModePreset) {
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
            action: .restyleText,
            correctionMode: preset.rawValue,
            text: target.text
        )
        styleRewriteCommandID = command.id
        bridgeStatus = KeyboardBridgeStatus(commandID: command.id, state: .sending, message: "Refining")
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        showTextKeyboardNotice(NSLocalizedString("Refining", comment: "Inline status while refining recent text"))

        styleRewriteTask?.cancel()
        let bridgeToken = hostKeyboardBridgeToken
        styleRewriteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(
                    command,
                    bridgeToken: bridgeToken,
                    timeout: KeyboardBridgeCommandAction.restyleText.requestTimeout
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

    private func saveCorrectionModeForNextRecording(using preset: CorrectionModePreset) {
        let command = KeyboardBridgeCommand(action: .configure, correctionMode: preset.rawValue)
        showTextKeyboardNotice(NSLocalizedString("Style saved", comment: "Inline status after choosing a style without rewrite text"))

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
                    self.showTextKeyboardNotice(NSLocalizedString("Style saved", comment: "Inline status after choosing a style without rewrite text"))
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
        if let selected = textDocumentProxy.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return captureSelectionTarget(selected)
        }

        if let recentSelection = recentSelectionTargetIfFresh() {
            kbLog.notice("using cached selection target for command")
            return recentSelection
        }

        if let contextTarget = currentExpandedContextRewriteTarget() {
            return contextTarget
        }

        if let recentResult = recentInsertedTextRewriteTarget() {
            kbLog.notice("using recent inserted result as rewrite target")
            return recentResult
        }

        return nil
    }

    private func recentInsertedTextRewriteTarget() -> TextRewriteTarget? {
        guard let text = defaults.string(forKey: lastInsertedTextKey),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(text) else { return nil }

        let contextBefore = String(before.dropLast(text.count))
        let contextAfter = textDocumentProxy.documentContextAfterInput ?? ""
        return .selection(text: text, contextBefore: contextBefore, contextAfter: contextAfter)
    }

    private func currentExpandedContextRewriteTarget() -> TextRewriteTarget? {
        let initialBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let initialAfter = textDocumentProxy.documentContextAfterInput ?? ""
        guard !(initialBefore + initialAfter).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let before = expandedContextBefore(startingWith: initialBefore)
        let after = expandedContextAfter(startingWith: initialAfter)
        kbLog.notice("context rewrite target captured: initialBeforeLen=\(initialBefore.count, privacy: .public), initialAfterLen=\(initialAfter.count, privacy: .public), beforeLen=\(before.count, privacy: .public), afterLen=\(after.count, privacy: .public)")
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
            kbLog.notice("using cached selection target for repair")
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
        intent: KeyboardTextEditIntent,
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
            bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Selection changed; result copied.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        recordRestyleUndoState(originalTarget: target, rewrittenText: text)
        defaults.set(commandID, forKey: lastInsertedCommandIDKey)
        defaults.set(text, forKey: lastInsertedTextKey)
        recentSelectionTarget = nil
        applyDefaultCorrectionModeFromHost(status.defaultCorrectionMode)
        bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .result, message: "Refined", resultText: text)
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
        switch target {
        case .selection(let original, let contextBefore, let contextAfter):
            guard applySelectionReplacement(
                text,
                replacing: original,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            ) else { return false }
        case .context(let before, let after):
            replaceContextText(text, before: before, after: after)
        }
        return true
    }

    private var canApplyRestyleUndo: Bool {
        guard let undo = restyleUndoState else { return false }
        guard Date().timeIntervalSince1970 - undo.updatedAt <= restyleUndoStateTTL else { return false }
        return canReplaceRestyleUndoTarget(undo.current)
    }

    private func recordRestyleUndoState(originalTarget: TextRewriteTarget, rewrittenText: String) {
        let now = Date().timeIntervalSince1970
        guard let current = currentRestyleUndoTarget(for: rewrittenText) else {
            restyleUndoState = nil
            updateRestyleUndoButtons()
            return
        }

        let restoredText: String
        if let previous = restyleUndoState,
           now - previous.updatedAt <= restyleUndoStateTTL,
           targetsBelongToSameRestyleSession(previous.current, originalTarget) {
            restoredText = previous.restoredText
        } else {
            restoredText = originalTarget.text
        }

        restyleUndoState = RestyleUndoState(
            restoredText: restoredText,
            current: current,
            updatedAt: now
        )
        updateRestyleUndoButtons()
    }

    private func currentRestyleUndoTarget(for text: String) -> RestyleUndoTarget? {
        if textDocumentProxy.selectedText == text {
            return RestyleUndoTarget(
                text: text,
                contextBefore: textDocumentProxy.documentContextBeforeInput ?? "",
                contextAfter: textDocumentProxy.documentContextAfterInput ?? ""
            )
        }

        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        guard currentBefore.hasSuffix(text) else {
            kbLog.notice("restyle undo skipped: rewritten text is not anchored at cursor")
            return nil
        }

        return RestyleUndoTarget(
            text: text,
            contextBefore: String(currentBefore.dropLast(text.count)),
            contextAfter: textDocumentProxy.documentContextAfterInput ?? ""
        )
    }

    private func targetsBelongToSameRestyleSession(_ lhs: RestyleUndoTarget, _ rhs: TextRewriteTarget) -> Bool {
        guard lhs.text == rhs.text else { return false }
        switch rhs {
        case .selection(_, let contextBefore, let contextAfter):
            return lhs.contextBefore == contextBefore && lhs.contextAfter == contextAfter
        case .context(let before, let after):
            return lhs.contextBefore.isEmpty && lhs.contextAfter.isEmpty && lhs.text == before + after
        }
    }

    private func canReplaceRestyleUndoTarget(_ target: RestyleUndoTarget) -> Bool {
        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentAfter = textDocumentProxy.documentContextAfterInput ?? ""

        if textDocumentProxy.selectedText == target.text,
           currentBefore == target.contextBefore,
           currentAfter.hasPrefix(target.contextAfter) {
            return true
        }

        if currentBefore == target.contextBefore + target.text,
           currentAfter.hasPrefix(target.contextAfter) {
            return true
        }

        return currentBefore == target.contextBefore
            && currentAfter.hasPrefix(target.text + target.contextAfter)
    }

    private func replaceRestyleUndoTarget(_ target: RestyleUndoTarget, with text: String) -> Bool {
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
            deleteBackward(characterCount: target.text.count)
            textDocumentProxy.insertText(text)
            return true
        }

        if currentBefore == target.contextBefore,
           currentAfter.hasPrefix(target.text + target.contextAfter) {
            replaceContextText(text, before: "", after: target.text)
            return true
        }

        kbLog.notice("restyle undo skipped: current text no longer matches undo target")
        return false
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
        if textDocumentProxy.selectedText == original {
            textDocumentProxy.insertText(text)
            return true
        }

        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentAfter = textDocumentProxy.documentContextAfterInput ?? ""
        if currentBefore.hasSuffix(original) {
            deleteBackward(characterCount: original.count)
            textDocumentProxy.insertText(text)
            return true
        }

        if currentBefore == contextBefore, currentAfter.hasPrefix(original) {
            replaceContextText(text, before: "", after: original)
            return true
        }

        kbLog.notice("selection replacement skipped: originalLen=\(original.count, privacy: .public), beforeLen=\(currentBefore.count, privacy: .public), afterLen=\(currentAfter.count, privacy: .public)")
        return false
    }

    private func replaceContextText(_ text: String, before: String, after: String) {
        guard !after.isEmpty else {
            deleteBackward(characterCount: before.count)
            textDocumentProxy.insertText(text)
            return
        }

        textDocumentProxy.adjustTextPosition(byCharacterOffset: after.count)
        deleteBackward(characterCount: before.count + after.count)
        textDocumentProxy.insertText(text)
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
            applyRimeState(rimeInput.commitComposition())
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
                kbLog.notice("Keyboard focus \(focusName, privacy: .public) animation completed in \(elapsedMS, privacy: .public) ms")
            }
        )
    }

    private func applyKeyboardFocusChanges(isTextFocus: Bool) {
        topRow.isHidden = isTextFocus
        orbContainer.isHidden = isTextFocus
        utilityRow.isHidden = isTextFocus
        textKeyboardContainer.isHidden = !isTextFocus
        updateKeyboardOverlayOrdering()
        keyboardFocusButton.configuration?.image = UIImage(systemName: isTextFocus ? "mic.fill" : "keyboard")
        keyboardFocusButton.accessibilityLabel = isTextFocus
            ? NSLocalizedString("Show voice input", comment: "Accessibility label for showing voice input")
            : NSLocalizedString("Show keyboard", comment: "Accessibility label for showing the screen keyboard")
        voiceTitleLabel.text = isTextFocus
            ? NSLocalizedString("中文键盘", comment: "Title for Chinese keyboard focus")
            : voiceTitle
    }

    @objc private func toggleSymbolKeyboard() {
        if isSymbolKeyboard {
            isSymbolKeyboard = false
            isAlternateSymbolKeyboard = false
        } else {
            isSymbolKeyboard = true
            isAlternateSymbolKeyboard = false
        }
        rebuildTextKeyboardRows()
        lightHaptic()
    }

    @objc private func toggleAlternateSymbolKeyboard() {
        guard isSymbolKeyboard else { return }
        isAlternateSymbolKeyboard.toggle()
        rebuildTextKeyboardRows()
        lightHaptic()
    }

    @objc private func toggleTextShift() {
        guard !isSymbolKeyboard else { return }
        let now = CACurrentMediaTime()
        if isTextShiftLocked {
            isTextShiftEnabled = false
            isTextShiftLocked = false
        } else if isTextShiftEnabled, now - lastShiftTapTime <= 0.42 {
            isTextShiftEnabled = true
            isTextShiftLocked = true
        } else {
            isTextShiftEnabled.toggle()
            isTextShiftLocked = false
        }
        lastShiftTapTime = now
        refreshShiftButtonImage()
        refreshLetterCasing()
        lightHaptic()
    }

    @objc private func toggleTextInputLanguage() {
        if textInputLanguage == .chinese {
            applyRimeState(rimeInput.commitComposition())
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
        lightHaptic()
    }

    private func refreshTextControlTitles() {
        configureTextControlButton(textModeButton, title: isSymbolKeyboard ? "ABC" : "123", image: nil)
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
        textShiftButton.isSelected = isTextShiftEnabled || isTextShiftLocked
        configureTextKeyButton(
            textShiftButton,
            title: "",
            image: isTextShiftLocked ? "capslock.fill" : (isTextShiftEnabled ? "shift.fill" : "shift"),
            weight: .utility
        )
        textShiftButton.accessibilityLabel = isTextShiftLocked
            ? NSLocalizedString("Caps Lock on", comment: "Accessibility label for active Caps Lock key")
            : (isTextShiftEnabled
                ? NSLocalizedString("Shift on", comment: "Accessibility label for active Shift key")
                : NSLocalizedString("Shift", comment: "Accessibility label for Shift key"))
    }

    private func refreshLetterCasing() {
        guard !isSymbolKeyboard else { return }
        let autoCap = shouldAutoCapitalizeNextEnglishLetter()
        let nextSnapshot = LetterCasingSnapshot(
            shift: isTextShiftEnabled,
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
        guard isTextShiftEnabled || isTextShiftLocked else { return }
        isTextShiftEnabled = false
        isTextShiftLocked = false
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
              currentBridgeStatus?.state != .recording
        else {
            return false
        }

        if textInputLanguage == .english {
            applyRimeState(rimeInput.commitComposition())
            let shouldCapitalize = isAlphabeticTextKey(character)
                && (isTextShiftEnabled || shouldAutoCapitalizeNextEnglishLetter())
            let output = shouldCapitalize
                ? character.uppercased()
                : character
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(output)
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
            applyRimeState(rimeInput.commitComposition())
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(character.uppercased())
            resetShiftIfSticky()
            renderRestyleSuggestionsIfIdle()
            return true
        }

        let processResult = rimeInput.processCharacterIfReady(
            character,
            asciiPunctuation: chinesePunctuationStyle == .english,
            asciiMode: false
        )
        switch processResult {
        case .notReady(let state) where state.errorMessage != nil:
            for queued in pendingRimeCharacters {
                clearRestyleUndoStateForManualEdit()
                textDocumentProxy.insertText(queued)
            }
            pendingRimeCharacters.removeAll()
            applyRimeState(state)
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(character)
            resetShiftIfSticky()
            renderRestyleSuggestionsIfIdle()
            return true
        case .notReady(let state):
            queuePendingRimeCharacter(character, state: state)
            return true
        case .processed(let state):
            applyRimeState(state)
            return true
        }
    }

    private func queuePendingRimeCharacter(_ character: String, state: RimeKeyboardState) {
        pendingRimeCharacters.append(character)
        if pendingRimeCharacters.count > 64 {
            pendingRimeCharacters.removeFirst(pendingRimeCharacters.count - 64)
        }
        applyRimeState(state)
    }

    private func applyReadyRimeStateOrRender(_ state: RimeKeyboardState) {
        guard state.isReady, !pendingRimeCharacters.isEmpty else {
            applyRimeState(state)
            return
        }

        let queuedCharacters = pendingRimeCharacters
        pendingRimeCharacters.removeAll()
        var replayState = state
        var unprocessed: ArraySlice<String> = []
        for (index, character) in queuedCharacters.enumerated() {
            replayState = rimeInput.processCharacter(
                character,
                asciiPunctuation: chinesePunctuationStyle == .english,
                asciiMode: false
            )
            if !replayState.isReady || replayState.errorMessage != nil {
                unprocessed = queuedCharacters[index...]
                break
            }
        }
        applyRimeState(replayState)
        for character in unprocessed {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(character)
        }
    }

    private func handleTextBackspace() {
        guard keyboardFocus == .text else {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            return
        }
        // Recording locks regular keys; only space (stop-and-send) is live.
        if currentBridgeStatus?.state == .recording { return }

        if !pendingRimeCharacters.isEmpty {
            beginTextTouchCorrectionFromBackspace(compositionActive: true)
            pendingRimeCharacters.removeLast()
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
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            renderRestyleSuggestionsIfIdle()
        }
    }

    private func handleTextSpace() {
        guard keyboardFocus == .text else {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(" ")
            return
        }

        // Space ends an in-progress text-keyboard dictation (replaces the
        // tap-toggle mic; the user types and stays on the keys).
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            cancelScheduledStop()
            tapRecordingActive = false
            showTextKeyboardNotice(NSLocalizedString("Transcribing", comment: "Inline status after stopping dictation"))
            sendBridgeCommand(.stop)
            return
        }

        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()

        if textInputLanguage == .english {
            applyRimeState(rimeInput.commitComposition())
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(" ")
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
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
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(" ")
        }
        resetShiftIfSticky()
    }

    private func handleTextReturn() {
        guard keyboardFocus == .text else {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText("\n")
            return
        }
        if currentBridgeStatus?.state == .recording { return }

        let currentState = rimeInput.state()
        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()
        if textInputLanguage == .english {
            if currentState.isComposing {
                applyRimeState(rimeInput.clearComposition())
            }
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText("\n")
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            return
        }

        let state = currentState.isComposing ? rimeInput.commitRawInput() : currentState
        applyRimeState(state)
        if state.commitText.isEmpty {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText("\n")
        }
        if !resetShiftIfSticky() {
            refreshEnglishLetterCasingIfNeeded()
        }
    }

    private func applyRimeState(_ state: RimeKeyboardState) {
        if !state.commitText.isEmpty {
            acceptPendingTextTouchIfSurvived()
            resetQuoteParity()
            clearRestyleUndoStateForManualEdit()
            commitTextReplacingMarkedText(state.commitText)
            activeMarkedText = ""
            activeMarkedTextOwner = nil
        }

        let composingText = state.isComposing ? (state.preedit.isEmpty ? state.input : state.preedit) : ""
        if composingText.isEmpty {
            clearMarkedText(ifOwnedBy: .rimeComposition)
        } else {
            replaceMarkedText(composingText, owner: .rimeComposition)
        }

        renderRimeState(state)
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
            addCandidateStatus(NSLocalizedString("Chinese preparing…", comment: "Rime preparing status"), color: .secondaryLabel, emphasized: true)
            return
        }

        guard !state.candidates.isEmpty else {
            renderCandidateGrid(state)
            return
        }

        // iOS-native top bar: ALL candidates render here and the user scrolls
        // horizontally. The expanded panel (chevron-down) lays the same list
        // out vertically. We do NOT cap by "what fits visually" because that
        // hides anything beyond the first screen of candidates with no way
        // to reach them except via expand.
        for index in state.candidates.indices {
            let candidate = state.candidates[index]
            let button = reusableCandidateButton(at: index)
            configureCandidateButton(
                button,
                candidate: candidate,
                displayIndex: index,
                selectionIndex: state.candidateOffset + index
            )
            addCandidateArrangedView(button)
        }
        // Trailing flexible spacer absorbs unused width when candidate total
        // width is less than the scroll view's frame width. Must be last in
        // the stack — `resetCandidateStackForReuse` hides everything, and we
        // re-add the spacer here so it ends up after all candidates.
        addCandidateArrangedView(candidateTrailingSpacer)
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
        candidateStack.arrangedSubviews.forEach { view in
            candidateStack.removeArrangedSubview(view)
            view.isHidden = true
        }
    }

    private func addCandidateArrangedView(_ view: UIView) {
        view.isHidden = false
        candidateStack.addArrangedSubview(view)
    }

    private func updateCandidateToolbarControls(for state: RimeKeyboardState) {
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
        textUndoButton.isHidden = !showAllIdleIcons
        textKeyboardSwitchButton.isHidden = !showAllIdleIcons
        textHostSettingsButton.isHidden = !showAllIdleIcons || isRunningInsideHostApp
    }

    private func updateCandidateScrollViewport() {
        candidateScrollView.contentInset.right = 0
        candidateScrollView.horizontalScrollIndicatorInsets.right = 0
        candidateScrollView.layer.mask = nil
    }

    private var isRunningInsideHostApp: Bool {
        currentTextHostBundleID == Self.containingAppBundleIdentifier
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
            let bottom = min(max(frame.maxY, toolbarFrame.maxY + 20), keyRowsFrame.minY - 2)
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
        let buttonHeight = min(Self.candidateGridRowHeight, max(44, gridFrame.height))
        candidateGridCollapseButton.frame = CGRect(
            x: max(view.bounds.minX, view.bounds.maxX - Self.candidateExpandButtonWidth),
            y: gridFrame.minY,
            width: Self.candidateExpandButtonWidth,
            height: buttonHeight
        )
        view.bringSubviewToFront(candidateGridCollapseButton)
        view.bringSubviewToFront(keyPreviewBubble)
    }

    private func updateKeyboardOverlayOrdering() {
        view.bringSubviewToFront(keyboardContentView)
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
        let maxColumnCount = candidateGridColumnCount(for: availableWidth)
        var currentRow: UIStackView?
        var currentRowButtons: [UIButton] = []
        var currentRowWidths: [CGFloat] = []
        var usedWidth: CGFloat = 0
        var didAddRow = false

        func finishCurrentRow() {
            guard let row = currentRow else { return }
            equalizeCandidateGridRowIfNeeded(row, buttons: currentRowButtons, naturalWidths: currentRowWidths, availableWidth: availableWidth)
            addCandidateGridTrailingSpacer(to: row)
            currentRow = nil
            currentRowButtons.removeAll()
            currentRowWidths.removeAll()
            usedWidth = 0
        }

        for index in state.candidates.indices {
            let candidate = state.candidates[index]
            let cellWidth = min(candidateGridNaturalCellWidth(for: candidate), availableWidth)
            if currentRow != nil,
               currentRowButtons.count >= maxColumnCount || usedWidth + cellWidth > availableWidth + 0.5 {
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
                selectionIndex: state.candidateOffset + index,
                width: cellWidth
            )
            currentRow?.addArrangedSubview(button)
            currentRowButtons.append(button)
            currentRowWidths.append(cellWidth)
            usedWidth += cellWidth
        }

        // Trailing spacer keeps each row left-aligned instead of stretching
        // the final cells to fill remaining width.
        finishCurrentRow()
        candidateGridScrollView.setContentOffset(.zero, animated: false)
    }

    private func candidateGridContentWidth() -> CGFloat {
        let fullWidth = candidateGridScrollView.bounds.width > 0
            ? candidateGridScrollView.bounds.width
            : view.bounds.width - Self.rootHorizontalInset * 2
        let nativeActionLeft = view.bounds.width > 0
            ? view.bounds.width - Self.candidateExpandButtonWidth - Self.rootHorizontalInset
            : fullWidth - Self.candidateExpandButtonWidth
        return min(fullWidth, max(140, nativeActionLeft))
    }

    private func candidateGridColumnCount(for available: CGFloat) -> Int {
        max(1, Int((available / Self.candidateGridPreferredCellWidth).rounded()))
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

    private func equalizeCandidateGridRowIfNeeded(
        _ row: UIStackView,
        buttons: [UIButton],
        naturalWidths: [CGFloat],
        availableWidth: CGFloat
    ) {
        guard !buttons.isEmpty else { return }
        let evenWidth = availableWidth / CGFloat(buttons.count)
        if naturalWidths.allSatisfy({ $0 <= evenWidth + 0.5 }) {
            for button in buttons {
                button.constraints
                    .filter { $0.firstAttribute == .width && $0.firstItem === button }
                    .forEach { $0.constant = evenWidth }
            }
        }
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
        // hit bands.
        button.isUserInteractionEnabled = false
        button.heightAnchor.constraint(equalToConstant: Self.candidateGridRowHeight).isActive = true
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Match iOS native: the expanded panel is visually uniform — no
        // first-cell highlight, no per-cell border. Use an attributed title
        // so the paragraph style sticks (UIButton.Configuration overrides
        // titleLabel settings on every layout pass).
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: candidateFont(weight: .regular),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(NSAttributedString(string: candidate.text, attributes: attributes))
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        configuration.background.backgroundColor = .clear
        configuration.contentInsets = .zero
        button.configuration = configuration
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: candidateFont(weight: .regular),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(NSAttributedString(string: candidate.text, attributes: attributes))
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.subtitle = nil
        configuration.cornerStyle = .fixed
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        configuration.background.cornerRadius = 0
        configuration.background.backgroundColor = .clear
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        candidateButtonWidthConstraints[displayIndex].constant = candidateButtonMinimumWidth(for: candidate)
    }

    @objc private func candidateButtonTapped(_ sender: UIButton) {
        pendingTextTouchCorrection = nil
        acceptPendingTextTouchIfSurvived()
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

    private func renderRestyleSuggestionsIfIdle() {
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

    private func showTextKeyboardNotice(_ text: String, color: UIColor = .secondaryLabel) {
        guard keyboardFocus == .text else { return }
        setCandidateGridExpanded(false)
        resetCandidateStackForReuse()
        addCandidateStatus(text, color: color, emphasized: true)
        candidateScrollView.setContentOffset(.zero, animated: false)
    }

    private func replaceMarkedText(_ text: String, owner: MarkedTextOwner? = nil) {
        let nextOwner = text.isEmpty ? nil : owner
        guard activeMarkedText != text || activeMarkedTextOwner != nextOwner else { return }
        if !text.isEmpty {
            let cursor = (text as NSString).length
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: cursor, length: 0))
        } else if !activeMarkedText.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        }
        activeMarkedText = text
        activeMarkedTextOwner = nextOwner
    }

    private func clearMarkedText(ifOwnedBy owner: MarkedTextOwner) {
        guard activeMarkedTextOwner == owner else { return }
        replaceMarkedText("")
    }

    private func commitTextReplacingMarkedText(_ text: String) {
        guard !text.isEmpty else { return }
        guard !activeMarkedText.isEmpty else {
            textDocumentProxy.insertText(text)
            return
        }
        let cursor = (text as NSString).length
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: cursor, length: 0))
        textDocumentProxy.unmarkText()
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

        var crossedLineBreak = false
        for character in context.reversed() {
            let text = String(character)
            if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                if text.rangeOfCharacter(from: .newlines) != nil {
                    crossedLineBreak = true
                }
                continue
            }
            if crossedLineBreak {
                return AutocapDecision(outcome: true, reason: "sentences-after-newline")
            }
            let isSentenceEnd = ".!?。？！".contains(character)
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

    private func shouldInsertDirectChinesePunctuation(_ character: String) -> Bool {
        guard textInputLanguage == .chinese,
              !isAlphabeticTextKey(character)
        else { return false }
        if isSymbolKeyboard { return true }
        guard chinesePunctuationStyle == .chinese,
              isChinesePunctuationContext
        else { return false }
        return ",.?!:;()\"'/\\|`~$^_<>-[]{}#%&*+=@€£¥•".contains(character)
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

    private func insertChineseDirectTextKey(_ character: String) {
        let currentState = rimeInput.state()
        if currentState.isComposing {
            if let quickSelectIndex = quickCandidateIndex(for: character),
               quickSelectIndex < currentState.candidates.count {
                applyRimeState(rimeInput.selectCandidate(at: currentState.candidateOffset + quickSelectIndex))
                return
            }
            if isRimeCompositionControlKey(character) {
                applyRimeState(
                    rimeInput.processCharacter(
                        character,
                        asciiPunctuation: chinesePunctuationStyle == .english,
                        asciiMode: false
                    )
                )
                return
            }
            applyRimeState(rimeInput.commitComposition())
        } else {
            replaceMarkedText("")
        }
        if shouldInsertDirectChinesePunctuation(character) {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(chineseDirectText(for: character))
            resetShiftIfSticky()
            renderRestyleSuggestionsIfIdle()
            return
        }
        let state = rimeInput.processCharacter(
            character,
            asciiPunctuation: chinesePunctuationStyle == .english,
            asciiMode: false
        )
        applyRimeState(state)
        if state.commitText.isEmpty, !state.isComposing {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.insertText(chineseDirectText(for: character))
        }
        resetShiftIfSticky()
        renderRestyleSuggestionsIfIdle()
    }

    private func quickCandidateIndex(for character: String) -> Int? {
        guard character.count == 1,
              let value = Int(character)
        else { return nil }
        switch value {
        case 1...9: return value - 1
        case 0: return 9
        default: return nil
        }
    }

    private func isRimeCompositionControlKey(_ character: String) -> Bool {
        character == "," || character == "." || character == "-" || character == "="
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
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            return
        }
        clearRestyleUndoStateForManualEdit()
        deleteBackward(characterCount: count)
    }

    private func deleteBackwardToLineBoundary() {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let count = deletionCountToLineBoundary(in: context)
        guard count > 0 else {
            clearRestyleUndoStateForManualEdit()
            textDocumentProxy.deleteBackward()
            return
        }
        clearRestyleUndoStateForManualEdit()
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
                applyRimeState(rimeInput.commitComposition())
            }
            lightHaptic()
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
        renderRestyleSuggestionsIfIdle()
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.74)
    }

    private var currentBridgeStatus: KeyboardBridgeStatus? {
        bridgeStatus
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

    private func showFullAccessRequiredStatus(showTextNotice: Bool = false) {
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.fullAccessRequired)
        bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
        lastBridgeContactAt = Date().timeIntervalSince1970
        if showTextNotice {
            showTextKeyboardNotice(NSLocalizedString("Enable Full Access", comment: "Inline status when keyboard full access is missing"))
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
        // `sessionStarted` is a durable handoff from the containing app: once
        // host has prepared the background audio session, it will post
        // `sessionEnded` when that session is explicitly torn down. Do not
        // expire the visible Ready state after a few seconds, because the
        // containing app can be backgrounded and reject localhost status probes.
        // `.result` and `.sending` only exist because the host bridge actively
        // produced them, so they're durable too — falling back to a slow probe
        // after a freshly finished dictation just to confirm what we already
        // know was the most common source of the 2s mic-press latency.
        switch status.state {
        case .standby, .recording, .result, .sending:
            return true
        default:
            return false
        }
    }

    /// One short line, under the orb. Doubles as the only verbal hint — the
    /// orb's color and pulse rings carry the rest of the state.
    private var voiceTitle: String {
        if !hasFullAccess { return NSLocalizedString("Enable Full Access", comment: "Voice title when keyboard full access is missing") }
        if isOpeningHostApp { return NSLocalizedString("Opening Typeforme…", comment: "Voice title when host is launching") }
        switch currentBridgeStatus?.state {
        case .recording: return inputMode.recordingTitle
        case .sending: return sendingStatusTitle
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
        case .sending: return "hourglass"
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

    private var statusColor: UIColor {
        if !hasFullAccess { return .systemOrange }
        if isOpeningHostApp { return .systemBlue }
        guard isBridgeAwake else { return .systemGray3 }
        switch currentBridgeStatus?.state {
        case .standby, .result: return .systemGreen
        case .recording: return .systemRed
        case .sending: return .systemBlue
        case .error: return .systemOrange
        default: return .systemGray3
        }
    }

    /// Top-left status pill is a *bridge session indicator*: a coarse-grained
    /// view of where the keyboard session is in its lifecycle (Ready /
    /// Recording / Sending / Inserted / Issue). The granular per-stage label
    /// (Transcribing / Refining / …) lives on the voice orb title and the
    /// text-toolbar status overlay so the two surfaces don't duplicate.
    private var statusText: String {
        if !hasFullAccess {
            return NSLocalizedString("Full Access", comment: "Status when keyboard full access is missing")
        }
        if isOpeningHostApp {
            return NSLocalizedString("Opening", comment: "Status while host opens")
        }
        let ready = NSLocalizedString("Ready", comment: "Status idle/standby")
        if !isBridgeAwake { return ready }
        guard let status = currentBridgeStatus else { return ready }
        switch status.state {
        case .standby:
            return ready
        case .recording:
            return NSLocalizedString("Recording", comment: "Status active recording")
        case .sending:
            return NSLocalizedString("Transcribing", comment: "Status during transcription/sending")
        case .result:
            return NSLocalizedString("Inserted", comment: "Status after result inserted")
        case .error:
            return isBridgeAwake
                ? NSLocalizedString("Issue", comment: "Status when bridge errored")
                : ready
        case .idle:
            return ready
        }
    }

    private var sendingStatusTitle: String {
        // The host publishes the curated stage label (Transcribing / Refining /
        // Inserted / error text) directly in `status.message`, so show it
        // verbatim — no inference, no rewriting.
        let message = currentBridgeStatus?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty { return message }
        return NSLocalizedString("Transcribing", comment: "Bridge job stage")
    }

    private func syncKeyboardSettingsToHost() {
        guard hasFullAccess, isBridgeAwake else { return }
        sendBridgeCommand(.configure)
    }

    private func sendBridgeCommand(_ action: KeyboardBridgeCommandAction) {
        let commandID: String
        if (action == .stop || action == .cancel),
           let activeCommandID = activeRecordingCommandID ?? activeRecordingTextTarget?.commandID {
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
            if action == .start || action == .stop || action == .cancel {
                sendLocalBridgeCommand(command)
                return
            }
            sendDarwinBridgeCommand(action, commandID: command.id)
            return
        }

        sendLocalBridgeCommand(command)
    }

    private func sendLocalBridgeCommand(_ command: KeyboardBridgeCommand) {
        if command.action == .start || command.action == .stop || command.action == .cancel {
            if command.action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if command.action == .stop || command.action == .cancel {
                tapRecordingActive = false
                isCommandPressActive = false
                if command.action == .stop {
                    pendingStopCommandID = command.id
                }
            }
            if command.action == .cancel {
                pendingStopCommandID = nil
                activeRecordingCommandID = nil
                activeRecordingTextTarget = nil
                cancelScheduledHostOpen()
            }
            bridgeStatus = KeyboardBridgeStatus(
                commandID: command.id,
                state: command.action == .start ? .standby : (command.action == .cancel ? .standby : .sending),
                message: command.action == .start ? "Starting recording" : (command.action == .cancel ? "Ready" : "Transcribing")
            )
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
                    if command.action == .start {
                        self.finishStartRequestIfNeeded(status: status)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.bridgeCommandTasks[command.id] = nil
                    if command.action == .stop || command.action == .cancel {
                        self.sendDarwinBridgeCommand(command.action, commandID: command.id)
                        return
                    }
                    if command.action == .start {
                        if command.textEditContext == nil {
                            self.sendDarwinBridgeCommand(.start, commandID: command.id)
                            return
                        }
                        self.isStartRequestInFlight = false
                        self.activeRecordingTextTarget = nil
                        self.openHostForDictation()
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
        if action == .start || action == .stop {
            if action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if action == .stop {
                tapRecordingActive = false
                isCommandPressActive = false
                pendingStopCommandID = commandID
            }
            bridgeStatus = KeyboardBridgeStatus(
                commandID: commandID,
                state: action == .start ? .standby : .sending,
                message: action == .start ? "Starting recording" : "Transcribing"
            )
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        switch action {
        case .start:
            if postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestStartDictation) {
                scheduleHostOpenIfStartStalls()
            } else {
                isStartRequestInFlight = false
                openHostForDictation()
            }
        case .stop:
            if !postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestStopDictation) {
                pendingStopCommandID = nil
                bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Open Typeforme once to prepare dictation.")
                lastBridgeContactAt = 0
                updateUI()
            }
        case .cancel:
            tapRecordingActive = false
            pendingStopCommandID = nil
            activeRecordingCommandID = nil
            activeRecordingTextTarget = nil
            cancelScheduledHostOpen()
            _ = postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestCancelDictation)
        case .configure, .restyleText:
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
        isStartRequestInFlight = false
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        isVoicePressActive = false
        isCommandPressActive = false
        tapRecordingActive = false
        activeRecordingCommandID = nil
        pendingStopCommandID = nil
    }

    private func scheduleHostOpenIfStartStalls() {
        cancelScheduledHostOpen()
        let delay: UInt64 = currentBridgeStatus?.state == .standby
            ? 2_500_000_000
            : 650_000_000
        scheduledHostOpenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard let self else { return }
                guard self.isStartRequestInFlight,
                      self.currentBridgeStatus?.state != .recording,
                      !self.isOpeningHostApp
                else { return }
                self.isStartRequestInFlight = false
                self.openHostForDictation()
            }
        }
    }

    private func cancelScheduledHostOpen() {
        scheduledHostOpenTask?.cancel()
        scheduledHostOpenTask = nil
        cancelHostBundleWakeFallback()
    }

    private func cancelStartupHostWake() {
        startupHostWakeTask?.cancel()
        startupHostWakeTask = nil
    }

    private func cancelBridgeCommandTasks() {
        bridgeCommandTasks.values.forEach { $0.cancel() }
        bridgeCommandTasks.removeAll()
    }

    private func startStatusPolling(interval: TimeInterval = 0.35) {
        stopStatusPolling()
        statusTimerInterval = interval
        statusTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshBridgeStatus()
        }
        if let statusTimer {
            RunLoop.current.add(statusTimer, forMode: .common)
        }
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
        statusTimerInterval = 0
    }

    private func cancelStatusRefresh() {
        statusRefreshGeneration &+= 1
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        statusRefreshStartedAt = 0
    }

    private func statusPollingInterval(for state: KeyboardBridgeState?) -> TimeInterval {
        switch state {
        case .some(.recording), .some(.sending):
            // Host stages can move Recording → Transcribing → Result in a few
            // hundred ms; keep this cadence fast enough not to skip feedback.
            return Self.fastStatusPollingInterval
        case .some(.idle), .some(.standby):
            return Self.idleStatusPollingInterval
        case .some(.result), .some(.error), .none:
            return Self.activeStatusPollingInterval
        }
    }

    private func scheduleDeferredStartupProbe() {
        deferredStartupWorkItem?.cancel()
        hasPresentedInitialFrame = false
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.view.window != nil else { return }
            let needsHostBootstrap = self.hasFullAccess && KeyboardSharedDefaults.loadPayload() == nil
            self.startStatusPolling()
            self.refreshBridgeStatus(captureSelection: false)
            self.postAuthenticatedKeyboardRequest(KeyboardDarwinNotificationName.requestSessionStatus)
            if needsHostBootstrap {
                self.scheduleStartupHostWakeIfNeeded(reason: "missing defaults", delay: 1.0)
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

    private func scheduleStartupHostWakeIfNeeded(reason: String, delay: TimeInterval) {
        guard hasFullAccess else { return }
        guard !isBridgeAwake, !isOpeningHostApp else { return }
        cancelStartupHostWake()
        startupHostWakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.startupHostWakeTask = nil
                guard self.view.window != nil,
                      self.hasFullAccess,
                      !self.isBridgeAwake,
                      !self.isOpeningHostApp,
                      !self.isStartRequestInFlight,
                      self.currentBridgeStatus?.state != .recording,
                      self.currentBridgeStatus?.state != .sending
                else { return }
                kbLog.notice("startup wake: opening host for standby reason=\(reason, privacy: .public)")
                self.openStandbyInHostApp(returnToKeyboard: false, allowBundleFallback: false)
            }
        }
    }

    private func refreshBridgeStatus(captureSelection: Bool = true) {
        guard hasFullAccess else {
            cancelStatusRefresh()
            return
        }
        let now = Date().timeIntervalSince1970
        if statusRefreshTask != nil {
            guard now - statusRefreshStartedAt >= Self.statusRefreshStaleTimeout else { return }
            cancelStatusRefresh()
        }
        if captureSelection {
            refreshSelectionSnapshot()
        }
        let bridgeToken = hostKeyboardBridgeToken
        statusRefreshGeneration &+= 1
        let generation = statusRefreshGeneration
        statusRefreshStartedAt = now
        statusRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.status(bridgeToken: bridgeToken)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.statusRefreshGeneration == generation
                    else { return }
                    self.statusRefreshTask = nil
                    self.statusRefreshStartedAt = 0
                    self.applyBridgeStatus(status)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.statusRefreshGeneration == generation
                    else { return }
                    self.statusRefreshTask = nil
                    self.statusRefreshStartedAt = 0
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
    }

    private func beginInsertedFlash() {
        insertedFlashClearTask?.cancel()
        insertedFlashUntil = Date().timeIntervalSince1970 + Self.insertedFlashDuration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.insertedFlashUntil = 0
            self.updateUI(animated: false)
        }
        insertedFlashClearTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.insertedFlashDuration, execute: work)
    }

    private func applyBridgeStatus(_ status: KeyboardBridgeStatus) {
        if shouldIgnoreStaleIdleStatus(status) {
            return
        }
        if shouldIgnoreStaleResultStatus(status) {
            return
        }
        if shouldIgnoreRecordingStatusAfterStop(status) {
            return
        }
        if isStartRequestInFlight && status.state == .standby {
            return
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
        }
        if status.state == .result, currentBridgeStatus?.state != .result, keyboardFocus == .text {
            beginInsertedFlash()
        }
        // Live partial preview (Apple Speech on the host) owns only the marked
        // text it created. Rime composition also uses marked text; bridge idle
        // polls must not clear the user's in-progress Pinyin preedit.
        let partial = status.livePartialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showsPartial = (status.state == .recording || status.state == .sending) && !partial.isEmpty
        if showsPartial {
            replaceMarkedText(partial, owner: .livePartial)
        } else if status.state != .result, activeMarkedTextOwner == .livePartial {
            // .result is handled below — don't clear here or the commit step
            // would have no marked text to replace.
            replaceMarkedText("")
        }
        bridgeStatus = status
        lastBridgeContactAt = Date().timeIntervalSince1970
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
            } else if activeRecordingTextTarget != nil {
                didApply = false
                appliedRewriteTarget = nil
            } else {
                // commitTextReplacingMarkedText handles both cases: if marked
                // text is active (live partial), it's atomically replaced by
                // `text` and committed; if not, it falls through to a plain
                // insertText. activeMarkedText must be reset by the caller.
                commitTextReplacingMarkedText(text)
                activeMarkedText = ""
                activeMarkedTextOwner = nil
                didApply = true
                appliedRewriteTarget = nil
            }
            if didApply {
                if let appliedRewriteTarget {
                    recordRestyleUndoState(originalTarget: appliedRewriteTarget, rewrittenText: text)
                } else {
                    restyleUndoState = nil
                }
                defaults.set(commandID, forKey: lastInsertedCommandIDKey)
                defaults.set(text, forKey: lastInsertedTextKey)
                recentSelectionTarget = nil
            } else {
                defaults.set(commandID, forKey: lastInsertedCommandIDKey)
                defaults.set(text, forKey: lastInsertedTextKey)
                copyFallbackText(text)
                bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Selection changed; result copied.")
            }
        }

        if status.state == .error || status.state == .idle {
            activeRecordingTextTarget = nil
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
                    kbLog.notice("recording status has no audioLevel; using local voiceprint animation")
                }
            } else {
                lastMissingAudioLevelLogAt = 0
            }
        }

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

    private func shouldIgnoreRecordingStatusAfterStop(_ status: KeyboardBridgeStatus) -> Bool {
        guard status.state == .recording,
              let pendingStopCommandID
        else { return false }
        guard status.commandID == nil || status.commandID == pendingStopCommandID else {
            return false
        }
        return true
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

    deinit {
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
    private static let fullConfidenceSamples = 24.0
    private static let minimumDecisionSamples = 5.0
    private static let decisionMargin = 0.28
    private static let correctionWeight = 3.0
    private static let acceptedWeight = 1.0
    private static let sigmaX = 0.34
    // Horizontal pairs usually share midY, but each key can learn a different
    // vertical mean; keep sigmaY active for that bias and future row-adjacent routing.
    private static let sigmaY = 0.70
    private static let maxObservationX = 0.75
    private static let maxObservationY = 0.75
    private static let maxMeanX = 0.34
    private static let maxMeanY = 0.28
    private static let persistDebounceInterval: TimeInterval = 0.5
    private static let persistSampleBatchSize = 5

    private let defaults: UserDefaults
    private let storageKey: String
    private var state: StoredState
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var dirtySampleCount = 0

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
        dirtySampleCount = 0
        state = StoredState(version: Self.storageVersion, keys: [:])
        defaults.removeObject(forKey: storageKey)
    }

    func flush() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        persistIfNeeded()
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
            min: -Self.maxMeanX,
            max: Self.maxMeanX
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

    private func score(offset: (x: Double, y: Double), stats: KeyStats?) -> Double {
        let confidence = min(1, (stats?.sampleCount ?? 0) / Self.fullConfidenceSamples)
        let meanX = Self.clamp((stats?.meanX ?? 0) * confidence, min: -Self.maxMeanX, max: Self.maxMeanX)
        let meanY = Self.clamp((stats?.meanY ?? 0) * confidence, min: -Self.maxMeanY, max: Self.maxMeanY)
        let dx = offset.x - meanX
        let dy = offset.y - meanY
        return -((dx * dx) / (2 * Self.sigmaX * Self.sigmaX)
            + (dy * dy) / (2 * Self.sigmaY * Self.sigmaY))
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
            flush()
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

/// Backing surface for blank keyboard areas. The owning controller paints it
/// with `keyboardTouchableBackgroundColor` (0.01 alpha); do not make it
/// `.clear`. iOS custom keyboards also consider rendered pixel alpha for
/// hit-test eligibility, so `point(inside:)` alone is not enough to stop gap
/// touches from leaking to the host app.
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
        let textKeySequence: UInt64?
    }

    private var activeTouches: [UITouch: ActiveKeyboardTouch] = [:]
    private var pendingEndedTextKeyPoints: [UITouch: CGPoint] = [:]
    private var nextTextKeySequence: UInt64 = 0
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
        case .textKey, .focusSurface:
            pendingActivationTarget = target
            pendingActivationPoint = controllerPoint
            pendingActivationResolvedAt = CACurrentMediaTime()
            return self
        case .candidateAction, .none:
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
            let sequence: UInt64?
            if case .textKey = target {
                sequence = nextTextKeySequence
                nextTextKeySequence += 1
            } else {
                sequence = nil
            }
            activeTouches[touch] = ActiveKeyboardTouch(
                target: target,
                startPoint: controllerPoint,
                textKeySequence: sequence
            )
            hitController.beginKeyboardTouchTarget(target, point: controllerPoint)
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
            hitController.logKeyboardTouchEvent(
                "swipe",
                target: active.target,
                point: controllerPoint,
                intent: horizontalIntent
            )
            hitController.switchKeyboardFocusFromFallbackSwipe(deltaX: horizontalIntent)
            pendingEndedTextKeyPoints.removeValue(forKey: touch)
            activeTouches.removeValue(forKey: touch)
            flushEndedTextKeyTouches()
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
            if active.textKeySequence != nil {
                pendingEndedTextKeyPoints[touch] = point
            } else {
                hitController.commitKeyboardTouchTarget(active.target, point: point)
                activeTouches.removeValue(forKey: touch)
                lastTouchCommitTime = CACurrentMediaTime()
            }
            handledAnyTouch = true
        }
        flushEndedTextKeyTouches()
        if !handledAnyTouch {
            super.touchesEnded(touches, with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let hitController else {
            activeTouches.removeAll()
            pendingEndedTextKeyPoints.removeAll()
            super.touchesCancelled(touches, with: event)
            return
        }

        var handledAnyTouch = false
        for touch in orderedTouches(touches) {
            guard let active = activeTouches[touch] else { continue }
            hitController.cancelKeyboardTouchTarget(active.target, point: touch.location(in: hitController.view))
            pendingEndedTextKeyPoints.removeValue(forKey: touch)
            activeTouches.removeValue(forKey: touch)
            handledAnyTouch = true
        }
        flushEndedTextKeyTouches()
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
        hitController.beginKeyboardTouchTarget(target, point: point)
        hitController.commitKeyboardTouchTarget(target, point: point)
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

    private func flushEndedTextKeyTouches() {
        guard let hitController else { return }

        while let next = nextEndedTextKeyReadyToCommit() {
            hitController.commitTextKeyTouchWithDragRescue(
                activeTarget: next.active.target,
                startPoint: next.active.startPoint,
                endPoint: next.point
            )
            pendingEndedTextKeyPoints.removeValue(forKey: next.touch)
            activeTouches.removeValue(forKey: next.touch)
            lastTouchCommitTime = CACurrentMediaTime()
        }
    }

    private func nextEndedTextKeyReadyToCommit() -> (touch: UITouch, active: ActiveKeyboardTouch, point: CGPoint)? {
        let endedTouches = activeTouches.compactMap { touch, active -> (touch: UITouch, active: ActiveKeyboardTouch, point: CGPoint)? in
            guard active.textKeySequence != nil,
                  let point = pendingEndedTextKeyPoints[touch]
            else { return nil }
            return (touch, active, point)
        }
        guard let next = endedTouches.min(by: { lhs, rhs in
            (lhs.active.textKeySequence ?? 0) < (rhs.active.textKeySequence ?? 0)
        }) else { return nil }
        guard let nextSequence = next.active.textKeySequence else { return nil }

        let hasOlderUnendedTextKey = activeTouches.contains { touch, active in
            guard let sequence = active.textKeySequence,
                  sequence < nextSequence
            else { return false }
            return pendingEndedTextKeyPoints[touch] == nil
        }
        return hasOlderUnendedTextKey ? nil : next
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
        pendingEndedTextKeyPoints.removeValue(forKey: existing.key)
        activeTouches.removeValue(forKey: existing.key)
        flushEndedTextKeyTouches()
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
