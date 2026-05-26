import AVFoundation
import Darwin
import Foundation
import Network
import ObjectiveC
import OSLog
import Speech
import UIKit

private let appLog = Logger(subsystem: "com.example.typeforme", category: "app")

/// Top-level UI phase for the iOS host app. Drives the hero record card,
/// busy/disabled gating, and the keyboard bridge status. Keep user-facing
/// labels derived from this typed state rather than using strings as control
/// flow.
enum AppPhase: Equatable {
    case idle
    case preparing
    case recording
    case sending
    case restyling
    case success(SuccessKind)
    case failure(String)

    enum SuccessKind: Equatable {
        case ready
        case copied
        case inserted
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .sending, .restyling: return true
        default: return false
        }
    }

    var allowsRecordingStart: Bool {
        switch self {
        case .idle, .success, .failure: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .sending: return "Transcribing"
        case .restyling: return "Refining"
        case .success(.ready): return "Result ready"
        case .success(.copied): return "Copied"
        case .success(.inserted): return "Inserted"
        case .failure(let msg): return msg
        }
    }
}

enum HostAudioSessionLength: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case untilStopped = "until_stopped"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        case .untilStopped: return "Until app stops"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .untilStopped: return nil
        }
    }
}

enum KeyboardChinesePunctuationStyle: String, CaseIterable, Identifiable {
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinese:
            return NSLocalizedString("Chinese", comment: "Chinese keyboard punctuation style")
        case .english:
            return NSLocalizedString("English", comment: "Chinese keyboard punctuation style")
        }
    }
}

enum KeyboardRimeDictionaryTier: String, CaseIterable, Identifiable {
    case standard
    case extended
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return NSLocalizedString("Standard", comment: "Rime dictionary tier")
        case .extended:
            return NSLocalizedString("Extended", comment: "Rime dictionary tier")
        case .large:
            return NSLocalizedString("Large", comment: "Rime dictionary tier")
        }
    }
}

enum KeyboardDefaultTextInputLanguage: String, CaseIterable, Identifiable {
    case lastUsed = "last_used"
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastUsed:
            return NSLocalizedString("Last Used", comment: "Default keyboard text input language")
        case .chinese:
            return NSLocalizedString("Chinese", comment: "Default keyboard text input language")
        case .english:
            return NSLocalizedString("English", comment: "Default keyboard text input language")
        }
    }
}

enum AppleSpeechPreviewCapability: Equatable {
    case unsupported
    case cloud
    case onDevice

    var supportsPreview: Bool {
        self != .unsupported
    }

    var supportsOnDevicePreview: Bool {
        self == .onDevice
    }
}

enum AppleSpeechPreviewSupport {
    private static let cacheLock = NSLock()
    private static var cachedCapabilities: [String: AppleSpeechPreviewCapability] = [:]
    private static let supportedLocaleIDs: Set<String> = Set(
        SFSpeechRecognizer.supportedLocales().map { normalizedIdentifier($0.identifier) }
    )

    static func capability(languageID: String) -> AppleSpeechPreviewCapability {
        let normalizedID = normalizedIdentifier(languageID)
        cacheLock.lock()
        if let cached = cachedCapabilities[normalizedID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let capability = resolveCapability(languageID: languageID, normalizedID: normalizedID)

        cacheLock.lock()
        cachedCapabilities[normalizedID] = capability
        cacheLock.unlock()
        return capability
    }

    private static func resolveCapability(languageID: String, normalizedID: String) -> AppleSpeechPreviewCapability {
        let locale = Locale(identifier: languageID)
        guard supportedLocaleIDs.contains(normalizedID),
              let recognizer = SFSpeechRecognizer(locale: locale)
        else { return .unsupported }
        return recognizer.supportsOnDeviceRecognition ? .onDevice : .cloud
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}

enum KeyboardLivePreviewRecognitionMode: String, CaseIterable, Identifiable {
    case onDeviceOnly = "on_device_only"
    case cloudFallback = "cloud_fallback"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDeviceOnly:
            return NSLocalizedString("On-device Only", comment: "Apple Speech preview recognition mode")
        case .cloudFallback:
            return NSLocalizedString("Cloud Fallback", comment: "Apple Speech preview recognition mode")
        }
    }

    var allowsCloud: Bool {
        self == .cloudFallback
    }

    func canUse(_ capability: AppleSpeechPreviewCapability) -> Bool {
        switch capability {
        case .onDevice:
            return true
        case .cloud:
            return allowsCloud
        case .unsupported:
            return false
        }
    }
}

struct ServerTimingSummary: Equatable {
    var transcriptionLatencyMs: Int?
    var correctionLatencyMs: Int?
    var totalLatencyMs: Int?

