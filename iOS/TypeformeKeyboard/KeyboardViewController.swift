import UIKit
import Darwin
import ObjectiveC
import OSLog

private let kbLog = Logger(subsystem: "com.typeforme.keyboard", category: "ui")

private typealias CorrectionModePreset = CorrectionMode

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

final class KeyboardViewController: UIInputViewController, UIScrollViewDelegate {
    private enum CapsuleStyle {
        case chrome
        case key
        case utility
    }

    private enum KeyboardFocus: String {
        case voice
        case text
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

    private enum ChinesePunctuationStyle: String {
        case chinese
        case english
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

    private let defaults = UserDefaults.standard
    private let localClient = KeyboardLocalClient()
    private let inputModeKey = "keyboard.inputMode"
    private let keyboardFocusKey = "keyboard.focus"
    private let textInputLanguageKey = "keyboard.textInputLanguage"
    private let lastInsertedTextKey = "keyboard.lastInsertedText"
    private let lastInsertedCommandIDKey = "keyboard.lastInsertedCommandID"
    private let keyboardDefaultsPasteboardName = UIPasteboard.Name("com.typeforme.keyboard.defaults")

    private var correctionMode: CorrectionModePreset = .polish
    private var inputMode: VoiceInputMode = .hold
    private var keyboardFocus: KeyboardFocus = .voice
    private var textInputLanguage: TextInputLanguage = .chinese
    private var isSymbolKeyboard = false
    private var isAlternateSymbolKeyboard = false
    private var isAutoCapitalizationEnabled = true
    private var isCharacterPreviewEnabled = true
    private var chinesePunctuationStyle: ChinesePunctuationStyle = .chinese
    private let rimeInput = RimeInputController()
    private var activeMarkedText = ""
    private var heightConstraint: NSLayoutConstraint?
    private var statusTimer: Timer?
    private var statusTimerInterval: TimeInterval = 0
    private var lastStatusSignature = ""
    private var lastMissingAudioLevelLogAt: TimeInterval = 0
    private var bridgeStatus: KeyboardBridgeStatus?
    private var lastBridgeContactAt: TimeInterval = 0
    private var openingHostUntil: TimeInterval = 0
    private var appliedKeyboardInterfaceStyle: UIUserInterfaceStyle?
    private var lastCorrectionModeButtonSignature = ""
    private var hasPresentedInitialFrame = false
    private var isVoicePressActive = false
    /// Hold-mode "release-to-cancel" zone: set when the user drags the
    /// finger off the orb mid-press, cleared if they drag back in. Lift
    /// while true => cancel; lift while false => commit.
    private var isVoicePressWillCancel = false
    private var voicePressBeganAt: TimeInterval = 0
    private var isStartRequestInFlight = false
    private var shouldStopWhenStartCompletes = false
    private var shouldCancelWhenStartCompletes = false
    private var tapRecordingActive = false
    private var isCommandPressActive = false
    private var activeRecordingTextTarget: TextRewriteTarget?
    private var recentSelectionTarget: TextRewriteTarget?
    private var recentSelectionCapturedAt: TimeInterval = 0
    private var styleRewriteCommandID: String?
    private var recentRestyleText: String?
    private var recentRestyleShownAt: TimeInterval = 0
    private var isTextSpaceCursorTracking = false
    private var textSpaceCursorStartX: CGFloat = 0
    private var suppressTextSpaceTapUntil: TimeInterval = 0
    private var scheduledHostOpenTask: Task<Void, Never>?
    private var scheduledStopTask: Task<Void, Never>?
    private var deleteRepeatTask: Task<Void, Never>?
    private var bridgeProbeTask: Task<Void, Never>?
    private var statusRefreshTask: Task<Void, Never>?
    private var deferredStartupWorkItem: DispatchWorkItem?
    private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    private let minimumHoldRecordingDuration: TimeInterval = 0.55
    private let minimumIntentReleaseDuration: TimeInterval = 0.28
    private let selectionSnapshotTTL: TimeInterval = 1.25
    private let restyleSuggestionTTL: TimeInterval = 45
    private static let dictationContextLimit = 600
    private static let textRewriteContextExpansionLimit = 2_000
    private static let textRewriteContextExpansionMaxSteps = 40
    private static let textSpaceCursorPointsPerCharacter: CGFloat = 9
    private let deleteRepeatInitialDelay: UInt64 = 450_000_000
    private let deleteRepeatInterval: UInt64 = 70_000_000

    private let rootStack = UIStackView()
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
    /// Smoothed audioLevel driving pulse-ring brightness — louder voice =
    /// brighter rings, visible at the orb's edges even when a finger covers
    /// the rest of the orb.
    private var smoothedAudioLevel: Float = 0
    private let voiceSpinner = UIActivityIndicatorView(style: .large)
    private let voiceTitleLabel = UILabel()
    private let inputModeSwitch = VoiceInputModeSwitch()
    private static let orbDiameter: CGFloat = 132
    private static let rootVerticalInset: CGFloat = 6
    private static let stackSpacing: CGFloat = 6
    private static let topRowHeight: CGFloat = 30
    private static let orbContainerHeight: CGFloat = 146
    private static let utilityRowHeight: CGFloat = 48
    private static let textKeyboardBodyHeight: CGFloat = 236
    private static var voiceContentHeight: CGFloat {
        rootVerticalInset * 2 + stackSpacing * 2 + topRowHeight + orbContainerHeight + utilityRowHeight
    }
    private static var textContentHeight: CGFloat {
        // Voice and text modes intentionally share the same extension height.
        // Changing only one side causes a visible host-app layout jump during
        // focus switches; update both modes together if the keyboard height
        // changes.
        voiceContentHeight
    }
    private static let topChromeCoverHeight: CGFloat = 0