    var displayText: String? {
        var parts: [String] = []
        if let transcriptionLatencyMs {
            parts.append("Transcription \(transcriptionLatencyMs)ms")
        }
        if let correctionLatencyMs {
            parts.append("Refine \(correctionLatencyMs)ms")
        }
        if parts.isEmpty, let totalLatencyMs {
            parts.append("Total \(totalLatencyMs)ms")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var config: PairingConfig
    @Published var correctionMode: CorrectionModeID
    @Published var inputMode: VoiceInputMode
    @Published var selectedLanguageIDs: Set<String>
    @Published var resultText = ""
    @Published var rawTranscript = ""
    @Published var sessionID: String?
    @Published var phase: AppPhase = .idle
    @Published var errorMessage: String?
    @Published var routeStatus = BridgeRouteStatus()
    @Published private(set) var isRefreshingRoute = false
    @Published var keyboardStandbyEnabled = true
    @Published var hostAudioSessionLength: HostAudioSessionLength
    @Published var keyboardAutoCapitalizationEnabled: Bool
    @Published var keyboardCharacterPreviewEnabled: Bool
    @Published var keyboardLivePreviewEnabled: Bool
    @Published var keyboardLivePreviewRecognitionMode: KeyboardLivePreviewRecognitionMode
    @Published var keyboardChinesePunctuationStyle: KeyboardChinesePunctuationStyle
    @Published var keyboardRimeDictionaryTier: KeyboardRimeDictionaryTier
    @Published var keyboardRimeCorrectionEnabled: Bool
    @Published var keyboardDefaultTextInputLanguage: KeyboardDefaultTextInputLanguage
    @Published private(set) var keyboardRimeLearningResetGeneration: Int
    @Published private(set) var keyboardTouchLearningResetGeneration: Int
    @Published var keyboardBridgeStatus = KeyboardBridgeStatus.idle
    /// True once the keyboard extension has successfully contacted the host
    /// (via the local bridge server or a Darwin notification). A successful
    /// contact implies the keyboard is enabled AND has Full Access — without
    /// Full Access the extension can't open a local network connection. Used
    /// by SetupStatusCard to decide whether to default-expand the onboarding
    /// hints. Persisted in UserDefaults so it survives app restarts.
    @Published var keyboardEverContacted: Bool
    @Published var keyboardFullAccessRequired: Bool
    @Published var lastRecordingSummary = ""
    @Published var processingStatusMessage: String?
    @Published var latestServerTiming: ServerTimingSummary?
    @Published var macSettings: BridgeMacSettingsPayload?
    @Published var isEditingMacSettings = false
    @Published private(set) var showsReturnButton = false
    @Published private(set) var isStopAndSendInFlight = false
    /// Transient feedback ("Copied!", "Saved!") rendered as a toast.
    @Published var transientMessage: String?

    var keyboardNeedsFullAccessSetup: Bool {
        keyboardFullAccessRequired || !keyboardEverContacted
    }

    let audioCoordinator = AudioCoordinator()

    private let bridgeService = BridgeService()
    private let keyboardCoordinator = KeyboardCoordinator()
    private let keyboardServer = KeyboardLocalServer()
    private let returnTracker = ReturnTracker(
        logName: "typeforme-return-trace.log",
        enabledKey: "debug.returnTraceEnabled"
    )
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(label: "com.example.typeforme.network-path")
    private static let inputModeKey = "keyboard.inputMode"
    private static let hostAudioSessionLengthKey = "keyboard.hostAudioSessionLength"
    private static let keyboardAutoCapitalizationKey = "keyboard.autoCapitalizationEnabled"
    private static let keyboardCharacterPreviewKey = "keyboard.characterPreviewEnabled"
    private static let keyboardLivePreviewKey = "keyboard.livePreviewEnabled"
    private static let keyboardLivePreviewRecognitionModeKey = "keyboard.livePreviewRecognitionMode"
    private static let keyboardChinesePunctuationStyleKey = "keyboard.chinesePunctuationStyle"
    private static let keyboardRimeDictionaryTierKey = "keyboard.rimeDictionaryTier"
    private static let keyboardRimeCorrectionKey = "keyboard.rimeCorrectionEnabled"
    private static let keyboardDefaultTextInputLanguageKey = "keyboard.defaultTextInputLanguage"
    private static let keyboardRimeLearningResetGenerationKey = "keyboard.rimeLearningResetGeneration"
    private static let keyboardTouchLearningResetGenerationKey = "keyboard.touchLearningResetGeneration"
    private static let keyboardEverContactedKey = "keyboard.everContacted"
    private static let keyboardFullAccessRequiredKey = "keyboard.fullAccessRequired"
    private static let serverRimeUserPhrasesKey = "server.rimeUserPhrases"
    private static let recordingTailBufferNanoseconds: UInt64 = 200_000_000
    private var hostHoldReleasePending = false
    private var hostRecordingUsesKeyboardAudioSession = false
    private var keyboardCaptureStartedFromKeyboard = false
    private var activeKeyboardRecordingCommandID: String?
    private var queuedKeyboardStopCommandID: String?
    private var hostAudioSessionExpiryTask: Task<Void, Never>?
    private var keyboardStandbyRefreshTask: Task<Void, Never>?
    private var routeFetchedAt: Date?
    private var networkPathSignature: String?
    private var lastNetworkPathRefreshAt: Date?
    private var macSettingsFetchedAt: Date?
    private var macSettingsRevision: String?
    private var cachedServerRimeUserPhrases: [String]
    private var returnBundleID: String?
    private var phaseResetTask: Task<Void, Never>?
    private var transientMessageTask: Task<Void, Never>?
    private var initialRenderDelayTask: Task<Void, Never>?
    private var recorderPreWarmTask: Task<Void, Never>?
    /// Live-preview transcript fed by SFSpeechRecognizer while the user is
    /// recording (and held in place until the Mac final result replaces it).
    /// Empty string = no preview surfaced (unsupported language, denied
    /// permission, or no recording in progress).
    @Published private(set) var livePartialTranscript: String = ""
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveSpeechTask: SFSpeechRecognitionTask?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    private var routeRefreshInFlightCount = 0
    private var idleTimerHolders = 0
    private var lastGeneratedResultText: String?
    private var activeKeyboardTextEditContext: KeyboardTextEditContext?
    private var activeKeyboardDictationContext: KeyboardDictationContext?
    private var canceledKeyboardCommandIDs: [String: TimeInterval] = [:]
    private var lastHandledOpenURL: (value: String, time: TimeInterval)?

    /// Force-refresh cloud/unavailable routes if cached probe is older than
    /// this. Local routes get a shorter TTL because stale LAN IPs hurt more
    /// than the extra probe.
    private static let routeCacheTTL: TimeInterval = 30
    private static let localRouteCacheTTL: TimeInterval = 5
    private static let networkPathSameSignatureRefreshInterval: TimeInterval = 2
    private static let canceledKeyboardCommandTTL: TimeInterval = 10
    /// How long a `.success` / `.failure` phase sticks before reverting to
    /// `.idle`. Long enough to read, short enough not to block the next press.
    private static let phaseAutoResetDelay: TimeInterval = 2.4

    private struct RestyleSource {
        let sessionID: String?
        let rawTranscript: String?
    }

    private enum MicrophonePermissionRequestResult: Equatable {
        case granted
        case denied
        case unavailable
    }

    var recorder: AudioRecorder {
        audioCoordinator.recorder
    }

    private var keyboardAudioSession: StandbyAudioSession {
        audioCoordinator.keyboardAudioSession
    }

    private var standbyKeeper: StandbyKeeper {
        audioCoordinator.standbyKeeper
    }

    private var store: PairingStore {
        bridgeService.store
    }

    private var routeResolver: BridgeRouteResolver {
        bridgeService.routeResolver
    }

    private var keyboardBridgeToken: String {
        keyboardCoordinator.bridgeToken
    }

    var isBusy: Bool {
        phase.isBusy
    }

    var canRestyleCurrentResult: Bool {
        !phase.isBusy && currentRestyleSource() != nil
    }

    var isConfigured: Bool {
        !config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && config.hasAnyBridgeURL
    }

    var isReadyToRecord: Bool {
        isConfigured && !isBusy
    }

    var canInteractWithHostDictation: Bool {
        guard isConfigured else { return false }
        if recorder.isRecording || keyboardAudioSession.isRecording || phase == .preparing { return true }
        return phase.allowsRecordingStart
    }

    var hostRecordingLevel: Float {
        hostRecordingUsesKeyboardAudioSession ? keyboardAudioSession.level : recorder.level
    }

    var activeModelInstallText: String? {
        guard let status = macSettings?.modelStatuses.first(where: { $0.installing }) else {
            return nil
        }
        let prefix = status.kind == "asr" ? "Installing ASR" : "Installing Refine"
        return "\(prefix): \(status.displayName)"
    }

    private var activeLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(
            Array(selectedLanguageIDs),
            supportedOptions: config.supportedLanguageOptions
        )
    }

    init() {
        let saved = PairingStore().load()
        self.config = saved
        self.correctionMode = saved.correctionMode
        self.inputMode = UserDefaults.standard.string(forKey: Self.inputModeKey)
            .flatMap(VoiceInputMode.init(rawValue:)) ?? .hold
        self.hostAudioSessionLength = UserDefaults.standard.string(forKey: Self.hostAudioSessionLengthKey)
            .flatMap(HostAudioSessionLength.init(rawValue:)) ?? .thirtyMinutes
        self.keyboardAutoCapitalizationEnabled = UserDefaults.standard.object(forKey: Self.keyboardAutoCapitalizationKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardAutoCapitalizationKey) } ?? true
        self.keyboardCharacterPreviewEnabled = UserDefaults.standard.object(forKey: Self.keyboardCharacterPreviewKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardCharacterPreviewKey) } ?? false
        self.keyboardLivePreviewEnabled = UserDefaults.standard.object(forKey: Self.keyboardLivePreviewKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardLivePreviewKey) } ?? true
        self.keyboardLivePreviewRecognitionMode = UserDefaults.standard.string(forKey: Self.keyboardLivePreviewRecognitionModeKey)
            .flatMap(KeyboardLivePreviewRecognitionMode.init(rawValue:)) ?? .onDeviceOnly
        self.keyboardChinesePunctuationStyle = UserDefaults.standard.string(forKey: Self.keyboardChinesePunctuationStyleKey)
            .flatMap(KeyboardChinesePunctuationStyle.init(rawValue:)) ?? .chinese
        self.keyboardRimeDictionaryTier = UserDefaults.standard.string(forKey: Self.keyboardRimeDictionaryTierKey)
            .flatMap(KeyboardRimeDictionaryTier.init(rawValue:)) ?? .standard
        self.keyboardRimeCorrectionEnabled = UserDefaults.standard.object(forKey: Self.keyboardRimeCorrectionKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardRimeCorrectionKey) } ?? true
        self.keyboardDefaultTextInputLanguage = UserDefaults.standard.string(forKey: Self.keyboardDefaultTextInputLanguageKey)
            .flatMap(KeyboardDefaultTextInputLanguage.init(rawValue:)) ?? .lastUsed
        self.keyboardRimeLearningResetGeneration = UserDefaults.standard.integer(forKey: Self.keyboardRimeLearningResetGenerationKey)
        self.keyboardTouchLearningResetGeneration = UserDefaults.standard.integer(forKey: Self.keyboardTouchLearningResetGenerationKey)
        self.keyboardEverContacted = UserDefaults.standard.bool(forKey: Self.keyboardEverContactedKey)
        self.keyboardFullAccessRequired = UserDefaults.standard.bool(forKey: Self.keyboardFullAccessRequiredKey)
        self.cachedServerRimeUserPhrases = Self.loadCachedServerRimeUserPhrases()
        self.selectedLanguageIDs = Set(saved.validatedLanguageIDs)
        self.keyboardStandbyEnabled = true
        configureKeyboardServer()
        configureKeyboardDarwinBridge()
        installLifecycleObservers()
        startNetworkPathMonitor()
        publishKeyboardDefaults(force: true)
        scheduleHostRecorderPreWarm()
    }

    deinit {
        hostAudioSessionExpiryTask?.cancel()
        keyboardStandbyRefreshTask?.cancel()
        recorderPreWarmTask?.cancel()
        networkPathMonitor.cancel()
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for observer in keyboardDarwinObservers {
            observer.stopObserving()
        }
        keyboardServer.stop()
        keyboardServer.expectedTokenProvider = nil
        keyboardServer.statusProvider = nil
        keyboardServer.onCommand = nil
    }

    func bootstrap() async {
        await waitForInitialRenderOpportunity()
        await setKeyboardStandby(true, surfaceAudioSessionErrors: false)
        await refreshRoute(force: true, showIndicator: false)
        _ = try? await refreshMacSettingsIfChanged()
        scheduleHostRecorderPreWarm()
    }

    func saveConfig(_ newConfig: PairingConfig) {
        var normalized = newConfig
        normalized.normalizeLanguageIDs()
        config = normalized
        correctionMode = normalized.correctionMode
        selectedLanguageIDs = Set(normalized.validatedLanguageIDs)
        store.save(normalized)
        publishKeyboardDefaults()
        routeFetchedAt = nil
        Task {
            await refreshRoute(force: true)
            _ = try? await refreshMacSettings()
        }
    }

    func unpair() {
        let empty = PairingConfig.empty
        config = empty
        correctionMode = empty.correctionMode
        selectedLanguageIDs = Set(empty.validatedLanguageIDs)
        store.delete()
        routeStatus = BridgeRouteStatus()
        routeFetchedAt = nil
        macSettings = nil
        macSettingsFetchedAt = nil
        macSettingsRevision = nil
        cachedServerRimeUserPhrases = []
        UserDefaults.standard.removeObject(forKey: Self.serverRimeUserPhrasesKey)
        errorMessage = nil
        setPhase(.idle)
        publishKeyboardDefaults(force: true)
    }

    func persistLanguageSelection() {
        let ordered = ASRLanguageSelection.validatedIDs(
            Array(selectedLanguageIDs),
            supportedOptions: config.supportedLanguageOptions
        )
        selectedLanguageIDs = Set(ordered)
        config.languageIDs = ordered
        store.save(config)
    }

    func setInputMode(_ mode: VoiceInputMode) {
        guard mode != inputMode else { return }
        inputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.inputModeKey)
    }

    func setHostAudioSessionLength(_ length: HostAudioSessionLength) {
        guard length != hostAudioSessionLength else { return }
        hostAudioSessionLength = length
        UserDefaults.standard.set(length.rawValue, forKey: Self.hostAudioSessionLengthKey)
        scheduleHostAudioSessionExpiry()
    }

    func setKeyboardAutoCapitalizationEnabled(_ enabled: Bool) {
        guard enabled != keyboardAutoCapitalizationEnabled else { return }
        keyboardAutoCapitalizationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keyboardAutoCapitalizationKey)
        publishKeyboardDefaults()
    }

    func setKeyboardCharacterPreviewEnabled(_ enabled: Bool) {
        guard enabled != keyboardCharacterPreviewEnabled else { return }
        keyboardCharacterPreviewEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keyboardCharacterPreviewKey)
        publishKeyboardDefaults()
    }

    func setKeyboardLivePreviewEnabled(_ enabled: Bool) {
        guard enabled != keyboardLivePreviewEnabled else { return }
        keyboardLivePreviewEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keyboardLivePreviewKey)
        if !enabled {
            teardownLivePartialPreview(clearText: true)
        }
    }

    func setKeyboardLivePreviewRecognitionMode(_ mode: KeyboardLivePreviewRecognitionMode) {
        guard mode != keyboardLivePreviewRecognitionMode else { return }
        keyboardLivePreviewRecognitionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.keyboardLivePreviewRecognitionModeKey)
    }

    func setKeyboardChinesePunctuationStyle(_ style: KeyboardChinesePunctuationStyle) {
        guard style != keyboardChinesePunctuationStyle else { return }
        keyboardChinesePunctuationStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.keyboardChinesePunctuationStyleKey)
        publishKeyboardDefaults()
    }

    func setKeyboardRimeDictionaryTier(_ tier: KeyboardRimeDictionaryTier) {
        guard tier != keyboardRimeDictionaryTier else { return }
        keyboardRimeDictionaryTier = tier
        UserDefaults.standard.set(tier.rawValue, forKey: Self.keyboardRimeDictionaryTierKey)
        publishKeyboardDefaults()
    }

    func setKeyboardRimeCorrectionEnabled(_ enabled: Bool) {
        guard enabled != keyboardRimeCorrectionEnabled else { return }
        keyboardRimeCorrectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keyboardRimeCorrectionKey)
        publishKeyboardDefaults()
    }

    func setKeyboardDefaultTextInputLanguage(_ language: KeyboardDefaultTextInputLanguage) {
        guard language != keyboardDefaultTextInputLanguage else { return }
        keyboardDefaultTextInputLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.keyboardDefaultTextInputLanguageKey)
        publishKeyboardDefaults()
    }

    func resetKeyboardRimeLearning() {
        keyboardRimeLearningResetGeneration += 1
        UserDefaults.standard.set(
            keyboardRimeLearningResetGeneration,
            forKey: Self.keyboardRimeLearningResetGenerationKey
        )
        publishKeyboardDefaults(force: true)
        showTransient(NSLocalizedString("Chinese learning reset requested", comment: "Rime learning reset toast"))
    }

    func resetKeyboardTouchLearning() {
        keyboardTouchLearningResetGeneration += 1
        UserDefaults.standard.set(
            keyboardTouchLearningResetGeneration,
            forKey: Self.keyboardTouchLearningResetGenerationKey
        )
        publishKeyboardDefaults(force: true)
        showTransient(NSLocalizedString("Touch learning reset requested", comment: "Touch learning reset toast"))
    }

    func refreshRoute(
        force: Bool = false,
        probeAllEndpoints: Bool = true,
        showIndicator: Bool = true
    ) async {
        let cacheTTL = routeStatus.activeKind == .local ? Self.localRouteCacheTTL : Self.routeCacheTTL
        if !force, let routeFetchedAt,
           Date().timeIntervalSince(routeFetchedAt) < cacheTTL,
           routeStatus.activeURL != nil,
           routeStatusSatisfiesProbeMode(probeAllEndpoints) {
            return
        }
        if showIndicator {
            beginRouteRefreshIndicator()
        }
        defer {
            if showIndicator {
                endRouteRefreshIndicator()
            }
        }
        routeStatus = await routeResolver.resolve(config: config, probeAllEndpoints: probeAllEndpoints)
        persistActiveLocalRouteIfNeeded(routeStatus)
        routeFetchedAt = Date()
    }

    private func preflightActiveBridgeRoute() async {
        guard let baseURL = routeStatus.activeURL else {
            await refreshRoute(force: true, probeAllEndpoints: false, showIndicator: false)
            return
        }

        let timeout = routeStatus.activeKind == .cloud ? 3.0 : 1.5
        let isHealthy = await BridgeClient(baseURL: baseURL, token: config.token).health(timeout: timeout)
        guard isHealthy else {
            routeFetchedAt = nil
            await refreshRoute(force: true, probeAllEndpoints: false, showIndicator: false)
            return
        }
        routeFetchedAt = Date()
    }

    private func beginRouteRefreshIndicator() {
        routeRefreshInFlightCount += 1
        isRefreshingRoute = true
    }

    private func endRouteRefreshIndicator() {
        routeRefreshInFlightCount = max(0, routeRefreshInFlightCount - 1)
        isRefreshingRoute = routeRefreshInFlightCount > 0
    }

    private func routeStatusSatisfiesProbeMode(_ probeAllEndpoints: Bool) -> Bool {
        guard probeAllEndpoints else { return true }
        let localConfigured = !config.localBridgeURLCandidates.isEmpty
        let cloudConfigured = !config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (!localConfigured || routeStatus.localChecked) &&
            (!cloudConfigured || routeStatus.cloudChecked)
    }

    func refreshMacSettings(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload {
        let client = try await activeBridgeClient()
        var settings = try await client.macSettings(timeout: timeout)
        settings.normalize()
        applyMacSettings(settings)
        return settings
    }

    @discardableResult
    private func refreshMacSettingsIfChanged(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload? {
        let client = try await activeBridgeClient()
        let localRevision = macSettingsRevision ?? macSettings?.settingsRevision
        if let localRevision,
           !localRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let health = try await client.healthResponse(timeout: min(timeout, 3))
            if let remoteRevision = health.settingsRevision?.trimmingCharacters(in: .whitespacesAndNewlines),
               !remoteRevision.isEmpty,
               remoteRevision == localRevision {
                macSettingsFetchedAt = Date()
                return macSettings
            }
        }
        var settings = try await client.macSettings(timeout: timeout)
        settings.normalize()
        applyMacSettings(settings)
        return settings
    }

    func updateMacSettings(_ settings: BridgeMacSettingsPayload) async throws -> BridgeMacSettingsPayload {
        var normalized = settings
        normalized.normalize()
        let client = try await activeBridgeClient()
        var updated = try await client.updateMacSettings(normalized)
        updated.normalize()
        applyMacSettings(updated)
        return updated
    }

    private func applyMacSettings(_ settings: BridgeMacSettingsPayload) {
        macSettings = settings
        macSettingsFetchedAt = Date()
        macSettingsRevision = settings.settingsRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedServerRimeUserPhrases = settings.rimeUserPhrases
        UserDefaults.standard.set(settings.rimeUserPhrases, forKey: Self.serverRimeUserPhrasesKey)
        config.supportedLanguages = settings.supportedLanguages
        // `config.correctionMode` tracks the server's current default so a
        // new scene (clearResult / cold start / unpair) can fall back to it.
        // Do NOT push it onto the live `correctionMode` — the user's chip
        // selection must survive Mac-settings refreshes (previous behavior
        // here forced re-align to server, which users found jarring).
        config.correctionMode = settings.correctionMode
        config.languageIDs = ASRLanguageSelection.validatedIDs(
            config.languageIDs,
            supportedOptions: config.supportedLanguageOptions
        )
        selectedLanguageIDs = Set(config.validatedLanguageIDs)
        store.save(config)
        publishKeyboardDefaults()
    }

    private func scheduleHostRecorderPreWarm() {
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        guard !recorder.isRecording,
              !keyboardAudioSession.isRecording,
              !keyboardAudioSession.isActive
        else { return }
        recorderPreWarmTask?.cancel()
        recorderPreWarmTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  !self.recorder.isRecording,
                  !self.keyboardAudioSession.isActive,
                  !self.phase.isBusy
            else { return }
            await self.recorder.preWarm()
        }
    }

    private func resetCorrectionModeToDefault() {
        guard correctionMode != config.correctionMode else { return }
        correctionMode = config.correctionMode
    }

    private func applyKeyboardDefaultCorrectionMode(_ mode: CorrectionModeID) {
        let configChanged = config.correctionMode != mode
        let visibleChanged = correctionMode != mode
        guard configChanged || visibleChanged else { return }
        config.correctionMode = mode
        correctionMode = mode
        if configChanged {
            store.save(config)
            publishKeyboardDefaults()
        }
    }

    private func publishKeyboardDefaults(force: Bool = false) {
        keyboardCoordinator.publishDefaults(
            correctionMode: config.correctionMode,
            autoCapitalizationEnabled: keyboardAutoCapitalizationEnabled,
            characterPreviewEnabled: keyboardCharacterPreviewEnabled,
            chinesePunctuationStyle: keyboardChinesePunctuationStyle,
            rimeDictionaryTier: keyboardRimeDictionaryTier,
            rimeCorrectionEnabled: keyboardRimeCorrectionEnabled,
            rimeUserPhrases: macSettings?.rimeUserPhrases ?? cachedServerRimeUserPhrases,
            defaultTextInputLanguage: keyboardDefaultTextInputLanguage,
            rimeLearningResetGeneration: keyboardRimeLearningResetGeneration,
            touchLearningResetGeneration: keyboardTouchLearningResetGeneration,
            force: force
        )
    }

    private static func loadCachedServerRimeUserPhrases() -> [String] {
        if let phrases = UserDefaults.standard.stringArray(forKey: Self.serverRimeUserPhrasesKey) {
            return phrases
        }
        if let phrases = KeyboardSharedDefaults.loadPayload()?["rime_user_phrases"] as? [String] {
            return phrases
        }
        return []
    }

    private func persistActiveLocalRouteIfNeeded(_ status: BridgeRouteStatus) {
        guard status.activeKind == .local,
              let activeURL = status.activeURL?.absoluteString
        else { return }

        let previous = config.localBridgeURLCandidates
        config.promoteLocalBridgeURL(activeURL)
        if config.localBridgeURLCandidates != previous {
            store.save(config)
        }
    }

    private func activeBridgeClient() async throws -> BridgeClient {
        if routeStatus.activeURL == nil {
            await refreshRoute(force: true, probeAllEndpoints: false, showIndicator: false)
        }
        guard let baseURL = routeStatus.activeURL else {
            throw BridgeClientError.unauthorizedOrUnavailable
        }
        return BridgeClient(baseURL: baseURL, token: config.token)
    }

    private func shouldRetryBridgeRequest(after error: Error) -> Bool {
        if let bridgeError = error as? BridgeClientError {
            if case .unauthorizedOrUnavailable = bridgeError {
                return true
            }
            return false
        }

        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .cannotLoadFromNetwork,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func dictateWithRouteRetry(
        initialBaseURL: URL,
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: CorrectionModeID,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool,
        keyboardCommandID: String?,
        recordingInfo: RecordingFileInfo
    ) async throws -> BridgeDictateResponse {
        // Snapshot the live preview text *before* tearing down — Mac uses it
        // as a supplementary hypothesis (neutral framing, no "from Apple
        // Speech" attribution; see prompt design in baseSystem).
        let alternate = livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternateForBridge: String? = alternate.isEmpty ? nil : alternate
        func dictate(to baseURL: URL) async throws -> BridgeDictateResponse {
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            let jobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            return try await client.dictate(
                audioURL: audioURL,
                audioExtension: audioExtension,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                includeRawTranscript: includeRawTranscript,
                clientJobID: jobID,
                alternateTranscript: alternateForBridge,
                onJobEvent: { event in
                    await MainActor.run {
                        self.applyBridgeJobStatus(
                            event,
                            keyboardCommandID: keyboardCommandID,
                            recordingInfo: recordingInfo
                        )
                    }
                }
            )
        }

        do {
            return try await dictate(to: initialBaseURL)
        } catch {
            guard shouldRetryBridgeRequest(after: error) else { throw error }
            routeFetchedAt = nil
            if let keyboardCommandID {
                publishKeyboardStatus(
                    .sending,
                    commandID: keyboardCommandID,
                    message: NSLocalizedString("Transcribing", comment: "Bridge job stage"),
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount
                )
            }
            await refreshRoute(force: true, probeAllEndpoints: false, showIndicator: false)
            guard let retryBaseURL = routeStatus.activeURL else { throw error }
            return try await dictate(to: retryBaseURL)
        }
    }

    // MARK: - Recording (host UI)

    func toggleRecording() async {
        if recorder.isRecording {
            await stopAndSend()
        } else {
            await startRecording()
        }
    }

    func toggleHostTapRecording() async {
        if recorder.isRecording || phase == .recording {
            await stopAndSend()
        } else {
            await startRecording()
        }
    }

    func beginHostHoldRecording() async {
        guard !recorder.isRecording, !keyboardAudioSession.isRecording else { return }
        guard isConfigured else {
            setFailure("Pair the Mac Bridge first.")
            return
        }
        guard phase.allowsRecordingStart else { return }

        hostHoldReleasePending = false
        setPhase(.preparing)
        errorMessage = nil

        guard await ensureMicrophonePermissionForUserAction() else {
            hostHoldReleasePending = false
            if phase == .preparing {
                setPhase(.idle)
            }
            return
        }

        // Keep the press-to-record path local-only. Mac settings refresh can
        // take seconds on a stale route; foreground/bootstrap keep it warm.
        // Note: do NOT reset correctionMode here — the user's last chip pick
        // must persist across recordings within a scene. New scenes (clear /
        // unpair / cold start) handle the reset themselves.
        do {
            try await startHostRecordingCapture()
            acquireIdleTimer()
            setPhase(.recording)
        } catch {
            setFailure(error.localizedDescription)
            await resumeKeyboardStandbyAfterCommand()
        }

        if hostHoldReleasePending {
            hostHoldReleasePending = false
            if recorder.isRecording || keyboardAudioSession.isRecording {
                await stopAndSend()
            }
        }
    }

    func endHostHoldRecording() async {
        if phase == .preparing {
            hostHoldReleasePending = true
            return
        }
        guard recorder.isRecording || keyboardAudioSession.isRecording else { return }
        await stopAndSend()
    }

    func startRecording() async {
        errorMessage = nil
        guard isConfigured else {
            setFailure("Pair the Mac Bridge first.")
            return
        }
        guard phase.allowsRecordingStart else { return }
        setPhase(.preparing)

        guard await ensureMicrophonePermissionForUserAction() else {
            if phase == .preparing {
                setPhase(.idle)
            }
            return
        }

        // Keep the press-to-record path local-only. Mac settings refresh can
        // take seconds on a stale route; foreground/bootstrap keep it warm.
        // Note: do NOT reset correctionMode here — the user's last chip pick
        // must persist across recordings within a scene. New scenes (clear /
        // unpair / cold start) handle the reset themselves.
        do {
            try await startHostRecordingCapture()
            acquireIdleTimer()
            setPhase(.recording)
        } catch {
            setFailure(error.localizedDescription)
            await resumeKeyboardStandbyAfterCommand()
        }
    }

    private func startHostRecordingCapture() async throws {
        clearKeyboardCaptureContext()
        let startedAt = CFAbsoluteTimeGetCurrent()
        let hadSilentStandby = standbyKeeper.isActive
        let hadKeyboardSession = keyboardAudioSession.isActive
        let hadPreWarmedRecorder = recorder.isPreWarmed
        var path = "recorder-cold"
        // Host press-to-record may run while the silent standby engine is
        // keeping the process warm. Stop that engine, but keep the audio
        // session active so recording does not pay a deactivate/reactivate
        // round trip before the UI can leave Preparing.
        standbyKeeper.stop(deactivateSession: false)
        if keyboardAudioSession.isActive, !keyboardAudioSession.isRecording {
            path = "keyboard-session"
            _ = try await keyboardAudioSession.beginRecording()
            hostRecordingUsesKeyboardAudioSession = true
            startLivePartialPreviewIfAvailable()
            logSlowHostRecordingStart(
                startedAt: startedAt,
                path: path,
                hadSilentStandby: hadSilentStandby,
                hadKeyboardSession: hadKeyboardSession,
                hadPreWarmedRecorder: hadPreWarmedRecorder
            )
            return
        }

        path = recorder.isPreWarmed ? "recorder-prewarmed" : "recorder-cold"
        try await recorder.start(reuseActiveSession: keyboardAudioSession.isActive)
        hostRecordingUsesKeyboardAudioSession = false
        logSlowHostRecordingStart(
            startedAt: startedAt,
            path: path,
            hadSilentStandby: hadSilentStandby,
            hadKeyboardSession: hadKeyboardSession,
            hadPreWarmedRecorder: hadPreWarmedRecorder
        )
    }

    private func logSlowHostRecordingStart(
        startedAt: CFAbsoluteTime,
        path: String,
        hadSilentStandby: Bool,
        hadKeyboardSession: Bool,
        hadPreWarmedRecorder: Bool
    ) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        guard elapsedMs >= 250 else { return }
        appLog.notice(
            "host recording start slow elapsedMs=\(elapsedMs, privacy: .public) path=\(path, privacy: .public) silentStandby=\(hadSilentStandby, privacy: .public) keyboardSession=\(hadKeyboardSession, privacy: .public) prewarmed=\(hadPreWarmedRecorder, privacy: .public)"
        )
    }

    func stopAndSend(keyboardCommandID: String? = nil) async {
        guard !isStopAndSendInFlight else { return }
        isStopAndSendInFlight = true
        defer { isStopAndSendInFlight = false }

        let requestedCorrectionMode = correctionMode
        let keyboardCaptureWasStartedFromKeyboard = keyboardCaptureStartedFromKeyboard
        keyboardCaptureStartedFromKeyboard = false
        let effectiveKeyboardCommandID = keyboardCommandID ?? activeKeyboardRecordingCommandID
        let isHostStandbyCapture = keyboardCommandID == nil
            && hostRecordingUsesKeyboardAudioSession
            && !keyboardCaptureWasStartedFromKeyboard
        let isKeyboardCapture = keyboardAudioSession.isRecording
        let shouldPublishKeyboardProgress = keyboardCommandID != nil
            || effectiveKeyboardCommandID != nil
            || keyboardCaptureWasStartedFromKeyboard
            || (isKeyboardCapture && !isHostStandbyCapture)
        defer {
            if shouldPublishKeyboardProgress || isKeyboardCapture {
                activeKeyboardRecordingCommandID = nil
            }
        }
        guard isKeyboardCapture || recorder.isRecording else {
            hostRecordingUsesKeyboardAudioSession = false
            releaseIdleTimer()
            return
        }
        // Stop is a user-visible state transition, so publish it before the
        // short tail capture below. The recorder keeps running for 200ms only
        // to avoid clipping the final syllable; the UI and keyboard should
        // already behave as stopped/sending.
        setPhase(.sending)
        if shouldPublishKeyboardProgress {
            publishKeyboardStatus(.sending, commandID: effectiveKeyboardCommandID, message: NSLocalizedString("Transcribing", comment: "Bridge job stage"))
        }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        try? await Task.sleep(nanoseconds: Self.recordingTailBufferNanoseconds)
        let fileURL = isKeyboardCapture
            ? keyboardAudioSession.finishRecording()
            : recorder.stop(deactivateSession: true)
        // Close the SFSpeechRecognizer audio side so it finalizes its last
        // partial. We intentionally do NOT clear livePartialTranscript yet —
        // keep the user's preview visible until Mac returns the final text.
        endLivePartialPreviewAudio()
        hostRecordingUsesKeyboardAudioSession = false
        let keyboardTextEditContext = shouldPublishKeyboardProgress ? activeKeyboardTextEditContext : nil
        let keyboardDictationContext = shouldPublishKeyboardProgress ? activeKeyboardDictationContext : nil
        activeKeyboardTextEditContext = nil
        activeKeyboardDictationContext = nil
        releaseIdleTimer()
        guard let fileURL else {
            setPhase(.idle)
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(.standby, commandID: effectiveKeyboardCommandID, message: "Nothing recorded")
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
            return
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recordingInfo = RecordingFileInfo(url: fileURL)
        lastRecordingSummary = recordingInfo.summary
        if recordingInfo.isTooShort {
            setPhase(.idle)
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(
                    .standby,
                    commandID: effectiveKeyboardCommandID,
                    message: "Too short; hold while speaking",
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount
                )
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
            return
        }

        acquireIdleTimer()
        defer { releaseIdleTimer() }

        var baseURL = routeStatus.activeURL
        let isKeyboardPath = shouldPublishKeyboardProgress || isKeyboardCapture
        // Happy-path: only spend the GET /v1/health round-trip when we don't
        // already trust the cached route. A fresh route within its cache TTL
        // (5s local / 30s cloud) was just validated successfully, so the next
        // POST will tell us if anything changed faster than a probe would.
        let routeIsFresh: Bool = {
            guard let routeFetchedAt, baseURL != nil else { return false }
            let cacheTTL = routeStatus.activeKind == .local ? Self.localRouteCacheTTL : Self.routeCacheTTL
            return Date().timeIntervalSince(routeFetchedAt) < cacheTTL
        }()
        if isKeyboardPath {
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(.sending, commandID: effectiveKeyboardCommandID, message: NSLocalizedString("Transcribing", comment: "Bridge job stage"))
            }
            if !routeIsFresh {
                await preflightActiveBridgeRoute()
                baseURL = routeStatus.activeURL
            }
        } else if baseURL == nil {
            await refreshRoute(force: false, probeAllEndpoints: false, showIndicator: false)
            baseURL = routeStatus.activeURL
        }
        guard let baseURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: errorMessage ?? "Bridge unavailable")
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
            return
        }

        if let effectiveKeyboardCommandID {
            publishKeyboardStatus(
                .sending,
                commandID: effectiveKeyboardCommandID,
                message: "Transcribing \(recordingInfo.durationLabel) audio",
                audioDurationSeconds: recordingInfo.durationSeconds,
                audioByteCount: recordingInfo.byteCount
            )
        }
        do {
            let dictationContext = keyboardTextEditContext == nil ? keyboardDictationContext : nil
            let response = try await dictateWithRouteRetry(
                initialBaseURL: baseURL,
                audioURL: fileURL,
                audioExtension: fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode,
                contextBefore: dictationContext?.contextBefore ?? "",
                contextAfter: dictationContext?.contextAfter ?? "",
                includeRawTranscript: true,
                keyboardCommandID: effectiveKeyboardCommandID,
                recordingInfo: recordingInfo
            )
            let client = BridgeClient(baseURL: routeStatus.activeURL ?? baseURL, token: config.token)
            let spokenTranscript = response.rawTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var resultMessage = "Inserted \(recordingInfo.durationLabel) audio"
            var correctionLatencyMs = response.correctionLatencyMs
            var totalLatencyMs = response.latencyMs

            if let editContext = keyboardTextEditContext {
                guard !spokenTranscript.isEmpty else {
                    setFailure("Mac returned an empty transcript.")
                    if let effectiveKeyboardCommandID {
                        publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: errorMessage ?? "Empty transcript")
                    }
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                    await resumeKeyboardStandbyAfterCommand()
                    return
                }
                if let effectiveKeyboardCommandID {
                    publishKeyboardStatus(
                        .sending,
                        commandID: effectiveKeyboardCommandID,
                        message: editContext.intent == .command ? "Editing selection" : "Repairing selection",
                        audioDurationSeconds: recordingInfo.durationSeconds,
                        audioByteCount: recordingInfo.byteCount
                    )
                }
                let editJobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
                let editResponse = try await client.editText(
                    intent: editContext.intent.rawValue,
                    contextBefore: editContext.contextBefore,
                    targetText: editContext.targetText,
                    contextAfter: editContext.contextAfter,
                    spokenInstruction: spokenTranscript,
                    languageIDs: activeLanguageIDs,
                    clientJobID: editJobID,
                    onJobEvent: { [weak self] event in
                        await MainActor.run {
                            self?.applyBridgeJobStatus(
                                event,
                                keyboardCommandID: effectiveKeyboardCommandID,
                                recordingInfo: recordingInfo
                            )
                        }
                    }
                )
                text = editResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                correctionLatencyMs = editResponse.editLatencyMs ?? editResponse.latencyMs
                if let transcriptionLatency = response.transcriptionLatencyMs,
                   let editLatency = editResponse.latencyMs {
                    totalLatencyMs = transcriptionLatency + editLatency
                } else {
                    totalLatencyMs = editResponse.latencyMs ?? response.latencyMs
                }
                resultMessage = editContext.intent == .command ? "Edited selection" : "Repaired selection"
            }
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                if let effectiveKeyboardCommandID {
                    publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: errorMessage ?? "Empty result")
                }
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                await resumeKeyboardStandbyAfterCommand()
                return
            }
            // Only populate the host Result panel's TextEditor when this
            // dictation was initiated from the host UI. Keyboard-driven
            // dictations insert directly into whatever the user is typing
            // (which may be the Result TextEditor itself when the user is
            // running Typeforme as the host) — setting `resultText` there
            // double-writes the text via the TextEditor's two-way binding.
            if !shouldPublishKeyboardProgress {
                resultText = text
            }
            // Mac final result is now the source of truth; preview is done.
            teardownLivePartialPreview(clearText: true)
            lastGeneratedResultText = text
            if keyboardTextEditContext == nil {
                rawTranscript = response.rawTranscript ?? rawTranscript
                sessionID = response.sessionID
            } else {
                rawTranscript = ""
                sessionID = nil
            }
            latestServerTiming = ServerTimingSummary(
                transcriptionLatencyMs: response.transcriptionLatencyMs,
                correctionLatencyMs: correctionLatencyMs,
                totalLatencyMs: totalLatencyMs
            )
            let shouldPublishKeyboardResult = keyboardCommandID != nil
                || effectiveKeyboardCommandID != nil
                || keyboardCaptureWasStartedFromKeyboard
                || (isKeyboardCapture && !isHostStandbyCapture)
            let resultCommandID = effectiveKeyboardCommandID ?? (shouldPublishKeyboardResult ? "keyboard-\(UUID().uuidString)" : nil)
            errorMessage = nil
            applyCorrectionMetadata(
                status: response.correctionStatus,
                error: response.correctionError,
                successKind: resultCommandID == nil ? .ready : .inserted
            )
            if let resultCommandID {
                publishKeyboardStatus(
                    .result,
                    commandID: resultCommandID,
                    message: resultMessage,
                    resultText: text,
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount,
                    rawTranscriptLength: spokenTranscript.count
                )
            }
            notifyKeyboardResultReady()
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            if resultCommandID != nil {
                scheduleKeyboardStandbyRefresh()
                return
            }
        } catch {
            if isBenignEmptyTranscript(error) {
                setPhase(.idle)
                if let effectiveKeyboardCommandID {
                    publishKeyboardStatus(.standby, commandID: effectiveKeyboardCommandID, message: "Nothing recorded")
                }
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                await resumeKeyboardStandbyAfterCommand()
                return
            }
            // Stale routes are the most common cause of bridge failures —
            // auth errors *and* network errors (timeout, cannotConnectToHost,
            // networkConnectionLost, etc.) both indicate the cached route may
            // be bad. Invalidate so the next press re-probes naturally.
            if shouldRetryBridgeRequest(after: error) {
                routeFetchedAt = nil
            }
            // Bridge failed — drop any in-flight live-preview state.
            teardownLivePartialPreview(clearText: true)
            setFailure(error.localizedDescription)
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: error.localizedDescription)
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        }
        await resumeKeyboardStandbyAfterCommand()
    }

    func applyCorrectionMode(_ newMode: CorrectionModeID) async {
        // Block mode changes while a request is mid-flight to avoid a stale
        // result coming back in the old mode while the UI shows the new one.
        guard !isBusy else { return }
        guard let source = currentRestyleSource() else {
            rawTranscript = ""
            sessionID = nil
            lastGeneratedResultText = nil
            applyKeyboardDefaultCorrectionMode(newMode)
            setPhase(.idle)
            return
        }
        correctionMode = newMode
        // Happy-path: reuse the cached route (5-30s TTL) instead of re-probing
        // local + cloud before every Restyle tap. If the cache is stale,
        // refreshRoute does a full resolve; if it's fresh we go straight to
        // POST. Errors below invalidate the cache so the next attempt re-probes.
        await refreshRoute(force: false, probeAllEndpoints: false, showIndicator: false)
        guard let baseURL = routeStatus.activeURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            return
        }
        do {
            setPhase(.restyling)
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            let restyleJobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            let response = try await client.restyle(
                sessionID: source.sessionID,
                rawTranscript: source.rawTranscript,
                languageIDs: activeLanguageIDs,
                correctionMode: newMode,
                clientJobID: restyleJobID,
                onJobEvent: { [weak self] event in
                    await MainActor.run {
                        self?.applyBridgeJobStatus(event, keyboardCommandID: nil)
                    }
                }
            )
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                return
            }
            resultText = text
            lastGeneratedResultText = text
            // Do NOT overwrite rawTranscript with the submitted source — it's
            // either the original raw (unchanged, no-op) or the previous
            // styled result (corruption). Keep raw from initial dictation.
            sessionID = response.sessionID
            latestServerTiming = ServerTimingSummary(
                transcriptionLatencyMs: latestServerTiming?.transcriptionLatencyMs,
                correctionLatencyMs: response.correctionLatencyMs ?? response.latencyMs,
                totalLatencyMs: response.latencyMs
            )
            notifyKeyboardResultReady()
            errorMessage = nil
            applyCorrectionMetadata(status: response.correctionStatus, error: response.correctionError)
        } catch {
            // Invalidate the route cache on both auth and network errors so
            // the next Restyle tap re-probes instead of reusing a dead route.
            if shouldRetryBridgeRequest(after: error) {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
        }
    }

    func copyResult() {
        guard !resultText.isEmpty else { return }
        UIPasteboard.general.string = resultText
        errorMessage = nil
        setPhase(.success(.copied))
        showTransient("Copied")
    }

    func clearResult() {
        resultText = ""
        rawTranscript = ""
        sessionID = nil
        lastGeneratedResultText = nil
        processingStatusMessage = nil
        resetCorrectionModeToDefault()
        setPhase(.idle)
    }

    private func currentRestyleSource() -> RestyleSource? {
        // Restyle acts on the visible Result editor. Passing the old session
        // would make the Mac prefer the original raw transcript and discard
        // manual edits or the previous style output.
        let visibleText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visibleText.isEmpty {
            return RestyleSource(sessionID: nil, rawTranscript: visibleText)
        }
        let rawText = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return nil }
        return RestyleSource(sessionID: sessionID, rawTranscript: rawText)
    }

    func handleOpenURL(_ url: URL, sourceApplication: String? = nil) async {
        guard url.scheme?.lowercased() == "typeforme" else { return }
        let now = Date().timeIntervalSince1970
        if let lastHandledOpenURL,
           lastHandledOpenURL.value == url.absoluteString,
           now - lastHandledOpenURL.time < 1.0 {
            appLog.notice("handleOpenURL: skipped duplicate typeforme URL")
            return
        }
        lastHandledOpenURL = (url.absoluteString, now)
        await waitForInitialRenderOpportunity()
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var source: String?
        var handoffID: String?
        var reason: String?
        var shouldReturnToKeyboard = false
        var returnBundleID: String?
        var returnProcessID: Int32?
        var keyboardHandoff: KeyboardHostHandoff?
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            source = items.first { $0.name == "source" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            handoffID = items.first { $0.name == "handoff_id" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            reason = items.first { $0.name == "reason" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if source == "keyboard", action == "setup", reason == "full_access" {
                markKeyboardFullAccessRequired()
            } else if source == "keyboard",
               let handoffID,
               let handoff = KeyboardSharedDefaults.consumeHostHandoff(id: handoffID, now: now),
               handoff.action == action {
                keyboardHandoff = handoff
                shouldReturnToKeyboard = handoff.shouldReturnToKeyboard
                returnBundleID = handoff.returnBundleID
                returnProcessID = handoff.returnProcessID
                if let nextMode = CorrectionModeID(rawValue: handoff.correctionMode) {
                    correctionMode = nextMode
                }
            } else if source == "keyboard" {
                appLog.notice("handleOpenURL: rejected unauthenticated keyboard handoff action=\(action, privacy: .public), has_handoff=\((handoffID?.isEmpty == false), privacy: .public)")
                return
            } else {
                applyKeyboardParameters(items, allowCorrectionMode: action == "record")
            }
        }
        let isAuthenticatedKeyboardHandoff = keyboardHandoff != nil
        let resolvedReturnBundleID = resolvedReturnBundleID(
            explicitBundleID: returnBundleID,
            sourceApplication: sourceApplication,
            processID: returnProcessID
        )
        if shouldReturnToKeyboard || resolvedReturnBundleID != nil {
            rememberReturnTarget(bundleID: resolvedReturnBundleID)
        }
        appLog.notice("handleOpenURL: action=\(action, privacy: .public), source=\(isAuthenticatedKeyboardHandoff ? "keyboard" : (source ?? "nil"), privacy: .public), handoff=\(isAuthenticatedKeyboardHandoff, privacy: .public)")
        if action == "setup" {
            if source == "keyboard", reason == "full_access" {
                markKeyboardFullAccessRequired()
            }
        } else if action == "record" {
            if isAuthenticatedKeyboardHandoff {
                // Older keyboard builds used `record` for the microphone handoff,
                // which could start host recording before the extension returned.
                // The extension must own start/stop after it is visible again, so
                // keyboard-origin `record` now behaves like `microphone`.
                let didPrepareKeyboardSession = await prepareKeyboardMicrophoneFromHostOpen()
                if !didPrepareKeyboardSession {
                    shouldReturnToKeyboard = false
                }
            } else {
                await toggleRecording()
            }
        } else if action == "microphone" {
            guard isAuthenticatedKeyboardHandoff else {
                appLog.notice("handleOpenURL: rejected unauthenticated microphone action")
                return
            }
            let didPrepareKeyboardSession = await prepareKeyboardMicrophoneFromHostOpen()
            if !didPrepareKeyboardSession {
                shouldReturnToKeyboard = false
            }
        } else if action == "standby" {
            guard isAuthenticatedKeyboardHandoff else {
                appLog.notice("handleOpenURL: rejected unauthenticated standby action")
                return
            }
            let didPrepareKeyboardSession = await setKeyboardStandby(
                true,
                requestMicrophoneIfNeeded: true
            )
            if !didPrepareKeyboardSession {
                shouldReturnToKeyboard = false
                showKeyboardMicrophoneDeniedFeedbackIfNeeded()
            }
        }
        if shouldReturnToKeyboard {
            await returnToPreviousAppSoon(bundleID: resolvedReturnBundleID)
        }
    }

    private func prepareKeyboardMicrophoneFromHostOpen() async -> Bool {
        let didPrepareKeyboardSession = await setKeyboardStandby(true, requestMicrophoneIfNeeded: true)
        if !didPrepareKeyboardSession {
            showKeyboardMicrophoneDeniedFeedbackIfNeeded()
        }
        return didPrepareKeyboardSession
    }

    private func waitForInitialRenderOpportunity() async {
        if let task = initialRenderDelayTask {
            await task.value
            return
        }

        let task = Task<Void, Never> {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        initialRenderDelayTask = task
        await task.value
    }

    @discardableResult
    func setKeyboardStandby(
        _ enabled: Bool,
        requestMicrophoneIfNeeded: Bool = false,
        surfaceAudioSessionErrors: Bool = true
    ) async -> Bool {
        keyboardStandbyEnabled = enabled
        configureKeyboardServer()

        if enabled {
            do {
                try keyboardServer.start()
                let isInputReady = try await prepareKeyboardInputStandby(
                    requestMicrophoneIfNeeded: requestMicrophoneIfNeeded
                )
                if isInputReady {
                    publishKeyboardStatus(.standby, message: "Ready")
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
                } else {
                    startSilentStandbyKeeperIfNeeded()
                    publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
                }
                scheduleHostAudioSessionExpiry()
                return isInputReady
            } catch {
                let message = "Keyboard audio session unavailable: \(error.localizedDescription)"
                if surfaceAudioSessionErrors {
                    errorMessage = message
                    appLog.error("setKeyboardStandby: \(message, privacy: .public)")
                    publishKeyboardStatus(.error, message: message)
                } else {
                    // App bootstrap uses keyboard standby as a best-effort
                    // prewarm. Audio-session activation can legitimately fail
                    // while iOS is settling routes after launch; keep the local
                    // bridge/silent standby available and let the keyboard mic
                    // handoff surface any real user-action failure.
                    appLog.notice("setKeyboardStandby bootstrap deferred: \(error.localizedDescription, privacy: .public)")
                    startSilentStandbyKeeperIfNeeded()
                    publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
                }
                return false
            }
        } else {
            hostAudioSessionExpiryTask?.cancel()
            hostAudioSessionExpiryTask = nil
            keyboardStandbyRefreshTask?.cancel()
            keyboardStandbyRefreshTask = nil
            keyboardServer.stop()
            standbyKeeper.stop()
            keyboardAudioSession.stop()
            publishKeyboardStatus(.idle)
            return false
        }
    }

    private var isKeyboardHostSessionActive: Bool {
        standbyKeeper.isActive || keyboardAudioSession.isActive
    }

    private func prepareKeyboardInputStandby(requestMicrophoneIfNeeded: Bool) async throws -> Bool {
        if keyboardAudioSession.isActive {
            startKeyboardSessionKeepAlive()
            return true
        }

        if !(await waitUntilApplicationIsActive(timeout: requestMicrophoneIfNeeded ? 3.0 : 1.0)) {
            appLog.notice("prepareKeyboardInputStandby: app did not become active before audio start; continuing with activation retry")
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            let reuseActiveSession = standbyKeeper.isActive
            standbyKeeper.stop(deactivateSession: false)
            try await keyboardAudioSession.start(reuseActiveSession: reuseActiveSession)
            startKeyboardSessionKeepAlive()
            return true
        case .undetermined:
            guard requestMicrophoneIfNeeded else { return false }
            guard await requestMicrophonePermission() == .granted else { return false }
            let reuseActiveSession = standbyKeeper.isActive
            standbyKeeper.stop(deactivateSession: false)
            try await keyboardAudioSession.start(reuseActiveSession: reuseActiveSession)
            startKeyboardSessionKeepAlive()
            return true
        case .denied:
            if requestMicrophoneIfNeeded {
                await openAppSettingsForMicrophone()
            }
            return false
        @unknown default:
            return false
        }
    }

    private func startKeyboardSessionKeepAlive() {
        guard keyboardAudioSession.isActive, !standbyKeeper.isActive else { return }
        // The prepared input engine alone is not enough to keep the containing
        // app schedulable after returning to the typing app on all iOS builds.
        // Keep a silent output engine running under the existing playAndRecord
        // session so Darwin start/stop notifications still reach the host.
        standbyKeeper.start(configureSession: false)
    }

    private func startSilentStandbyKeeperIfNeeded() {
        guard !keyboardAudioSession.isActive else { return }
        standbyKeeper.start()
    }

    private func scheduleHostAudioSessionExpiry() {
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        guard keyboardStandbyEnabled,
              isKeyboardHostSessionActive,
              let seconds = hostAudioSessionLength.seconds
        else { return }

        hostAudioSessionExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireHostAudioSessionIfIdle()
        }
    }

    private func expireHostAudioSessionIfIdle() {
        guard keyboardStandbyEnabled, isKeyboardHostSessionActive else { return }
        guard !keyboardAudioSession.isRecording,
              !recorder.isRecording,
              !phase.isBusy
        else {
            scheduleHostAudioSessionExpiry()
            return
        }
        keyboardServer.stop()
        standbyKeeper.stop()
        if keyboardAudioSession.isActive {
            keyboardAudioSession.stop()
        }
        publishKeyboardStatus(.idle, message: "Host audio session expired")
    }

    private func applyKeyboardParameters(_ items: [URLQueryItem], allowCorrectionMode: Bool) {
        for item in items {
            switch item.name {
            case "correction_mode":
                if allowCorrectionMode,
                   let value = item.value,
                   let nextMode = CorrectionModeID(rawValue: value) {
                    correctionMode = nextMode
                }
            case "languages":
                let ids = item.value?
                    .split(separator: ",")
                    .map { String($0) } ?? []
                if !ids.isEmpty {
                    selectedLanguageIDs = Set(ASRLanguageSelection.validatedIDs(
                        ids,
                        supportedOptions: config.supportedLanguageOptions
                    ))
                    persistLanguageSelection()
                }
            default:
                break
            }
        }
    }

    private func requestMicrophonePermission() async -> MicrophonePermissionRequestResult {
        guard await waitUntilApplicationIsActive() else { return .unavailable }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
    }

    private func ensureMicrophonePermissionForUserAction() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            switch await requestMicrophonePermission() {
            case .granted:
                return true
            case .denied:
                setFailure("Microphone permission is required.")
                return false
            case .unavailable:
                return false
            }
        case .denied:
            setFailure("Microphone permission is required. Enable it in Settings.")
            await openAppSettingsForMicrophone()
            return false
        @unknown default:
            setFailure("Microphone permission is required.")
            return false
        }
    }

    private func waitUntilApplicationIsActive(timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while UIApplication.shared.applicationState != .active {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    @discardableResult
    private func showKeyboardMicrophoneDeniedFeedbackIfNeeded() -> Bool {
        guard AVAudioApplication.shared.recordPermission == .denied else { return false }
        showTransient("Microphone permission is required.")
        return true
    }

    private var keyboardMicrophonePreparationMessage: String {
        AVAudioApplication.shared.recordPermission == .denied
            ? "Microphone permission is required."
            : "Open Typeforme to prepare dictation."
    }

    private func openAppSettingsForMicrophone() async {
        guard await waitUntilApplicationIsActive() else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        _ = await UIApplication.shared.open(url)
    }

    // MARK: - Live partial preview (Apple Speech)
    //
    // Starts an `SFSpeechRecognizer` alongside the keyboard audio session so
    // the user sees their words appear as they speak. The recognized text
    // never replaces the Mac result — it's just a fast preview. The same
    // text is also shipped to Mac as `alternate_transcript` (see Step 5/6).
    //
    // Gating: this only runs when the user enables live preview and the selected
    // primary locale is usable in the selected Apple Speech preview mode.
    // Unsupported locales / denied permission silently degrade to the previous
    // no-preview behaviour.

    private func startLivePartialPreviewIfAvailable() {
        // Tear down anything previous so re-press never leaks tasks.
        teardownLivePartialPreview(clearText: true)

        guard keyboardLivePreviewEnabled else { return }
        let primaryID = activeLanguageIDs.first ?? "en-US"
        let capability = AppleSpeechPreviewSupport.capability(languageID: primaryID)
        guard keyboardLivePreviewRecognitionMode.canUse(capability) else { return }
        let locale = Locale(identifier: primaryID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return }

        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            break
        case .notDetermined:
            // First use: request silently. We do not block the current recording
            // on the prompt — preview just stays off this session. Subsequent
            // recordings benefit if the user grants.
            SFSpeechRecognizer.requestAuthorization { _ in }
            return
        case .denied, .restricted:
            return
        @unknown default:
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = capability.supportsOnDevicePreview || !keyboardLivePreviewRecognitionMode.allowsCloud
        request.addsPunctuation = (macSettings?.punctuationPreference ?? .normal) != .spaces

        liveSpeechRecognizer = recognizer
        liveSpeechRequest = request
        liveSpeechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The task callback runs off the main actor — hop back before
            // touching @Published state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.livePartialTranscript = text
                        self.publishLivePartialTranscriptToKeyboard()
                    }
                }
                if error != nil {
                    self.teardownLivePartialPreview(clearText: false)
                }
            }
        }

        // Fan the audio session's PCM tap into the recognition request. Capture
        // a weak request so we never retain the recognizer after teardown.
        keyboardAudioSession.onPCMBuffer = { [weak request] buffer in
            request?.append(buffer)
        }
    }

    /// Called when the user stops recording. We close the audio side of the
    /// request so the recognizer finalises its last partial, but keep the
    /// resulting text on screen until the Mac final result replaces it.
    private func endLivePartialPreviewAudio() {
        keyboardAudioSession.onPCMBuffer = nil
        liveSpeechRequest?.endAudio()
    }

    /// Called after the Mac final result is applied. Tears down the recognizer
    /// task and clears the on-screen partial — the keyboard / host now show
    /// the Mac final text.
    private func teardownLivePartialPreview(clearText: Bool) {
        keyboardAudioSession.onPCMBuffer = nil
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        liveSpeechRequest = nil
        liveSpeechRecognizer = nil
        if clearText {
            livePartialTranscript = ""
            publishLivePartialTranscriptToKeyboard()
        }
    }

    private func resolvedReturnBundleID(
        explicitBundleID: String?,
        sourceApplication: String?,
        processID: Int32?
    ) -> String? {
        if let explicitBundleID = explicitBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsableReturnBundleID(explicitBundleID) {
            appendReturnTrace("resolvedReturnBundleID explicit=\(explicitBundleID)")
            return explicitBundleID
        }
        if let sourceApplication = sourceApplication?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsableReturnBundleID(sourceApplication) {
            appendReturnTrace("resolvedReturnBundleID sourceApplication=\(sourceApplication)")
            return sourceApplication
        }
        if let processID {
            appendReturnTrace("resolvedReturnBundleID pidLookupSkipped pid=\(processID)")
        }
        return nil
    }

    private func rememberReturnTarget(bundleID: String?) {
        guard let bundleID else {
            clearReturnTarget()
            appendReturnTrace("rememberReturnTarget skipped missingBundle")
            return
        }
        showsReturnButton = true
        returnBundleID = bundleID
    }

    private func clearReturnTarget() {
        showsReturnButton = false
        returnBundleID = nil
    }

    func returnToPreviousAppFromToolbar() async {
        guard returnBundleID != nil else {
            clearReturnTarget()
            await refreshRoute(force: true)
            return
        }
        await returnToPreviousAppSoon(bundleID: returnBundleID)
    }

    private func returnToPreviousAppSoon(bundleID: String?) async {
        appendReturnTrace("returnToPreviousAppSoon start bundle=\(bundleID ?? "nil")")
        appLog.notice("returnToPreviousAppSoon: start bundle=\(bundleID ?? "nil", privacy: .private)")
        guard let bundleID else {
            appLog.notice("returnToPreviousAppSoon: no return bundle available")
            appendReturnTrace("return skipped missingBundle")
            clearReturnTarget()
            showTransient(NSLocalizedString("Ready. Return to your previous app manually.", comment: "Return-to-keyboard fallback toast"))
            return
        }

        let retryDelays: [UInt64] = [
            350_000_000,
            450_000_000,
            650_000_000,
            900_000_000,
        ]

        for (index, delay) in retryDelays.enumerated() {
            try? await Task.sleep(nanoseconds: delay)
            appendReturnTrace("return attempt=\(index + 1) bundle=\(bundleID)")
            appLog.notice("returnToPreviousAppSoon: attempt \(index + 1, privacy: .public), bundle=\(bundleID, privacy: .private)")
            logReturnTrace("attempt \(index + 1), bundleID=\(bundleID)")
            if openApplication(bundleID: bundleID) {
                appLog.notice("returnToPreviousAppSoon: returned via LSApplicationWorkspace bundle")
                appendReturnTrace("return success LSApplicationWorkspace attempt=\(index + 1) bundle=\(bundleID)")
                logReturnTrace("returned via LSApplicationWorkspace bundle")
                clearReturnTarget()
                return
            }
        }

        appLog.notice("returnToPreviousAppSoon: all attempts failed")
        appendReturnTrace("return failed allAttempts bundle=\(bundleID)")
        clearReturnTarget()
        showTransient(NSLocalizedString("Ready. Return to your previous app manually.", comment: "Return-to-keyboard fallback toast"))
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
        for part in parts {
            guard !part.isEmpty else { return false }
            guard part.allSatisfy({ character in
                character.isLetter || character.isNumber || character == "-"
            }) else { return false }
        }
        return true
    }

    private func openApplication(bundleID: String) -> Bool {
        // Counterpart to the keyboard host-wake workaround. The keyboard cannot
        // record audio, and iOS does not provide a public custom-keyboard API to
        // open the containing app and then return to the previous host. This
        // private return path is intentionally isolated here; App Store-targeted
        // builds should replace it with the visible toolbar return affordance.
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Bundle.main.bundleIdentifier else {
            appendReturnTrace("openApplication invalid bundle=\(trimmed)")
            logReturnTrace("invalid return bundle \(trimmed)")
            return false
        }
        guard let workspaceClass = objc_getClass("LSApplicationWorkspace") as? AnyObject else {
            appendReturnTrace("openApplication LSApplicationWorkspace unavailable bundle=\(trimmed)")
            logReturnTrace("LSApplicationWorkspace unavailable")
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject else {
            appendReturnTrace("openApplication defaultWorkspace unavailable bundle=\(trimmed)")
            logReturnTrace("defaultWorkspace unavailable")
            return false
        }
        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector),
              let imp = workspace.method(for: openSelector)
        else {
            appendReturnTrace("openApplication openApplicationWithBundleID unavailable bundle=\(trimmed)")
            logReturnTrace("openApplicationWithBundleID unavailable")
            return false
        }
        typealias OpenApplication = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let openApplication = unsafeBitCast(imp, to: OpenApplication.self)
        let didOpen = openApplication(workspace, openSelector, trimmed as NSString)
        appLog.notice("openApplication: bundle=\(trimmed, privacy: .private), result=\(didOpen, privacy: .public)")
        appendReturnTrace("openApplication bundle=\(trimmed) result=\(didOpen)")
        logReturnTrace("openApplicationWithBundleID \(trimmed) result=\(didOpen)")
        return didOpen
    }

    private func configureKeyboardServer() {
        keyboardServer.expectedTokenProvider = { [weak self] in
            await MainActor.run { self?.keyboardBridgeToken }
        }
        keyboardServer.statusProvider = { [weak self] in
            guard let self else { return .idle }
            return await MainActor.run {
                self.markKeyboardEverContacted()
                let base = self.keyboardBridgeStatus
                guard base.state == .recording else {
                    return base
                }
                let level = self.keyboardAudioSession.isRecording
                    ? self.keyboardAudioSession.level
                    : self.recorder.level
                return base.withAudioLevel(level)
            }
        }
        keyboardServer.onCommand = { [weak self] command in
            guard let self else {
                return KeyboardBridgeStatus(commandID: command.id, state: .error, message: "Typeforme is unavailable")
            }
            self.markKeyboardEverContacted()
            return await self.handleKeyboardCommand(command)
        }
    }

    /// Called when ANY keyboard → host signal arrives (local bridge connect,
    /// status poll, command). Setting this flag is the only way the host
    /// learns the keyboard is enabled + has Full Access, since iOS does not
    /// expose Full Access state to the containing app.
    @MainActor
    private func markKeyboardEverContacted() {
        if keyboardFullAccessRequired {
            keyboardFullAccessRequired = false
            UserDefaults.standard.set(false, forKey: Self.keyboardFullAccessRequiredKey)
        }
        guard !keyboardEverContacted else { return }
        keyboardEverContacted = true
        UserDefaults.standard.set(true, forKey: Self.keyboardEverContactedKey)
    }

    @MainActor
    private func markKeyboardFullAccessRequired() {
        guard !keyboardFullAccessRequired else { return }
        keyboardFullAccessRequired = true
        UserDefaults.standard.set(true, forKey: Self.keyboardFullAccessRequiredKey)
    }

    private func clearKeyboardCaptureContext() {
        activeKeyboardTextEditContext = nil
        activeKeyboardDictationContext = nil
        keyboardCaptureStartedFromKeyboard = false
        activeKeyboardRecordingCommandID = nil
    }

    private func rememberCanceledKeyboardCommand(_ commandID: String) {
        guard !commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pruneCanceledKeyboardCommands()
        canceledKeyboardCommandIDs[commandID] = Date().timeIntervalSince1970
    }

    private func consumeCanceledKeyboardCommand(_ commandID: String) -> Bool {
        pruneCanceledKeyboardCommands()
        return canceledKeyboardCommandIDs.removeValue(forKey: commandID) != nil
    }

    private func pruneCanceledKeyboardCommands() {
        let cutoff = Date().timeIntervalSince1970 - Self.canceledKeyboardCommandTTL
        canceledKeyboardCommandIDs = canceledKeyboardCommandIDs.filter { $0.value >= cutoff }
    }

    private func configureKeyboardDarwinBridge() {
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        let fullAccessObserver = KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.fullAccessRequired) { [weak self] in
            Task { @MainActor [weak self] in
                self?.markKeyboardFullAccessRequired()
            }
        }
        guard let requestStartName = KeyboardDarwinNotificationName.authenticatedRequest(
            KeyboardDarwinNotificationName.requestStartDictation,
            token: keyboardBridgeToken
        ),
            let requestStopName = KeyboardDarwinNotificationName.authenticatedRequest(
                KeyboardDarwinNotificationName.requestStopDictation,
                token: keyboardBridgeToken
            ),
            let requestCancelName = KeyboardDarwinNotificationName.authenticatedRequest(
                KeyboardDarwinNotificationName.requestCancelDictation,
                token: keyboardBridgeToken
            ),
            let requestSessionStatusName = KeyboardDarwinNotificationName.authenticatedRequest(
                KeyboardDarwinNotificationName.requestSessionStatus,
                token: keyboardBridgeToken
            )
        else {
            keyboardDarwinObservers = [fullAccessObserver]
            return
        }
        keyboardDarwinObservers = [
            fullAccessObserver,
            KeyboardDarwinBridge.observe(requestStartName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markKeyboardEverContacted()
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else { return }
                    self.clearKeyboardCaptureContext()
                    self.keyboardCaptureStartedFromKeyboard = true
                    await self.startKeyboardRecording(commandID: nil, allowSessionStart: true)
                }
            },
            KeyboardDarwinBridge.observe(requestStopName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else { return }
                    await self.stopAndSend(keyboardCommandID: nil)
                }
            },
            KeyboardDarwinBridge.observe(requestCancelName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.clearKeyboardCaptureContext()
                    if self.keyboardAudioSession.isRecording {
                        self.keyboardAudioSession.cancelRecording()
                    } else {
                        _ = self.recorder.stop(deactivateSession: true)
                    }
                    self.teardownLivePartialPreview(clearText: true)
                    self.releaseIdleTimer()
                    await self.resumeKeyboardStandbyAfterCommand()
                    self.publishKeyboardStatus(.standby, message: "Ready")
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                }
            },
            KeyboardDarwinBridge.observe(requestSessionStatusName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.keyboardAudioSession.isActive {
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
                    }
                    if self.keyboardAudioSession.isRecording {
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
                    }
                }
            },
        ]
    }

    private func handleKeyboardCommand(_ command: KeyboardBridgeCommand) async -> KeyboardBridgeStatus {
        guard keyboardStandbyEnabled || keyboardAudioSession.isRecording else {
            publishKeyboardStatus(.idle, commandID: command.id, message: "Keyboard standby is off")
            return keyboardBridgeStatus
        }
        guard Date().timeIntervalSince1970 - command.createdAt < 60 else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Keyboard command expired")
            return keyboardBridgeStatus
        }
        switch command.action {
        case .start:
            guard !consumeCanceledKeyboardCommand(command.id) else {
                clearKeyboardCaptureContext()
                publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                return keyboardBridgeStatus
            }
            if let requestedMode = CorrectionModeID(rawValue: command.correctionMode) {
                applyKeyboardDefaultCorrectionMode(requestedMode)
            }
            activeKeyboardTextEditContext = command.textEditContext
            activeKeyboardDictationContext = command.dictationContext
            keyboardCaptureStartedFromKeyboard = true
            activeKeyboardRecordingCommandID = command.id
            await startKeyboardRecording(commandID: command.id, allowSessionStart: true)
        case .stop:
            return beginKeyboardStopAndSend(commandID: command.id)
        case .cancel:
            rememberCanceledKeyboardCommand(command.id)
            clearKeyboardCaptureContext()
            if keyboardAudioSession.isRecording {
                keyboardAudioSession.cancelRecording()
            } else {
                _ = recorder.stop(deactivateSession: true)
            }
            teardownLivePartialPreview(clearText: true)
            releaseIdleTimer()
            await resumeKeyboardStandbyAfterCommand()
            publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            resetCorrectionModeToDefault()
        case .configure:
            if let requestedMode = CorrectionModeID(rawValue: command.correctionMode) {
                applyKeyboardDefaultCorrectionMode(requestedMode)
            } else {
                resetCorrectionModeToDefault()
            }
            clearKeyboardCaptureContext()
            publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
        case .restyleText:
            await restyleKeyboardText(command)
        }
        return keyboardBridgeStatus
    }

    private func beginKeyboardStopAndSend(commandID: String) -> KeyboardBridgeStatus {
        guard keyboardAudioSession.isRecording || recorder.isRecording else {
            queuedKeyboardStopCommandID = nil
            publishKeyboardStatus(.standby, commandID: commandID, message: "Ready")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            return keyboardBridgeStatus
        }
        guard !isStopAndSendInFlight, queuedKeyboardStopCommandID == nil else {
            if keyboardBridgeStatus.state != .sending {
                publishKeyboardStatus(
                    .sending,
                    commandID: queuedKeyboardStopCommandID ?? commandID,
                    message: NSLocalizedString("Transcribing", comment: "Bridge job stage")
                )
            }
            return keyboardBridgeStatus
        }

        queuedKeyboardStopCommandID = commandID
        publishKeyboardStatus(.sending, commandID: commandID, message: NSLocalizedString("Transcribing", comment: "Bridge job stage"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopAndSend(keyboardCommandID: commandID)
            if self.queuedKeyboardStopCommandID == commandID {
                self.queuedKeyboardStopCommandID = nil
            }
        }
        return keyboardBridgeStatus
    }

    private func restyleKeyboardText(_ command: KeyboardBridgeCommand) async {
        guard !isBusy else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Typeforme is busy")
            return
        }
        let requestedCorrectionMode = CorrectionModeID(rawValue: command.correctionMode) ?? config.correctionMode
        guard let source = command.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty
        else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Nothing to refine")
            return
        }
        let existingResultText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingGeneratedText = lastGeneratedResultText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRestylingCurrentDictationResult = source == existingResultText
            || source == existingGeneratedText
        let preservedRawTranscript = rawTranscript
        correctionMode = requestedCorrectionMode

        publishKeyboardStatus(.sending, commandID: command.id, message: NSLocalizedString("Refining", comment: "Bridge job stage"))
        // Happy-path: reuse cached route. Errors invalidate the cache below so
        // the next attempt re-probes naturally.
        await refreshRoute(force: false, probeAllEndpoints: false, showIndicator: false)
        guard let baseURL = routeStatus.activeURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            publishKeyboardStatus(.error, commandID: command.id, message: errorMessage ?? "Bridge unavailable")
            return
        }

        do {
            setPhase(.restyling)
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            let restyleJobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            let response = try await client.restyle(
                sessionID: nil,
                rawTranscript: source,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode,
                clientJobID: restyleJobID,
                onJobEvent: { [weak self] event in
                    await MainActor.run {
                        self?.applyBridgeJobStatus(event, keyboardCommandID: command.id)
                    }
                }
            )
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                publishKeyboardStatus(.error, commandID: command.id, message: errorMessage ?? "Empty result")
                return
            }

            resultText = text
            lastGeneratedResultText = text
            rawTranscript = isRestylingCurrentDictationResult ? preservedRawTranscript : ""
            sessionID = response.sessionID
            latestServerTiming = ServerTimingSummary(
                transcriptionLatencyMs: nil,
                correctionLatencyMs: response.correctionLatencyMs ?? response.latencyMs,
                totalLatencyMs: response.latencyMs
            )
            errorMessage = nil
            applyCorrectionMetadata(
                status: response.correctionStatus,
                error: response.correctionError,
                successKind: .inserted
            )
            publishKeyboardStatus(
                .result,
                commandID: command.id,
                message: "Refined",
                resultText: text,
                rawTranscriptLength: isRestylingCurrentDictationResult
                    ? preservedRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count
                    : nil
            )
        } catch {
            // Invalidate the route cache on both auth and network errors so
            // the next keyboard-edit attempt re-probes.
            if shouldRetryBridgeRequest(after: error) {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
            publishKeyboardStatus(.error, commandID: command.id, message: error.localizedDescription)
        }
    }

    private func startKeyboardRecording(
        commandID: String?,
        allowSessionStart: Bool
    ) async {
        if let commandID {
            activeKeyboardRecordingCommandID = commandID
        }
        if keyboardAudioSession.isRecording {
            keyboardCaptureStartedFromKeyboard = true
            publishKeyboardStatus(.recording, commandID: commandID, message: "Recording")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
            return
        }
        if !keyboardAudioSession.isActive {
            guard allowSessionStart else {
                clearKeyboardCaptureContext()
                resetCorrectionModeToDefault()
                publishKeyboardStatus(.idle, commandID: commandID, message: "Keyboard audio session is not active")
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                return
            }
            do {
                let isInputReady = try await prepareKeyboardInputStandby(
                    requestMicrophoneIfNeeded: false
                )
                guard isInputReady else {
                    clearKeyboardCaptureContext()
                    resetCorrectionModeToDefault()
                    startSilentStandbyKeeperIfNeeded()
                    publishKeyboardStatus(.idle, commandID: commandID, message: keyboardMicrophonePreparationMessage)
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                    return
                }
                scheduleHostAudioSessionExpiry()
            } catch {
                clearKeyboardCaptureContext()
                resetCorrectionModeToDefault()
                setFailure(error.localizedDescription)
                publishKeyboardStatus(.error, commandID: commandID, message: error.localizedDescription)
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                await resumeKeyboardStandbyAfterCommand()
                return
            }
        }
        // Keep the keyboard press-to-record path local-only for the same reason.
        // No correctionMode reset here either — match the host orb path.
        do {
            _ = try await keyboardAudioSession.beginRecording()
            keyboardCaptureStartedFromKeyboard = true
            startLivePartialPreviewIfAvailable()
            acquireIdleTimer()
            setPhase(.recording)
            publishKeyboardStatus(.recording, commandID: commandID, message: "Recording")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
        } catch {
            clearKeyboardCaptureContext()
            setFailure(error.localizedDescription)
            publishKeyboardStatus(.error, commandID: commandID, message: error.localizedDescription)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
        }
    }

    private func resumeKeyboardStandbyAfterCommand(retryCount: Int = 0) async {
        guard keyboardStandbyEnabled else { return }
        guard !keyboardAudioSession.isRecording else { return }
        guard !phase.isBusy else { return }
        do {
            try keyboardServer.start()
            let isInputReady = try await prepareKeyboardInputStandby(requestMicrophoneIfNeeded: false)
            if isInputReady {
                publishKeyboardStatus(.standby, message: "Ready")
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
            } else {
                startSilentStandbyKeeperIfNeeded()
                publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
            }
            scheduleHostAudioSessionExpiry()
        } catch {
            // This tail runs after recording/transcription has already
            // succeeded. iOS can reject immediate audio-session reactivation
            // while the recorder/route is still settling, so do not surface it
            // as a user-visible failure. Keep the bridge process warm if
            // possible and retry in the background; the next keyboard press can
            // still open the host if input standby is not ready yet.
            appLog.notice("keyboard standby refresh deferred: \(error.localizedDescription, privacy: .public)")
            startSilentStandbyKeeperIfNeeded()
            publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
            guard retryCount < 2 else { return }
            scheduleKeyboardStandbyRefresh(delay: 2.0 * Double(retryCount + 1), retryCount: retryCount + 1)
        }
    }

    private func scheduleKeyboardStandbyRefresh(delay: TimeInterval = 1.5, retryCount: Int = 0) {
        keyboardStandbyRefreshTask?.cancel()
        keyboardStandbyRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resumeKeyboardStandbyAfterCommand(retryCount: retryCount)
        }
    }

    private func notifyKeyboardResultReady() {
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.transcriptionReady)
    }

    private func publishKeyboardStatus(
        _ state: KeyboardBridgeState,
        commandID: String? = nil,
        message: String? = nil,
        resultText: String? = nil,
        audioDurationSeconds: Double? = nil,
        audioByteCount: Int? = nil,
            rawTranscriptLength: Int? = nil
    ) {
        if keyboardAudioSession.isRecording,
           state == .standby || state == .idle,
           commandID == nil || commandID == activeKeyboardRecordingCommandID {
            let preservedCommandID = activeKeyboardRecordingCommandID
                ?? keyboardBridgeStatus.commandID
                ?? commandID
            if keyboardBridgeStatus.state == .recording,
               keyboardBridgeStatus.commandID == preservedCommandID,
               keyboardBridgeStatus.message == "Recording" {
                return
            }
            keyboardBridgeStatus = KeyboardBridgeStatus(
                commandID: preservedCommandID,
                state: .recording,
                message: "Recording",
                defaultCorrectionMode: config.correctionMode.rawValue
            )
            return
        }

        let partial = livePartialTranscript.isEmpty ? nil : livePartialTranscript
        let status = KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message ?? KeyboardBridgeStatus.idle.message,
            resultText: resultText,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: config.correctionMode.rawValue,
            livePartialTranscript: partial
        )
        keyboardBridgeStatus = status
    }

    /// Called from the SFSpeechRecognizer partial callback on every new
    /// hypothesis. Updates only the live partial field on the keyboard bridge
    /// status — keeps the existing state / message / commandID intact so the
    /// keyboard's stage indicator doesn't churn.
    private func publishLivePartialTranscriptToKeyboard() {
        guard keyboardBridgeStatus.state == .recording || keyboardBridgeStatus.state == .sending else { return }
        let next = livePartialTranscript.isEmpty ? nil : livePartialTranscript
        guard keyboardBridgeStatus.livePartialTranscript != next else { return }
        keyboardBridgeStatus = keyboardBridgeStatus.withLivePartialTranscript(next)
    }

    private func applyBridgeJobStatus(
        _ event: BridgeJobStatusEvent,
        keyboardCommandID: String?,
        recordingInfo: RecordingFileInfo? = nil
    ) {
        guard phase.isBusy else { return }
        let transcriptLength = event.rawTranscriptLength
            ?? event.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).count

        // Collapse the bridge's 6 raw stages into the 5 user-meaningful ones:
        //   audio_received    → Sending
        //   transcribing      → Transcribing
        //   transcript_ready  → (skip; still in Transcribing, refining starts next)
        //   refining          → Refining
        //   result_ready      → Inserted
        //   failed            → <error reason>
        // Same string drives `processingStatusMessage` (host orb detail) and
        // `publishKeyboardStatus(... message:)` (keyboard top label).
        if event.stage == .transcriptReady,
           let raw = event.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            rawTranscript = raw
        }

        let stageMessage: String?
        let keyboardState: KeyboardBridgeState
        switch event.stage {
        case .audioReceived:
            stageMessage = NSLocalizedString("Transcribing", comment: "Bridge job stage")
            keyboardState = .sending
        case .transcribing:
            stageMessage = NSLocalizedString("Transcribing", comment: "Bridge job stage")
            keyboardState = .sending
        case .transcriptReady:
            stageMessage = nil
            keyboardState = .sending
        case .refining:
            stageMessage = NSLocalizedString("Refining", comment: "Bridge job stage")
            keyboardState = .sending
        case .resultReady:
            stageMessage = NSLocalizedString("Inserted", comment: "Bridge job stage")
            keyboardState = .sending
        case .failed:
            let trimmedError = event.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            stageMessage = trimmedError.isEmpty ? event.message : trimmedError
            keyboardState = .error
        }

        guard let stageMessage else { return }
        processingStatusMessage = stageMessage
        if event.stage != .resultReady, let keyboardCommandID {
            // `.resultReady` is a host-only transient — the final keyboard
            // status is published by the dictate response handler.
            publishKeyboardStatus(
                keyboardState,
                commandID: keyboardCommandID,
                message: stageMessage,
                audioDurationSeconds: recordingInfo?.durationSeconds,
                audioByteCount: recordingInfo?.byteCount,
                rawTranscriptLength: transcriptLength
            )
        }
    }

    private func applyCorrectionMetadata(
        status correctionStatus: String?,
        error correctionError: String?,
        successKind: AppPhase.SuccessKind = .ready
    ) {
        if correctionStatus == "error" {
            let message = correctionError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            setFailure(message.isEmpty ? "Mac refine failed." : message)
            return
        }
        if correctionStatus == "timeout" {
            errorMessage = nil
            setPhase(.success(successKind))
            switch successKind {
            case .ready:
                showTransient("Refine timed out; transcript ready")
            case .copied:
                showTransient("Refine timed out; copied transcript")
            case .inserted:
                showTransient("Refine timed out; inserted transcript")
            }
            return
        }
        errorMessage = nil
        setPhase(.success(successKind))
        switch successKind {
        case .ready:
            showTransient("Ready")
        case .copied:
            showTransient("Copied")
        case .inserted:
            showTransient("Inserted")
        }
    }

    private func isBenignEmptyTranscript(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("empty transcript")
            || message.contains("audio produced an empty transcript")
            || message.contains("asr return empty")
    }

    // MARK: - Phase / transient state

    private func setPhase(_ next: AppPhase) {
        phase = next
        if !next.isBusy {
            processingStatusMessage = nil
        }
        phaseResetTask?.cancel()
        phaseResetTask = nil
        switch next {
        case .success, .failure:
            phaseResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.phaseAutoResetDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if case .success = self.phase {
                        self.setPhase(.idle)
                    } else if case .failure = self.phase {
                        self.setPhase(.idle)
                    }
                }
            }
        default:
            break
        }
        if !next.isBusy {
            scheduleHostRecorderPreWarm()
        }
    }

    private func setFailure(_ message: String) {
        teardownLivePartialPreview(clearText: true)
        errorMessage = message
        setPhase(.failure(message))
    }

    private func showTransient(_ message: String) {
        transientMessage = message
        transientMessageTask?.cancel()
        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transientMessage = nil
            }
        }
    }

    private func resetReturnTrace(_ message: String) {
        returnTracker.reset(message)
    }

    private func appendReturnTrace(_ message: String) {
        returnTracker.append(message)
    }

    private func logReturnTrace(_ message: String) {
        returnTracker.log(message)
    }

    // MARK: - Idle timer

    /// Multiple paths can ask the screen to stay on; track holders so we don't
    /// drop it back to default while one path is still recording.
    private func acquireIdleTimer() {
        idleTimerHolders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func releaseIdleTimer() {
        idleTimerHolders = max(0, idleTimerHolders - 1)
        if idleTimerHolders == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - App lifecycle

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEnteredBackground()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillEnterForeground()
            }
        })
    }

    private func startNetworkPathMonitor() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.networkSignature(for: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.networkPathSignature == nil {
                    self.networkPathSignature = signature
                    return
                }
                let now = Date()
                let signatureChanged = self.networkPathSignature != signature
                let shouldRefreshSameSignature = !signatureChanged
                    && path.status == .satisfied
                    && path.usesInterfaceType(.wifi)
                    && self.routeStatus.activeKind == .local
                    && self.shouldRefreshRouteForSameSignaturePathUpdate(at: now)
                guard signatureChanged || shouldRefreshSameSignature else { return }
                if signatureChanged {
                    self.networkPathSignature = signature
                }
                self.lastNetworkPathRefreshAt = now
                self.routeFetchedAt = nil
                self.routeStatus = BridgeRouteStatus()
                if self.isConfigured {
                    await self.refreshRoute(force: true, showIndicator: false)
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    private func shouldRefreshRouteForSameSignaturePathUpdate(at now: Date) -> Bool {
        guard let lastNetworkPathRefreshAt else { return true }
        return now.timeIntervalSince(lastNetworkPathRefreshAt) >= Self.networkPathSameSignatureRefreshInterval
    }

    nonisolated private static func networkSignature(for path: NWPath) -> String {
        [
            path.status == .satisfied ? "up" : "down",
            path.usesInterfaceType(.wifi) ? "wifi" : "",
            path.usesInterfaceType(.cellular) ? "cellular" : "",
            path.usesInterfaceType(.wiredEthernet) ? "wired" : "",
            path.usesInterfaceType(.loopback) ? "loopback" : "",
            path.isExpensive ? "expensive" : "",
            path.isConstrained ? "constrained" : "",
        ].filter { !$0.isEmpty }.joined(separator: ":")
    }

    private func handleEnteredBackground() {
        teardownLivePartialPreview(clearText: true)
        // Backgrounding kills the AVAudioSession we're recording on. Cancel
        // the in-flight recording so we don't ship an empty / corrupted file
        // to the Bridge on resume.
        if recorder.isRecording || (hostRecordingUsesKeyboardAudioSession && keyboardAudioSession.isRecording) {
            if hostRecordingUsesKeyboardAudioSession {
                keyboardAudioSession.cancelRecording()
                hostRecordingUsesKeyboardAudioSession = false
                clearKeyboardCaptureContext()
            } else {
                _ = recorder.stop(deactivateSession: true)
            }
            releaseIdleTimer()
            hostHoldReleasePending = false
            setPhase(.failure("Recording stopped — app went to background."))
        }
    }

    private func handleWillEnterForeground() {
        scheduleHostRecorderPreWarm()
        // Warm route status for the UI. Hot recording/rewrite paths request a
        // fast route separately so Cloud diagnostics never block input.
        routeFetchedAt = nil
        Task {
            await refreshRoute(force: true, showIndicator: false)
            _ = try? await refreshMacSettingsIfChanged()
            scheduleHostRecorderPreWarm()
        }
    }
}

private struct RecordingFileInfo {
    let durationSeconds: Double?
    let byteCount: Int
    let sampleRate: Double?
    let channelCount: AVAudioChannelCount?
    let fileExtension: String

    init(url: URL) {
        fileExtension = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            durationSeconds = Double(file.length) / file.fileFormat.sampleRate
            sampleRate = file.fileFormat.sampleRate
            channelCount = file.fileFormat.channelCount
        } else {
            durationSeconds = nil
            sampleRate = nil
            channelCount = nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    var isTooShort: Bool {
        if let durationSeconds {
            return durationSeconds < 0.35
        }
        return byteCount <= 44
    }

    var durationLabel: String {
        guard let durationSeconds else { return "unknown-length" }
        return String(format: "%.1fs", durationSeconds)
    }

    var summary: String {
        let kb = Double(byteCount) / 1024
        let format: String
        if let sampleRate, let channelCount {
            format = String(format: ", %@ %.0fkHz %dch", fileExtension, sampleRate / 1000, channelCount)
        } else {
            format = ", \(fileExtension)"
        }
        if let durationSeconds {
            return String(format: "%.2fs, %.0f KB%@", durationSeconds, kb, format)
        }
        return String(format: "unknown duration, %.0f KB%@", kb, format)
    }
}