    private let utilityRow = UIStackView()
    private let pasteButton = UIButton(type: .system)
    private let commandButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    private let textKeyboardContainer = UIStackView()
    private let textToolbar = UIStackView()
    private let textVoiceButton = UIButton(type: .system)
    private let textVoiceFocusButton = UIButton(type: .system)
    private let textSettingsButton = UIButton(type: .system)
    private let textToolsButton = UIButton(type: .system)
    private let textModeButton = UIButton(type: .system)
    private let textAlternateSymbolButton = UIButton(type: .system)
    private let textGlobeButton = UIButton(type: .system)
    private let textLanguageButton = UIButton(type: .system)
    private let textLanguageLabel = UILabel()
    private let compositionLabel = UILabel()
    private let pinyinBannerLabel = UILabel()
    private let quickCandidateRow = UIStackView()
    private let candidateScrollView = UIScrollView()
    private let candidateStack = UIStackView()
    private let keyRowsStack = UIStackView()
    private let keyPreviewBubble = UIView()
    private let keyPreviewLabel = UILabel()
    private lazy var textTrackpadPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTextTrackpadPan(_:)))
    private var textKeyboardButtons: [UIButton] = []
    private var letterButtonMap: [String: UIButton] = [:]
    private var reusableCandidateButtons: [UIButton] = []
    private var reusableCandidateButtonWidthConstraints: [NSLayoutConstraint] = []
    private var reusableCandidateSeparators: [UIView] = []
    private var reusableCandidateStatusLabels: [UILabel] = []
    private var reusableRestyleButtons: [CorrectionModePreset: UIButton] = [:]
    private let previousCandidatePageButton = UIButton(type: .system)
    private let nextCandidatePageButton = UIButton(type: .system)
    private var didConfigureCandidatePagerButtons = false
    private var activeCandidateSeparatorIndex = 0
    private var activeCandidateStatusLabelIndex = 0
    private var textRowLayoutConstraints: [NSLayoutConstraint] = []
    private var quickCandidateButtons: [UIButton] = []
    private weak var textReturnKeyButton: UIButton?
    private weak var textShiftButton: UIButton?
    private var lastReturnKeyTitle = ""
    private var isTextShiftEnabled = false
    private var doubleQuoteOpen = true
    private var singleQuoteOpen = true
    private weak var activeTrackpadSourceView: UIView?
    private var textTrackpadLastStepX = 0
    private var textTrackpadLastStepY = 0

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        configureSystemKeyboardAffordances()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSystemKeyboardAffordances()
    }

    override func loadView() {
        let rootView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        rootView.allowsSelfSizing = false
        rootView.isOpaque = false
        rootView.backgroundColor = .clear
        rootView.clipsToBounds = false
        rootView.layer.masksToBounds = false
        rootView.layer.backgroundColor = UIColor.clear.cgColor
        inputView = rootView
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSystemKeyboardAffordances()
        loadState()
        syncPrimaryLanguage()
        rimeInput.onStateChange = { [weak self] state in
            guard let self else { return }
            self.applyRimeState(state)
        }
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
        configureSystemKeyboardAffordances()
        refreshKeyboardPreferencesFromHost(rebuildIfNeeded: true)
        refreshInputModeSwitchKeyVisibility()
        heightConstraint?.constant = currentContentHeight + Self.topChromeCoverHeight
        resetCorrectionModeToDefault()
        prepareInitialLayoutForDisplay()
        // The current input scene's style isn't always settled by
        // `viewDidLoad`; pick up whatever's current right before display.
        refreshDynamicAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleDeferredStartupProbe()
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
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        bridgeProbeTask?.cancel()
        statusRefreshTask?.cancel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if keyboardFocus == .text {
            applyRimeState(rimeInput.commitComposition())
        }
        stopDeleteRepeat()
        clearTextShiftState()
        deferredStartupWorkItem?.cancel()
        deferredStartupWorkItem = nil
        bridgeProbeTask?.cancel()
        bridgeProbeTask = nil
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        cancelScheduledHostOpen()
        stopStatusPolling()
        voicePrint.isActive = false
        topRowVoicePrint.isActive = false
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
        if let raw = defaults.string(forKey: textInputLanguageKey),
           let saved = TextInputLanguage(rawValue: raw) {
            textInputLanguage = saved
        }
        refreshKeyboardPreferencesFromHost(rebuildIfNeeded: false)
        defaults.removeObject(forKey: "keyboard.pendingAutoStartUntil")
    }

    private func syncPrimaryLanguage() {
        primaryLanguage = textInputLanguage == .chinese ? "zh-Hans" : "en-US"
    }

    private func applyTextInputOptionsToRime() {
        _ = rimeInput.setAsciiPunctuation(chinesePunctuationStyle == .english)
        applyRimeState(rimeInput.setAsciiMode(textInputLanguage == .english))
    }

    private func resetCorrectionModeToDefault() {
        correctionMode = currentDefaultCorrectionMode()
        lastCorrectionModeButtonSignature = ""
    }

    private func applyDefaultCorrectionModeFromHost(_ rawValue: String?) {
        guard let rawValue,
              let defaultMode = CorrectionModePreset(rawValue: rawValue),
              correctionMode != defaultMode
        else { return }
        correctionMode = defaultMode
        lastCorrectionModeButtonSignature = ""
    }

    private func currentDefaultCorrectionMode() -> CorrectionModePreset {
        defaultCorrectionModeFromHost() ?? .polish
    }

    private func defaultCorrectionModeFromHost() -> CorrectionModePreset? {
        guard let raw = hostKeyboardDefaultsPayload()?["correction_mode"] as? String else {
            return nil
        }
        return CorrectionModePreset(rawValue: raw)
    }

    private func refreshKeyboardPreferencesFromHost(rebuildIfNeeded: Bool) {
        guard let payload = hostKeyboardDefaultsPayload() else { return }
        let previousAutoCapitalization = isAutoCapitalizationEnabled
        let previousCharacterPreview = isCharacterPreviewEnabled
        let previousPunctuationStyle = chinesePunctuationStyle

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

        guard rebuildIfNeeded else { return }
        let changed = previousAutoCapitalization != isAutoCapitalizationEnabled
            || previousCharacterPreview != isCharacterPreviewEnabled
            || previousPunctuationStyle != chinesePunctuationStyle
        guard changed else { return }

        if previousPunctuationStyle != chinesePunctuationStyle {
            applyTextInputOptionsToRime()
        }
        if keyboardFocus == .text {
            rebuildTextKeyboardRows()
        }
    }

    private func hostKeyboardDefaultsPayload() -> [String: Any]? {
        guard hasFullAccess,
              let pasteboard = UIPasteboard(name: keyboardDefaultsPasteboardName, create: false),
              let text = pasteboard.string,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload
    }

    private func configureRoot() {
        refreshKeyboardBackground()

        rootStack.axis = .vertical
        rootStack.spacing = Self.stackSpacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        heightConstraint = view.heightAnchor.constraint(equalToConstant: currentContentHeight + Self.topChromeCoverHeight)
        heightConstraint?.priority = .required
        heightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.rootVerticalInset + Self.topChromeCoverHeight),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.rootVerticalInset),
        ])
    }

    private func refreshKeyboardBackground() {
        // Keep the extension's own root transparent. UIInputView with
        // `.keyboard` style supplies the same system keyboard material that
        // iOS uses for the automatic bottom globe/safe-area region.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
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
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
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

    private var currentContentHeight: CGFloat {
        switch keyboardFocus {
        case .voice: return Self.voiceContentHeight
        case .text: return Self.textContentHeight
        }
    }

    @discardableResult
    private func applyKeyboardInterfaceStyle(force: Bool = false) -> Bool {
        let style = keyboardInterfaceStyle
        guard force || appliedKeyboardInterfaceStyle != style else { return false }
        appliedKeyboardInterfaceStyle = style
        lastCorrectionModeButtonSignature = ""
        let views: [UIView] = [
            rootStack,
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
            voiceTitleLabel,
            inputModeSwitch,
            utilityRow,
            pasteButton,
            spaceButton,
            deleteButton,
            returnButton,
            textKeyboardContainer,
            textToolbar,
            textVoiceButton,
            textVoiceFocusButton,
            textSettingsButton,
            textToolsButton,
            textModeButton,
            textAlternateSymbolButton,
            textGlobeButton,
            textLanguageButton,
            compositionLabel,
            pinyinBannerLabel,
            quickCandidateRow,
            candidateScrollView,
            candidateStack,
            keyRowsStack,
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
        [settingsButton, keyboardFocusButton, pasteButton, spaceButton, deleteButton, returnButton].forEach {
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
                    if self.currentBridgeStatus?.state != .recording,
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
                    self.cancelScheduledHostOpen()
                    self.openingHostUntil = 0
                    self.isStartRequestInFlight = false
                    self.tapRecordingActive = false
                    self.bridgeStatus = KeyboardBridgeStatus(state: .idle, message: self.inputMode.idleTitle)
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStarted) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let status = KeyboardBridgeStatus(state: .recording, message: "Recording")
                    self.cancelScheduledHostOpen()
                    self.applyBridgeStatus(status)
                    self.finishStartRequestIfNeeded(status: status)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStopped) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let wasStarting = self.isStartRequestInFlight
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

        configureIconButton(settingsButton, image: "gearshape.fill", accessibilityLabel: NSLocalizedString("Open Typeforme", comment: "Accessibility label for settings/host launcher button"))
        settingsButton.addTarget(self, action: #selector(openHostFromSettingsButton), for: .touchUpInside)
        attachPressAnimation(settingsButton)

        configureIconButton(keyboardFocusButton, image: "keyboard", accessibilityLabel: NSLocalizedString("Show keyboard", comment: "Accessibility label for showing the screen keyboard"))
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

            keyboardFocusButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -6),
            keyboardFocusButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -4),
            settingsButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
        ])
    }

    private func configureIconButton(_ button: UIButton, image: String, accessibilityLabel: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: image)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7)
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityTraits = .button
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.topRowHeight).isActive = true
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
        voiceButton.addTarget(self, action: #selector(voicePressDragIn), for: .touchDragEnter)
        voiceButton.addTarget(self, action: #selector(voicePressDragOut), for: .touchDragExit)
        voiceButton.addTarget(self, action: #selector(voicePressUp), for: .touchUpInside)
        // touchDragExit no longer fires the cancel here — it sets the
        // "release-to-cancel" pre-state via `voicePressDragOut`, so the
        // user can drag back in to recover instead of being cancelled the
        // instant their finger crosses the edge.
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
        orbContainer.addSubview(correctionModePanel)
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
            correctionPopover.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            correctionPopover.heightAnchor.constraint(equalToConstant: 60),
        ])

        NSLayoutConstraint.activate([
            orbContainer.heightAnchor.constraint(equalToConstant: Self.orbContainerHeight),

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

            correctionModePanel.leadingAnchor.constraint(equalTo: orbContainer.leadingAnchor, constant: 10),
            correctionModePanel.trailingAnchor.constraint(lessThanOrEqualTo: voiceButton.leadingAnchor, constant: -8),
            correctionModePanel.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            correctionModePanel.widthAnchor.constraint(equalToConstant: 92),
            correctionModePanel.heightAnchor.constraint(equalToConstant: 44),

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
            correctionModeTrigger.heightAnchor.constraint(equalToConstant: 44),
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
        CATransaction.commit()
    }

    private func configureUtilityRow() {
        utilityRow.axis = .horizontal
        utilityRow.spacing = 6
        utilityRow.alignment = .fill
        utilityRow.distribution = .fill
        utilityRow.heightAnchor.constraint(equalToConstant: Self.utilityRowHeight).isActive = true

        configureCapsuleButton(pasteButton, title: "", image: "doc.on.clipboard", style: .utility)
        pasteButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        pasteButton.addTarget(self, action: #selector(pasteResult), for: .touchUpInside)
        attachPressAnimation(pasteButton)

        configureCapsuleButton(commandButton, title: "", image: "wand.and.stars", style: .utility)
        commandButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        commandButton.accessibilityLabel = NSLocalizedString("Command selected text", comment: "Accessibility label for command/edit-selection button")
        commandButton.addTarget(self, action: #selector(commandPressDown), for: [.touchDown, .touchDragEnter])
        commandButton.addTarget(self, action: #selector(commandPressUp), for: .touchUpInside)
        commandButton.addTarget(self, action: #selector(commandPressCancelled), for: [.touchUpOutside, .touchCancel, .touchDragExit])

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

        utilityRow.addArrangedSubview(pasteButton)
        utilityRow.addArrangedSubview(commandButton)
        utilityRow.addArrangedSubview(spaceButton)
        utilityRow.addArrangedSubview(deleteButton)
        utilityRow.addArrangedSubview(returnButton)
        rootStack.addArrangedSubview(utilityRow)
    }

    private func configureTextKeyboard() {
        textKeyboardContainer.axis = .vertical
        textKeyboardContainer.spacing = 6
        textKeyboardContainer.alignment = .fill
        textKeyboardContainer.distribution = .fill
        textKeyboardContainer.heightAnchor.constraint(equalToConstant: Self.textKeyboardBodyHeight).isActive = true

        textToolbar.axis = .horizontal
        textToolbar.spacing = 4
        textToolbar.alignment = .center
        textToolbar.distribution = .fill
        textToolbar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        configureTextControlButton(textVoiceButton, title: "", image: "mic.fill")
        textVoiceButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        textVoiceButton.accessibilityLabel = NSLocalizedString("Dictate", comment: "Accessibility label for dictation in the screen keyboard")
        textVoiceButton.addTarget(self, action: #selector(textVoiceTapped), for: .touchUpInside)
        attachPressAnimation(textVoiceButton)

        configureTextControlButton(textVoiceFocusButton, title: "", image: "waveform")
        textVoiceFocusButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        textVoiceFocusButton.accessibilityLabel = NSLocalizedString("Show voice input", comment: "Accessibility label for switching to voice input")
        textVoiceFocusButton.addTarget(self, action: #selector(showVoiceFocus), for: .touchUpInside)
        attachPressAnimation(textVoiceFocusButton)

        configureTextControlButton(textSettingsButton, title: "", image: "gearshape")
        textSettingsButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        textSettingsButton.accessibilityLabel = NSLocalizedString("Open Typeforme", comment: "Accessibility label for opening host settings")
        textSettingsButton.addTarget(self, action: #selector(openHostFromSettingsButton), for: .touchUpInside)
        attachPressAnimation(textSettingsButton)

        configureTextControlButton(textToolsButton, title: "", image: "ellipsis.circle")
        textToolsButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        textToolsButton.accessibilityLabel = NSLocalizedString("Keyboard tools", comment: "Accessibility label for keyboard tools menu")
        textToolsButton.showsMenuAsPrimaryAction = true
        refreshTextToolsMenu(isRecording: false)
        attachPressAnimation(textToolsButton)

        compositionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        compositionLabel.textColor = .secondaryLabel
        compositionLabel.numberOfLines = 1
        compositionLabel.lineBreakMode = .byTruncatingTail
        compositionLabel.adjustsFontSizeToFitWidth = true
        compositionLabel.minimumScaleFactor = 0.72
        compositionLabel.text = NSLocalizedString("中文", comment: "Default composition label")
        compositionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        compositionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        candidateScrollView.showsHorizontalScrollIndicator = false
        candidateScrollView.alwaysBounceHorizontal = true
        candidateScrollView.delaysContentTouches = false
        candidateScrollView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        candidateScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        candidateStack.axis = .horizontal
        candidateStack.spacing = 3
        candidateStack.alignment = .fill
        candidateStack.distribution = .fill
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScrollView.addSubview(candidateStack)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScrollView.frameLayoutGuide.heightAnchor),
        ])
        candidateScrollView.delegate = self
        configureCandidatePagerButtonsIfNeeded()

        keyRowsStack.axis = .vertical
        keyRowsStack.spacing = 6
        keyRowsStack.alignment = .fill
        keyRowsStack.distribution = .fillEqually
        textTrackpadPanRecognizer.isEnabled = false
        textTrackpadPanRecognizer.cancelsTouchesInView = true
        textKeyboardContainer.addGestureRecognizer(textTrackpadPanRecognizer)

        configureTextControlButton(textModeButton, title: "123", image: nil)
        textModeButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        textModeButton.addTarget(self, action: #selector(toggleSymbolKeyboard), for: .touchUpInside)
        attachPressAnimation(textModeButton)

        configureTextControlButton(textAlternateSymbolButton, title: "#+=", image: nil)
        textAlternateSymbolButton.addTarget(self, action: #selector(toggleAlternateSymbolKeyboard), for: .touchUpInside)
        attachPressAnimation(textAlternateSymbolButton)

        configureTextControlButton(textGlobeButton, title: "", image: "globe")
        textGlobeButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
        textGlobeButton.accessibilityLabel = NSLocalizedString("Next keyboard", comment: "Accessibility label for switching to the next keyboard")
        textGlobeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        attachPressAnimation(textGlobeButton)

        configureTextLanguageButton()
        textLanguageButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
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

        pinyinBannerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pinyinBannerLabel.textColor = .secondaryLabel
        pinyinBannerLabel.numberOfLines = 1
        pinyinBannerLabel.lineBreakMode = .byTruncatingTail
        pinyinBannerLabel.adjustsFontSizeToFitWidth = true
        pinyinBannerLabel.minimumScaleFactor = 0.72
        pinyinBannerLabel.isHidden = true
        pinyinBannerLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true

        quickCandidateRow.axis = .horizontal
        quickCandidateRow.spacing = 4
        quickCandidateRow.alignment = .fill
        quickCandidateRow.distribution = .fillEqually
        quickCandidateRow.isHidden = true
        quickCandidateRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for index in 0..<9 {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.title = "\(index + 1)"
            configuration.cornerStyle = .medium
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
            configuration.baseForegroundColor = .label
            configuration.baseBackgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.10)
                    : UIColor.black.withAlphaComponent(0.06)
            }
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
                return outgoing
            }
            button.configuration = configuration
            button.tag = index
            button.accessibilityLabel = String(format: NSLocalizedString("Select candidate %d", comment: "Accessibility label for quick candidate selection"), index + 1)
            button.addTarget(self, action: #selector(quickCandidateButtonTapped(_:)), for: .touchUpInside)
            attachPressAnimation(button)
            quickCandidateButtons.append(button)
            quickCandidateRow.addArrangedSubview(button)
        }

        textKeyboardContainer.addArrangedSubview(pinyinBannerLabel)
        textKeyboardContainer.addArrangedSubview(textToolbar)
        textToolbar.addArrangedSubview(candidateScrollView)
        textToolbar.addArrangedSubview(textToolsButton)
        textKeyboardContainer.addArrangedSubview(quickCandidateRow)
        textKeyboardContainer.addArrangedSubview(keyRowsStack)
        rootStack.addArrangedSubview(textKeyboardContainer)

        rebuildTextKeyboardRows()
        renderRimeState(RimeKeyboardState(
            isReady: true,
            isComposing: false,
            input: "",
            preedit: "",
            candidates: [],
            commitText: "",
            errorMessage: nil
        ))
    }

    private func rebuildTextKeyboardRows() {
        NSLayoutConstraint.deactivate(textRowLayoutConstraints)
        textRowLayoutConstraints.removeAll()
        keyRowsStack.arrangedSubviews.forEach { row in
            keyRowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        textKeyboardButtons.removeAll()
        letterButtonMap.removeAll()
        textShiftButton = nil

        if isSymbolKeyboard {
            let rows = symbolRowsForCurrentLanguage()
            addTextKeyRow(rows[0])
            addTextKeyRow(rows[1])
            addTextKeyRow(rows[2], includeAlternateSymbols: true, includeDelete: true)
        } else {
            addTextKeyRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
            addTextKeyRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"], leadingInset: 18, trailingInset: 18)
            addTextKeyRow(
                ["z", "x", "c", "v", "b", "n", "m"],
                leadingTextKey: textInputLanguage == .chinese ? "," : nil,
                includeShift: textInputLanguage == .english,
                includeDelete: true
            )
        }
        addTextBottomRow()
        refreshTextControlTitles()
    }

    private func symbolRowsForCurrentLanguage() -> [[String]] {
        if textInputLanguage == .chinese {
            if isAlternateSymbolKeyboard {
                return [
                    ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                    ["<", ">", "/", "\\", "$", "|", "`", "~", "@", "&"],
                    ["_", "-", "+", "'", "\""],
                ]
            }
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                [",", ".", "?", "!", ":", ";", "(", ")", "\"", "'"],
                ["/", "`", "<", ">", "$", "_", "^"],
            ]
        }

        if isAlternateSymbolKeyboard {
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                [".", ",", "?", "!", "'", "`"],
            ]
        }
        return [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            [".", ",", "?", "!", "'"],
        ]
    }

    private func addTextKeyRow(
        _ keys: [String],
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0,
        leadingTextKey: String? = nil,
        includeAlternateSymbols: Bool = false,
        includeShift: Bool = false,
        includeDelete: Bool = false
    ) {
        let row = makeTextKeyRow()
        var keyButtons: [UIButton] = []
        var leadingUtilityButton: UIButton?
        var trailingUtilityButton: UIButton?

        if leadingInset > 0 {
            addFixedTextRowSpacer(to: row, width: leadingInset)
        }
        if includeAlternateSymbols {
            row.addArrangedSubview(textAlternateSymbolButton)
            textKeyboardButtons.append(textAlternateSymbolButton)
            leadingUtilityButton = textAlternateSymbolButton
        } else if let leadingTextKey {
            let title = displayTitle(forTextKey: leadingTextKey)
            let button = makeTextKeyButton(title: title, weight: .utility)
            attachKeyPreview(to: button, title: title)
            button.addAction(UIAction { [weak self] _ in
                self?.handleTextCharacter(leadingTextKey)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
            textKeyboardButtons.append(button)
            leadingUtilityButton = button
        } else if includeShift {
            let shiftKey = makeTextShiftButton()
            row.addArrangedSubview(shiftKey)
            textKeyboardButtons.append(shiftKey)
            leadingUtilityButton = shiftKey
        }
        keys.forEach { key in
            let title = displayTitle(forTextKey: key)
            let button = makeTextKeyButton(title: title)
            attachKeyPreview(to: button, title: title)
            button.addAction(UIAction { [weak self] _ in
                self?.handleTextCharacter(key)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
            textKeyboardButtons.append(button)
            if isAlphabeticTextKey(key) {
                letterButtonMap[key.lowercased()] = button
                if let hint = digitHint(for: key) {
                    attachDigitHint(to: button, hint: hint)
                }
            }
            keyButtons.append(button)
        }
        if includeDelete {
            let deleteKey = makeTextKeyButton(title: "", image: "delete.left", weight: .utility)
            deleteKey.addTarget(self, action: #selector(deletePressDown), for: [.touchDown, .touchDragEnter])
            deleteKey.addTarget(self, action: #selector(deletePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            row.addArrangedSubview(deleteKey)
            textKeyboardButtons.append(deleteKey)
            trailingUtilityButton = deleteKey
        }
        if trailingInset > 0 {
            addFixedTextRowSpacer(to: row, width: trailingInset)
        }
        constrainTextKeyRow(
            keyButtons: keyButtons,
            leadingUtilityButton: leadingUtilityButton,
            trailingUtilityButton: trailingUtilityButton
        )
        keyRowsStack.addArrangedSubview(row)
    }

    private func addFixedTextRowSpacer(to row: UIStackView, width: CGFloat) {
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        let constraint = spacer.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        textRowLayoutConstraints.append(constraint)
        row.addArrangedSubview(spacer)
    }

    private func constrainTextKeyRow(
        keyButtons: [UIButton],
        leadingUtilityButton: UIButton?,
        trailingUtilityButton: UIButton?
    ) {
        guard let referenceButton = keyButtons.first else { return }
        var constraints: [NSLayoutConstraint] = [
            referenceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ]
        constraints.append(contentsOf: keyButtons.dropFirst().map {
            $0.widthAnchor.constraint(equalTo: referenceButton.widthAnchor)
        })
        if let leadingUtilityButton {
            constraints.append(leadingUtilityButton.widthAnchor.constraint(equalTo: referenceButton.widthAnchor, multiplier: 1.5))
        }
        if let trailingUtilityButton {
            constraints.append(trailingUtilityButton.widthAnchor.constraint(equalTo: referenceButton.widthAnchor, multiplier: 1.5))
        }
        NSLayoutConstraint.activate(constraints)
        textRowLayoutConstraints.append(contentsOf: constraints)
    }

    private func makeTextShiftButton() -> UIButton {
        let button = makeTextKeyButton(title: "", image: isTextShiftEnabled ? "shift.fill" : "shift", weight: .utility)
        button.accessibilityLabel = isTextShiftEnabled
            ? NSLocalizedString("Shift on", comment: "Accessibility label for active Shift key")
            : NSLocalizedString("Shift", comment: "Accessibility label for Shift key")
        button.addTarget(self, action: #selector(toggleTextShift), for: .touchUpInside)
        textShiftButton = button
        return button
    }

    private func displayTitle(forTextKey key: String) -> String {
        if textInputLanguage == .chinese,
           !isAlphabeticTextKey(key),
           chinesePunctuationStyle == .chinese {
            return chinesePunctuationDisplayTitle(for: key)
        }
        if textInputLanguage == .english,
           isAlphabeticTextKey(key),
           isTextShiftEnabled || shouldAutoCapitalizeNextEnglishLetter() {
            return key.uppercased()
        }
        return key
    }

    private func digitHint(for key: String) -> String? {
        switch key.lowercased() {
        case "q": return "1"
        case "w": return "2"
        case "e": return "3"
        case "r": return "4"
        case "t": return "5"
        case "y": return "6"
        case "u": return "7"
        case "i": return "8"
        case "o": return "9"
        case "p": return "0"
        default: return nil
        }
    }

    private func attachDigitHint(to button: UIButton, hint: String) {
        guard textInputLanguage == .chinese, !isSymbolKeyboard else { return }
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = hint
        label.font = .systemFont(ofSize: 8.5, weight: .semibold)
        label.textColor = .tertiaryLabel
        label.isUserInteractionEnabled = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
        ])
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

        let returnKey = makeTextKeyButton(title: returnKeyTitle, weight: .utility)
        returnKey.widthAnchor.constraint(equalToConstant: 72).isActive = true
        returnKey.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        row.addArrangedSubview(returnKey)
        textKeyboardButtons.append(returnKey)
        textReturnKeyButton = returnKey
        lastReturnKeyTitle = returnKeyTitle

        keyRowsStack.addArrangedSubview(row)
    }

    private func refreshReturnKeyTitle() {
        guard let textReturnKeyButton else { return }
        let next = returnKeyTitle
        guard next != lastReturnKeyTitle else { return }
        lastReturnKeyTitle = next
        configureTextKeyButton(textReturnKeyButton, title: next, image: nil, weight: .utility)
    }

    private var spaceKeyTitle: String {
        textInputLanguage == .chinese
            ? NSLocalizedString("空格", comment: "Space key title in Chinese input mode")
            : NSLocalizedString("space", comment: "Space key title in English input mode")
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
            return isChinese
                ? NSLocalizedString("换行", comment: "Default return key title in Chinese input mode")
                : NSLocalizedString("return", comment: "Default return key title in English input mode")
        }
    }

    private func makeTextKeyRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
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
        button.isExclusiveTouch = true
        attachPressAnimation(button)
        return button
    }

    private func configureTextControlButton(_ button: UIButton, title: String, image: String?) {
        configureTextKeyButton(button, title: title, image: image, weight: .utility)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    private func configureTextKeyButton(_ button: UIButton, title: String, image: String?, weight: TextKeyWeight) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = image.flatMap { UIImage(systemName: $0) }
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        configuration.baseForegroundColor = .label
        configuration.background.strokeColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.08)
                : UIColor.black.withAlphaComponent(0.08)
        }
        configuration.background.strokeWidth = weight == .primary ? 0.8 : 0.35
        switch weight {
        case .normal:
            configuration.baseBackgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor.white.withAlphaComponent(0.92)
            }
        case .primary:
            configuration.baseBackgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1) : UIColor.white.withAlphaComponent(0.82)
            }
        case .utility:
            configuration.baseBackgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 0.31, alpha: 1) : UIColor.systemGray4
            }
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: title.count > 2 ? 13 : 18, weight: .medium)
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityLabel = title.isEmpty ? image : title
    }

    private func configureCapsuleButton(_ button: UIButton, title: String, image: String?, style: CapsuleStyle) {
        button.configuration = capsuleButtonConfiguration(title: title, image: image, style: style)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    private func refreshCapsuleButtonConfigurations() {
        pasteButton.configuration = capsuleButtonConfiguration(title: "", image: "doc.on.clipboard", style: .utility)
        commandButton.configuration = capsuleButtonConfiguration(title: "", image: "wand.and.stars", style: .utility)
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
        updateCorrectionModeButtons()
    }

    /// Tap-mode swap: pasteButton becomes a red ✕ Cancel during recording.
    /// Paste is meaningless mid-recording anyway, so the slot doubles as the
    /// only cancel affordance tap-mode users have (hold mode uses drag-out).
    private func applyPasteButtonRecordingState(isTapRecording: Bool) {
        if isTapRecording {
            var configuration = capsuleButtonConfiguration(title: "", image: "xmark", style: .utility)
            configuration.baseForegroundColor = .systemRed
            configuration.baseBackgroundColor = UIColor.systemRed
                .withAlphaComponent(isKeyboardDark ? 0.22 : 0.14)
            pasteButton.configuration = configuration
            pasteButton.accessibilityLabel = NSLocalizedString("Cancel recording", comment: "Tap-mode cancel paste-slot button")
        } else {
            pasteButton.configuration = capsuleButtonConfiguration(title: "", image: "doc.on.clipboard", style: .utility)
            pasteButton.accessibilityLabel = NSLocalizedString("Paste last result", comment: "Paste button accessibility label")
        }
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

        let font: UIFont = title.count > 5 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 15, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }

        switch style {
        case .chrome:
            configuration.baseBackgroundColor = UIColor.secondarySystemGroupedBackground
                .withAlphaComponent(isKeyboardDark ? 0.32 : 0.72)
        case .key:
            configuration.baseBackgroundColor = UIColor.systemBackground
                .withAlphaComponent(isKeyboardDark ? 0.34 : 0.78)
        case .utility:
            configuration.baseBackgroundColor = UIColor.secondarySystemBackground
                .withAlphaComponent(isKeyboardDark ? 0.30 : 0.72)
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
        let isTapRecording = isRecordingState && inputMode == .tap
        // When the finger drags off the orb mid-hold, swap the topRow
        // voiceprint out for a "Release to cancel" cue so the user knows
        // letting go now will discard. updateUI is the single source of
        // truth so subsequent status refreshes don't fight us.
        let showsWillCancelCue = isHoldRecording && isVoicePressWillCancel
        let showsInOrbVoicePrint = isRecordingState && !isHoldRecording
        let showsTopRowVoicePrint = isHoldRecording && !showsWillCancelCue
        applyPasteButtonRecordingState(isTapRecording: isTapRecording)
        let updates = {
            self.statusLabel.text = self.statusText
            self.statusDot.backgroundColor = self.statusColor

            if self.keyboardFocus == .text {
                self.voiceTitleLabel.text = NSLocalizedString("中文键盘", comment: "Title for Chinese keyboard focus")
                self.voiceTitleLabel.textColor = .label
                self.voiceTitleLabel.alpha = 1
            } else {
                self.voiceTitleLabel.text = showsWillCancelCue
                    ? NSLocalizedString("Release to cancel", comment: "Hold-mode drag-out cancel hint")
                    : self.voiceTitle
                self.voiceTitleLabel.textColor = showsWillCancelCue ? .systemRed : self.voiceTitleColor
                self.voiceTitleLabel.alpha = (isHoldRecording && !showsWillCancelCue) ? 0 : 1
            }
            self.voiceIconView.image = UIImage(systemName: self.voiceIconName)
            let showsSpinner = isSendingState || (!isRecordingState && (self.isStartRequestInFlight || self.isOpeningHostApp))
            self.voiceIconView.alpha = (isRecordingState || showsSpinner) ? 0 : 1
            self.voicePrint.alpha = showsInOrbVoicePrint ? 1 : 0
            self.topRowVoicePrint.alpha = (self.keyboardFocus == .text ? false : showsTopRowVoicePrint) ? 1 : 0
            self.voiceButton.alpha = showsWillCancelCue ? 0.45 : 1
            self.voiceSpinner.alpha = showsSpinner ? 1 : 0

            let acceptsVoiceTouch = !isSendingState || self.isVoicePressActive
            self.voiceButton.isEnabled = acceptsVoiceTouch
            self.voiceButton.accessibilityValue = self.inputMode.title
            self.commandButton.isEnabled = !isSendingState || self.isCommandPressActive
            self.commandButton.alpha = self.commandButton.isEnabled ? 1 : 0.45
            self.inputModeSwitch.setEnabled(!isRecordingState && !isSendingState && !self.isStartRequestInFlight)
            let locksTextRows = self.keyboardFocus == .text && (isRecordingState || isSendingState)
            self.keyRowsStack.isUserInteractionEnabled = !locksTextRows
            self.keyRowsStack.alpha = locksTextRows ? 0.48 : 1
            self.candidateScrollView.alpha = locksTextRows ? 0.62 : 1
            self.configureTextControlButton(self.textVoiceButton, title: "", image: isRecordingState ? "stop.fill" : "mic.fill")
            if isRecordingState {
                self.textVoiceButton.configuration?.baseBackgroundColor = UIColor.systemRed
                self.textVoiceButton.configuration?.baseForegroundColor = UIColor.white
            }
            self.textVoiceButton.isEnabled = !isSendingState || isRecordingState || self.isVoicePressActive
            self.textVoiceButton.alpha = self.textVoiceButton.isEnabled ? 1 : 0.45
            self.configureTextControlButton(self.textToolsButton, title: "", image: isRecordingState ? "stop.circle.fill" : "ellipsis.circle")
            if isRecordingState {
                self.textToolsButton.configuration?.baseBackgroundColor = UIColor.systemRed
                self.textToolsButton.configuration?.baseForegroundColor = UIColor.white
            }
            self.textToolsButton.isEnabled = !isSendingState || isRecordingState || self.isVoicePressActive
            self.textToolsButton.alpha = self.textToolsButton.isEnabled ? 1 : 0.45
            self.refreshTextToolsMenu(isRecording: isRecordingState)
            self.voiceButton.layer.shadowColor = self.voiceShadowColor.cgColor

            if showsSpinner {
                self.voiceSpinner.startAnimating()
            } else {
                self.voiceSpinner.stopAnimating()
            }
        }

        let gradientColors = voiceGradientColors.map { $0.cgColor }
        let shouldAnimate = animated && !isVoicePressActive && !isStartRequestInFlight
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

        voicePrint.isActive = showsInOrbVoicePrint
        topRowVoicePrint.isActive = isHoldRecording
        if isRecordingState {
            let audioLevel = currentBridgeStatus?.audioLevel
            voicePrint.updateLevel(audioLevel)
            topRowVoicePrint.updateLevel(audioLevel)
            updatePulseAudioLevel(audioLevel)
            startPulseRings()
        } else {
            stopPulseRings()
        }

        let desiredInterval: TimeInterval = isRecordingState ? 0.12 : 0.35
        if statusTimer != nil, abs(statusTimerInterval - desiredInterval) > 0.01 {
            stopStatusPolling()
            startStatusPolling(interval: desiredInterval)
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
        keyPreviewBubble.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.keyPreviewBubble.alpha = 1
            self.keyPreviewBubble.transform = .identity
        }
    }

    private func hideKeyPreview() {
        guard !keyPreviewBubble.isHidden else { return }
        UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.keyPreviewBubble.alpha = 0
            self.keyPreviewBubble.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        } completion: { _ in
            self.keyPreviewBubble.isHidden = true
            self.keyPreviewBubble.transform = .identity
        }
    }

    @objc private func controlPressDown(_ sender: UIControl) {
        sender.layer.cornerRadius = min(sender.bounds.height / 2, 10)
        sender.layer.backgroundColor = UIColor.label.withAlphaComponent(isKeyboardDark ? 0.10 : 0.07).cgColor
        sender.layer.borderWidth = 1
        sender.layer.borderColor = UIColor.label.withAlphaComponent(isKeyboardDark ? 0.26 : 0.18).cgColor
        sender.layer.shadowColor = UIColor.black.cgColor
        sender.layer.shadowOpacity = isKeyboardDark ? 0.22 : 0.10
        sender.layer.shadowRadius = 3
        sender.layer.shadowOffset = CGSize(width: 0, height: 1)
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            sender.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        }
    }

    @objc private func controlPressUp(_ sender: UIControl) {
        sender.layer.backgroundColor = UIColor.clear.cgColor
        sender.layer.borderWidth = 0
        sender.layer.shadowOpacity = 0
        UIView.animate(withDuration: 0.10, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
            sender.transform = .identity
        }
    }

    @objc private func voicePressDown() {
        kbLog.notice("voicePressDown fired (bounds=\(NSCoder.string(for: self.voiceButton.bounds), privacy: .public))")
        guard !isVoicePressActive else { return }
        isVoicePressActive = true
        isVoicePressWillCancel = false
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
        kbLog.notice("voicePressUp fired (willCancel=\(self.isVoicePressWillCancel, privacy: .public))")
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = .identity
            self.voiceButton.alpha = 1
        }
        switch inputMode {
        case .hold:
            // Safety net: touchUpInside while still flagged as will-cancel
            // (e.g., user drag-enters and immediately lifts in the same frame
            // before touchDragEnter is dispatched) → honour the cancel intent.
            if isVoicePressWillCancel, hasFullAccess {
                isVoicePressWillCancel = false
                cancelActiveHoldRecording()
                isVoicePressActive = false
                return
            }
            endDictationPress()
        case .tap:
            isVoicePressActive = false
        }
    }

    @objc private func voicePressCancelled() {
        // Fires for touchUpOutside / touchCancel — i.e., user released the
        // finger off the orb, or the system interrupted us. In hold mode
        // this is the canonical "drag-up to cancel" path.
        kbLog.notice("voicePressCancelled fired (willCancel=\(self.isVoicePressWillCancel, privacy: .public))")
        let wasActive = isVoicePressActive
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = .identity
            self.voiceButton.alpha = 1
        }
        if wasActive, inputMode == .hold, hasFullAccess {
            cancelActiveHoldRecording()
        }
        isVoicePressActive = false
        isVoicePressWillCancel = false
    }

    /// Hold-mode finger left the orb — enter "release-to-cancel" visual state
    /// without cancelling yet. The user can drag back in to recover.
    @objc private func voicePressDragOut() {
        guard inputMode == .hold, isVoicePressActive else { return }
        guard !isVoicePressWillCancel else { return }
        isVoicePressWillCancel = true
        // updateUI() owns the will-cancel cue (label swap + orb dim + topRow
        // voiceprint hide) so subsequent status refreshes don't overwrite it.
        // Wrap in a property animation block so the alpha/text swaps fade in.
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.updateUI(animated: false)
        }
    }

    /// Hold-mode finger came back onto the orb — clear the will-cancel state
    /// and let recording continue. Tap mode treats this like a fresh press if
    /// the user dragged in from elsewhere without first lifting.
    @objc private func voicePressDragIn() {
        if inputMode == .hold, isVoicePressActive {
            guard isVoicePressWillCancel else { return }
            isVoicePressWillCancel = false
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.updateUI(animated: false)
            }
            return
        }
        if !isVoicePressActive {
            voicePressDown()
        }
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
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            showTextKeyboardNotice(NSLocalizedString("Enable Full Access", comment: "Inline status when keyboard full access is missing"))
            updateUI()
            return
        }

        guard !isStartRequestInFlight else {
            showTextKeyboardNotice(NSLocalizedString("Preparing", comment: "Inline status while dictation is being prepared"))
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            showTextKeyboardNotice(NSLocalizedString("Transcribing", comment: "Inline status while dictation result is being processed"))
            return
        }

        cancelScheduledStop()
        tapRecordingActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        showTextKeyboardNotice(NSLocalizedString("Preparing", comment: "Inline status while dictation is being prepared"))
        let repairTarget = selectedTextRewriteTarget()
        beginDictationFromKeyboard(
            textEditContext: repairTarget.map { keyboardTextEditContext(intent: .repairSelection, target: $0) },
            target: repairTarget,
            continuesAfterRelease: true
        )
    }

    @objc private func textVoicePressDown() {
        guard keyboardFocus == .text else { return }
        guard !isVoicePressActive else { return }
        isVoicePressActive = true
        isVoicePressWillCancel = false
        voicePressBeganAt = Date().timeIntervalSince1970
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.textVoiceButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            self.textVoiceButton.alpha = 0.9
        }
        switch inputMode {
        case .hold:
            beginDictationPress()
        case .tap:
            handleTapModePress()
        }
    }

    @objc private func textVoicePressUp() {
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.textVoiceButton.transform = .identity
            self.textVoiceButton.alpha = 1
        }
        switch inputMode {
        case .hold:
            if isVoicePressWillCancel, hasFullAccess {
                isVoicePressWillCancel = false
                cancelActiveHoldRecording()
                isVoicePressActive = false
                return
            }
            endDictationPress()
        case .tap:
            isVoicePressActive = false
        }
    }

    @objc private func textVoicePressCancelled() {
        let wasActive = isVoicePressActive
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.textVoiceButton.transform = .identity
            self.textVoiceButton.alpha = 1
        }
        if wasActive, inputMode == .hold, hasFullAccess {
            cancelActiveHoldRecording()
        }
        isVoicePressActive = false
        isVoicePressWillCancel = false
    }

    @objc private func textVoicePressDragOut() {
        guard inputMode == .hold, isVoicePressActive else { return }
        guard !isVoicePressWillCancel else { return }
        isVoicePressWillCancel = true
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.textVoiceButton.alpha = 0.55
        }
    }

    @objc private func textVoicePressDragIn() {
        guard inputMode == .hold, isVoicePressActive else { return }
        guard isVoicePressWillCancel else { return }
        isVoicePressWillCancel = false
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.textVoiceButton.alpha = 0.9
        }
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
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
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
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
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
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
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
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
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
        activeRecordingTextTarget = target
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
        bridgeProbeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.status(timeout: 0.9)
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

    private func openStandbyInHostApp(returnToKeyboard: Bool = true) {
        openHostAppForKeyboardAction(
            "standby",
            returnToKeyboard: returnToKeyboard,
            openingMessage: "Opening Typeforme to prepare dictation."
        )
    }

    private func openHostAppForKeyboardAction(
        _ action: String,
        returnToKeyboard: Bool,
        openingMessage: String
    ) {
        var components = URLComponents()
        components.scheme = "typeforme"
        components.host = action
        let requestedCorrectionMode = action == "record" ? currentDefaultCorrectionMode() : correctionMode
        var queryItems = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "return", value: returnToKeyboard ? "1" : "0"),
            URLQueryItem(name: "correction_mode", value: requestedCorrectionMode.rawValue),
        ]
        if returnToKeyboard, let returnBundleID = currentHostBundleID {
            queryItems.append(URLQueryItem(name: "return_bundle", value: returnBundleID))
        }
        if returnToKeyboard, let returnProcessID = currentHostProcessID {
            queryItems.append(URLQueryItem(name: "return_pid", value: String(returnProcessID)))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return }
        openingHostUntil = Date().timeIntervalSince1970 + 8
        bridgeStatus = KeyboardBridgeStatus(state: .standby, message: openingMessage)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        if keyboardFocus == .text {
            showTextKeyboardNotice(NSLocalizedString("Opening Typeforme…", comment: "Inline status while opening the host app"))
        }
        openHostApp(url) { [weak self] success in
            kbLog.notice("openHostAppForKeyboardAction: open success=\(success, privacy: .public)")
            guard let self, !success else { return }
            self.openingHostUntil = 0
            self.tapRecordingActive = false
            self.bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Open Typeforme to prepare dictation.")
            self.lastBridgeContactAt = Date().timeIntervalSince1970
            self.updateUI()
            if self.keyboardFocus == .text {
                self.showTextKeyboardNotice(NSLocalizedString("Open Typeforme", comment: "Inline status when host app cannot be opened"))
            }
        }
    }

    private func openHostApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        // Non-public but deliberate: custom keyboards do not get a supported
        // "open containing app" API for this microphone handoff. Keep all
        // host-wake reflection in this method so an App Store build can replace
        // it with a manual "open Typeforme" fallback without touching the
        // dictation state machine.
        kbLog.notice("openHostApp: opening via LSApplicationWorkspace")
        completion(openHostAppViaApplicationWorkspace(url))
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

    private var currentHostBundleID: String? {
        // Non-public return-target discovery. This exists only to make the
        // microphone handoff feel like a keyboard action on device. Removing it
        // makes host return manual; keeping it is not appropriate for an App
        // Store-safe build.
        if let id = privateStringValue(named: "_hostApplicationBundleIdentifier", from: self),
           isUsableReturnBundleID(id) {
            return id
        }
        if let id = privateStringValue(named: "_hostBundleID", from: parent),
           isUsableReturnBundleID(id) {
            return id
        }
        guard let pid = currentHostProcessID else { return nil }
        let hostPID: AnyObject = NSNumber(value: pid)
        return currentHostBundleIDFromXPC(hostPID: hostPID).flatMap {
            isUsableReturnBundleID($0) ? $0 : nil
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
        typealias CopyBundleID = @convention(c) (AnyObject) -> UnsafePointer<CChar>?
        let copyBundleID = unsafeBitCast(symbol, to: CopyBundleID.self)
        guard let cString = copyBundleID(connection) else { return nil }
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
        guard !trimmed.hasPrefix("com.typeforme.") else { return false }
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
        activeRecordingTextTarget = target
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

    @objc private func pasteResult() {
        lightHaptic()
        guard hasFullAccess else { return }
        // Tap mode hijacks this slot as a Cancel button while recording —
        // there's no touch on the orb to swipe away from, so the user needs
        // an explicit affordance to discard.
        if currentBridgeStatus?.state == .recording, inputMode == .tap {
            kbLog.notice("pasteResult: tap-mode cancel pressed")
            tapRecordingActive = false
            cancelActiveHoldRecording()
            return
        }
        let candidates = [
            UIPasteboard.general.string,
            defaults.string(forKey: lastInsertedTextKey),
        ]
        guard let text = candidates.compactMap({ $0 }).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return }
        textDocumentProxy.insertText(text)
        defaults.set(text, forKey: lastInsertedTextKey)
    }

    @objc private func selectCorrectionModeButton(_ sender: UIButton) {
        guard let preset = correctionModeButtons.first(where: { $0.button === sender })?.preset else { return }
        lightHaptic()
        // Close the popover before kicking off the rewrite so the user sees
        // the orb again immediately rather than the popover lingering.
        hideCorrectionPopover()
        rewriteCurrentInputOrPasteboard(using: preset)
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

    /// Builds the trigger button's compact "current preset + chevron"
    /// configuration. Mirrors `correctionModeButtonConfiguration` but tuned
    /// for the always-visible chip so it fits the 92×44 panel slot.
    private func applyCorrectionTriggerConfiguration(isEnabled: Bool) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = correctionMode.title
        configuration.image = UIImage(systemName: "chevron.up.chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = UIColor.systemBackground
            .withAlphaComponent(isKeyboardDark ? 0.30 : 0.78)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 12, weight: .semibold)
            return outgoing
        }
        correctionModeTrigger.configuration = configuration
        correctionModeTrigger.isEnabled = isEnabled
        correctionModeTrigger.alpha = isEnabled ? 1 : 0.45
        let modeLabelFormat = NSLocalizedString("Correction mode: %@", comment: "Accessibility label for the mode trigger")
        correctionModeTrigger.accessibilityLabel = String(format: modeLabelFormat, correctionMode.title)
        correctionModeTrigger.accessibilityHint = NSLocalizedString("Double tap to choose another mode", comment: "Accessibility hint for mode trigger")
    }

    private func rewriteCurrentInputOrPasteboard(using preset: CorrectionModePreset) {
        guard hasFullAccess else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        guard styleRewriteCommandID == nil,
              currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending
        else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Nothing to rewrite.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }

        correctionMode = preset
        lastCorrectionModeButtonSignature = ""
        let command = KeyboardBridgeCommand(
            action: .restyleText,
            correctionMode: preset.rawValue,
            text: target.text
        )
        styleRewriteCommandID = command.id
        bridgeStatus = KeyboardBridgeStatus(commandID: command.id, state: .sending, message: "Rewriting")
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        showTextKeyboardNotice(NSLocalizedString("Rewriting", comment: "Inline status while rewriting recent text"))

        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(command, timeout: KeyboardBridgeCommandAction.restyleText.requestTimeout)
                await MainActor.run {
                    self.finishStyleRewrite(status: status, target: target, commandID: command.id)
                }
            } catch {
                await MainActor.run {
                    guard self.styleRewriteCommandID == command.id else { return }
                    self.styleRewriteCommandID = nil
                    self.bridgeStatus = KeyboardBridgeStatus(commandID: command.id, state: .error, message: "Open Typeforme once to prepare rewriting.")
                    self.lastBridgeContactAt = 0
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

        if let recentResult = recentInsertedTextRewriteTarget() {
            kbLog.notice("using recent inserted result as rewrite target")
            return recentResult
        }

        if let contextTarget = currentExpandedContextRewriteTarget() {
            return contextTarget
        }

        return nil
    }

    private func recentInsertedTextRewriteTarget() -> TextRewriteTarget? {
        guard let text = recentRestyleText ?? defaults.string(forKey: lastInsertedTextKey),
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
            bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Selection changed; result copied.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        defaults.set(commandID, forKey: lastInsertedCommandIDKey)
        defaults.set(text, forKey: lastInsertedTextKey)
        recentSelectionTarget = nil
        rememberRestyleText(text)
        applyDefaultCorrectionModeFromHost(status.defaultCorrectionMode)
        bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .result, message: "Rewritten", resultText: text)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        renderRestyleSuggestionsIfIdle()
    }

    @discardableResult
    private func applyRewrittenText(_ text: String, replacing target: TextRewriteTarget) -> Bool {
        UIPasteboard.general.string = text
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

    private func setKeyboardFocus(_ focus: KeyboardFocus, animated: Bool) {
        guard keyboardFocus != focus else { return }
        if keyboardFocus == .text {
            applyRimeState(rimeInput.commitComposition())
        }
        clearTextShiftState()
        keyboardFocus = focus
        defaults.set(focus.rawValue, forKey: keyboardFocusKey)
        updateKeyboardFocus(animated: animated)
        lightHaptic()
    }

    private func updateKeyboardFocus(animated: Bool = true) {
        let isTextFocus = keyboardFocus == .text
        if isTextFocus {
            applyTextInputOptionsToRime()
        } else {
            replaceMarkedText("")
        }
        let changes = {
            self.topRow.isHidden = isTextFocus
            self.orbContainer.isHidden = isTextFocus
            self.utilityRow.isHidden = isTextFocus
            self.textKeyboardContainer.isHidden = !isTextFocus
            self.keyboardFocusButton.configuration?.image = UIImage(systemName: isTextFocus ? "mic.fill" : "keyboard")
            self.keyboardFocusButton.accessibilityLabel = isTextFocus
                ? NSLocalizedString("Show voice input", comment: "Accessibility label for showing voice input")
                : NSLocalizedString("Show keyboard", comment: "Accessibility label for showing the screen keyboard")
            self.voiceTitleLabel.text = isTextFocus
                ? NSLocalizedString("中文键盘", comment: "Title for Chinese keyboard focus")
                : self.voiceTitle
        }
        if animated {
            UIView.transition(
                with: rootStack,
                duration: 0.22,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
                animations: changes
            )
        } else {
            UIView.performWithoutAnimation(changes)
        }
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
        isTextShiftEnabled.toggle()
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
        isTextShiftEnabled = false
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
        configureTextControlButton(textToolsButton, title: "", image: "ellipsis.circle")
        textToolsButton.accessibilityLabel = NSLocalizedString("Keyboard tools", comment: "Accessibility label for keyboard tools menu")
        refreshTextToolsMenu(isRecording: currentBridgeStatus?.state == .recording)
        configureTextLanguageButton()
        refreshReturnKeyTitle()
    }

    private func refreshTextToolsMenu(isRecording: Bool) {
        let dictateTitle = isRecording
            ? NSLocalizedString("Stop dictation", comment: "Menu item for stopping keyboard dictation")
            : NSLocalizedString("Dictate", comment: "Menu item for starting keyboard dictation")
        textToolsButton.menu = UIMenu(children: [
            UIAction(title: dictateTitle, image: UIImage(systemName: isRecording ? "stop.fill" : "mic.fill")) { [weak self] _ in
                self?.textVoiceTapped()
            },
            UIAction(title: NSLocalizedString("Voice keyboard", comment: "Menu item for switching to voice keyboard"), image: UIImage(systemName: "waveform")) { [weak self] _ in
                self?.showVoiceFocus()
            },
            UIAction(title: NSLocalizedString("Open Typeforme", comment: "Menu item for opening Typeforme"), image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.openHostFromSettingsButton()
            },
        ])
    }

    private func refreshInputModeSwitchKeyVisibility() {
        textGlobeButton.isHidden = !needsInputModeSwitchKey
    }

    private func refreshShiftButtonImage() {
        guard let textShiftButton else { return }
        configureTextKeyButton(
            textShiftButton,
            title: "",
            image: isTextShiftEnabled ? "shift.fill" : "shift",
            weight: .utility
        )
        textShiftButton.accessibilityLabel = isTextShiftEnabled
            ? NSLocalizedString("Shift on", comment: "Accessibility label for active Shift key")
            : NSLocalizedString("Shift", comment: "Accessibility label for Shift key")
    }

    private func refreshLetterCasing() {
        guard !isSymbolKeyboard else { return }
        for (key, button) in letterButtonMap {
            let title = displayTitle(forTextKey: key)
            configureTextKeyButton(button, title: title, image: nil, weight: .normal)
            button.accessibilityValue = title
        }
    }

    @discardableResult
    private func resetShiftIfSticky() -> Bool {
        guard isTextShiftEnabled else { return false }
        isTextShiftEnabled = false
        refreshShiftButtonImage()
        refreshLetterCasing()
        return true
    }

    private func clearTextShiftState() {
        guard isTextShiftEnabled else { return }
        isTextShiftEnabled = false
        refreshShiftButtonImage()
        refreshLetterCasing()
    }

    private func configureTextLanguageButton() {
        configureTextKeyButton(textLanguageButton, title: "", image: nil, weight: .utility)
        var configuration = textLanguageButton.configuration ?? .filled()
        configuration.title = nil
        configuration.attributedTitle = nil
        configuration.contentInsets = .zero
        textLanguageButton.configuration = configuration

        let activeTitle = textInputLanguage == .chinese ? "中" : "英"
        let inactiveTitle = textInputLanguage == .chinese ? "英" : "中"
        let text = NSMutableAttributedString(
            string: activeTitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.label,
            ]
        )
        text.append(NSAttributedString(
            string: "/",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.tertiaryLabel,
            ]
        ))
        text.append(NSAttributedString(
            string: inactiveTitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .medium),
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

    private func handleTextCharacter(_ character: String) {
        guard keyboardFocus == .text else {
            textDocumentProxy.insertText(character)
            return
        }
        clearRestyleSuggestions()

        if textInputLanguage == .english {
            applyRimeState(rimeInput.commitComposition())
            let shouldCapitalize = isAlphabeticTextKey(character)
                && (isTextShiftEnabled || shouldAutoCapitalizeNextEnglishLetter())
            let output = shouldCapitalize
                ? character.uppercased()
                : character
            textDocumentProxy.insertText(output)
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            return
        }

        guard isAlphabeticTextKey(character) else {
            insertChineseDirectTextKey(character)
            return
        }

        _ = rimeInput.setAsciiPunctuation(chinesePunctuationStyle == .english)
        _ = rimeInput.setAsciiMode(false)
        let state = rimeInput.processCharacter(character)
        applyRimeState(state)
    }

    private func handleTextBackspace() {
        guard keyboardFocus == .text else {
            textDocumentProxy.deleteBackward()
            return
        }
        clearRestyleSuggestions()

        let currentState = rimeInput.state()
        if currentState.isComposing {
            applyRimeState(rimeInput.processKeyCode(0xFF08))
            resetShiftIfSticky()
        } else {
            replaceMarkedText("")
            textDocumentProxy.deleteBackward()
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            renderRestyleSuggestionsIfIdle()
        }
    }

    private func handleTextSpace() {
        guard keyboardFocus == .text else {
            textDocumentProxy.insertText(" ")
            return
        }
        clearRestyleSuggestions()

        if textInputLanguage == .english {
            applyRimeState(rimeInput.commitComposition())
            textDocumentProxy.insertText(" ")
            if !resetShiftIfSticky() {
                refreshEnglishLetterCasingIfNeeded()
            }
            return
        }

        _ = rimeInput.setAsciiPunctuation(chinesePunctuationStyle == .english)
        _ = rimeInput.setAsciiMode(false)
        let wasComposing = rimeInput.state().isComposing
        let state = rimeInput.processKeyCode(32)
        applyRimeState(state)
        if !wasComposing, state.commitText.isEmpty, !state.isComposing {
            textDocumentProxy.insertText(" ")
        }
        resetShiftIfSticky()
    }

    private func handleTextReturn() {
        guard keyboardFocus == .text else {
            textDocumentProxy.insertText("\n")
            return
        }
        clearRestyleSuggestions()

        let state = rimeInput.state().isComposing ? rimeInput.commitComposition() : rimeInput.state()
        applyRimeState(state)
        if state.commitText.isEmpty {
            textDocumentProxy.insertText("\n")
        }
        if !resetShiftIfSticky() {
            refreshEnglishLetterCasingIfNeeded()
        }
    }

    private func applyRimeState(_ state: RimeKeyboardState) {
        if !state.commitText.isEmpty {
            replaceMarkedText("")
            textDocumentProxy.insertText(state.commitText)
        }

        replaceMarkedText("")

        renderRimeState(state)
    }

    private func renderRimeState(_ state: RimeKeyboardState) {
        compositionLabel.text = state.errorMessage ?? ""
        updatePinyinBanner(for: state)
        updateQuickCandidateRow(for: state)

        resetCandidateStackForReuse()

        if let errorMessage = state.errorMessage {
            addCandidateStatus(errorMessage, color: .systemOrange)
            return
        }

        if !state.isReady {
            addCandidateStatus(NSLocalizedString("Chinese preparing…", comment: "Rime preparing status"), color: .secondaryLabel, emphasized: true)
            return
        }

        if !state.isComposing, renderRecentRestyleActions() {
            return
        }

        guard !state.candidates.isEmpty else {
            return
        }

        for (index, candidate) in state.candidates.enumerated() {
            if index > 0 {
                addCandidateSeparator()
            }
            let button = reusableCandidateButton(at: index)
            configureCandidateButton(button, candidate: candidate, index: index)
            addCandidateArrangedView(button)
        }
        addCandidatePagerButton(previousCandidatePageButton)
        addCandidatePagerButton(nextCandidatePageButton)
        candidateScrollView.setContentOffset(.zero, animated: false)
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
        if view.superview == nil {
            candidateStack.addSubview(view)
        }
        candidateStack.addArrangedSubview(view)
    }

    private func updatePinyinBanner(for state: RimeKeyboardState) {
        let composingText = state.isComposing ? (state.preedit.isEmpty ? state.input : state.preedit) : ""
        pinyinBannerLabel.text = composingText
        pinyinBannerLabel.isHidden = composingText.isEmpty
    }

    private func updateQuickCandidateRow(for state: RimeKeyboardState) {
        let shouldShow = keyboardFocus == .text
            && textInputLanguage == .chinese
            && state.isComposing
            && !state.candidates.isEmpty
        quickCandidateRow.isHidden = !shouldShow
        guard shouldShow else { return }
        for (index, button) in quickCandidateButtons.enumerated() {
            let hasCandidate = index < state.candidates.count
            button.isEnabled = hasCandidate
            button.alpha = hasCandidate ? 1 : 0.28
        }
    }

    private func addCandidateSeparator() {
        let separator: UIView
        if activeCandidateSeparatorIndex < reusableCandidateSeparators.count {
            separator = reusableCandidateSeparators[activeCandidateSeparatorIndex]
        } else {
            separator = UIView()
            separator.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
            separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
            separator.setContentHuggingPriority(.required, for: .horizontal)
            separator.setContentCompressionResistancePriority(.required, for: .horizontal)
            reusableCandidateSeparators.append(separator)
        }
        activeCandidateSeparatorIndex += 1
        separator.backgroundColor = UIColor.separator.withAlphaComponent(isKeyboardDark ? 0.28 : 0.22)
        addCandidateArrangedView(separator)
    }

    private func configureCandidatePagerButtonsIfNeeded() {
        guard !didConfigureCandidatePagerButtons else { return }
        didConfigureCandidatePagerButtons = true
        configureCandidatePagerButton(
            previousCandidatePageButton,
            title: "‹",
            keyCode: 0xFF55,
            accessibilityLabel: NSLocalizedString("Previous candidates", comment: "Candidate page up button")
        )
        configureCandidatePagerButton(
            nextCandidatePageButton,
            title: "›",
            keyCode: 0xFF56,
            accessibilityLabel: NSLocalizedString("Next candidates", comment: "Candidate page down button")
        )
    }

    private func configureCandidatePagerButton(_ button: UIButton, title: String, keyCode: Int32, accessibilityLabel: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.baseForegroundColor = .secondaryLabel
        configuration.background.cornerRadius = 7
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 21, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
        button.tag = Int(keyCode)
        button.addTarget(self, action: #selector(candidatePagerButtonTapped(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        attachPressAnimation(button)
    }

    private func addCandidatePagerButton(_ button: UIButton) {
        addCandidateArrangedView(button)
    }

    @objc private func candidatePagerButtonTapped(_ sender: UIButton) {
        applyRimeState(rimeInput.processKeyCode(Int32(sender.tag)))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        handleCandidateScrollPagingIfNeeded(scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        handleCandidateScrollPagingIfNeeded(scrollView)
    }

    private func handleCandidateScrollPagingIfNeeded(_ scrollView: UIScrollView) {
        guard scrollView === candidateScrollView,
              keyboardFocus == .text,
              rimeInput.state().isComposing
        else { return }
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        if scrollView.contentOffset.x > maxOffset + 24 {
            applyRimeState(rimeInput.processKeyCode(0xFF56))
        } else if scrollView.contentOffset.x < -24 {
            applyRimeState(rimeInput.processKeyCode(0xFF55))
        }
    }

    private func reusableCandidateButton(at index: Int) -> UIButton {
        if index < reusableCandidateButtons.count {
            return reusableCandidateButtons[index]
        }
        let button = UIButton(type: .system)
        button.addTarget(self, action: #selector(candidateButtonTapped(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let widthConstraint = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 46)
        widthConstraint.isActive = true
        attachPressAnimation(button)
        reusableCandidateButtons.append(button)
        reusableCandidateButtonWidthConstraints.append(widthConstraint)
        return button
    }

    private func configureCandidateButton(_ button: UIButton, candidate: RimeKeyboardCandidate, index: Int) {
        button.tag = index
        var configuration = UIButton.Configuration.plain()
        configuration.title = candidate.text
        configuration.subtitle = candidate.comment.isEmpty ? nil : candidate.comment
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        configuration.baseForegroundColor = .label
        configuration.background.cornerRadius = 7
        configuration.background.backgroundColor = index == 0 ? UIColor.systemFill : .clear
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: index == 0 ? 19 : 18, weight: index == 0 ? .semibold : .medium)
            return outgoing
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 10, weight: .regular)
            outgoing.foregroundColor = .secondaryLabel
            return outgoing
        }
        button.configuration = configuration
        reusableCandidateButtonWidthConstraints[index].constant = candidateButtonMinimumWidth(for: candidate, isFirst: index == 0)
    }

    @objc private func candidateButtonTapped(_ sender: UIButton) {
        applyRimeState(rimeInput.selectCandidate(at: sender.tag))
    }

    @objc private func quickCandidateButtonTapped(_ sender: UIButton) {
        applyRimeState(rimeInput.selectCandidate(at: sender.tag))
    }

    private func candidateButtonMinimumWidth(for candidate: RimeKeyboardCandidate, isFirst: Bool) -> CGFloat {
        let titleFont = UIFont.systemFont(ofSize: isFirst ? 19 : 18, weight: isFirst ? .semibold : .medium)
        let titleWidth = ceil((candidate.text as NSString).size(withAttributes: [.font: titleFont]).width)
        var minimumWidth = titleWidth + 26
        if !candidate.comment.isEmpty {
            let commentFont = UIFont.systemFont(ofSize: 10, weight: .regular)
            let commentWidth = ceil((candidate.comment as NSString).size(withAttributes: [.font: commentFont]).width)
            minimumWidth = max(minimumWidth, commentWidth + 26)
        }
        return max(46, minimumWidth)
    }

    private func addCandidateStatus(_ text: String, color: UIColor, emphasized: Bool = false) {
        let label: UILabel
        if activeCandidateStatusLabelIndex < reusableCandidateStatusLabels.count {
            label = reusableCandidateStatusLabels[activeCandidateStatusLabelIndex]
        } else {
            label = UILabel()
            label.textAlignment = .left
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            reusableCandidateStatusLabels.append(label)
        }
        activeCandidateStatusLabelIndex += 1
        label.text = text
        label.font = .systemFont(ofSize: emphasized ? 15 : 13, weight: emphasized ? .semibold : .medium)
        label.textColor = color
        addCandidateArrangedView(label)
    }

    private func rememberRestyleText(_ text: String) {
        recentRestyleText = text
        recentRestyleShownAt = Date().timeIntervalSince1970
    }

    private func clearRestyleSuggestions() {
        recentRestyleText = nil
        recentRestyleShownAt = 0
    }

    private func renderRestyleSuggestionsIfIdle() {
        guard keyboardFocus == .text else { return }
        renderRimeState(RimeKeyboardState(
            isReady: true,
            isComposing: false,
            input: "",
            preedit: "",
            candidates: [],
            commitText: "",
            errorMessage: nil
        ))
    }

    private func renderRecentRestyleActions() -> Bool {
        guard styleRewriteCommandID == nil,
              currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending,
              let text = recentRestyleText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Date().timeIntervalSince1970 - recentRestyleShownAt <= restyleSuggestionTTL,
              recentInsertedTextRewriteTarget() != nil
        else { return false }

        for preset in CorrectionModePreset.allCases {
            let button: UIButton
            if let existing = reusableRestyleButtons[preset] {
                button = existing
            } else {
                button = UIButton(type: .system)
                button.heightAnchor.constraint(equalToConstant: 34).isActive = true
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: preset == .structurePlus ? 74 : 58).isActive = true
                button.addAction(UIAction { [weak self] _ in
                    self?.rewriteCurrentInputOrPasteboard(using: preset)
                }, for: .touchUpInside)
                attachPressAnimation(button)
                reusableRestyleButtons[preset] = button
            }
            button.configuration = correctionModeButtonConfiguration(title: preset.title, selected: preset == correctionMode)
            addCandidateArrangedView(button)
        }
        candidateScrollView.setContentOffset(.zero, animated: false)
        return true
    }

    private func showTextKeyboardNotice(_ text: String, color: UIColor = .secondaryLabel) {
        guard keyboardFocus == .text else { return }
        compositionLabel.text = text
        pinyinBannerLabel.text = ""
        pinyinBannerLabel.isHidden = true
        resetCandidateStackForReuse()
        addCandidateStatus(text, color: color, emphasized: true)
        candidateScrollView.setContentOffset(.zero, animated: false)
    }

    private func replaceMarkedText(_ text: String) {
        guard activeMarkedText != text else { return }
        if text.isEmpty {
            if !activeMarkedText.isEmpty {
                textDocumentProxy.unmarkText()
            }
        }
        activeMarkedText = text
    }

    private func isAlphabeticTextKey(_ character: String) -> Bool {
        guard character.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.uppercaseLetters.contains(scalar)
    }

    private func shouldAutoCapitalizeNextEnglishLetter() -> Bool {
        guard isAutoCapitalizationEnabled,
              textInputLanguage == .english
        else { return false }

        switch textDocumentProxy.keyboardType {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .twitter, .webSearch, .asciiCapableNumberPad:
            return false
        default:
            break
        }

        let capitalizationPolicy = textDocumentProxy.autocapitalizationType ?? .sentences
        switch capitalizationPolicy {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            return context.isEmpty || context.last?.isWhitespace == true
        case .sentences:
            break
        @unknown default:
            break
        }

        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        guard !context.isEmpty else { return true }

        var crossedLineBreak = false
        for character in context.reversed() {
            let text = String(character)
            if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                if text.rangeOfCharacter(from: .newlines) != nil {
                    crossedLineBreak = true
                }
                continue
            }
            if crossedLineBreak { return true }
            return ".!?".contains(character)
        }
        return true
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
        case "\\": return "、"
        case "|": return "·"
        case "`": return "｀"
        case "~": return "～"
        case "$": return "￥"
        case "^": return "……"
        case "_": return "——"
        case "<": return "《"
        case ">": return "》"
        default: return character
        }
    }

    private func chineseDirectText(for character: String) -> String {
        guard chinesePunctuationStyle == .chinese else { return character }
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

    private func shouldInsertDirectChinesePunctuation(_ character: String) -> Bool {
        guard textInputLanguage == .chinese,
              chinesePunctuationStyle == .chinese,
              !isAlphabeticTextKey(character)
        else { return false }
        return ",.?!:;()\"'/\\|`~$^_<>-".contains(character)
    }

    private func insertChineseDirectTextKey(_ character: String) {
        let currentState = rimeInput.state()
        if currentState.isComposing {
            if let quickSelectIndex = quickCandidateIndex(for: character),
               quickSelectIndex < currentState.candidates.count {
                applyRimeState(rimeInput.selectCandidate(at: quickSelectIndex))
                return
            }
            if isRimeCompositionControlKey(character) {
                applyRimeState(rimeInput.processCharacter(character))
                return
            }
            applyRimeState(rimeInput.commitComposition())
        } else {
            replaceMarkedText("")
        }
        if shouldInsertDirectChinesePunctuation(character) {
            textDocumentProxy.insertText(chineseDirectText(for: character))
            resetShiftIfSticky()
            renderRestyleSuggestionsIfIdle()
            return
        }
        _ = rimeInput.setAsciiPunctuation(chinesePunctuationStyle == .english)
        _ = rimeInput.setAsciiMode(false)
        let state = rimeInput.processCharacter(character)
        applyRimeState(state)
        if state.commitText.isEmpty, !state.isComposing {
            textDocumentProxy.insertText(chineseDirectText(for: character))
        }
        resetShiftIfSticky()
        renderRestyleSuggestionsIfIdle()
    }

    private func quickCandidateIndex(for character: String) -> Int? {
        guard character.count == 1,
              let value = Int(character),
              value >= 1,
              value <= 9
        else { return nil }
        return value - 1
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
            textDocumentProxy.deleteBackward()
            return
        }
        deleteBackward(characterCount: count)
    }

    private func deleteBackwardToLineBoundary() {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let count = deletionCountToLineBoundary(in: context)
        guard count > 0 else {
            textDocumentProxy.deleteBackward()
            return
        }
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
            textTrackpadLastStepY = 0
            if rimeInput.state().isComposing {
                applyRimeState(rimeInput.commitComposition())
            }
            lightHaptic()
            setTextTrackpadMode(true)
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                keyView.alpha = 0.72
                keyView.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
            }
        case .changed:
            guard isTextSpaceCursorTracking else { return }
            updateTrackpadCursorPosition(deltaX: location.x - textSpaceCursorStartX, deltaY: 0)
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
        UIView.animate(withDuration: 0.10, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            keyView.alpha = 1
            keyView.transform = .identity
        }
        setTextTrackpadMode(false)
        renderRestyleSuggestionsIfIdle()
    }

    private func setTextTrackpadMode(_ enabled: Bool) {
        textTrackpadPanRecognizer.isEnabled = enabled
        if !enabled {
            textTrackpadLastStepX = 0
            textTrackpadLastStepY = 0
        }
        for button in textKeyboardButtons {
            button.isUserInteractionEnabled = !enabled || button === activeTrackpadSourceView
        }
        UIView.animate(withDuration: 0.10, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.keyRowsStack.alpha = enabled ? 0.25 : 1
            self.candidateScrollView.alpha = enabled ? 0.38 : 1
            self.quickCandidateRow.alpha = enabled ? 0.28 : 1
        }
    }

    @objc private func handleTextTrackpadPan(_ recognizer: UIPanGestureRecognizer) {
        guard isTextSpaceCursorTracking else { return }
        let translation = recognizer.translation(in: textKeyboardContainer)
        switch recognizer.state {
        case .changed:
            updateTrackpadCursorPosition(deltaX: translation.x, deltaY: translation.y)
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

    private func updateTrackpadCursorPosition(deltaX: CGFloat, deltaY: CGFloat) {
        let stepX = Int(deltaX / 8)
        let deltaStepX = stepX - textTrackpadLastStepX
        if deltaStepX != 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: deltaStepX)
            textTrackpadLastStepX = stepX
        }

        let stepY = Int(deltaY / 12)
        if stepY != textTrackpadLastStepY {
            textTrackpadLastStepY = stepY
        }
    }

    @objc private func insertReturn() {
        handleTextReturn()
    }

    private func lightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var currentBridgeStatus: KeyboardBridgeStatus? {
        bridgeStatus
    }

    private var isOpeningHostApp: Bool {
        openingHostUntil > Date().timeIntervalSince1970
    }

    private var isBridgeAwake: Bool {
        guard let status = currentBridgeStatus else { return false }
        guard Date().timeIntervalSince1970 - lastBridgeContactAt < 3 else { return false }
        return status.state != .idle
    }

    /// One short line, under the orb. Doubles as the only verbal hint — the
    /// orb's color and pulse rings carry the rest of the state.
    private var voiceTitle: String {
        if isOpeningHostApp { return NSLocalizedString("Opening Typeforme…", comment: "Voice title when host is launching") }
        switch currentBridgeStatus?.state {
        case .recording: return inputMode.recordingTitle
        case .sending: return NSLocalizedString("Transcribing", comment: "Voice title during transcription")
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

    private var statusText: String {
        if !hasFullAccess {
            return NSLocalizedString("Setup", comment: "Status when Full Access missing")
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
            return NSLocalizedString("Sending", comment: "Status during transcription/sending")
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

    private func syncKeyboardSettingsToHost() {
        guard hasFullAccess, isBridgeAwake else { return }
        sendBridgeCommand(.configure)
    }

    private func sendBridgeCommand(_ action: KeyboardBridgeCommandAction) {
        let command = KeyboardBridgeCommand(
            action: action,
            correctionMode: correctionMode.rawValue
        )
        sendBridgeCommand(command)
    }

    private func sendBridgeCommand(_ command: KeyboardBridgeCommand) {
        let action = command.action
        if action != .configure {
            if action == .start, command.textEditContext != nil || command.dictationContext != nil {
                sendLocalBridgeCommand(command)
                return
            }
            if action == .stop {
                sendLocalBridgeCommand(command)
                return
            }
            sendDarwinBridgeCommand(action, commandID: command.id)
            return
        }

        sendLocalBridgeCommand(command)
    }

    private func sendLocalBridgeCommand(_ command: KeyboardBridgeCommand) {
        if command.action == .start || command.action == .stop {
            if command.action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if command.action == .stop {
                tapRecordingActive = false
            }
            bridgeStatus = KeyboardBridgeStatus(
                commandID: command.id,
                state: command.action == .start ? .standby : .sending,
                message: command.action == .start ? "Starting recording" : "Sending"
            )
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(command, timeout: command.action.requestTimeout)
                await MainActor.run {
                    self.applyBridgeStatus(status)
                    if command.action == .start {
                        self.finishStartRequestIfNeeded(status: status)
                    }
                }
            } catch {
                await MainActor.run {
                    if command.action == .stop {
                        self.sendDarwinBridgeCommand(.stop, commandID: command.id)
                        return
                    }
                    if command.action == .start {
                        if command.textEditContext == nil {
                            self.sendDarwinBridgeCommand(.start, commandID: command.id)
                            return
                        }
                        self.isStartRequestInFlight = false
                        self.activeRecordingTextTarget = nil
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
    }

    private func sendDarwinBridgeCommand(_ action: KeyboardBridgeCommandAction, commandID: String) {
        if action == .start || action == .stop {
            if action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if action == .stop {
                tapRecordingActive = false
            }
            bridgeStatus = KeyboardBridgeStatus(
                commandID: commandID,
                state: action == .start ? .standby : .sending,
                message: action == .start ? "Starting recording" : "Sending"
            )
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        switch action {
        case .start:
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestStartDictation)
            scheduleHostOpenIfStartStalls()
        case .stop:
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestStopDictation)
        case .cancel:
            tapRecordingActive = false
            activeRecordingTextTarget = nil
            cancelScheduledHostOpen()
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestCancelDictation)
        case .configure, .restyleText:
            break
        }
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
    }

    private func scheduleHostOpenIfStartStalls() {
        cancelScheduledHostOpen()
        scheduledHostOpenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
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
    }

    private func startStatusPolling(interval: TimeInterval = 0.35) {
        guard statusTimer == nil else { return }
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

    private func scheduleDeferredStartupProbe() {
        deferredStartupWorkItem?.cancel()
        hasPresentedInitialFrame = false
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.startStatusPolling()
            self.refreshBridgeStatus(captureSelection: false)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestSessionStatus)
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

    private func refreshBridgeStatus(captureSelection: Bool = true) {
        if captureSelection {
            refreshSelectionSnapshot()
        }
        guard hasFullAccess else { return }
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.status()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.applyBridgeStatus(status)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
    }

    private func applyBridgeStatus(_ status: KeyboardBridgeStatus) {
        if isStartRequestInFlight && status.state == .standby {
            return
        }
        if status.state != .idle {
            openingHostUntil = 0
        }
        if status.state == .recording, inputMode == .tap {
            tapRecordingActive = true
        } else if status.state != .recording && status.state != .sending {
            tapRecordingActive = false
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
            if hasFullAccess {
                UIPasteboard.general.string = text
            }
            let didApply: Bool
            if let target = activeRecordingTextTarget {
                didApply = applyRewrittenText(text, replacing: target)
                activeRecordingTextTarget = nil
            } else {
                textDocumentProxy.insertText(text)
                didApply = true
            }
            if didApply {
                defaults.set(commandID, forKey: lastInsertedCommandIDKey)
                defaults.set(text, forKey: lastInsertedTextKey)
                recentSelectionTarget = nil
                rememberRestyleText(text)
                renderRestyleSuggestionsIfIdle()
            } else {
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
