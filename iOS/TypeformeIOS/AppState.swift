import AVFoundation
import Darwin
import Foundation
import Network
import ObjectiveC
import Observation
import OSLog
import os.lock
import Speech
import UIKit

private let appLog = Logger(subsystem: TypeformeBundleConfiguration.hostBundleIdentifier, category: "app")

private final class LivePreviewTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: CFAbsoluteTime
    private var firstPCMAt: CFAbsoluteTime?
    private var firstPartialAt: CFAbsoluteTime?
    private var pcmBufferCount = 0

    init(startedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.startedAt = startedAt
    }

    func recordPCM(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> (isFirst: Bool, startToPCMMS: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        pcmBufferCount += 1
        let isFirst = firstPCMAt == nil
        if isFirst {
            firstPCMAt = now
        }
        return (isFirst, Int((now - startedAt) * 1_000), pcmBufferCount)
    }

    func recordPartial(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> (isFirst: Bool, startToPartialMS: Int, firstPCMToPartialMS: Int?, pcmBufferCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        let isFirst = firstPartialAt == nil
        if isFirst {
            firstPartialAt = now
        }
        let pcmDelta = firstPCMAt.map { Int((now - $0) * 1_000) }
        return (isFirst, Int((now - startedAt) * 1_000), pcmDelta, pcmBufferCount)
    }
}

private final class LiveSpeechRequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var isOpen = true

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        request.append(buffer)
    }

    func endAudio() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        isOpen = false
        request.endAudio()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        isOpen = false
    }
}

/// Top-level UI phase for the iOS host app. Drives the hero record card,
/// busy/disabled gating, and the keyboard bridge status. Keep user-facing
/// labels derived from this typed state rather than using strings as control
/// flow.
enum AppPhase: Equatable {
    case idle
    case preparing
    case recording
    case sending
    case refining
    case success(SuccessKind)
    case failure(String)

    enum SuccessKind: Equatable {
        case ready
        case copied
        case inserted
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .sending, .refining: return true
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
        case .refining: return "Refining"
        case .success(.ready): return "Result ready"
        case .success(.copied): return "Copied"
        case .success(.inserted): return "Inserted"
        case .failure(let msg): return msg
        }
    }
}

enum HostReadinessAuthorizationStatus: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted
    case unavailable
    case unknown

    var isGranted: Bool {
        self == .granted
    }
}

private struct BridgeStageLabels {
    let transcribing: String
    let refining: String
    let resultReady: String

    func transcribingMessage(for event: BridgeJobStatusEvent) -> String {
        guard let completed = event.transcriptionCompletedSources,
              let total = event.transcriptionTotalSources,
              total > 1
        else { return transcribing }
        let clampedCompleted = min(max(0, completed), total)
        return "\(transcribing) (\(clampedCompleted)/\(total))"
    }

    static var dictation: BridgeStageLabels {
        BridgeStageLabels(
            transcribing: NSLocalizedString("Transcribing", comment: "Bridge job stage"),
            refining: NSLocalizedString("Refining", comment: "Bridge job stage"),
            resultReady: NSLocalizedString("Inserted", comment: "Bridge job stage")
        )
    }

    static var commandRecognition: BridgeStageLabels {
        let understanding = NSLocalizedString("Understanding", comment: "Bridge job stage while understanding a voice command")
        return BridgeStageLabels(
            transcribing: understanding,
            refining: understanding,
            resultReady: understanding
        )
    }

    static var commandEditing: BridgeStageLabels {
        let editing = NSLocalizedString("Editing", comment: "Bridge job stage while applying a voice command")
        return BridgeStageLabels(
            transcribing: editing,
            refining: editing,
            resultReady: NSLocalizedString("Inserted", comment: "Bridge job stage")
        )
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

enum KeyboardDictationCaptureMode: String, CaseIterable, Identifiable {
    case backgroundMic = "background_mic"
    case pictureInPicture = "picture_in_picture"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backgroundMic:
            return NSLocalizedString("Background Mic", comment: "Keyboard dictation capture method")
        case .pictureInPicture:
            return NSLocalizedString("PiP", comment: "Keyboard dictation capture method")
        }
    }

    var detail: String {
        switch self {
        case .backgroundMic:
            return NSLocalizedString(
                "When Typeforme is opened, the host app keeps a background microphone session ready for keyboard dictation.",
                comment: "Background mic capture mode detail"
            )
        case .pictureInPicture:
            return NSLocalizedString(
                "When Typeforme is opened, the host app keeps a visible PiP session and local bridge ready for keyboard dictation. The microphone and host audio session open only while recording.",
                comment: "PiP capture mode detail"
            )
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
    private static let cachedCapabilities = OSAllocatedUnfairLock(initialState: [String: AppleSpeechPreviewCapability]())
    private static let supportedLocaleIDs: Set<String> = Set(
        SFSpeechRecognizer.supportedLocales().map { normalizedIdentifier($0.identifier) }
    )

    static func capability(languageID: String) -> AppleSpeechPreviewCapability {
        let normalizedID = normalizedIdentifier(languageID)

        if let cached = cachedCapabilities.withLock({ $0[normalizedID] }) {
            return cached
        }

        let capability = resolveCapability(languageID: languageID, normalizedID: normalizedID)

        cachedCapabilities.withLock { cache in
            cache[normalizedID] = capability
        }
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

enum KeyboardLivePreviewSource: String, CaseIterable, Identifiable {
    case appleSpeech = "apple-speech"
    case qwen = "qwen3-asr-llama"
    case nvidiaNemotron = "nvidia-nemotron"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech:
            return NSLocalizedString("Apple Speech", comment: "Apple Speech live preview source")
        case .qwen:
            return NSLocalizedString("Qwen3-ASR (Mac)", comment: "Qwen server ASR preview source")
        case .nvidiaNemotron:
            return NSLocalizedString("NVIDIA Nemotron (Mac)", comment: "Nemotron server ASR preview source")
        }
    }

    var bridgeLivePreviewSource: VoiceLivePreviewSource? {
        switch self {
        case .appleSpeech:
            return nil
        case .qwen:
            return .qwen
        case .nvidiaNemotron:
            return .nvidiaNemotron
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
@Observable
final class AppState {
    var config: PairingConfig
    var correctionMode: CorrectionMode
    var inputMode: VoiceInputMode
    var selectedLanguageIDs: Set<String>
    var resultText = ""
    var rawTranscript = ""
    var sessionID: String?
    var phase: AppPhase = .idle
    var errorMessage: String?
    var routeStatus = BridgeRouteResolutionStatus()
    private(set) var isRefreshingRoute = false
    var keyboardStandbyEnabled = true
    var hostAudioSessionLength: HostAudioSessionLength
    var keyboardDictationCaptureMode: KeyboardDictationCaptureMode
    var keyboardAutoCapitalizationEnabled: Bool
    var keyboardCharacterPreviewEnabled: Bool
    var keyboardKeySoundEnabled: Bool
    var keyboardKeyHapticsEnabled: Bool
    var keyboardLivePreviewEnabled: Bool
    var keyboardLivePreviewSource: KeyboardLivePreviewSource
    var keyboardLivePreviewRecognitionMode: KeyboardLivePreviewRecognitionMode
    var keyboardChineseInputEnabled: Bool
    var keyboardChinesePunctuationStyle: KeyboardChinesePunctuationStyle
    var keyboardRimeDictionaryTier: KeyboardRimeDictionaryTier
    var keyboardRimeLearningEnabled: Bool
    var keyboardRimeCorrectionEnabled: Bool
    var keyboardTouchLearningEnabled: Bool
    var keyboardDefaultTextInputLanguage: KeyboardDefaultTextInputLanguage
    private(set) var keyboardRimeLearningResetGeneration: Int
    private(set) var keyboardTouchLearningResetGeneration: Int
    var keyboardBridgeStatus = KeyboardBridgeStatus.idle
    private let keyboardStatusHostInstanceID = UUID().uuidString
    private var keyboardStatusRevision: UInt64 = 0
    /// True once the keyboard extension has successfully contacted the host
    /// (via the local bridge server or a Darwin notification). A successful
    /// contact implies the keyboard is enabled AND has Full Access — without
    /// Full Access the extension can't open a local network connection. Used
    /// by SetupStatusCard to decide whether to default-expand the onboarding
    /// hints. Persisted in UserDefaults so it survives app restarts.
    var keyboardEverContacted: Bool
    var keyboardFullAccessRequired: Bool
    var lastRecordingSummary = ""
    var processingStatusMessage: String?
    var latestServerTiming: ServerTimingSummary?
    var macSettings: BridgeMacSettingsPayload?
    var isEditingMacSettings = false
    private(set) var microphonePermissionStatus: HostReadinessAuthorizationStatus
    private(set) var speechRecognitionPermissionStatus: HostReadinessAuthorizationStatus
    var setupReadinessDismissed: Bool
    private(set) var isStopAndSendInFlight = false
    /// Transient feedback ("Copied!", "Saved!") rendered as a toast.
    var transientMessage: String?
    /// Set on entering `.recording`, cleared when the pipeline goes idle.
    /// Drives the elapsed-time readout under the orb title.
    private(set) var recordingStartedAt: Date?

    var keyboardNeedsFullAccessSetup: Bool {
        keyboardFullAccessRequired || !keyboardEverContacted
    }

    var setupReadinessNeedsAttention: Bool {
        !microphonePermissionStatus.isGranted || keyboardNeedsFullAccessSetup
    }

    var shouldPresentSetupReadiness: Bool {
        !setupReadinessDismissed && setupReadinessNeedsAttention
    }

    let audioCoordinator = AudioCoordinator()
    @ObservationIgnored let pipDictationCoordinator = PiPDictationCoordinator()

    private let bridgeService = BridgeService()
    private let keyboardCoordinator = KeyboardCoordinator()
    private let keyboardServer = KeyboardLocalServer()
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(label: "\(TypeformeBundleConfiguration.hostBundleIdentifier).network-path")
    private static let inputModeKey = "keyboard.inputMode"
    private static let hostAudioSessionLengthKey = "keyboard.hostAudioSessionLength"
    private static let keyboardDictationCaptureModeKey = "keyboard.dictationCaptureMode"
    private static let keyboardAutoCapitalizationKey = "keyboard.autoCapitalizationEnabled"
    private static let keyboardCharacterPreviewKey = "keyboard.characterPreviewEnabled"
    private static let keyboardKeySoundKey = "keyboard.keySoundEnabled"
    private static let keyboardKeyHapticsKey = "keyboard.keyHapticsEnabled"
    private static let keyboardLivePreviewKey = "keyboard.livePreviewEnabled"
    private static let keyboardLivePreviewSourceKey = "keyboard.livePreviewSource"
    private static let keyboardLivePreviewRecognitionModeKey = "keyboard.livePreviewRecognitionMode"
    private static let keyboardChineseInputEnabledKey = "keyboard.chineseInputEnabled"
    private static let minimumRecordingStopInterval: TimeInterval = 0.55
    private static let keyboardStartFinalizationWaitTimeout: TimeInterval = 4.0
    private static let maximumCaptureDuration: TimeInterval = 590
    private static let firstAudioFrameTimeout: TimeInterval = 4.0
    private static let audioFrameStallTimeout: TimeInterval = 4.0
    private static let captureHealthPollInterval: TimeInterval = 0.5
    private static let keyboardChinesePunctuationStyleKey = "keyboard.chinesePunctuationStyle"
    private static let keyboardRimeDictionaryTierKey = "keyboard.rimeDictionaryTier"
    private static let keyboardRimeLearningKey = "keyboard.rimeLearningEnabled"
    private static let keyboardRimeCorrectionKey = "keyboard.rimeCorrectionEnabled"
    private static let keyboardTouchLearningKey = "keyboard.touchLearningEnabled"
    private static let keyboardDefaultTextInputLanguageKey = "keyboard.defaultTextInputLanguage"
    private static let keyboardRimeLearningResetGenerationKey = "keyboard.rimeLearningResetGeneration"
    private static let keyboardTouchLearningResetGenerationKey = "keyboard.touchLearningResetGeneration"
    private static let keyboardEverContactedKey = "keyboard.everContacted"
    private static let keyboardFullAccessRequiredKey = "keyboard.fullAccessRequired"
    private static let setupReadinessDismissedKey = "setup.readinessDismissed"
    private static let serverRimeUserPhrasesKey = "server.rimeUserPhrases"
    private static let livePreviewFinishWaitTimeout: TimeInterval = BridgeSettingsNormalization.asrTimeoutSecondsRange.upperBound + 5
    private static let automaticPiPStartMaxAttempts = 3
    private var hostHoldReleasePending = false
    private var hostRecordingUsesKeyboardAudioSession = false
    private var keyboardCaptureStartedFromKeyboard = false
    private var captureGeneration: UInt64 = 0
    private var captureStartInFlightGeneration: UInt64?
    private var captureStartInFlightOwner: CaptureOwner?
    private var activeCaptureGeneration: UInt64?
    private var activeCaptureOwner: CaptureOwner?
    @ObservationIgnored private var captureDurationWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var captureHealthWatchdogTask: Task<Void, Never>?
    private var activeKeyboardRecordingCommandID: String?
    private var activeBridgeDictateJobID: String?
    private var activeBridgeRefineJobID: String?
    private var queuedKeyboardStopCommandID: String?
    @ObservationIgnored private var stopAndSendTask: Task<Void, Never>?
    private var stopAndSendTaskID: UUID?
    @ObservationIgnored private var hostAudioSessionExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardStandbyRefreshTask: Task<Void, Never>?
    private var keyboardStandbyRefreshTaskID: UUID?
    private var postCaptureBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var postCaptureBackgroundTaskGeneration: UInt64?
    private var routeFetchedAt: Date?
    private var pairingRevision: UInt64 = 0
    private var networkPathSignature: String?
    private var lastNetworkPathRefreshAt: Date?
    private var lastForegroundRouteRefreshAt: Date?
    private var routeRefreshGeneration: UInt64 = 0
    private var routeStatusProbeInFlightCount = 0
    private var macSettingsFetchedAt: Date?
    private var macSettingsRevision: String?
    private var cachedServerRimeUserPhrases: [String]
    private var phaseResetTask: Task<Void, Never>?
    private var transientMessageTask: Task<Void, Never>?
    private var initialRenderDelayTask: Task<Void, Never>?
    @ObservationIgnored private var autoStartPiPTask: Task<Void, Never>?
    private var autoStartPiPTaskID: UUID?
    private var capturePreparationGeneration: UInt64 = 0
    @ObservationIgnored private var foregroundCapturePreparationTask: Task<Void, Never>?
    private var foregroundCapturePreparationTaskID: UUID?
    @ObservationIgnored private var captureModeTransitionTask: Task<Void, Never>?
    private var captureModeTransitionTaskID: UUID?
    private var suppressAutomaticPiPStart = false
    private var automaticPiPStartAttemptsRemaining = 0
    private var automaticPiPStartShowsErrors = false
    private var lastPiPStopAt: Date?
    @ObservationIgnored private var recorderPreWarmTask: Task<Void, Never>?
    private var bridgeProgressStatusTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardStatusAudioLevelTask: Task<Void, Never>?
    /// Live-preview transcript fed by the selected preview source while the
    /// user is recording (and held until the Mac final result replaces it).
    /// Empty string = no preview surfaced (unsupported language, denied
    /// permission, or no recording in progress).
    private(set) var livePartialTranscript: String = ""
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveSpeechRequestSink: LiveSpeechRequestSink?
    private var liveSpeechTask: SFSpeechRecognitionTask?
    private var serverLivePreviewStreamer: BridgeLivePreviewStreamer?
    private var livePreviewTrace: LivePreviewTrace?
    private var livePreviewGeneration: UInt64 = 0
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    private var routeRefreshInFlightCount = 0
    private(set) var isCheckingRouteStatus = false
    private var idleTimerHolders = 0
    private var lastGeneratedResultText: String?
    private var activeKeyboardTextEditContext: KeyboardTextEditContext?
    private var activeKeyboardDictationContext: KeyboardDictationContext?
    private var canceledKeyboardCommandIDs: [String: TimeInterval] = [:]
    private var lastHandledOpenURL: (value: String, time: TimeInterval)?
    private var keyboardAudioUnavailableMessage: String?
    private var audioSessionInterruptionActive = false
#if DEBUG && targetEnvironment(simulator)
    private var simulatorDebugAllowsUnpairedCapturePreparation = false
    private var simulatorDebugUnpairedCommandIDs: Set<String> = []
#endif

    /// Force-refresh cloud/unavailable routes if cached probe is older than
    /// this. Local routes get a shorter TTL because stale LAN IPs hurt more
    /// than the extra probe.
    private static let routeCacheTTL: TimeInterval = 30
    private static let localRouteCacheTTL: TimeInterval = 5
    private static let foregroundRouteRefreshTTL: TimeInterval = 20
    private static let networkPathSameSignatureRefreshInterval: TimeInterval = 15
    private static let canceledKeyboardCommandTTL: TimeInterval = KeyboardBridgeCommand.maxAge + 5
    private static let bridgeProgressStatusDelay: TimeInterval = 1.2
    private static let keyboardStatusAudioLevelInterval: UInt64 = 100_000_000
    private static let keyboardStatusAudioLevelMinimumDelta: Float = 0.025
    /// How long a `.success` / `.failure` phase sticks before reverting to
    /// `.idle`. Long enough to read, short enough not to block the next press.
    private static let phaseAutoResetDelay: TimeInterval = 2.4

    private static func recognitionStageLabels(for context: KeyboardTextEditContext?) -> BridgeStageLabels {
        context?.intent == .command ? .commandRecognition : .dictation
    }

    private static func editingStageLabels(for context: KeyboardTextEditContext) -> BridgeStageLabels {
        context.intent == .command ? .commandEditing : .dictation
    }

    private struct RefineSource {
        let sessionID: String?
        let rawTranscript: String?
    }

    private enum MicrophonePermissionRequestResult: Equatable {
        case granted
        case denied
        case unavailable
    }

    private enum CaptureOwner: Equatable {
        case host
        case keyboard(commandID: String?)
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

    var canRefineCurrentResult: Bool {
        !phase.isBusy && currentRefineSource() != nil
    }

    var isConfigured: Bool {
        !config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && config.hasAnyBridgeURL
    }

    private var capturePreparationIsAuthorized: Bool {
#if DEBUG && targetEnvironment(simulator)
        isConfigured
            || simulatorDebugAllowsUnpairedCapturePreparation
            || !simulatorDebugUnpairedCommandIDs.isEmpty
#else
        isConfigured
#endif
    }

    var isReadyToRecord: Bool {
        isConfigured && !isBusy
    }

    var canInteractWithHostDictation: Bool {
        guard isConfigured else { return false }
        if recorder.isRecording || keyboardAudioSession.isRecording || phase == .preparing { return true }
        return phase.allowsRecordingStart
    }

    var isRecordingCaptureActive: Bool {
        hasAnyActiveRecordingCapture
    }

    var canMutateResult: Bool {
        !phase.isBusy && !hasAnyActiveRecordingCapture && !isStopAndSendInFlight
    }

    var hostRecordingLevel: Float {
        hostRecordingUsesKeyboardAudioSession ? keyboardAudioSession.level : recorder.level
    }

    private var hasAnyActiveRecordingCapture: Bool {
        recorder.isRecording || keyboardAudioSession.isRecording
    }

    private var hasHostOwnedRecordingCapture: Bool {
        if activeCaptureOwner == .host {
            return hasAnyActiveRecordingCapture
        }
        return recorder.isRecording || (hostRecordingUsesKeyboardAudioSession && keyboardAudioSession.isRecording)
    }

    private var hasKeyboardCaptureLifecycleOwner: Bool {
        if case .keyboard = activeCaptureOwner { return true }
        if case .keyboard = captureStartInFlightOwner { return true }
        return false
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

    var keyboardLivePreviewSourceOptions: [KeyboardLivePreviewSource] {
        KeyboardLivePreviewSource.allCases.filter(isKeyboardLivePreviewSourceEnabled)
    }

    func isCorrectionModeAvailable(_ mode: CorrectionMode) -> Bool {
        guard mode == .fast else { return true }
        return macSettings?.fastASRReadiness.ready == true
    }

    func isKeyboardLivePreviewSourceEnabled(_ source: KeyboardLivePreviewSource) -> Bool {
        switch source {
        case .appleSpeech:
            return true
        case .qwen:
            return macSettings?.isRecognitionSourceEnabled(.qwen) == true
        case .nvidiaNemotron:
            return macSettings?.isRecognitionSourceEnabled(.nvidiaNemotron) == true
        }
    }

    init() {
        let saved = PairingStore().load()
        self.config = saved
        self.correctionMode = saved.correctionMode
        self.inputMode = UserDefaults.standard.string(forKey: Self.inputModeKey)
            .flatMap(VoiceInputMode.init(rawValue:)) ?? .tap
        self.hostAudioSessionLength = UserDefaults.standard.string(forKey: Self.hostAudioSessionLengthKey)
            .flatMap(HostAudioSessionLength.init(rawValue:)) ?? .fifteenMinutes
        self.keyboardDictationCaptureMode = UserDefaults.standard.string(forKey: Self.keyboardDictationCaptureModeKey)
            .flatMap(KeyboardDictationCaptureMode.init(rawValue:)) ?? .backgroundMic
        self.keyboardAutoCapitalizationEnabled = UserDefaults.standard.object(forKey: Self.keyboardAutoCapitalizationKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardAutoCapitalizationKey) } ?? true
        self.keyboardCharacterPreviewEnabled = UserDefaults.standard.object(forKey: Self.keyboardCharacterPreviewKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardCharacterPreviewKey) } ?? false
        self.keyboardKeySoundEnabled = UserDefaults.standard.object(forKey: Self.keyboardKeySoundKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardKeySoundKey) } ?? true
        self.keyboardKeyHapticsEnabled = UserDefaults.standard.object(forKey: Self.keyboardKeyHapticsKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardKeyHapticsKey) } ?? true
        self.keyboardLivePreviewEnabled = UserDefaults.standard.object(forKey: Self.keyboardLivePreviewKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardLivePreviewKey) } ?? true
        self.keyboardLivePreviewSource = UserDefaults.standard.string(forKey: Self.keyboardLivePreviewSourceKey)
            .flatMap(KeyboardLivePreviewSource.init(rawValue:)) ?? .appleSpeech
        self.keyboardLivePreviewRecognitionMode = UserDefaults.standard.string(forKey: Self.keyboardLivePreviewRecognitionModeKey)
            .flatMap(KeyboardLivePreviewRecognitionMode.init(rawValue:)) ?? .onDeviceOnly
        self.keyboardChineseInputEnabled = UserDefaults.standard.object(forKey: Self.keyboardChineseInputEnabledKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardChineseInputEnabledKey) } ?? true
        self.keyboardChinesePunctuationStyle = UserDefaults.standard.string(forKey: Self.keyboardChinesePunctuationStyleKey)
            .flatMap(KeyboardChinesePunctuationStyle.init(rawValue:)) ?? .chinese
        self.keyboardRimeDictionaryTier = UserDefaults.standard.string(forKey: Self.keyboardRimeDictionaryTierKey)
            .flatMap(KeyboardRimeDictionaryTier.init(rawValue:)) ?? .standard
        self.keyboardRimeLearningEnabled = UserDefaults.standard.object(forKey: Self.keyboardRimeLearningKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardRimeLearningKey) } ?? true
        self.keyboardRimeCorrectionEnabled = UserDefaults.standard.object(forKey: Self.keyboardRimeCorrectionKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardRimeCorrectionKey) } ?? false
        self.keyboardTouchLearningEnabled = UserDefaults.standard.object(forKey: Self.keyboardTouchLearningKey)
            .map { _ in UserDefaults.standard.bool(forKey: Self.keyboardTouchLearningKey) } ?? true
        self.keyboardDefaultTextInputLanguage = UserDefaults.standard.string(forKey: Self.keyboardDefaultTextInputLanguageKey)
            .flatMap(KeyboardDefaultTextInputLanguage.init(rawValue:)) ?? .lastUsed
        self.keyboardRimeLearningResetGeneration = UserDefaults.standard.integer(forKey: Self.keyboardRimeLearningResetGenerationKey)
        self.keyboardTouchLearningResetGeneration = UserDefaults.standard.integer(forKey: Self.keyboardTouchLearningResetGenerationKey)
        self.keyboardEverContacted = UserDefaults.standard.bool(forKey: Self.keyboardEverContactedKey)
        self.keyboardFullAccessRequired = UserDefaults.standard.bool(forKey: Self.keyboardFullAccessRequiredKey)
        self.microphonePermissionStatus = Self.currentMicrophonePermissionStatus()
        self.speechRecognitionPermissionStatus = Self.currentSpeechRecognitionPermissionStatus()
        self.setupReadinessDismissed = UserDefaults.standard.bool(forKey: Self.setupReadinessDismissedKey)
        self.cachedServerRimeUserPhrases = Self.loadCachedServerRimeUserPhrases()
        self.selectedLanguageIDs = Set(saved.validatedLanguageIDs)
        self.keyboardStandbyEnabled = true
        KeyboardSharedDefaults.pruneExpiredControlPlanePayloads()
        configureKeyboardServer()
        configureKeyboardDarwinBridge()
        keyboardAudioSession.onCaptureInvalidated = { [weak self] reason in
            Task { @MainActor [weak self] in
                await self?.handleCaptureAudioInvalidation(reason: reason)
            }
        }
        pipDictationCoordinator.audioLevelProvider = { [weak self] in
            self?.hostRecordingLevel ?? 0
        }
        pipDictationCoordinator.onDidStop = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handlePiPDidStop()
            }
        }
        syncPiPDictationPresentation()
        consumeKeyboardHostIssue()
        installLifecycleObservers()
        startNetworkPathMonitor()
        publishKeyboardDefaults(force: true)
        scheduleHostRecorderPreWarm()
    }

    isolated deinit {
        hostAudioSessionExpiryTask?.cancel()
        keyboardStandbyRefreshTask?.cancel()
        autoStartPiPTask?.cancel()
        foregroundCapturePreparationTask?.cancel()
        captureModeTransitionTask?.cancel()
        recorderPreWarmTask?.cancel()
        keyboardStatusAudioLevelTask?.cancel()
        captureDurationWatchdogTask?.cancel()
        captureHealthWatchdogTask?.cancel()
        stopAndSendTask?.cancel()
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
        keyboardAudioSession.onCaptureInvalidated = nil
    }

    func bootstrap() async {
        await prepareHostForegroundCapture()
        await refreshRoute(force: true, showIndicator: false, reason: "bootstrap")
        _ = try? await refreshMacSettingsIfChanged()
        scheduleHostRecorderPreWarm()
    }

    func prepareHostForegroundCapture(honorRecentPiPStop: Bool = true) async {
        guard isConfigured, keyboardStandbyEnabled else {
            refreshSetupReadinessStatuses()
            return
        }
        if let foregroundCapturePreparationTask {
            await foregroundCapturePreparationTask.value
            return
        }
        let generation = beginCapturePreparation()
        let taskID = UUID()
        foregroundCapturePreparationTaskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForInitialRenderOpportunity()
            guard !Task.isCancelled,
                  self.capturePreparationIsCurrent(generation),
                  self.isConfigured,
                  self.keyboardStandbyEnabled
            else { return }
            self.refreshSetupReadinessStatuses()
            let honorManualSuppression = self.keyboardDictationCaptureMode == .pictureInPicture
                && honorRecentPiPStop
                && self.shouldHonorRecentPiPStopForForegroundActivation
            _ = await self.prepareSelectedHostCaptureMode(
                showErrors: false,
                honorManualSuppression: honorManualSuppression,
                preparationGeneration: generation
            )
        }
        foregroundCapturePreparationTask = task
        await task.value
        if foregroundCapturePreparationTaskID == taskID {
            foregroundCapturePreparationTask = nil
            foregroundCapturePreparationTaskID = nil
        }
    }

    @discardableResult
    private func beginCapturePreparation() -> UInt64 {
        capturePreparationGeneration &+= 1
        foregroundCapturePreparationTask?.cancel()
        foregroundCapturePreparationTask = nil
        foregroundCapturePreparationTaskID = nil
        captureModeTransitionTask?.cancel()
        captureModeTransitionTask = nil
        captureModeTransitionTaskID = nil
        return capturePreparationGeneration
    }

    private func capturePreparationIsCurrent(
        _ generation: UInt64,
        mode: KeyboardDictationCaptureMode? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              generation == capturePreparationGeneration,
              capturePreparationIsAuthorized,
              keyboardStandbyEnabled
        else { return false }
        return mode == nil || mode == keyboardDictationCaptureMode
    }

    private func discardResourcesFromStaleCapturePreparation(
        _ generation: UInt64,
        expectedMode: KeyboardDictationCaptureMode? = nil
    ) {
        guard generation != capturePreparationGeneration else { return }
        if !capturePreparationIsAuthorized || !keyboardStandbyEnabled {
            cancelAutomaticPiPStart()
            pipDictationCoordinator.stop()
            standbyKeeper.stop()
            keyboardAudioSession.stop(discardInputEngine: true)
            return
        }
        guard let expectedMode, expectedMode != keyboardDictationCaptureMode else { return }
        guard captureStartInFlightGeneration == nil,
              activeCaptureGeneration == nil,
              !hasAnyActiveRecordingCapture
        else { return }
        // A stale mode transition may finish after its replacement. Tear down
        // only the old mode's resources so it cannot undo the selected mode.
        switch expectedMode {
        case .backgroundMic:
            standbyKeeper.stop()
            keyboardAudioSession.stop(discardInputEngine: true)
        case .pictureInPicture:
            cancelAutomaticPiPStart()
            pipDictationCoordinator.stop()
        }
    }

    func refreshSetupReadinessStatuses() {
        microphonePermissionStatus = Self.currentMicrophonePermissionStatus()
        speechRecognitionPermissionStatus = Self.currentSpeechRecognitionPermissionStatus()
    }

    @discardableResult
    func requestMicrophonePermissionForSetup() async -> Bool {
        refreshSetupReadinessStatuses()
        switch microphonePermissionStatus {
        case .granted:
            return true
        case .notDetermined:
            let result = await requestMicrophonePermission()
            refreshSetupReadinessStatuses()
            guard result == .granted else {
                showTransient(NSLocalizedString("Microphone permission is required.", comment: "Setup microphone permission denied toast"))
                return false
            }
            await prepareSelectedHostCaptureMode(
                showErrors: false,
                honorManualSuppression: false
            )
            showTransient(NSLocalizedString("Microphone ready.", comment: "Setup microphone permission granted toast"))
            return true
        case .denied:
            showTransient(NSLocalizedString("Enable Microphone in iOS Settings.", comment: "Setup microphone settings toast"))
            await openAppSettingsForMicrophone()
            refreshSetupReadinessStatuses()
            return false
        case .restricted, .unavailable, .unknown:
            showTransient(NSLocalizedString("Microphone permission is unavailable.", comment: "Setup microphone unavailable toast"))
            return false
        }
    }

    @discardableResult
    func requestSpeechRecognitionPermissionForSetup() async -> HostReadinessAuthorizationStatus {
        refreshSetupReadinessStatuses()
        guard speechRecognitionPermissionStatus == .notDetermined else {
            return speechRecognitionPermissionStatus
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        speechRecognitionPermissionStatus = Self.readinessStatus(for: status)
        return speechRecognitionPermissionStatus
    }

    func dismissSetupReadiness() {
        guard !setupReadinessDismissed else { return }
        setupReadinessDismissed = true
        UserDefaults.standard.set(true, forKey: Self.setupReadinessDismissedKey)
    }

    private static func currentMicrophonePermissionStatus() -> HostReadinessAuthorizationStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .undetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    private static func currentSpeechRecognitionPermissionStatus() -> HostReadinessAuthorizationStatus {
        readinessStatus(for: SFSpeechRecognizer.authorizationStatus())
    }

    private static func readinessStatus(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> HostReadinessAuthorizationStatus {
        switch status {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    @discardableResult
    func saveConfig(_ newConfig: PairingConfig) -> Bool {
        var normalized = newConfig
        normalized.normalize()
        guard persistPairingConfig(normalized) else { return false }
        pairingRevision &+= 1
        _ = nextRouteRefreshGeneration()
        config = normalized
        if !normalized.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalized.hasAnyBridgeURL {
            keyboardStandbyEnabled = true
        }
        correctionMode = normalized.correctionMode
        selectedLanguageIDs = Set(normalized.validatedLanguageIDs)
        publishKeyboardDefaults()
        routeFetchedAt = nil
        Task {
            await prepareHostForegroundCapture(honorRecentPiPStop: false)
        }
        Task {
            await refreshRoute(force: true, syncPairingEndpoints: true, reason: "save_config")
            _ = try? await refreshMacSettings()
        }
        return true
    }

    @discardableResult
    func saveBridgeEndpoints(_ bridgeEndpoints: BridgeEndpoints) -> Bool {
        var normalized = config
        normalized.bridgeEndpoints = bridgeEndpoints
        normalized.normalizeBridgeEndpoints()
        guard normalized.bridgeEndpoints != config.bridgeEndpoints else { return true }
        guard persistPairingConfig(normalized) else { return false }
        pairingRevision &+= 1
        _ = nextRouteRefreshGeneration()
        config = normalized
        publishKeyboardDefaults()
        routeFetchedAt = nil
        Task {
            await refreshRoute(force: true, syncPairingEndpoints: true, reason: "save_bridge_endpoints")
        }
        return true
    }

    @discardableResult
    private func persistPairingConfig(_ candidate: PairingConfig) -> Bool {
        do {
            try store.save(candidate)
            return true
        } catch {
            appLog.error("pairing save failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = NSLocalizedString(
                "Couldn't save pairing securely. Your previous pairing is unchanged.",
                comment: "Pairing persistence failure"
            )
            showTransient(errorMessage ?? error.localizedDescription)
            return false
        }
    }

    func unpair() async {
        // Credentials are the final thing removed. First make every pending
        // capture continuation stale and tear down all resources that could
        // otherwise keep recording or publish a late result into the unpaired
        // scene.
        pairingRevision &+= 1
        _ = nextRouteRefreshGeneration()
        _ = beginCapturePreparation()
        keyboardStandbyEnabled = false
        invalidateCaptureLifecycle()
        await cancelActiveRecordingWithoutSending(
            hostFailureMessage: nil,
            keyboardCommandID: activeKeyboardRecordingCommandID ?? keyboardBridgeStatus.commandID,
            keyboardMessage: "Ready",
            resumeKeyboardStandby: false
        )
        clearKeyboardHostSessionTimers()
        cancelAutomaticPiPStart()
        recorderPreWarmTask?.cancel()
        recorderPreWarmTask = nil
        recorder.discardPreWarm()
        keyboardServer.stop()
        KeyboardSharedKeychain.clearPendingFinalResult()
        KeyboardSharedKeychain.clearPendingDestination()
        KeyboardSharedDefaults.clearHostHandoff()
        KeyboardSharedDefaults.clearAllDarwinCommands()
        KeyboardSharedDefaults.clearCommandReceipt()
        pipDictationCoordinator.stop()
        standbyKeeper.stop()
        keyboardAudioSession.stop(discardInputEngine: true)
        teardownLivePartialPreview(clearText: true)
        clearKeyboardCaptureContext()
        queuedKeyboardStopCommandID = nil
        activeBridgeDictateJobID = nil
        activeBridgeRefineJobID = nil
        idleTimerHolders = 0
        UIApplication.shared.isIdleTimerDisabled = false
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)

        let empty = PairingConfig.empty
        config = empty
        correctionMode = empty.correctionMode
        selectedLanguageIDs = Set(empty.validatedLanguageIDs)
        store.delete()
        routeStatus = BridgeRouteResolutionStatus()
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
        var candidate = config
        candidate.languageIDs = ordered
        guard persistPairingConfig(candidate) else {
            selectedLanguageIDs = Set(config.validatedLanguageIDs)
            return
        }
        selectedLanguageIDs = Set(ordered)
        config = candidate
    }

    func setInputMode(_ mode: VoiceInputMode) {
        updateStoredRawPreference(\.inputMode, to: mode, key: Self.inputModeKey)
    }

    func setHostAudioSessionLength(_ length: HostAudioSessionLength) {
        guard updateStoredRawPreference(
            \.hostAudioSessionLength,
            to: length,
            key: Self.hostAudioSessionLengthKey
        ) else { return }
        scheduleHostAudioSessionExpiry()
    }

    func setKeyboardDictationCaptureMode(_ mode: KeyboardDictationCaptureMode) {
        guard !hasAnyActiveRecordingCapture,
              captureStartInFlightGeneration == nil,
              !isStopAndSendInFlight,
              !phase.isBusy
        else { return }
        guard updateStoredRawPreference(
            \.keyboardDictationCaptureMode,
            to: mode,
            key: Self.keyboardDictationCaptureModeKey
        ) else { return }
        cancelKeyboardStandbyRefresh()
        let generation = beginCapturePreparation()
        syncPiPDictationPresentation()
        let taskID = UUID()
        captureModeTransitionTaskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.prepareSelectedHostCaptureMode(
                showErrors: false,
                honorManualSuppression: false,
                preparationGeneration: generation
            )
            guard self.captureModeTransitionTaskID == taskID else { return }
            self.captureModeTransitionTask = nil
            self.captureModeTransitionTaskID = nil
        }
        captureModeTransitionTask = task
    }

    func attachPiPSourceView(_ view: UIView) {
        pipDictationCoordinator.attachSourceView(view)
        syncPiPDictationPresentation()
        if keyboardDictationCaptureMode == .pictureInPicture,
           !pipDictationCoordinator.isActive,
           !suppressAutomaticPiPStart,
           automaticPiPStartAttemptsRemaining > 0 {
            scheduleAutomaticPiPVisibilityStart(showErrors: automaticPiPStartShowsErrors)
        }
    }

    func setKeyboardAutoCapitalizationEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardAutoCapitalizationEnabled,
            to: enabled,
            key: Self.keyboardAutoCapitalizationKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardCharacterPreviewEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardCharacterPreviewEnabled,
            to: enabled,
            key: Self.keyboardCharacterPreviewKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardKeySoundEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardKeySoundEnabled,
            to: enabled,
            key: Self.keyboardKeySoundKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardKeyHapticsEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardKeyHapticsEnabled,
            to: enabled,
            key: Self.keyboardKeyHapticsKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardLivePreviewEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardLivePreviewEnabled,
            to: enabled,
            key: Self.keyboardLivePreviewKey
        ) else { return }
        if enabled {
            constrainKeyboardLivePreviewSourceToMacSettings()
        } else {
            teardownLivePartialPreview(clearText: true)
        }
    }

    func setKeyboardLivePreviewSource(_ source: KeyboardLivePreviewSource) {
        guard isKeyboardLivePreviewSourceEnabled(source) else { return }
        updateStoredRawPreference(
            \.keyboardLivePreviewSource,
            to: source,
            key: Self.keyboardLivePreviewSourceKey
        )
    }

    private func constrainKeyboardLivePreviewSourceToMacSettings() {
        guard keyboardLivePreviewEnabled,
              !isKeyboardLivePreviewSourceEnabled(keyboardLivePreviewSource)
        else { return }
        if let preferred = keyboardLivePreviewSourceOptions.first {
            updateStoredRawPreference(
                \.keyboardLivePreviewSource,
                to: preferred,
                key: Self.keyboardLivePreviewSourceKey
            )
        } else {
            _ = updateStoredBoolPreference(
                \.keyboardLivePreviewEnabled,
                to: false,
                key: Self.keyboardLivePreviewKey
            )
            updateStoredRawPreference(
                \.keyboardLivePreviewSource,
                to: KeyboardLivePreviewSource.appleSpeech,
                key: Self.keyboardLivePreviewSourceKey
            )
            teardownLivePartialPreview(clearText: true)
        }
    }

    func setKeyboardLivePreviewRecognitionMode(_ mode: KeyboardLivePreviewRecognitionMode) {
        updateStoredRawPreference(
            \.keyboardLivePreviewRecognitionMode,
            to: mode,
            key: Self.keyboardLivePreviewRecognitionModeKey
        )
    }

    func setKeyboardChineseInputEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardChineseInputEnabled,
            to: enabled,
            key: Self.keyboardChineseInputEnabledKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardChinesePunctuationStyle(_ style: KeyboardChinesePunctuationStyle) {
        guard updateStoredRawPreference(
            \.keyboardChinesePunctuationStyle,
            to: style,
            key: Self.keyboardChinesePunctuationStyleKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardRimeDictionaryTier(_ tier: KeyboardRimeDictionaryTier) {
        guard updateStoredRawPreference(
            \.keyboardRimeDictionaryTier,
            to: tier,
            key: Self.keyboardRimeDictionaryTierKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardRimeCorrectionEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardRimeCorrectionEnabled,
            to: enabled,
            key: Self.keyboardRimeCorrectionKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardRimeLearningEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardRimeLearningEnabled,
            to: enabled,
            key: Self.keyboardRimeLearningKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardTouchLearningEnabled(_ enabled: Bool) {
        guard updateStoredBoolPreference(
            \.keyboardTouchLearningEnabled,
            to: enabled,
            key: Self.keyboardTouchLearningKey
        ) else { return }
        publishKeyboardDefaults()
    }

    func setKeyboardDefaultTextInputLanguage(_ language: KeyboardDefaultTextInputLanguage) {
        guard updateStoredRawPreference(
            \.keyboardDefaultTextInputLanguage,
            to: language,
            key: Self.keyboardDefaultTextInputLanguageKey
        ) else { return }
        publishKeyboardDefaults()
    }

    @discardableResult
    private func updateStoredRawPreference<Value>(
        _ keyPath: ReferenceWritableKeyPath<AppState, Value>,
        to value: Value,
        key: String
    ) -> Bool where Value: Equatable & RawRepresentable, Value.RawValue == String {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        UserDefaults.standard.set(value.rawValue, forKey: key)
        return true
    }

    @discardableResult
    private func updateStoredBoolPreference(
        _ keyPath: ReferenceWritableKeyPath<AppState, Bool>,
        to value: Bool,
        key: String
    ) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        UserDefaults.standard.set(value, forKey: key)
        return true
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
        showIndicator: Bool = true,
        syncPairingEndpoints: Bool? = nil,
        reason: String = "unspecified"
    ) async {
        let cacheTTL = routeStatus.activeKind == .local ? Self.localRouteCacheTTL : Self.routeCacheTTL
        if !force, let routeFetchedAt,
           Date().timeIntervalSince(routeFetchedAt) < cacheTTL,
           routeStatus.activeURL != nil,
           routeStatusSatisfiesProbeMode(probeAllEndpoints) {
            return
        }
        let configSnapshot = config
        let pairingRevisionSnapshot = pairingRevision
        let generation = nextRouteRefreshGeneration()
        let startedAt = Date()
        let shouldSyncPairingEndpoints = syncPairingEndpoints ?? showIndicator
        beginRouteRefresh(showIndicator: showIndicator)
        recordRouteRefreshBegin(
            generation: generation,
            pairingRevision: pairingRevisionSnapshot,
            reason: reason,
            force: force,
            probeAllEndpoints: probeAllEndpoints,
            config: configSnapshot
        )
        defer {
            endRouteRefresh(showIndicator: showIndicator)
        }

        let resolved = await routeResolver.resolve(config: configSnapshot, probeAllEndpoints: probeAllEndpoints)
        guard commitRouteRefreshResult(
            resolved,
            generation: generation,
            pairingRevision: pairingRevisionSnapshot,
            reason: reason,
            config: configSnapshot,
            startedAt: startedAt
        ) else {
            return
        }

        guard shouldSyncPairingEndpoints,
              shouldRefreshPairingEndpointsAfterRouteRefresh(force: force, status: routeStatus),
              routeRefreshGeneration == generation,
              pairingRevision == pairingRevisionSnapshot,
              await refreshPairingEndpointsFromActiveRoute(
                  status: routeStatus,
                  expectedPairingRevision: pairingRevisionSnapshot
              )
        else { return }

        guard routeRefreshGeneration == generation,
              pairingRevision == pairingRevisionSnapshot
        else {
            recordRouteRefreshDiscarded(
                generation: generation,
                reason: "\(reason):endpoint_sync",
                candidate: routeStatus,
                discardReason: "stale_generation_after_endpoint_sync"
            )
            return
        }
        let refreshedConfig = config
        let rerouted = await routeResolver.resolve(config: refreshedConfig, probeAllEndpoints: probeAllEndpoints)
        _ = commitRouteRefreshResult(
            rerouted,
            generation: generation,
            pairingRevision: pairingRevisionSnapshot,
            reason: "\(reason):endpoint_sync",
            config: refreshedConfig,
            startedAt: startedAt
        )
    }

    private func preflightActiveBridgeRoute() async {
        guard let baseURL = routeStatus.activeURL else {
            await refreshRoute(
                force: true,
                probeAllEndpoints: false,
                showIndicator: false,
                reason: "preflight_missing_route"
            )
            return
        }

        let timeout = routeStatus.activeKind == .cloud ? 3.0 : 1.5
        let isHealthy = await BridgeClient(baseURL: baseURL, token: config.token).health(timeout: timeout)
        guard isHealthy else {
            routeFetchedAt = nil
            await refreshRoute(
                force: true,
                probeAllEndpoints: false,
                showIndicator: false,
                reason: "preflight_failed"
            )
            return
        }
        routeFetchedAt = Date()
    }

    private func nextRouteRefreshGeneration() -> UInt64 {
        routeRefreshGeneration += 1
        return routeRefreshGeneration
    }

    private func beginRouteRefresh(showIndicator: Bool) {
        routeStatusProbeInFlightCount += 1
        isCheckingRouteStatus = true
        if showIndicator {
            beginRouteRefreshIndicator()
        }
    }

    private func endRouteRefresh(showIndicator: Bool) {
        routeStatusProbeInFlightCount = max(0, routeStatusProbeInFlightCount - 1)
        isCheckingRouteStatus = routeStatusProbeInFlightCount > 0
        if showIndicator {
            endRouteRefreshIndicator()
        }
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

    @discardableResult
    private func commitRouteRefreshResult(
        _ status: BridgeRouteResolutionStatus,
        generation: UInt64,
        pairingRevision: UInt64,
        reason: String,
        config: PairingConfig,
        startedAt: Date
    ) -> Bool {
        guard generation == routeRefreshGeneration else {
            recordRouteRefreshDiscarded(
                generation: generation,
                reason: reason,
                candidate: status,
                discardReason: "stale_generation"
            )
            return false
        }
        guard pairingRevision == self.pairingRevision else {
            recordRouteRefreshDiscarded(
                generation: generation,
                reason: reason,
                candidate: status,
                discardReason: "stale_pairing_revision"
            )
            return false
        }
        guard routeStatusCanCommitOffline(status, config: config) else {
            recordRouteRefreshDiscarded(
                generation: generation,
                reason: reason,
                candidate: status,
                discardReason: "incomplete_offline"
            )
            return false
        }

        routeStatus = status
        persistActiveLocalRouteIfNeeded(status)
        routeFetchedAt = Date()
        recordRouteRefreshCommit(
            generation: generation,
            reason: reason,
            status: status,
            config: config,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
        )
        return true
    }

    private func routeStatusCanCommitOffline(
        _ status: BridgeRouteResolutionStatus,
        config: PairingConfig
    ) -> Bool {
        guard status.activeKind == .unavailable else { return true }
        let localConfigured = !config.localBridgeURLCandidates.isEmpty
        let cloudConfigured = !config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (!localConfigured || status.localChecked) &&
            (!cloudConfigured || status.cloudChecked)
    }

    private func recordRouteRefreshBegin(
        generation: UInt64,
        pairingRevision: UInt64,
        reason: String,
        force: Bool,
        probeAllEndpoints: Bool,
        config: PairingConfig
    ) {
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "route_refresh_begin",
            fields: [
                "generation": "\(generation)",
                "pairing_revision": "\(pairingRevision)",
                "reason": reason,
                "force": "\(force)",
                "probe_all": "\(probeAllEndpoints)",
                "local_configured_count": "\(config.localBridgeURLCandidates.count)",
                "cloud_configured": "\(!config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "current_kind": routeStatus.activeKind.rawValue,
            ]
        )
    }

    private func recordRouteRefreshCommit(
        generation: UInt64,
        reason: String,
        status: BridgeRouteResolutionStatus,
        config: PairingConfig,
        elapsedMs: Int
    ) {
        var fields = routeRefreshDiagnosticFields(
            generation: generation,
            reason: reason,
            status: status,
            config: config
        )
        fields["elapsed_ms"] = "\(elapsedMs)"
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "route_refresh_commit",
            fields: fields
        )
    }

    private func recordRouteRefreshDiscarded(
        generation: UInt64,
        reason: String,
        candidate: BridgeRouteResolutionStatus,
        discardReason: String
    ) {
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "route_refresh_discarded",
            fields: [
                "generation": "\(generation)",
                "current_generation": "\(routeRefreshGeneration)",
                "reason": reason,
                "discard_reason": discardReason,
                "candidate_kind": candidate.activeKind.rawValue,
                "local_checked": "\(candidate.localChecked)",
                "local_ok": "\(candidate.localOK)",
                "cloud_checked": "\(candidate.cloudChecked)",
                "cloud_ok": "\(candidate.cloudOK)",
            ]
        )
    }

    private func routeRefreshDiagnosticFields(
        generation: UInt64,
        reason: String,
        status: BridgeRouteResolutionStatus,
        config: PairingConfig
    ) -> [String: String] {
        [
            "generation": "\(generation)",
            "reason": reason,
            "active_kind": status.activeKind.rawValue,
            "has_active_url": "\(status.activeURL != nil)",
            "local_configured_count": "\(config.localBridgeURLCandidates.count)",
            "cloud_configured": "\(!config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            "local_checked": "\(status.localChecked)",
            "local_ok": "\(status.localOK)",
            "local_latency_ms": status.localLatencyMs.map(String.init) ?? "nil",
            "cloud_checked": "\(status.cloudChecked)",
            "cloud_ok": "\(status.cloudOK)",
            "cloud_latency_ms": status.cloudLatencyMs.map(String.init) ?? "nil",
        ]
    }

    private func shouldRefreshPairingEndpointsAfterRouteRefresh(
        force: Bool,
        status: BridgeRouteResolutionStatus
    ) -> Bool {
        guard status.activeURL != nil else { return false }
        return force || status.activeKind == .cloud || (status.localChecked && !status.localOK)
    }

    @discardableResult
    private func refreshPairingEndpointsFromActiveRoute(
        status: BridgeRouteResolutionStatus,
        expectedPairingRevision: UInt64,
        timeout: TimeInterval = 4
    ) async -> Bool {
        guard expectedPairingRevision == pairingRevision,
              let activeURL = status.activeURL
        else { return false }
        let configSnapshot = config
        let previous = configSnapshot.bridgeEndpoints
        do {
            let refreshed = try await BridgeClient(
                baseURL: activeURL,
                token: configSnapshot.token
            ).pairing(timeout: timeout)
            guard expectedPairingRevision == pairingRevision else { return false }
            var candidate = configSnapshot
            candidate.bridgeEndpoints = refreshed.bridgeEndpoints
            recordRouteEndpointSyncResult(
                changed: candidate.bridgeEndpoints != previous,
                previous: previous,
                refreshed: candidate.bridgeEndpoints,
                activeKind: status.activeKind.rawValue,
                error: nil
            )
            if candidate.bridgeEndpoints != previous {
                guard expectedPairingRevision == pairingRevision else { return false }
                guard persistPairingConfig(candidate) else { return false }
                config = candidate
                publishKeyboardDefaults()
                routeFetchedAt = nil
                return true
            }
        } catch {
            appLog.notice("pairing endpoint refresh deferred: \(error.localizedDescription, privacy: .public)")
            recordRouteEndpointSyncResult(
                changed: false,
                previous: previous,
                refreshed: config.bridgeEndpoints,
                activeKind: status.activeKind.rawValue,
                error: error.localizedDescription
            )
        }
        return false
    }

    private func recordRouteEndpointSyncResult(
        changed: Bool,
        previous: BridgeEndpoints,
        refreshed: BridgeEndpoints,
        activeKind: String,
        error: String?
    ) {
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "route_endpoint_sync_result",
            fields: [
                "changed": "\(changed)",
                "active_kind": activeKind,
                "previous_local_count": "\(previous.localBridgeURLCandidates.count)",
                "previous_cloud_configured": "\(!previous.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "refreshed_local_count": "\(refreshed.localBridgeURLCandidates.count)",
                "refreshed_cloud_configured": "\(!refreshed.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "previous_token_present": "\(!previous.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "refreshed_token_present": "\(!refreshed.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "error": error ?? "none",
            ]
        )
    }

    func refreshMacSettings(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload {
        let expectedPairingRevision = pairingRevision
        let client = try await activeBridgeClient()
        var settings = try await client.macSettings(timeout: timeout)
        settings.normalize()
        guard expectedPairingRevision == pairingRevision else {
            throw CancellationError()
        }
        guard applyMacSettings(settings, expectedPairingRevision: expectedPairingRevision) else {
            throw PairingStoreError.secureTokenWriteFailed
        }
        return settings
    }

    @discardableResult
    private func refreshMacSettingsIfChanged(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload? {
        let expectedPairingRevision = pairingRevision
        let client = try await activeBridgeClient()
        let localRevision = macSettingsRevision ?? macSettings?.settingsRevision
        if let localRevision,
           !localRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let health = try await client.healthResponse(timeout: min(timeout, 3))
            if let remoteRevision = health.settingsRevision?.trimmingCharacters(in: .whitespacesAndNewlines),
               !remoteRevision.isEmpty,
               remoteRevision == localRevision {
                guard expectedPairingRevision == pairingRevision else {
                    throw CancellationError()
                }
                macSettingsFetchedAt = Date()
                return macSettings
            }
        }
        var settings = try await client.macSettings(timeout: timeout)
        settings.normalize()
        guard expectedPairingRevision == pairingRevision else {
            throw CancellationError()
        }
        guard applyMacSettings(settings, expectedPairingRevision: expectedPairingRevision) else {
            throw PairingStoreError.secureTokenWriteFailed
        }
        return settings
    }

    func updateMacSettings(_ settings: BridgeMacSettingsPayload) async throws -> BridgeMacSettingsPayload {
        let expectedPairingRevision = pairingRevision
        var normalized = settings
        normalized.normalize()
        let client = try await activeBridgeClient()
        var updated = try await client.updateMacSettings(normalized)
        updated.normalize()
        guard expectedPairingRevision == pairingRevision else {
            throw CancellationError()
        }
        guard applyMacSettings(updated, expectedPairingRevision: expectedPairingRevision) else {
            throw PairingStoreError.secureTokenWriteFailed
        }
        return updated
    }

    @discardableResult
    private func applyMacSettings(
        _ settings: BridgeMacSettingsPayload,
        expectedPairingRevision: UInt64
    ) -> Bool {
        guard expectedPairingRevision == pairingRevision else { return false }
        var candidate = config
        candidate.supportedLanguages = settings.supportedLanguages
        candidate.languageIDs = ASRLanguageSelection.validatedIDs(
            candidate.languageIDs,
            supportedOptions: candidate.supportedLanguageOptions
        )
        guard persistPairingConfig(candidate) else { return false }
        config = candidate
        macSettings = settings
        macSettingsFetchedAt = Date()
        macSettingsRevision = settings.settingsRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedServerRimeUserPhrases = settings.rimeUserPhrases
        UserDefaults.standard.set(settings.rimeUserPhrases, forKey: Self.serverRimeUserPhrasesKey)
        constrainKeyboardLivePreviewSourceToMacSettings()
        selectedLanguageIDs = Set(config.validatedLanguageIDs)
        publishKeyboardDefaults()
        return true
    }

    private func scheduleHostRecorderPreWarm() {
        // Keyboard standby owns the launch-time microphone session. The separate
        // host-recorder prewarm path stays disabled so the orb does not compete
        // with keyboard standby or create a second idle capture path.
    }

    private func resetCorrectionModeToDefault() {
        guard correctionMode != config.correctionMode else { return }
        correctionMode = config.correctionMode
        constrainKeyboardLivePreviewSourceToMacSettings()
    }

    private func applyKeyboardDefaultCorrectionMode(
        _ mode: CorrectionMode,
        updateActiveCorrectionMode: Bool = true
    ) {
        let configChanged = config.correctionMode != mode
        let visibleChanged = updateActiveCorrectionMode && correctionMode != mode
        guard configChanged || visibleChanged else { return }
        if configChanged {
            var candidate = config
            candidate.correctionMode = mode
            guard persistPairingConfig(candidate) else { return }
            config = candidate
        }
        if updateActiveCorrectionMode {
            correctionMode = mode
            constrainKeyboardLivePreviewSourceToMacSettings()
        }
        if configChanged {
            publishKeyboardDefaults()
        }
    }

    func setDefaultCorrectionMode(_ mode: CorrectionMode) {
        guard isCorrectionModeAvailable(mode) else {
            showTransient(NSLocalizedString("Fast ASR source is not ready.", comment: "Fast mode unavailable toast"))
            return
        }
        applyKeyboardDefaultCorrectionMode(mode)
    }

    private func publishKeyboardDefaults(force: Bool = false) {
        keyboardCoordinator.publishDefaults(
            correctionMode: config.correctionMode,
            autoCapitalizationEnabled: keyboardAutoCapitalizationEnabled,
            characterPreviewEnabled: keyboardCharacterPreviewEnabled,
            keySoundEnabled: keyboardKeySoundEnabled,
            keyHapticsEnabled: keyboardKeyHapticsEnabled,
            chineseInputEnabled: keyboardChineseInputEnabled,
            chinesePunctuationStyle: keyboardChinesePunctuationStyle,
            rimeDictionaryTier: keyboardRimeDictionaryTier,
            rimeLearningEnabled: keyboardRimeLearningEnabled,
            rimeCorrectionEnabled: keyboardRimeCorrectionEnabled,
            touchLearningEnabled: keyboardTouchLearningEnabled,
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
        if let phrases = KeyboardSharedDefaults.loadPayload()?.rimeUserPhrases {
            return phrases
        }
        return []
    }

    private func persistActiveLocalRouteIfNeeded(_ status: BridgeRouteResolutionStatus) {
        guard status.activeKind == .local,
              let activeURL = status.activeURL?.absoluteString
        else { return }

        let previous = config.localBridgeURLCandidates
        var candidate = config
        candidate.promoteLocalBridgeURL(activeURL)
        if candidate.localBridgeURLCandidates != previous,
           persistPairingConfig(candidate) {
            config = candidate
        }
    }

    private func activeBridgeClient() async throws -> BridgeClient {
        await waitForRouteRefreshToSettleIfNeeded(reason: "active_bridge_client")
        if shouldPreflightBridgeRouteBeforeRequest(routeIsFresh: currentBridgeRouteIsFresh()) {
            await preflightActiveBridgeRoute()
        }
        guard let baseURL = routeStatus.activeURL else {
            throw BridgeClientError.unauthorizedOrUnavailable
        }
        return BridgeClient(baseURL: baseURL, token: config.token)
    }

    private func waitForRouteRefreshToSettleIfNeeded(
        reason: String,
        timeout: TimeInterval = 1.2
    ) async {
        guard isCheckingRouteStatus else { return }
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeout)
        while isCheckingRouteStatus, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "route_refresh_wait",
            fields: [
                "reason": reason,
                "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                "settled": "\(!isCheckingRouteStatus)",
                "current_kind": routeStatus.activeKind.rawValue,
            ]
        )
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

    private static func newBridgeJobID() -> String {
        "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    private func dictateWithRouteRetry(
        initialBaseURL: URL,
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool,
        keyboardCommandID: String?,
        stageLabels: BridgeStageLabels,
        shouldAdvanceToRefineWhenTranscriptionCompletes: Bool,
        recordingInfo: RecordingFileInfo
    ) async throws -> BridgeDictateResponse {
        let jobID = activeBridgeDictateJobID ?? Self.newBridgeJobID()
        activeBridgeDictateJobID = jobID
        func dictate(to baseURL: URL) async throws -> BridgeDictateResponse {
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            return try await client.dictate(
                audioURL: audioURL,
                audioExtension: audioExtension,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                includeRawTranscript: includeRawTranscript,
                clientJobID: jobID,
                onJobEvent: { event in
                    await MainActor.run {
                        guard event.jobID == jobID,
                              self.activeBridgeDictateJobID == jobID
                        else { return }
                        self.applyBridgeJobStatus(
                            event,
                            keyboardCommandID: keyboardCommandID,
                            stageLabels: stageLabels,
                            shouldAdvanceToRefineWhenTranscriptionCompletes: shouldAdvanceToRefineWhenTranscriptionCompletes,
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
            try await Task.sleep(nanoseconds: 250_000_000)
            routeFetchedAt = nil
            if let keyboardCommandID {
                publishKeyboardStatus(
                    .sending,
                    commandID: keyboardCommandID,
                    message: stageLabels.transcribing,
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount
                )
            }
            await refreshRoute(
                force: true,
                probeAllEndpoints: false,
                showIndicator: false,
                reason: "dictate_retry"
            )
            guard let retryBaseURL = routeStatus.activeURL else { throw error }
            return try await dictate(to: retryBaseURL)
        }
    }

    // MARK: - Recording (host UI)

    private func beginCaptureStart(owner: CaptureOwner) -> UInt64? {
        guard captureStartInFlightGeneration == nil,
              activeCaptureGeneration == nil,
              !hasAnyActiveRecordingCapture
        else { return nil }
        _ = beginCapturePreparation()
        cancelKeyboardStandbyRefresh()
        captureGeneration &+= 1
        captureStartInFlightGeneration = captureGeneration
        captureStartInFlightOwner = owner
        return captureGeneration
    }

    private func finishCaptureStart(_ generation: UInt64) {
        guard captureStartInFlightGeneration == generation else { return }
        captureStartInFlightGeneration = nil
        captureStartInFlightOwner = nil
    }

    private func isCaptureGenerationCurrent(_ generation: UInt64) -> Bool {
        captureGeneration == generation
    }

    private func markCaptureActive(_ generation: UInt64, owner: CaptureOwner) -> Bool {
        guard isCaptureGenerationCurrent(generation) else { return false }
        activeCaptureGeneration = generation
        activeCaptureOwner = owner
        scheduleCaptureDurationWatchdog(generation: generation, owner: owner)
        scheduleCaptureHealthWatchdog(generation: generation, owner: owner)
        return true
    }

    private func invalidateCaptureLifecycle() {
        captureGeneration &+= 1
        captureStartInFlightGeneration = nil
        captureStartInFlightOwner = nil
        activeCaptureGeneration = nil
        activeCaptureOwner = nil
        captureDurationWatchdogTask?.cancel()
        captureDurationWatchdogTask = nil
        captureHealthWatchdogTask?.cancel()
        captureHealthWatchdogTask = nil
        endPostCaptureBackgroundTask()
        stopAndSendTask?.cancel()
        stopAndSendTask = nil
        stopAndSendTaskID = nil
    }

    private func discardResourcesFromInvalidatedCaptureStart(_ generation: UInt64) {
        guard !isCaptureGenerationCurrent(generation),
              captureStartInFlightGeneration == nil || captureStartInFlightGeneration == generation,
              activeCaptureGeneration == nil
        else { return }
        if let fileURL = recorder.stop(deactivateSession: true) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if keyboardAudioSession.isRecording {
            keyboardAudioSession.cancelRecording()
            if keyboardDictationCaptureMode == .pictureInPicture {
                keyboardAudioSession.stop(discardInputEngine: true)
            }
        } else if keyboardDictationCaptureMode == .pictureInPicture,
                  keyboardAudioSession.isActive {
            keyboardAudioSession.stop(discardInputEngine: true)
        }
        teardownLivePartialPreview(clearText: true)
        hostRecordingUsesKeyboardAudioSession = false
        keyboardCaptureStartedFromKeyboard = false
        activeBridgeDictateJobID = nil
    }

    private func claimCaptureOperationIfNeeded() -> UInt64? {
        if let activeCaptureGeneration {
            return activeCaptureGeneration
        }
        guard hasAnyActiveRecordingCapture else { return nil }
        captureGeneration &+= 1
        activeCaptureGeneration = captureGeneration
        let owner: CaptureOwner = hostRecordingUsesKeyboardAudioSession || recorder.isRecording
            ? .host
            : .keyboard(commandID: activeKeyboardRecordingCommandID)
        activeCaptureOwner = owner
        scheduleCaptureDurationWatchdog(generation: captureGeneration, owner: owner)
        scheduleCaptureHealthWatchdog(generation: captureGeneration, owner: owner)
        return captureGeneration
    }

    private func completeCaptureOperation(_ generation: UInt64) {
        guard activeCaptureGeneration == generation else { return }
        activeCaptureGeneration = nil
        activeCaptureOwner = nil
        captureDurationWatchdogTask?.cancel()
        captureDurationWatchdogTask = nil
        captureHealthWatchdogTask?.cancel()
        captureHealthWatchdogTask = nil
    }

    private func scheduleCaptureDurationWatchdog(generation: UInt64, owner: CaptureOwner) {
        captureDurationWatchdogTask?.cancel()
        captureDurationWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.maximumCaptureDuration * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  self.activeCaptureGeneration == generation,
                  self.activeCaptureOwner == owner,
                  self.hasAnyActiveRecordingCapture
            else { return }
            let commandID: String?
            if case .keyboard(commandID: let ownedCommandID) = owner {
                commandID = ownedCommandID
            } else {
                commandID = nil
            }
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "capture_duration_limit_reached",
                fields: [
                    "generation": "\(generation)",
                    "command_id": commandID ?? "none",
                ]
            )
            await self.stopAndSend(keyboardCommandID: commandID)
        }
    }

    private func scheduleCaptureHealthWatchdog(generation: UInt64, owner: CaptureOwner) {
        captureHealthWatchdogTask?.cancel()
        captureHealthWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.captureHealthPollInterval * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self,
                      self.activeCaptureGeneration == generation,
                      self.activeCaptureOwner == owner,
                      self.hasAnyActiveRecordingCapture
                else { return }

                let health: (
                    source: String,
                    startedAt: Date?,
                    firstFrameAt: Date?,
                    lastFrameAt: Date?,
                    frameCount: Int64
                )
                if self.keyboardAudioSession.isRecording {
                    health = (
                        "keyboard_audio_session",
                        self.keyboardAudioSession.captureStartedAt,
                        self.keyboardAudioSession.firstAudioFrameAt,
                        self.keyboardAudioSession.lastAudioFrameAt,
                        self.keyboardAudioSession.capturedFrameCount
                    )
                } else if self.recorder.isRecording {
                    health = (
                        "audio_recorder",
                        self.recorder.captureStartedAt,
                        self.recorder.firstAudioFrameAt,
                        self.recorder.lastAudioFrameAt,
                        self.recorder.capturedFrameCount
                    )
                } else {
                    return
                }

                let now = Date()
                let failureReason: String?
                if health.firstFrameAt == nil,
                   let startedAt = health.startedAt,
                   now.timeIntervalSince(startedAt) >= Self.firstAudioFrameTimeout {
                    failureReason = "no_audio_frames"
                } else if let lastFrameAt = health.lastFrameAt,
                          now.timeIntervalSince(lastFrameAt) >= Self.audioFrameStallTimeout {
                    failureReason = "audio_frames_stalled"
                } else {
                    failureReason = nil
                }
                guard let failureReason else { continue }

                let commandID: String?
                if case .keyboard(commandID: let ownedCommandID) = owner {
                    commandID = ownedCommandID
                } else {
                    commandID = nil
                }
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "capture_audio_health_failed",
                    fields: [
                        "reason": failureReason,
                        "source": health.source,
                        "generation": "\(generation)",
                        "command_id": commandID ?? "none",
                        "captured_frame_count": "\(health.frameCount)",
                    ]
                )
                await self.handleCaptureAudioInvalidation(reason: failureReason)
                return
            }
        }
    }

    private func captureOperationIsCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled
            && captureGeneration == generation
            && activeCaptureGeneration == generation
    }

    private func beginPostCaptureBackgroundTask(
        operationGeneration: UInt64,
        commandID: String?
    ) {
        endPostCaptureBackgroundTask()
        postCaptureBackgroundTaskGeneration = operationGeneration
        postCaptureBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "typeforme.post-capture-processing"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePostCaptureBackgroundTaskExpiration(
                    operationGeneration: operationGeneration,
                    commandID: commandID
                )
            }
        }
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "post_capture_background_task_started",
            fields: [
                "command_id": commandID ?? "none",
                "generation": "\(operationGeneration)",
                "valid": "\(postCaptureBackgroundTaskID != .invalid)",
            ]
        )
    }

    private func endPostCaptureBackgroundTask(operationGeneration: UInt64? = nil) {
        if let operationGeneration,
           postCaptureBackgroundTaskGeneration != operationGeneration {
            return
        }
        let taskID = postCaptureBackgroundTaskID
        postCaptureBackgroundTaskID = .invalid
        postCaptureBackgroundTaskGeneration = nil
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private func handlePostCaptureBackgroundTaskExpiration(
        operationGeneration: UInt64,
        commandID: String?
    ) {
        guard postCaptureBackgroundTaskGeneration == operationGeneration else { return }
        endPostCaptureBackgroundTask(operationGeneration: operationGeneration)
        guard captureOperationIsCurrent(operationGeneration) else { return }

        let message = "Transcription was interrupted while Typeforme was in the background."
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "post_capture_background_task_expired",
            fields: [
                "command_id": commandID ?? "none",
                "generation": "\(operationGeneration)",
            ]
        )
        setFailure(message)
        if let commandID {
            publishKeyboardStatus(.error, commandID: commandID, message: message)
        }
        stopAndSendTask?.cancel()
    }

    func toggleRecording() async {
        if hasAnyActiveRecordingCapture || phase == .recording {
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
        guard let generation = beginCaptureStart(owner: .host) else { return }
        var shouldResumeAfterStartFailure = false
        defer {
            finishCaptureStart(generation)
            if shouldResumeAfterStartFailure {
                scheduleKeyboardStandbyRefresh(delay: 0.15)
            }
        }

        hostHoldReleasePending = false
        setPhase(.preparing)
        errorMessage = nil

        let hasMicrophonePermission = await ensureMicrophonePermissionForUserAction(
            captureGeneration: generation
        )
        guard isCaptureGenerationCurrent(generation) else {
            discardResourcesFromInvalidatedCaptureStart(generation)
            return
        }
        guard hasMicrophonePermission else {
            hostHoldReleasePending = false
            if phase == .preparing {
                setPhase(.idle)
            }
            return
        }
        await startSelectedVisibleCaptureMode(showErrors: false, honorManualSuppression: false)
        guard isCaptureGenerationCurrent(generation) else {
            discardResourcesFromInvalidatedCaptureStart(generation)
            return
        }

        // Keep the press-to-record path local-only. Mac settings refresh can
        // take seconds on a stale route; foreground/bootstrap keep it warm.
        // Note: do NOT reset correctionMode here — the user's last chip pick
        // must persist across recordings within a scene. New scenes (clear /
        // unpair / cold start) handle the reset themselves.
        do {
            try await startHostRecordingCapture(generation: generation)
            guard markCaptureActive(generation, owner: .host) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            acquireIdleTimer()
            setPhase(.recording)
        } catch {
            guard isCaptureGenerationCurrent(generation) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            setFailure(keyboardAudioStatusMessage(for: error))
            shouldResumeAfterStartFailure = true
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
        guard let generation = beginCaptureStart(owner: .host) else { return }
        var shouldResumeAfterStartFailure = false
        defer {
            finishCaptureStart(generation)
            if shouldResumeAfterStartFailure {
                scheduleKeyboardStandbyRefresh(delay: 0.15)
            }
        }
        setPhase(.preparing)

        let hasMicrophonePermission = await ensureMicrophonePermissionForUserAction(
            captureGeneration: generation
        )
        guard isCaptureGenerationCurrent(generation) else {
            discardResourcesFromInvalidatedCaptureStart(generation)
            return
        }
        guard hasMicrophonePermission else {
            if phase == .preparing {
                setPhase(.idle)
            }
            return
        }
        await startSelectedVisibleCaptureMode(showErrors: false, honorManualSuppression: false)
        guard isCaptureGenerationCurrent(generation) else {
            discardResourcesFromInvalidatedCaptureStart(generation)
            return
        }

        // Keep the press-to-record path local-only. Mac settings refresh can
        // take seconds on a stale route; foreground/bootstrap keep it warm.
        // Note: do NOT reset correctionMode here — the user's last chip pick
        // must persist across recordings within a scene. New scenes (clear /
        // unpair / cold start) handle the reset themselves.
        do {
            try await startHostRecordingCapture(generation: generation)
            guard markCaptureActive(generation, owner: .host) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            acquireIdleTimer()
            setPhase(.recording)
        } catch {
            guard isCaptureGenerationCurrent(generation) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            setFailure(keyboardAudioStatusMessage(for: error))
            shouldResumeAfterStartFailure = true
        }
    }

    private func startHostRecordingCapture(generation: UInt64) async throws {
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
        // PiP mode uses the same FLAC writer as keyboard dictation. Do not
        // fall through to AVAudioRecorder here: PiP keeps an AV playback
        // session alive and device logs show host AVAudioRecorder can leave an
        // unreadable FLAC under that session.
        if keyboardDictationCaptureMode == .pictureInPicture {
            path = keyboardAudioSession.isActive ? "keyboard-session" : "keyboard-session-cold"
            try await keyboardAudioSession.startWithFreshInputEngine(
                reuseActiveSession: hadSilentStandby,
                deactivateExistingSession: hadKeyboardSession
            )
            guard isCaptureGenerationCurrent(generation) else { throw CancellationError() }
            _ = try await keyboardAudioSession.beginRecording()
            guard isCaptureGenerationCurrent(generation) else { throw CancellationError() }
            hostRecordingUsesKeyboardAudioSession = true
            activeBridgeDictateJobID = Self.newBridgeJobID()
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

        if keyboardAudioSession.isActive,
           !keyboardAudioSession.isRecording {
            path = "keyboard-session"
            _ = try await keyboardAudioSession.beginRecording()
            guard isCaptureGenerationCurrent(generation) else { throw CancellationError() }
            hostRecordingUsesKeyboardAudioSession = true
            activeBridgeDictateJobID = Self.newBridgeJobID()
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
        try await recorder.start(reuseActiveSession: hadSilentStandby)
        guard isCaptureGenerationCurrent(generation) else { throw CancellationError() }
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
        if let keyboardCommandID,
           !keyboardCaptureOperationBelongs(to: keyboardCommandID) {
            appLog.notice("stopAndSend ignored: keyboard command does not own capture command_id=\(keyboardCommandID, privacy: .public)")
            return
        }
        guard stopAndSendTask == nil, !isStopAndSendInFlight else { return }
        let taskID = UUID()
        stopAndSendTaskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopAndSend(keyboardCommandID: keyboardCommandID)
        }
        stopAndSendTask = task
        await task.value
        guard stopAndSendTaskID == taskID else { return }
        stopAndSendTask = nil
        stopAndSendTaskID = nil
        if let keyboardCommandID,
           queuedKeyboardStopCommandID == keyboardCommandID {
            queuedKeyboardStopCommandID = nil
        }
        // performStopAndSend's capture/task ownership is released by its
        // defers before this point. Schedule recovery here; attempting it from
        // inside that function is guaranteed to fail the in-flight guards.
        if keyboardStandbyRefreshTask == nil {
            scheduleKeyboardStandbyRefresh(delay: 0.15)
        }
    }

    private func performStopAndSend(keyboardCommandID: String?) async {
        guard !isStopAndSendInFlight else { return }
        guard let operationGeneration = claimCaptureOperationIfNeeded() else { return }
        isStopAndSendInFlight = true
        defer { isStopAndSendInFlight = false }
        defer { activeBridgeDictateJobID = nil }
        defer { completeCaptureOperation(operationGeneration) }
        await waitForMinimumRecordingDurationIfNeeded()
        guard captureOperationIsCurrent(operationGeneration) else { return }

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
        let pendingKeyboardTextEditContext = shouldPublishKeyboardProgress ? activeKeyboardTextEditContext : nil
        let recognitionStageLabels = Self.recognitionStageLabels(for: pendingKeyboardTextEditContext)
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
            publishKeyboardStatus(
                .sending,
                commandID: effectiveKeyboardCommandID,
                message: recognitionStageLabels.transcribing,
                processingStage: .transcribing
            )
        }
        // This is the single stopped edge for this capture. Darwin
        // notifications carry no command ID and can be delivered after the
        // terminal status. Posting another edge at result/error time can then
        // cancel an immediately-following command.
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        try? await Task.sleep(nanoseconds: BridgeAudioRecordingContract.stopTailBufferNanoseconds)
        guard captureOperationIsCurrent(operationGeneration) else { return }
        let fileURL = isKeyboardCapture
            ? keyboardAudioSession.finishRecording()
            : recorder.stop(deactivateSession: true)
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "capture_writer_stopped",
            fields: [
                "command_id": effectiveKeyboardCommandID ?? "none",
                "keyboard_recording": "\(keyboardAudioSession.isRecording)",
                "recorder_recording": "\(recorder.isRecording)",
            ]
        )
        defer {
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        if isKeyboardCapture {
            switch keyboardDictationCaptureMode {
            case .pictureInPicture:
                if keyboardAudioSession.isActive {
                    keyboardAudioSession.stop(discardInputEngine: true)
                }
            case .backgroundMic:
                if !keyboardAudioSession.isActive {
                    startSilentStandbyKeeperIfNeeded()
                }
            }
        }
        // Close the live preview audio side so it finalizes its last partial.
        // We intentionally do NOT clear livePartialTranscript yet — keep the
        // preview source's latest text visible until preview final or the final
        // committed result replaces it.
        await endLivePartialPreviewAudio()
        guard captureOperationIsCurrent(operationGeneration) else { return }
        hostRecordingUsesKeyboardAudioSession = false
        syncPiPDictationPresentation()
        let keyboardTextEditContext = pendingKeyboardTextEditContext
        let keyboardDictationContext = shouldPublishKeyboardProgress ? activeKeyboardDictationContext : nil
        activeKeyboardTextEditContext = nil
        activeKeyboardDictationContext = nil
        releaseIdleTimer()
        guard let fileURL else {
            setPhase(.idle)
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(.standby, commandID: effectiveKeyboardCommandID, message: "Nothing recorded")
            }
            return
        }
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
            return
        }

        acquireIdleTimer()
        defer { releaseIdleTimer() }
        beginPostCaptureBackgroundTask(
            operationGeneration: operationGeneration,
            commandID: effectiveKeyboardCommandID
        )
        defer {
            endPostCaptureBackgroundTask(operationGeneration: operationGeneration)
        }

        var baseURL = routeStatus.activeURL
        let isKeyboardPath = shouldPublishKeyboardProgress || isKeyboardCapture
        // Local routes can disappear while Cloud remains reachable. Probe Local
        // before shipping the recorded file so route changes cost the short
        // health timeout instead of the full dictate POST timeout.
        let routeIsFresh = currentBridgeRouteIsFresh(activeURL: baseURL)
        if isKeyboardPath {
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(
                    .sending,
                    commandID: effectiveKeyboardCommandID,
                    message: recognitionStageLabels.transcribing,
                    processingStage: .transcribing
                )
            }
        }
        if shouldPreflightBridgeRouteBeforeRequest(routeIsFresh: routeIsFresh) {
            await preflightActiveBridgeRoute()
            guard captureOperationIsCurrent(operationGeneration) else { return }
            baseURL = routeStatus.activeURL
        }
        guard let baseURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            if let effectiveKeyboardCommandID {
                publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: errorMessage ?? "Bridge unavailable")
            }
            return
        }

        if let effectiveKeyboardCommandID {
            publishKeyboardStatus(
                .sending,
                commandID: effectiveKeyboardCommandID,
                message: recognitionStageLabels.transcribing,
                audioDurationSeconds: recordingInfo.durationSeconds,
                audioByteCount: recordingInfo.byteCount,
                processingStage: .transcribing
            )
        }
        do {
            scheduleBridgeProgressStatusDelay(
                keyboardCommandID: effectiveKeyboardCommandID,
                message: recognitionStageLabels.transcribing,
                recordingInfo: recordingInfo
            )
            defer { cancelBridgeProgressStatusDelay() }
            let dictationContext = keyboardTextEditContext == nil ? keyboardDictationContext : nil
            let response = try await dictateWithRouteRetry(
                initialBaseURL: baseURL,
                audioURL: fileURL,
                audioExtension: fileURL.pathExtension.isEmpty ? "flac" : fileURL.pathExtension,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode,
                contextBefore: dictationContext?.contextBefore ?? "",
                contextAfter: dictationContext?.contextAfter ?? "",
                includeRawTranscript: true,
                keyboardCommandID: effectiveKeyboardCommandID,
                stageLabels: recognitionStageLabels,
                shouldAdvanceToRefineWhenTranscriptionCompletes: requestedCorrectionMode.usesRefine
                    || keyboardTextEditContext != nil,
                recordingInfo: recordingInfo
            )
            guard captureOperationIsCurrent(operationGeneration) else { return }
            let spokenTranscript = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var resultMessage = "Inserted \(recordingInfo.durationLabel) audio"
            var correctionLatencyMs = response.correctionLatencyMs
            var totalLatencyMs = response.latencyMs
            var finalCorrectionStatus = response.correctionStatus
            var finalCorrectionError = response.correctionError

            if let editContext = keyboardTextEditContext {
                let editingStageLabels = Self.editingStageLabels(for: editContext)
                guard !spokenTranscript.isEmpty else {
                    setFailure("Mac returned an empty transcript.")
                    if let effectiveKeyboardCommandID {
                        publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: errorMessage ?? "Empty transcript")
                    }
                    return
                }
                if let effectiveKeyboardCommandID {
                    publishKeyboardStatus(
                        .sending,
                        commandID: effectiveKeyboardCommandID,
                        message: editingStageLabels.refining,
                        audioDurationSeconds: recordingInfo.durationSeconds,
                        audioByteCount: recordingInfo.byteCount,
                        processingStage: .refining
                    )
                }
                let editJobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
                let client = try await activeBridgeClient()
                guard captureOperationIsCurrent(operationGeneration) else { return }
                activeBridgeDictateJobID = editJobID
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
                            guard let self,
                                  event.jobID == editJobID,
                                  self.activeBridgeDictateJobID == editJobID,
                                  self.captureOperationIsCurrent(operationGeneration)
                            else { return }
                            self.applyBridgeJobStatus(
                                event,
                                keyboardCommandID: effectiveKeyboardCommandID,
                                stageLabels: editingStageLabels,
                                shouldAdvanceToRefineWhenTranscriptionCompletes: true,
                                recordingInfo: recordingInfo
                            )
                        }
                    }
                )
                guard captureOperationIsCurrent(operationGeneration) else { return }
                text = editResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                correctionLatencyMs = editResponse.editLatencyMs ?? editResponse.latencyMs
                if let transcriptionLatency = response.transcriptionLatencyMs,
                   let editLatency = editResponse.latencyMs {
                    totalLatencyMs = transcriptionLatency + editLatency
                } else {
                    totalLatencyMs = editResponse.latencyMs ?? response.latencyMs
                }
                finalCorrectionStatus = editResponse.editStatus
                finalCorrectionError = editResponse.editError
                resultMessage = editContext.intent == .command ? "Edited selection" : "Repaired selection"
            }
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                if let effectiveKeyboardCommandID {
                    publishKeyboardStatus(.error, commandID: effectiveKeyboardCommandID, message: errorMessage ?? "Empty result")
                }
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
            // Final committed result is now the source of truth; preview is done.
            teardownLivePartialPreview(clearText: true)
            lastGeneratedResultText = text
            if keyboardTextEditContext == nil {
                rawTranscript = response.rawTranscript ?? rawTranscript
                sessionID = response.sessionID
            } else {
                rawTranscript = spokenTranscript
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
            let successKind: AppPhase.SuccessKind = resultCommandID == nil ? .ready : .inserted
            if Self.isCorrectionDegradedStatus(finalCorrectionStatus) {
                resultMessage = Self.degradedCorrectionMessage(for: successKind, status: finalCorrectionStatus)
            }
            errorMessage = nil
            applyCorrectionMetadata(
                status: finalCorrectionStatus,
                error: finalCorrectionError,
                asrWarning: response.asrWarning,
                successKind: successKind
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
            notifyKeyboardTranscriptionReady()
            if resultCommandID != nil {
                scheduleKeyboardStandbyRefresh()
                return
            }
        } catch {
            guard captureOperationIsCurrent(operationGeneration) else { return }
            if isBenignEmptyTranscript(error) {
                teardownLivePartialPreview(clearText: true)
                errorMessage = nil
                setPhase(.idle)
                if let effectiveKeyboardCommandID {
                    publishKeyboardStatus(.standby, commandID: effectiveKeyboardCommandID, message: "Nothing recorded")
                }
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
        }
    }

    private func waitForMinimumRecordingDurationIfNeeded() async {
        guard let recordingStartedAt else { return }
        let remaining = Self.minimumRecordingStopInterval - Date().timeIntervalSince(recordingStartedAt)
        guard remaining > 0 else { return }
        appLog.debug("stopAndSend delayed during recording warmup by \(remaining, privacy: .public)s")
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func shouldPreflightBridgeRouteBeforeRequest(routeIsFresh: Bool) -> Bool {
        guard routeStatus.activeURL != nil else { return true }
        guard routeIsFresh else { return true }
        return routeStatus.activeKind == .local
    }

    private func currentBridgeRouteIsFresh(activeURL: URL? = nil) -> Bool {
        guard let routeFetchedAt, (activeURL ?? routeStatus.activeURL) != nil else { return false }
        let cacheTTL = routeStatus.activeKind == .local ? Self.localRouteCacheTTL : Self.routeCacheTTL
        return Date().timeIntervalSince(routeFetchedAt) < cacheTTL
    }

    func applyCorrectionMode(_ newMode: CorrectionMode) async {
        // Block mode changes while a request is mid-flight to avoid a stale
        // result coming back in the old mode while the UI shows the new one.
        guard !isBusy else { return }
        guard let source = currentRefineSource() else {
            rawTranscript = ""
            sessionID = nil
            lastGeneratedResultText = nil
            applyKeyboardDefaultCorrectionMode(newMode)
            setPhase(.idle)
            // Without a result to refine, a chip tap silently changed the
            // default style — invisible, and it also retargets the keyboard's
            // default. Say so.
            showTransient("Default style: \(newMode.title)")
            return
        }
        correctionMode = newMode
        constrainKeyboardLivePreviewSourceToMacSettings()
        let expectedPairingRevision = pairingRevision
        do {
            await refreshRoute(
                force: false,
                probeAllEndpoints: false,
                showIndicator: false,
                reason: "refine_route"
            )
            let client = try await activeBridgeClient()
            setPhase(.refining)
            let refineJobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            activeBridgeRefineJobID = refineJobID
            defer {
                if activeBridgeRefineJobID == refineJobID {
                    activeBridgeRefineJobID = nil
                }
            }
            let response = try await client.refine(
                sessionID: source.sessionID,
                rawTranscript: source.rawTranscript,
                languageIDs: activeLanguageIDs,
                correctionMode: newMode,
                clientJobID: refineJobID,
                onJobEvent: { [weak self] event in
                    await MainActor.run {
                        guard let self,
                              event.jobID == refineJobID,
                              self.activeBridgeRefineJobID == refineJobID,
                              self.pairingRevision == expectedPairingRevision
                        else { return }
                        self.applyBridgeJobStatus(
                            event,
                            keyboardCommandID: nil,
                            shouldAdvanceToRefineWhenTranscriptionCompletes: true
                        )
                    }
                }
            )
            guard pairingRevision == expectedPairingRevision else {
                throw CancellationError()
            }
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
            notifyKeyboardTranscriptionReady()
            errorMessage = nil
            applyCorrectionMetadata(
                status: response.correctionStatus,
                error: response.correctionError
            )
        } catch {
            guard pairingRevision == expectedPairingRevision else { return }
            // Invalidate the route cache on both auth and network errors so
            // the next Refine tap re-probes instead of reusing a dead route.
            if shouldRetryBridgeRequest(after: error) {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
        }
    }

    func copyResult() {
        guard canMutateResult, !resultText.isEmpty else { return }
        UIPasteboard.general.string = resultText
        errorMessage = nil
        setPhase(.success(.copied))
        showTransient("Copied")
    }

    func clearResult() {
        guard canMutateResult else { return }
        resultText = ""
        rawTranscript = ""
        sessionID = nil
        lastGeneratedResultText = nil
        processingStatusMessage = nil
        resetCorrectionModeToDefault()
        setPhase(.idle)
    }

    private func currentRefineSource() -> RefineSource? {
        let rawText = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawText.isEmpty {
            return RefineSource(sessionID: sessionID, rawTranscript: rawText)
        }

        // Host mode chips restyle a dictation from the captured raw transcript
        // above. Only fall back to visible Result text when no raw source exists,
        // so IME marked text, caret position, and keyboard selected-text flows do
        // not change the source for generated dictations.
        let visibleText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleText.isEmpty else { return nil }
        return RefineSource(sessionID: nil, rawTranscript: visibleText)
    }

    func handleOpenURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "typeforme" else { return }
        let now = Date().timeIntervalSince1970
        if let lastHandledOpenURL,
           lastHandledOpenURL.value == url.absoluteString,
           now - lastHandledOpenURL.time < 1.0 {
            appLog.notice("handleOpenURL: skipped duplicate typeforme URL")
            return
        }
        lastHandledOpenURL = (url.absoluteString, now)
#if DEBUG && targetEnvironment(simulator)
        if await handleSimulatorDebugOpenURL(url) {
            return
        }
#endif
        await waitForInitialRenderOpportunity()
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var source: String?
        var handoffID: String?
        var reason: String?
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
            } else if source == "keyboard", let handoffID {
                if let handoff = await consumeKeyboardHostHandoff(id: handoffID, action: action) {
                    keyboardHandoff = handoff
                } else {
                    appLog.notice("handleOpenURL: rejected unauthenticated keyboard handoff action=\(action, privacy: .public), has_handoff=true")
                    return
                }
            } else if source == "keyboard" {
                appLog.notice("handleOpenURL: rejected unauthenticated keyboard handoff action=\(action, privacy: .public), has_handoff=\((handoffID?.isEmpty == false), privacy: .public)")
                return
            } else if action != "setup" {
                // Custom URL schemes can be invoked by any installed app or
                // webpage. Recording and preference mutations require the
                // one-time App Group handoff created by our keyboard.
                appLog.notice("handleOpenURL: rejected unauthenticated external action=\(action, privacy: .public)")
                return
            }
        }
        if let keyboardHandoff {
            await handleKeyboardHostHandoff(action: action, handoff: keyboardHandoff)
            return
        }
        appLog.notice("handleOpenURL: action=\(action, privacy: .public), source=\(source ?? "nil", privacy: .public), handoff=false")
        if action == "setup" {
            if source == "keyboard", reason == "full_access" {
                markKeyboardFullAccessRequired()
            }
        } else if action == "record" {
            appLog.notice("handleOpenURL: rejected unauthenticated record action")
            return
        } else if action == "microphone" {
            appLog.notice("handleOpenURL: rejected unauthenticated microphone action")
            return
        } else if action == "standby" {
            appLog.notice("handleOpenURL: rejected unauthenticated standby action")
            return
        }
    }

#if DEBUG && targetEnvironment(simulator)
    private func handleSimulatorDebugOpenURL(_ url: URL) async -> Bool {
        guard url.host == "debug" else { return false }
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch action {
        case "keyboard-darwin-start":
            postSimulatorKeyboardDarwinCommand(.start, url: url)
            return true
        case "keyboard-darwin-stop":
            postSimulatorKeyboardDarwinCommand(.stop, url: url)
            return true
        case "keyboard-darwin-cancel":
            postSimulatorKeyboardDarwinCommand(.cancel, url: url)
            return true
        case "keyboard-mic-session":
            await runSimulatorKeyboardMicSessionSmoke(url: url)
            return true
        case "keyboard-mic-session-stop":
            await stopSimulatorKeyboardMicSessionSmoke(url: url)
            return true
        case "keyboard-capture-state":
            recordSimulatorKeyboardCaptureState(url: url, event: "simulator_keyboard_capture_state")
            return true
        case "keyboard-capture-mode":
            setSimulatorKeyboardCaptureMode(url: url)
            return true
        case "keyboard-background-capture-stop":
            stopSimulatorBackgroundKeyboardCapture(url: url)
            return true
        case "keyboard-local-server-stop":
            stopSimulatorKeyboardLocalServer(url: url)
            return true
        case "keyboard-pip-stop":
            stopSimulatorPiPDictation(url: url)
            return true
        default:
            return false
        }
    }

    private func simulatorDebugQueryItems(from url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func simulatorDebugValue(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func simulatorDebugBool(_ name: String, in items: [URLQueryItem], default defaultValue: Bool) -> Bool {
        guard let value = simulatorDebugValue(name, in: items)?.lowercased(),
              !value.isEmpty
        else { return defaultValue }
        return value == "1" || value == "true" || value == "yes"
    }

    private func runSimulatorKeyboardMicSessionSmoke(url: URL) async {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        let requestMic = simulatorDebugBool("request_mic", in: items, default: true)
        let warmInputEngine = simulatorDebugBool("warm_input_engine", in: items, default: true)
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_mic_session_begin",
            fields: [
                "run_id": runID,
                "request_mic": "\(requestMic)",
                "warm_input_engine": "\(warmInputEngine)",
                "mode": keyboardDictationCaptureMode.rawValue,
            ]
        )
        simulatorDebugAllowsUnpairedCapturePreparation = true
        defer { simulatorDebugAllowsUnpairedCapturePreparation = false }
        let ready = await setKeyboardStandby(
            true,
            requestMicrophoneIfNeeded: requestMic,
            surfaceAudioSessionErrors: false,
            warmInputEngine: warmInputEngine
        )
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_mic_session_result",
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "mic_session_result")
                .merging(["ready": "\(ready)"]) { current, _ in current }
        )
    }

    private func stopSimulatorKeyboardMicSessionSmoke(url: URL) async {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        _ = await setKeyboardStandby(false)
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_mic_session_stopped",
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "mic_session_stopped")
        )
    }

    private func setSimulatorKeyboardCaptureMode(url: URL) {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        guard let rawMode = simulatorDebugValue("mode", in: items),
              let mode = KeyboardDictationCaptureMode(rawValue: rawMode)
        else {
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "simulator_keyboard_capture_mode_failed",
                fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "capture_mode_failed")
                    .merging(["requested_mode": simulatorDebugValue("mode", in: items) ?? "none"]) { current, _ in current }
            )
            return
        }
        setKeyboardDictationCaptureMode(mode)
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_capture_mode_set",
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "capture_mode_set")
        )
    }

    private func stopSimulatorBackgroundKeyboardCapture(url: URL) {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        stopBackgroundAudioCaptureForVisibleMode()
        publishKeyboardCaptureNotReady()
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_background_capture_stopped",
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "background_capture_stopped")
        )
    }

    private func stopSimulatorKeyboardLocalServer(url: URL) {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        keyboardServer.stop(reason: "simulator_debug")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_local_server_stopped",
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "local_server_stopped")
        )
    }

    private func stopSimulatorPiPDictation(url: URL) {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        suppressAutomaticPiPStart = true
        cancelAutomaticPiPStart()
        pipDictationCoordinator.stop()
        stopBackgroundAudioCaptureForVisibleMode()
        publishKeyboardCaptureNotReady()
        syncPiPDictationPresentation()
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_pip_stopped",
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: "pip_stopped")
        )
    }

    private func recordSimulatorKeyboardCaptureState(url: URL, event: String) {
        let items = simulatorDebugQueryItems(from: url)
        let runID = simulatorDebugValue("run_id", in: items) ?? "sim-\(UUID().uuidString)"
        let label = simulatorDebugValue("label", in: items) ?? "state"
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: event,
            fields: simulatorKeyboardCaptureStateFields(runID: runID, label: label)
        )
    }

    private func simulatorKeyboardCaptureStateFields(runID: String, label: String) -> [String: String] {
        [
            "run_id": runID,
            "label": label,
            "mode": keyboardDictationCaptureMode.rawValue,
            "keyboard_active": "\(keyboardAudioSession.isActive)",
            "keyboard_recording": "\(keyboardAudioSession.isRecording)",
            "standby_keeper_active": "\(standbyKeeper.isActive)",
            "audio_host_session_active": "\(isKeyboardAudioHostSessionActive)",
            "host_session_active": "\(isKeyboardHostSessionActive)",
            "selected_capture_ready": "\(isSelectedKeyboardCaptureReady)",
            "server_running": "\(keyboardServer.isRunning)",
            "pip_supported": "\(pipDictationCoordinator.isSupported)",
            "pip_possible": "\(pipDictationCoordinator.isPossible)",
            "pip_active": "\(pipDictationCoordinator.isActive)",
            "status_state": keyboardBridgeStatus.state.rawValue,
        ]
    }

    private func postSimulatorKeyboardDarwinCommand(_ action: KeyboardBridgeCommandAction, url: URL) {
        let items = simulatorDebugQueryItems(from: url)
        let commandID = simulatorDebugValue("command_id", in: items)
        let correctionModeRaw = simulatorDebugValue("correction_mode", in: items)
        let id = commandID?.isEmpty == false ? commandID! : "sim-\(UUID().uuidString)"
        let allowUnpairedCapture = simulatorDebugBool(
            "allow_unpaired_capture",
            in: items,
            default: false
        )
        if action == .start, allowUnpairedCapture {
            simulatorDebugUnpairedCommandIDs.insert(id)
        }
        let command = KeyboardBridgeCommand(
            id: id,
            action: action,
            correctionMode: correctionModeRaw?.isEmpty == false ? correctionModeRaw! : config.correctionMode.rawValue,
            dictationContext: action == .start ? KeyboardDictationContext(contextBefore: "", contextAfter: "") : nil
        )
        if action == .start {
            KeyboardSharedDefaults.clearCommandReceipt()
        }
        let saved = KeyboardSharedDefaults.saveDarwinCommand(command)
        let notificationName: String
        switch action {
        case .start:
            notificationName = KeyboardDarwinNotificationName.requestStartDictation
        case .stop:
            notificationName = KeyboardDarwinNotificationName.requestStopDictation
        case .cancel:
            notificationName = KeyboardDarwinNotificationName.requestCancelDictation
        case .configure, .refineText:
            return
        }
        guard let requestName = KeyboardDarwinNotificationName.authenticatedRequest(
            notificationName,
            token: keyboardBridgeToken
        ) else {
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "simulator_keyboard_darwin_command_missing_token",
                fields: ["action": action.rawValue, "command_id": id]
            )
            return
        }
        appLog.notice("simulator keyboard darwin command action=\(action.rawValue, privacy: .public) command_id=\(id, privacy: .public) saved=\(saved, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "simulator_keyboard_darwin_command_posted",
            fields: [
                "action": action.rawValue,
                "command_id": id,
                "saved": "\(saved)",
            ]
        )
        guard saved else { return }
        KeyboardDarwinBridge.post(requestName)
        if action == .cancel {
            simulatorDebugUnpairedCommandIDs.remove(id)
        }
    }

    private func simulatorDebugAllowsUnpairedCommand(_ commandID: String) -> Bool {
        simulatorDebugUnpairedCommandIDs.contains(commandID)
    }
#endif

    private func consumeKeyboardHostHandoff(id: String, action: String) async -> KeyboardHostHandoff? {
        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let handoff = KeyboardSharedDefaults.consumeHostHandoff(
                id: id,
                now: Date().timeIntervalSince1970
            ) else {
                continue
            }
            guard handoff.action == action else {
                appLog.notice("consumeKeyboardHostHandoff: action mismatch expected=\(action, privacy: .public) actual=\(handoff.action, privacy: .public)")
                return nil
            }
            return handoff
        }
        return nil
    }

    private func handleKeyboardHostHandoff(
        action: String,
        handoff: KeyboardHostHandoff
    ) async {
        guard isConfigured else {
            publishKeyboardStatus(.error, message: "Pair Typeforme with your Mac before dictating.")
            return
        }
        if let nextMode = CorrectionMode(rawValue: handoff.correctionMode) {
            correctionMode = nextMode
        } else {
            setFailure("Unsupported correction mode: \(handoff.correctionMode)")
            return
        }

        appLog.notice("handleKeyboardHostHandoff: action=\(action, privacy: .public), source=keyboard")

        if action == "record" || action == "microphone" {
            let didPrepare = await prepareKeyboardCaptureFromHostOpen()
            if didPrepare {
                showKeyboardSwipeBackPrompt()
            }
        } else if action == "standby" {
            let didPrepareKeyboardSession = await prepareKeyboardCaptureFromHostOpen()
            if didPrepareKeyboardSession {
                showKeyboardSwipeBackPrompt()
            } else if AVAudioApplication.shared.recordPermission == .denied {
                showKeyboardMicrophoneDeniedFeedbackIfNeeded()
            }
        }
    }

    private func prepareKeyboardCaptureFromHostOpen() async -> Bool {
        await prepareSelectedHostCaptureMode(
            showErrors: true,
            honorManualSuppression: false,
            requestMicrophoneIfNeeded: true
        )
    }

    @discardableResult
    private func prepareSelectedHostCaptureMode(
        showErrors: Bool,
        honorManualSuppression: Bool = true,
        requestMicrophoneIfNeeded: Bool = false,
        preserveCommandStatus: Bool = false,
        preparationGeneration suppliedPreparationGeneration: UInt64? = nil
    ) async -> Bool {
        let preparationGeneration = suppliedPreparationGeneration ?? beginCapturePreparation()
        let selectedMode = keyboardDictationCaptureMode
        guard capturePreparationIsCurrent(preparationGeneration, mode: selectedMode) else { return false }
        let shouldPreserveCommandStatus = preserveCommandStatus
            || shouldPreserveKeyboardCommandStatusDuringStandbyResume
        appLog.notice("prepare selected capture begin mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) show_errors=\(showErrors, privacy: .public) honor_suppression=\(honorManualSuppression, privacy: .public) request_mic=\(requestMicrophoneIfNeeded, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "prepare_selected_capture_begin",
            fields: [
                "mode": self.keyboardDictationCaptureMode.rawValue,
                "show_errors": "\(showErrors)",
                "honor_suppression": "\(honorManualSuppression)",
                "request_mic": "\(requestMicrophoneIfNeeded)",
                "preserve_command_status": "\(shouldPreserveCommandStatus)",
                "pip_active": "\(self.pipDictationCoordinator.isActive)",
                "keyboard_active": "\(self.keyboardAudioSession.isActive)",
                "audio_host_session_active": "\(self.isKeyboardAudioHostSessionActive)",
                "host_session_active": "\(self.isKeyboardHostSessionActive)",
                "server_running": "\(self.keyboardServer.isRunning)",
            ]
        )
        switch keyboardDictationCaptureMode {
        case .backgroundMic:
            suppressAutomaticPiPStart = true
            cancelAutomaticPiPStart()
            guard await pipDictationCoordinator.stopAndWait() else {
                if !(preserveCommandStatus || shouldPreserveKeyboardCommandStatusDuringStandbyResume) {
                    publishKeyboardCaptureNotReady()
                }
                return false
            }
            guard capturePreparationIsCurrent(preparationGeneration, mode: selectedMode) else {
                discardResourcesFromStaleCapturePreparation(
                    preparationGeneration,
                    expectedMode: selectedMode
                )
                return false
            }
            let didPrepareKeyboardSession = await setKeyboardStandby(
                true,
                requestMicrophoneIfNeeded: requestMicrophoneIfNeeded,
                surfaceAudioSessionErrors: showErrors,
                warmInputEngine: true,
                preserveCommandStatus: shouldPreserveCommandStatus,
                preparationGeneration: preparationGeneration,
                expectedMode: selectedMode
            )
            guard capturePreparationIsCurrent(preparationGeneration, mode: selectedMode) else {
                discardResourcesFromStaleCapturePreparation(
                    preparationGeneration,
                    expectedMode: selectedMode
                )
                return false
            }
            if !didPrepareKeyboardSession, showErrors {
                showKeyboardMicrophoneDeniedFeedbackIfNeeded()
            }
            appLog.notice("prepare selected capture result mode=background_mic ready=\(didPrepareKeyboardSession, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "prepare_selected_capture_result",
                fields: [
                    "mode": "background_mic",
                    "ready": "\(didPrepareKeyboardSession)",
                    "keyboard_active": "\(self.keyboardAudioSession.isActive)",
                    "audio_host_session_active": "\(self.isKeyboardAudioHostSessionActive)",
                    "host_session_active": "\(self.isKeyboardHostSessionActive)",
                    "server_running": "\(self.keyboardServer.isRunning)",
                    "selected_capture_ready": "\(self.isSelectedKeyboardCaptureReady)",
                ]
            )
            return didPrepareKeyboardSession
        case .pictureInPicture:
            stopBackgroundAudioCaptureForVisibleMode()
            let didStartVisibleCapture = await startSelectedVisibleCaptureMode(
                showErrors: showErrors,
                honorManualSuppression: honorManualSuppression
            )
            guard capturePreparationIsCurrent(preparationGeneration, mode: selectedMode) else {
                discardResourcesFromStaleCapturePreparation(
                    preparationGeneration,
                    expectedMode: selectedMode
                )
                return false
            }
            guard didStartVisibleCapture else {
                appLog.notice("prepare selected capture result mode=picture_in_picture ready=false reason=visible_capture_failed pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "prepare_selected_capture_result",
                    fields: [
                        "mode": "picture_in_picture",
                        "ready": "false",
                        "reason": "visible_capture_failed",
                        "preserve_command_status": "\(shouldPreserveCommandStatus)",
                        "pip_active": "\(self.pipDictationCoordinator.isActive)",
                        "host_session_active": "\(self.isKeyboardHostSessionActive)",
                        "server_running": "\(self.keyboardServer.isRunning)",
                        "selected_capture_ready": "\(self.isSelectedKeyboardCaptureReady)",
                    ]
                )
                if !(preserveCommandStatus || shouldPreserveKeyboardCommandStatusDuringStandbyResume) {
                    publishKeyboardCaptureNotReady()
                }
                return false
            }
            let bridgeReady = await prepareKeyboardBridgeForOnDemandCapture(
                showErrors: showErrors,
                preserveCommandStatus: shouldPreserveCommandStatus,
                preparationGeneration: preparationGeneration
            )
            guard capturePreparationIsCurrent(preparationGeneration, mode: selectedMode) else {
                discardResourcesFromStaleCapturePreparation(
                    preparationGeneration,
                    expectedMode: selectedMode
                )
                return false
            }
            appLog.notice("prepare selected capture result mode=picture_in_picture ready=\(bridgeReady, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) server_running=\(self.keyboardServer.isRunning, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "prepare_selected_capture_result",
                fields: [
                    "mode": "picture_in_picture",
                    "ready": "\(bridgeReady)",
                    "preserve_command_status": "\(shouldPreserveCommandStatus)",
                    "pip_active": "\(self.pipDictationCoordinator.isActive)",
                    "audio_host_session_active": "\(self.isKeyboardAudioHostSessionActive)",
                    "host_session_active": "\(self.isKeyboardHostSessionActive)",
                    "server_running": "\(self.keyboardServer.isRunning)",
                    "selected_capture_ready": "\(self.isSelectedKeyboardCaptureReady)",
                ]
            )
            return bridgeReady
        }
    }

    @discardableResult
    private func prepareKeyboardBridgeForOnDemandCapture(
        showErrors: Bool,
        preserveCommandStatus: Bool = false,
        preparationGeneration: UInt64
    ) async -> Bool {
        guard capturePreparationIsCurrent(preparationGeneration, mode: .pictureInPicture) else {
            return false
        }
        keyboardStandbyEnabled = true
        configureKeyboardServer()
        let bridgeReady = await ensureKeyboardLocalBridgeReady(
            reason: "prepare_on_demand_capture",
            showErrors: showErrors,
            forceProbe: true
        )
        guard capturePreparationIsCurrent(preparationGeneration, mode: .pictureInPicture) else {
            discardResourcesFromStaleCapturePreparation(
                preparationGeneration,
                expectedMode: .pictureInPicture
            )
            return false
        }
        guard bridgeReady else {
            let message = NSLocalizedString("Keyboard bridge is unavailable.", comment: "Keyboard local bridge unavailable")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "prepare_keyboard_bridge_failed",
                fields: [
                    "reason": "bridge_not_ready",
                    "preserve_command_status": "\(preserveCommandStatus)",
                ]
            )
            if showErrors {
                errorMessage = message
            }
            if !preserveCommandStatus {
                publishKeyboardStatus(.error, message: errorMessage ?? message)
            }
            return false
        }
        keyboardAudioUnavailableMessage = nil
        if !preserveCommandStatus {
            publishKeyboardStatus(.standby, message: "Ready")
        }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
        appLog.notice("prepare keyboard bridge ready server_running=\(self.keyboardServer.isRunning, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "prepare_keyboard_bridge_ready",
            fields: [
                "server_running": "\(self.keyboardServer.isRunning)",
                "host_session_active": "\(self.isKeyboardHostSessionActive)",
                "selected_capture_ready": "\(self.isSelectedKeyboardCaptureReady)",
            ]
        )
        return true
    }

    private func stopBackgroundAudioCaptureForVisibleMode(
        cancelStandbyRefresh: Bool = true
    ) {
        guard !keyboardAudioSession.isRecording, !recorder.isRecording else { return }
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        if cancelStandbyRefresh {
            cancelKeyboardStandbyRefresh()
        }
        stopKeyboardStatusAudioLevelPush()
        if keyboardAudioSession.isActive {
            keyboardAudioSession.stop(
                discardInputEngine: keyboardDictationCaptureMode == .pictureInPicture
            )
        }
        standbyKeeper.stop()
    }

    private func publishKeyboardCaptureNotReady() {
        guard !keyboardAudioSession.isRecording, !recorder.isRecording else { return }
        appLog.notice("keyboard capture not ready mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "keyboard_capture_not_ready",
            fields: [
                "mode": self.keyboardDictationCaptureMode.rawValue,
                "pip_active": "\(self.pipDictationCoordinator.isActive)",
                "keyboard_active": "\(self.keyboardAudioSession.isActive)",
            ]
        )
        publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
    }

    private var shouldHonorRecentPiPStopForForegroundActivation: Bool {
        guard let lastPiPStopAt else { return false }
        return Date().timeIntervalSince(lastPiPStopAt) < 1.5
    }

    private func requestAutomaticPiPVisibilityStart(showErrors: Bool) {
        guard keyboardDictationCaptureMode == .pictureInPicture else { return }
        guard !suppressAutomaticPiPStart else { return }
        automaticPiPStartAttemptsRemaining = Self.automaticPiPStartMaxAttempts
        automaticPiPStartShowsErrors = automaticPiPStartShowsErrors || showErrors
        scheduleAutomaticPiPVisibilityStart(showErrors: automaticPiPStartShowsErrors)
    }

    private func cancelAutomaticPiPStart() {
        autoStartPiPTask?.cancel()
        autoStartPiPTask = nil
        autoStartPiPTaskID = nil
        automaticPiPStartAttemptsRemaining = 0
        automaticPiPStartShowsErrors = false
    }

    private func scheduleAutomaticPiPVisibilityStart(showErrors: Bool) {
        guard autoStartPiPTask == nil else { return }
        guard automaticPiPStartAttemptsRemaining > 0 else { return }
        let taskID = UUID()
        autoStartPiPTaskID = taskID
        autoStartPiPTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let didStart = await self.startAutomaticPiPVisibilityIfNeeded(showErrors: showErrors)
            guard self.autoStartPiPTaskID == taskID else { return }
            self.autoStartPiPTask = nil
            self.autoStartPiPTaskID = nil
            if !didStart,
               self.automaticPiPStartAttemptsRemaining > 0,
               !self.suppressAutomaticPiPStart {
                self.scheduleAutomaticPiPVisibilityStart(showErrors: showErrors)
            }
        }
    }

    @discardableResult
    private func startAutomaticPiPVisibilityIfNeeded(showErrors: Bool) async -> Bool {
        guard keyboardDictationCaptureMode == .pictureInPicture else { return false }
        guard !pipDictationCoordinator.isActive else {
            automaticPiPStartAttemptsRemaining = 0
            automaticPiPStartShowsErrors = false
            return true
        }
        guard !suppressAutomaticPiPStart else { return false }
        guard automaticPiPStartAttemptsRemaining > 0 else { return false }

        automaticPiPStartAttemptsRemaining -= 1
        let shouldSurfaceFailure = showErrors && automaticPiPStartAttemptsRemaining == 0
        let didStart = await startPiPVisibility(showErrors: shouldSurfaceFailure)
        if didStart {
            automaticPiPStartAttemptsRemaining = 0
            automaticPiPStartShowsErrors = false
            return true
        }
        if automaticPiPStartAttemptsRemaining == 0 || suppressAutomaticPiPStart {
            automaticPiPStartShowsErrors = false
        }
        return false
    }

    private func clearKeyboardHostSessionTimers() {
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        cancelKeyboardStandbyRefresh()
        stopKeyboardStatusAudioLevelPush()
    }

    @discardableResult
    private func startSelectedVisibleCaptureMode(
        showErrors: Bool,
        honorManualSuppression: Bool = true
    ) async -> Bool {
        switch keyboardDictationCaptureMode {
        case .backgroundMic:
            suppressAutomaticPiPStart = true
            cancelAutomaticPiPStart()
            return await pipDictationCoordinator.stopAndWait()
        case .pictureInPicture:
            guard !honorManualSuppression || showErrors || !suppressAutomaticPiPStart else { return false }
            suppressAutomaticPiPStart = false
            if showErrors || !honorManualSuppression {
                let pendingAutomaticStart = autoStartPiPTask
                cancelAutomaticPiPStart()
                await pendingAutomaticStart?.value
                return await startPiPVisibilityWithForegroundRetry(showErrors: showErrors)
            }
            requestAutomaticPiPVisibilityStart(showErrors: showErrors)
            guard let task = autoStartPiPTask else {
                return pipDictationCoordinator.isActive
            }
            await task.value
            return pipDictationCoordinator.isActive
        }
    }

    @discardableResult
    private func startPiPVisibility(showErrors: Bool) async -> Bool {
        guard keyboardDictationCaptureMode == .pictureInPicture else { return false }
        guard !pipDictationCoordinator.isActive else { return true }
        let didStart = await preparePiPDictationSession(showErrors: showErrors)
        if didStart {
            lastPiPStopAt = nil
        }
        return didStart
    }

    @discardableResult
    private func startPiPVisibilityWithForegroundRetry(showErrors: Bool) async -> Bool {
        guard keyboardDictationCaptureMode == .pictureInPicture else { return false }
        guard !pipDictationCoordinator.isActive else { return true }

        let maxAttempts = Self.automaticPiPStartMaxAttempts
        for attempt in 1...maxAttempts {
            let shouldSurfaceFailure = showErrors && attempt == maxAttempts
            if await startPiPVisibility(showErrors: shouldSurfaceFailure) {
                return true
            }
            guard attempt < maxAttempts,
                  !pipDictationCoordinator.isActive,
                  keyboardDictationCaptureMode == .pictureInPicture
            else { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return pipDictationCoordinator.isActive
    }

    @discardableResult
    private func preparePiPDictationSession(showErrors: Bool) async -> Bool {
        syncPiPDictationPresentation()
        if !(await waitUntilApplicationIsActive(timeout: 3.0)) {
            appLog.notice("preparePiPDictationSession: app did not become active before PiP start; continuing with readiness retry")
        }
        let didStart = await pipDictationCoordinator.start()
        if !didStart, showErrors {
            let message = pipDictationCoordinator.lastErrorMessage
                ?? NSLocalizedString("Picture in Picture is unavailable.", comment: "PiP unavailable toast")
            showTransient(message)
        }
        return didStart
    }

    private func handlePiPDidStop() async {
        guard keyboardDictationCaptureMode == .pictureInPicture else { return }
        lastPiPStopAt = Date()
        suppressAutomaticPiPStart = true
        cancelAutomaticPiPStart()
        let preservesCommandStatus = isStopAndSendInFlight
            || phase == .sending
            || phase == .refining
            || keyboardBridgeStatus.state == .sending
            || keyboardBridgeStatus.state == .result
            || keyboardBridgeStatus.state == .error
        if hasAnyActiveRecordingCapture || captureStartInFlightGeneration != nil {
            await cancelActiveRecordingWithoutSending(
                hostFailureMessage: nil,
                keyboardCommandID: activeKeyboardRecordingCommandID,
                keyboardMessage: "Ready",
                resumeKeyboardStandby: false
            )
        }
        stopBackgroundAudioCaptureForVisibleMode()
        if preservesCommandStatus {
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "pip_stop_preserved_command_status",
                fields: [
                    "command_id": keyboardBridgeStatus.commandID ?? "none",
                    "state": keyboardBridgeStatus.state.rawValue,
                ]
            )
        } else {
            publishKeyboardCaptureNotReady()
        }
        syncPiPDictationPresentation()
    }

    private func showKeyboardSwipeBackPrompt() {
        showTransient(NSLocalizedString(
            "Swipe back to return to your previous app.",
            comment: "Toast after the host prepares the microphone for keyboard dictation"
        ))
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
        surfaceAudioSessionErrors: Bool = true,
        warmInputEngine: Bool = true,
        preserveCommandStatus: Bool = false,
        preparationGeneration suppliedPreparationGeneration: UInt64? = nil,
        expectedMode: KeyboardDictationCaptureMode? = nil
    ) async -> Bool {
        if enabled {
            if suppliedPreparationGeneration == nil {
                keyboardStandbyEnabled = true
            }
            let preparationGeneration = suppliedPreparationGeneration ?? beginCapturePreparation()
            guard capturePreparationIsCurrent(preparationGeneration, mode: expectedMode),
                  capturePreparationIsAuthorized
            else {
                if suppliedPreparationGeneration == nil, !capturePreparationIsAuthorized {
                    keyboardStandbyEnabled = false
                }
                return false
            }
            configureKeyboardServer()
            do {
                guard await ensureKeyboardLocalBridgeReady(
                    reason: "set_keyboard_standby",
                    showErrors: surfaceAudioSessionErrors,
                    forceProbe: true
                ) else {
                    return false
                }
                guard capturePreparationIsCurrent(preparationGeneration, mode: expectedMode) else {
                    discardResourcesFromStaleCapturePreparation(
                        preparationGeneration,
                        expectedMode: expectedMode
                    )
                    return false
                }
                let isInputReady = try await prepareKeyboardInputStandby(
                    requestMicrophoneIfNeeded: requestMicrophoneIfNeeded,
                    warmInputEngine: warmInputEngine,
                    preparationGeneration: preparationGeneration,
                    expectedMode: expectedMode
                )
                guard capturePreparationIsCurrent(preparationGeneration, mode: expectedMode) else {
                    discardResourcesFromStaleCapturePreparation(
                        preparationGeneration,
                        expectedMode: expectedMode
                    )
                    return false
                }
                if isInputReady {
                    if !preserveCommandStatus {
                        publishKeyboardStatus(.standby, message: "Ready")
                    }
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
                } else {
                    startSilentStandbyKeeperIfNeeded()
                    if !preserveCommandStatus {
                        publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
                    }
                }
                scheduleHostAudioSessionExpiry()
                return isInputReady
            } catch {
                guard capturePreparationIsCurrent(preparationGeneration, mode: expectedMode) else {
                    discardResourcesFromStaleCapturePreparation(
                        preparationGeneration,
                        expectedMode: expectedMode
                    )
                    return false
                }
                let message = keyboardAudioStatusMessage(for: error)
                if surfaceAudioSessionErrors {
                    if IOSRecordingAudioSession.isPriorityConflict(error) {
                        appLog.notice("setKeyboardStandby: \(message, privacy: .public)")
                        startSilentStandbyKeeperIfNeeded()
                        if !preserveCommandStatus {
                            publishKeyboardStatus(.idle, message: message)
                        }
                    } else {
                        errorMessage = "Keyboard audio session unavailable: \(message)"
                        appLog.error("setKeyboardStandby: \(self.errorMessage ?? message, privacy: .public)")
                        if !preserveCommandStatus {
                            publishKeyboardStatus(.error, message: errorMessage)
                        }
                    }
                } else {
                    // App bootstrap uses keyboard standby as a best-effort
                    // prewarm. Audio-session activation can legitimately fail
                    // while iOS is settling routes after launch; keep the local
                    // bridge/silent standby available and let the keyboard mic
                    // handoff surface any real user-action failure.
                    appLog.notice("setKeyboardStandby bootstrap deferred: \(message, privacy: .public)")
                    startSilentStandbyKeeperIfNeeded()
                    if !preserveCommandStatus {
                        publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
                    }
                }
                return false
            }
        } else {
            _ = beginCapturePreparation()
            keyboardStandbyEnabled = false
            hostAudioSessionExpiryTask?.cancel()
            hostAudioSessionExpiryTask = nil
            cancelKeyboardStandbyRefresh()
            stopKeyboardStatusAudioLevelPush()
            keyboardServer.stop()
            pipDictationCoordinator.stop()
            standbyKeeper.stop()
            keyboardAudioSession.stop(discardInputEngine: true)
            publishKeyboardStatus(.idle)
            return false
        }
    }

    private var isKeyboardHostSessionActive: Bool {
        isKeyboardAudioHostSessionActive
            || (keyboardDictationCaptureMode == .pictureInPicture && pipDictationCoordinator.isActive)
    }

    private var isKeyboardAudioHostSessionActive: Bool {
        standbyKeeper.isActive || keyboardAudioSession.isActive
    }

    private var isSelectedKeyboardCaptureReady: Bool {
        guard keyboardServer.isRunning else { return false }
        switch keyboardDictationCaptureMode {
        case .backgroundMic:
            return isKeyboardAudioHostSessionActive
        case .pictureInPicture:
            return pipDictationCoordinator.isActive
        }
    }

    private func shouldReportKeyboardCaptureNotReady(for status: KeyboardBridgeStatus) -> Bool {
        switch status.state {
        case .recording, .sending, .result, .error:
            return false
        case .idle, .standby:
            return !isSelectedKeyboardCaptureReady
        }
    }

    private func keyboardCaptureNotReadyStatus(from status: KeyboardBridgeStatus) -> KeyboardBridgeStatus {
        KeyboardBridgeStatus(
            commandID: status.commandID,
            state: .idle,
            message: keyboardMicrophonePreparationMessage,
            defaultCorrectionMode: status.defaultCorrectionMode,
            backendReachable: status.backendReachable,
            correctionTimeoutMs: status.correctionTimeoutMs
        )
    }

    private func prepareKeyboardInputStandby(
        requestMicrophoneIfNeeded: Bool,
        warmInputEngine: Bool = true,
        waitForApplicationActive: Bool = true,
        preparationGeneration: UInt64? = nil,
        expectedMode: KeyboardDictationCaptureMode? = nil
    ) async throws -> Bool {
        func validatePreparation() throws {
            let isValid = preparationGeneration.map {
                capturePreparationIsCurrent($0, mode: expectedMode)
            }
                ?? (capturePreparationIsAuthorized && keyboardStandbyEnabled && !Task.isCancelled)
            guard isValid else { throw CancellationError() }
        }
        try validatePreparation()
        if keyboardAudioSession.isActive {
            keyboardAudioUnavailableMessage = nil
            startKeyboardSessionKeepAlive()
            return true
        }

        // Music-priority: passive/idle standby (cold launch) keeps only the
        // silent keeper, so it never activates play-and-record (which forces
        // Bluetooth to HFP / interrupts other audio). Paths that actually start
        // a recording pass warmInputEngine: true, so the inactive→record cold
        // start still works.
        guard warmInputEngine else { return false }

        if waitForApplicationActive,
           !(await waitUntilApplicationIsActive(timeout: requestMicrophoneIfNeeded ? 3.0 : 1.0)) {
            appLog.notice("prepareKeyboardInputStandby: app did not become active before audio start; continuing with activation retry")
        }
        try validatePreparation()

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            let reuseActiveSession = standbyKeeper.isActive
            standbyKeeper.stop(deactivateSession: false)
            try await keyboardAudioSession.start(reuseActiveSession: reuseActiveSession)
            do {
                try validatePreparation()
            } catch {
                let lostExclusiveOwnership = !keyboardStandbyEnabled
                    || !capturePreparationIsAuthorized
                    || expectedMode.map({ $0 != keyboardDictationCaptureMode }) == true
                if lostExclusiveOwnership,
                   captureStartInFlightGeneration == nil,
                   activeCaptureGeneration == nil,
                   !hasAnyActiveRecordingCapture {
                    keyboardAudioSession.stop(discardInputEngine: true)
                }
                throw error
            }
            keyboardAudioUnavailableMessage = nil
            startKeyboardSessionKeepAlive()
            return true
        case .undetermined:
            guard requestMicrophoneIfNeeded else { return false }
            guard await requestMicrophonePermission() == .granted else { return false }
            try validatePreparation()
            let reuseActiveSession = standbyKeeper.isActive
            standbyKeeper.stop(deactivateSession: false)
            try await keyboardAudioSession.start(reuseActiveSession: reuseActiveSession)
            do {
                try validatePreparation()
            } catch {
                let lostExclusiveOwnership = !keyboardStandbyEnabled
                    || !capturePreparationIsAuthorized
                    || expectedMode.map({ $0 != keyboardDictationCaptureMode }) == true
                if lostExclusiveOwnership,
                   captureStartInFlightGeneration == nil,
                   activeCaptureGeneration == nil,
                   !hasAnyActiveRecordingCapture {
                    keyboardAudioSession.stop(discardInputEngine: true)
                }
                throw error
            }
            keyboardAudioUnavailableMessage = nil
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
        scheduleHostAudioSessionExpiry()
    }

    private func scheduleHostAudioSessionExpiry() {
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        guard keyboardStandbyEnabled,
              isKeyboardAudioHostSessionActive,
              let seconds = hostAudioSessionLength.seconds
        else { return }

        hostAudioSessionExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireHostAudioSessionIfIdle()
        }
    }

    private func expireHostAudioSessionIfIdle() {
        guard keyboardStandbyEnabled, isKeyboardAudioHostSessionActive else { return }
        guard !keyboardAudioSession.isRecording,
              !recorder.isRecording,
              !phase.isBusy
        else {
            scheduleHostAudioSessionExpiry()
            return
        }
        keyboardServer.stop()
        standbyKeeper.stop()
        publishKeyboardStatus(.idle, message: "Host audio session expired")
        if keyboardAudioSession.isActive {
            keyboardAudioSession.stop()
        }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
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

    private func ensureMicrophonePermissionForUserAction(captureGeneration generation: UInt64) async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            switch await requestMicrophonePermission() {
            case .granted:
                return true
            case .denied:
                guard isCaptureGenerationCurrent(generation) else { return false }
                setFailure("Microphone permission is required.")
                return false
            case .unavailable:
                return false
            }
        case .denied:
            guard isCaptureGenerationCurrent(generation) else { return false }
            setFailure("Microphone permission is required. Enable it in Settings.")
            await openAppSettingsForMicrophone()
            return false
        @unknown default:
            guard isCaptureGenerationCurrent(generation) else { return false }
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
        if let keyboardAudioUnavailableMessage {
            return keyboardAudioUnavailableMessage
        }
        return AVAudioApplication.shared.recordPermission == .denied
            ? "Microphone permission is required."
            : "Open Typeforme to prepare dictation."
    }

    private func keyboardAudioStatusMessage(for error: Error) -> String {
        if IOSRecordingAudioSession.isPriorityConflict(error) {
            keyboardAudioUnavailableMessage = "Microphone is in use by another app."
            return keyboardAudioUnavailableMessage ?? error.localizedDescription
        }
        return error.localizedDescription
    }

    private func openAppSettingsForMicrophone() async {
        guard await waitUntilApplicationIsActive() else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        _ = await UIApplication.shared.open(url)
    }

    // MARK: - Live partial preview
    //
    // Starts the selected preview source alongside the keyboard audio session
    // so the user sees their words appear as they speak. Preview text never
    // replaces the Mac result; it is held only until the final result arrives.
    //
    // Gating: this only runs when the user enables live preview and the selected
    // source is usable for the current recording. Unsupported sources fail
    // closed for the current session; no other source is selected implicitly.

    @discardableResult
    private func startLivePartialPreviewIfAvailable() -> Bool {
        // Tear down anything previous so re-press never leaks tasks.
        teardownLivePartialPreview(clearText: true)
        let generation = nextLivePreviewGeneration()

        guard keyboardLivePreviewEnabled else {
            appLog.debug("live preview skipped: disabled")
            return false
        }
        if correctionMode == .fast {
            guard let macSettings, macSettings.fastASRReadiness.ready else {
                appLog.debug("live preview skipped: Fast ASR source unavailable")
                return false
            }
            switch macSettings.fastRecognitionSource {
            case .appleSpeech:
                return startAppleSpeechLivePreviewIfAvailable(generation: generation)
            case .qwen:
                return startServerASRLivePreviewIfAvailable(source: .qwen, generation: generation)
            case .nvidiaNemotron:
                return startServerASRLivePreviewIfAvailable(source: .nvidiaNemotron, generation: generation)
            }
        }
        guard isKeyboardLivePreviewSourceEnabled(keyboardLivePreviewSource) else {
            appLog.debug("live preview skipped: source disabled")
            return false
        }
        switch keyboardLivePreviewSource {
        case .appleSpeech:
            return startAppleSpeechLivePreviewIfAvailable(generation: generation)
        case .qwen, .nvidiaNemotron:
            return startServerASRLivePreviewIfAvailable(
                source: keyboardLivePreviewSource,
                generation: generation
            )
        }
    }

    @discardableResult
    private func startAppleSpeechLivePreviewIfAvailable(generation: UInt64) -> Bool {
        let primaryID = activeLanguageIDs.first ?? "en-US"
        let capability = AppleSpeechPreviewSupport.capability(languageID: primaryID)
        guard keyboardLivePreviewRecognitionMode.canUse(capability) else {
            appLog.notice("live preview skipped: unsupported locale=\(primaryID, privacy: .public) mode=\(self.keyboardLivePreviewRecognitionMode.rawValue, privacy: .public)")
            return false
        }
        let locale = Locale(identifier: primaryID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            appLog.notice("live preview skipped: recognizer unavailable locale=\(primaryID, privacy: .public)")
            return false
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            break
        case .notDetermined:
            // First use: request silently. We do not block the current recording
            // on the prompt — preview just stays off this session. Subsequent
            // recordings benefit if the user grants.
            SFSpeechRecognizer.requestAuthorization { _ in }
            appLog.notice("live preview skipped: speech permission not determined")
            return false
        case .denied, .restricted:
            appLog.notice("live preview skipped: speech permission denied or restricted")
            return false
        @unknown default:
            appLog.notice("live preview skipped: unknown speech permission")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = capability.supportsOnDevicePreview || !keyboardLivePreviewRecognitionMode.allowsCloud
        request.addsPunctuation = (macSettings?.punctuationPreference ?? .normal) != .spaces

        liveSpeechRecognizer = recognizer
        liveSpeechRequest = request
        let requestSink = LiveSpeechRequestSink(request: request)
        liveSpeechRequestSink = requestSink
        let trace = LivePreviewTrace()
        livePreviewTrace = trace
        appLog.notice("live preview started: locale=\(primaryID, privacy: .public), mode=\(self.keyboardLivePreviewRecognitionMode.rawValue, privacy: .public), onDevice=\(request.requiresOnDeviceRecognition, privacy: .public)")
        liveSpeechTask = recognizer.recognitionTask(with: request) { [weak self, trace] result, error in
            // The task callback runs off the main actor — hop back before
            // touching state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.livePreviewGeneration == generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let timing = trace.recordPartial()
                        if timing.isFirst {
                            appLog.debug(
                                "live preview first partial: startToPartialMs=\(timing.startToPartialMS, privacy: .public), firstPCMToPartialMs=\(timing.firstPCMToPartialMS ?? -1, privacy: .public), pcmBuffers=\(timing.pcmBufferCount, privacy: .public), chars=\(text.count, privacy: .public)"
                            )
                        }
                        self.updateLivePartialTranscript(text, source: "apple")
                    }
                }
                if error != nil {
                    appLog.notice("live preview stopped: error=\(error?.localizedDescription ?? "unknown", privacy: .public)")
                    self.teardownLivePartialPreview(clearText: false)
                }
            }
        }

        keyboardAudioSession.onPCMBuffer = { [requestSink, trace] buffer in
            requestSink.append(buffer)
            let timing = trace.recordPCM()
            if timing.isFirst {
                appLog.debug(
                    "live preview first pcm: startToPCMms=\(timing.startToPCMMS, privacy: .public), buffers=\(timing.count, privacy: .public), sampleRate=\(buffer.format.sampleRate, privacy: .public), frames=\(buffer.frameLength, privacy: .public)"
                )
            }
        }
        return true
    }

    @discardableResult
    private func startServerASRLivePreviewIfAvailable(
        source: KeyboardLivePreviewSource,
        generation: UInt64
    ) -> Bool {
        guard isKeyboardLivePreviewSourceEnabled(source) else {
            appLog.debug("server live preview skipped: server ASR preview disabled")
            return false
        }
        guard let bridgeLivePreviewSource = source.bridgeLivePreviewSource else {
            appLog.debug("server live preview skipped: local source selected")
            return false
        }
        guard let baseURL = routeStatus.activeURL else {
            appLog.debug("server live preview skipped: no active bridge route")
            return false
        }

        let trace = LivePreviewTrace()
        livePreviewTrace = trace
        let client = BridgeClient(baseURL: baseURL, token: config.token)
        let streamer = BridgeLivePreviewStreamer(
            client: client,
            languageIDs: activeLanguageIDs,
            correctionMode: correctionMode,
            livePreviewSource: bridgeLivePreviewSource,
            clientJobID: activeBridgeDictateJobID,
            onTranscript: { [weak self, trace] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.livePreviewGeneration == generation else { return }
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return }
                    let timing = trace.recordPartial()
                    if timing.isFirst {
                        appLog.debug(
                            "server live preview first partial: startToPartialMs=\(timing.startToPartialMS, privacy: .public), firstPCMToPartialMs=\(timing.firstPCMToPartialMS ?? -1, privacy: .public), pcmBuffers=\(timing.pcmBufferCount, privacy: .public), chars=\(cleaned.count, privacy: .public)"
                        )
                    }
                    self.updateLivePartialTranscript(cleaned, source: bridgeLivePreviewSource.rawValue)
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.livePreviewGeneration == generation else { return }
                    appLog.notice("server live preview failed: \(message, privacy: .public)")
                    if self.serverLivePreviewStreamer != nil {
                        self.serverLivePreviewStreamer = nil
                    }
                    if self.keyboardLivePreviewSource == source {
                        self.keyboardAudioSession.onPCMBuffer = nil
                    }
                }
            }
        )
        serverLivePreviewStreamer = streamer
        appLog.notice("server live preview started source=\(bridgeLivePreviewSource.rawValue, privacy: .public)")
        keyboardAudioSession.onPCMBuffer = { [streamer, trace] buffer in
            streamer.append(buffer)
            let timing = trace.recordPCM()
            if timing.isFirst {
                appLog.debug(
                    "server live preview first pcm: startToPCMms=\(timing.startToPCMMS, privacy: .public), buffers=\(timing.count, privacy: .public), sampleRate=\(buffer.format.sampleRate, privacy: .public), frames=\(buffer.frameLength, privacy: .public)"
                )
            }
        }
        streamer.start()
        return true
    }

    /// Called when the user stops recording. We close the audio side of the
    /// request/stream so it finalises its last partial, but keep the resulting
    /// text on screen until a final ASR/correction result replaces it.
    private func endLivePartialPreviewAudio() async {
        keyboardAudioSession.onPCMBuffer = nil
        liveSpeechRequestSink?.endAudio()
        _ = await serverLivePreviewStreamer?.finishAndWait(timeout: Self.livePreviewFinishWaitTimeout)
        serverLivePreviewStreamer = nil
    }

    private func applyASRFinalPreview(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        teardownLivePartialPreview(clearText: false)
        livePartialTranscript = text
    }

    private func updateLivePartialTranscript(_ text: String, source: String) {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        let current = livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLikelyLivePartialSuffixRegression(candidate: candidate, current: current) {
            appLog.debug(
                "live preview partial ignored source=\(source, privacy: .public) reason=suffix_regression current_chars=\(current.count, privacy: .public) candidate_chars=\(candidate.count, privacy: .public)"
            )
            return
        }
        guard candidate != current else { return }
        livePartialTranscript = candidate
        publishLivePartialTranscriptToKeyboard()
    }

    private static func isLikelyLivePartialSuffixRegression(candidate: String, current: String) -> Bool {
        guard candidate.count < current.count else { return false }
        let normalizedCandidate = livePartialComparisonText(candidate)
        let normalizedCurrent = livePartialComparisonText(current)
        guard normalizedCandidate.count >= 4,
              normalizedCurrent.count > normalizedCandidate.count
        else { return false }
        if normalizedCurrent.hasSuffix(normalizedCandidate) {
            return true
        }
        let lengthRatio = Double(normalizedCandidate.count) / Double(normalizedCurrent.count)
        guard lengthRatio <= 0.75 else { return false }
        return livePartialTailSimilarity(current: normalizedCurrent, candidate: normalizedCandidate) >= 0.75
    }

    private static func livePartialComparisonText(_ text: String) -> String {
        var result = ""
        let keptScalars = CharacterSet.alphanumerics
        let ignoredScalars = CharacterSet.whitespacesAndNewlines
        for scalar in text.unicodeScalars {
            if ignoredScalars.contains(scalar) {
                continue
            }
            if keptScalars.contains(scalar) {
                result.append(String(scalar))
            }
        }
        return result.lowercased()
    }

    private static func livePartialTailSimilarity(current: String, candidate: String) -> Double {
        let currentCharacters = Array(current)
        let candidateCharacters = Array(candidate)
        guard !candidateCharacters.isEmpty,
              currentCharacters.count >= candidateCharacters.count
        else { return 0 }
        let suffix = currentCharacters.suffix(candidateCharacters.count)
        let matches = zip(suffix, candidateCharacters).reduce(0) { count, pair in
            count + (pair.0 == pair.1 ? 1 : 0)
        }
        return Double(matches) / Double(candidateCharacters.count)
    }

    /// Called after a final ASR/correction result owns the display. Tears down
    /// the preview source and optionally clears the on-screen partial.
    private func teardownLivePartialPreview(clearText: Bool) {
        _ = nextLivePreviewGeneration()
        keyboardAudioSession.onPCMBuffer = nil
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        liveSpeechRequestSink?.close()
        liveSpeechRequestSink = nil
        liveSpeechRequest = nil
        liveSpeechRecognizer = nil
        serverLivePreviewStreamer?.cancel()
        serverLivePreviewStreamer = nil
        livePreviewTrace = nil
        if clearText {
            livePartialTranscript = ""
            publishLivePartialTranscriptToKeyboard()
        }
    }

    private func nextLivePreviewGeneration() -> UInt64 {
        livePreviewGeneration &+= 1
        return livePreviewGeneration
    }

    private func configureKeyboardServer() {
        keyboardServer.expectedTokenProvider = { [weak self] in
            await MainActor.run { self?.keyboardBridgeToken }
        }
        keyboardServer.statusProvider = { [weak self] in
            guard let self else { return .idle }
            return await MainActor.run {
                self.markKeyboardEverContacted()
                self.reconcileStaleRecordingStateIfNeeded(
                    message: "Recording stopped because the audio session ended."
                )
                let base = self.keyboardBridgeStatus
                let status: KeyboardBridgeStatus
                if self.shouldReportKeyboardCaptureNotReady(for: base) {
                    status = self.keyboardCaptureNotReadyStatus(from: base)
                } else if base.state == .recording {
                    let level = self.keyboardAudioSession.isRecording
                        ? self.keyboardAudioSession.level
                        : self.recorder.level
                    status = base.withAudioLevel(level)
                } else {
                    status = base
                }
                return self.nextKeyboardStatusFrame(status)
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

    @discardableResult
    private func ensureKeyboardLocalBridgeReady(
        reason: String,
        showErrors: Bool,
        forceProbe: Bool
    ) async -> Bool {
        configureKeyboardServer()
        let result = await keyboardServer.ensureReady(reason: reason, forceProbe: forceProbe)
        appLog.notice("keyboard bridge ensure result reason=\(reason, privacy: .public) ready=\(result.ready, privacy: .public) state=\(result.listenerState, privacy: .public) generation=\(result.generation, privacy: .public) restarted=\(result.restarted, privacy: .public) probe=\(result.selfProbeSucceeded, privacy: .public) elapsed_ms=\(result.elapsedMilliseconds, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "bridge_ensure_result",
            fields: result.diagnosticFields.merging(["reason": reason]) { current, _ in current }
        )
        if !result.ready, showErrors {
            let message = NSLocalizedString("Keyboard bridge is unavailable.", comment: "Keyboard local bridge unavailable")
            errorMessage = result.failureReason.map { "\(message) \($0)" } ?? message
            publishKeyboardStatus(.error, message: errorMessage)
        }
        return result.ready
    }

    private func postKeyboardCommandReceipt(
        commandID: String,
        action: KeyboardBridgeCommandAction,
        phase: KeyboardCommandReceiptPhase,
        reason: String? = nil
    ) {
        let receipt = KeyboardCommandReceipt(
            commandID: commandID,
            action: action,
            phase: phase,
            reason: reason
        )
        let saved = KeyboardSharedDefaults.saveCommandReceipt(receipt)
        appLog.notice("keyboard command receipt phase=\(phase.rawValue, privacy: .public) saved=\(saved, privacy: .public) command_id=\(commandID, privacy: .public) reason=\(reason ?? "none", privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: phase == .accepted ? "darwin_start_receipt_posted" : "command_receipt_posted",
            fields: [
                "command_id": commandID,
                "action": action.rawValue,
                "phase": phase.rawValue,
                "reason": reason ?? "none",
                "saved": "\(saved)",
            ]
        )
        guard saved else { return }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.commandReceiptUpdated)
    }

    private func postKeyboardCaptureNotReadyReceipt(commandID: String?, reason: String) {
        appLog.notice("keyboard capture not ready command_id=\(commandID ?? "none", privacy: .public) reason=\(reason, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "capture_not_ready",
            fields: [
                "command_id": commandID ?? "none",
                "reason": reason,
            ]
        )
        guard let commandID else { return }
        postKeyboardCommandReceipt(
            commandID: commandID,
            action: .start,
            phase: .captureNotReady,
            reason: reason
        )
    }

    private func postKeyboardRecordingStartedReceipt(commandID: String?, reason: String) {
        guard let commandID else { return }
        postKeyboardCommandReceipt(
            commandID: commandID,
            action: .start,
            phase: .recordingStarted,
            reason: reason
        )
    }

    /// Called when ANY keyboard → host signal arrives (local bridge connect,
    /// status stream subscription, command). Setting this flag is the only way the host
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

    private func consumeKeyboardHostIssue() {
        guard let issue = KeyboardSharedDefaults.consumeKeyboardHostIssue() else { return }
        let message = issue.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        errorMessage = message
        appLog.error(
            "keyboard issue reported command_id=\(issue.commandID ?? "none", privacy: .public) message=\(message, privacy: .public)"
        )
    }

    private func clearKeyboardCaptureContext() {
        activeKeyboardTextEditContext = nil
        activeKeyboardDictationContext = nil
        keyboardCaptureStartedFromKeyboard = false
        activeKeyboardRecordingCommandID = nil
        activeBridgeDictateJobID = nil
    }

    private func keyboardStartCommandIsAuthorized(_ commandID: String) -> Bool {
        if isConfigured { return true }
#if DEBUG && targetEnvironment(simulator)
        return simulatorDebugAllowsUnpairedCommand(commandID)
#else
        return false
#endif
    }

    private func keyboardCaptureOperationBelongs(to commandID: String) -> Bool {
        if case .keyboard(commandID: let activeCommandID) = activeCaptureOwner,
           activeCommandID == commandID {
            return true
        }
        if case .keyboard(commandID: let startingCommandID) = captureStartInFlightOwner,
           startingCommandID == commandID {
            return true
        }
        return false
    }

    private var hasKeyboardCaptureOperation: Bool {
        if case .keyboard = activeCaptureOwner { return true }
        if case .keyboard = captureStartInFlightOwner { return true }
        return false
    }

    @discardableResult
    private func rememberCanceledKeyboardCommand(_ commandID: String) -> Bool {
        guard !commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pruneCanceledKeyboardCommands()
        let isNew = canceledKeyboardCommandIDs[commandID] == nil
        canceledKeyboardCommandIDs[commandID] = Date().timeIntervalSince1970
        return isNew
    }

    private func isKeyboardCommandCanceled(_ commandID: String) -> Bool {
        pruneCanceledKeyboardCommands()
        return canceledKeyboardCommandIDs[commandID] != nil
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
        let keyboardIssueObserver = KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.keyboardIssueReported) { [weak self] in
            Task { @MainActor [weak self] in
                self?.consumeKeyboardHostIssue()
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
            keyboardDarwinObservers = [fullAccessObserver, keyboardIssueObserver]
            return
        }
        keyboardDarwinObservers = [
            fullAccessObserver,
            keyboardIssueObserver,
            KeyboardDarwinBridge.observe(requestStartName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markKeyboardEverContacted()
                    appLog.notice("darwin requestStart received mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) standby=\(self.keyboardStandbyEnabled, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public) keyboard_recording=\(self.keyboardAudioSession.isRecording, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) bridge_state=\(self.keyboardBridgeStatus.state.rawValue, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "darwin_request_start_received",
                        fields: [
                            "mode": self.keyboardDictationCaptureMode.rawValue,
                            "standby": "\(self.keyboardStandbyEnabled)",
                            "keyboard_active": "\(self.keyboardAudioSession.isActive)",
                            "keyboard_recording": "\(self.keyboardAudioSession.isRecording)",
                            "pip_active": "\(self.pipDictationCoordinator.isActive)",
                            "bridge_state": self.keyboardBridgeStatus.state.rawValue,
                        ]
                    )
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else {
                        appLog.notice("darwin requestStart ignored: standby disabled and keyboard audio not recording")
                        KeyboardDiagnosticEventLog.record(
                            source: "host-app",
                            event: "darwin_request_start_ignored_standby_disabled"
                        )
                        return
                    }
                    guard let command = KeyboardSharedDefaults.consumeDarwinCommand(action: .start) else {
                        appLog.notice("darwin requestStart failed: command missing or expired")
                        KeyboardDiagnosticEventLog.record(
                            source: "host-app",
                            event: "darwin_request_start_missing_command"
                        )
                        if !self.hasKeyboardCaptureOperation,
                           !self.isStopAndSendInFlight {
                            self.publishKeyboardStatus(.error, message: "Keyboard start command expired")
                        }
                        return
                    }
                    appLog.notice("darwin requestStart command consumed command_id=\(command.id, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "darwin_request_start_command_consumed",
                        fields: ["command_id": command.id]
                    )
                    guard self.keyboardStartCommandIsAuthorized(command.id) else {
                        self.postKeyboardCommandReceipt(
                            commandID: command.id,
                            action: .start,
                            phase: .failed,
                            reason: "not_paired"
                        )
                        self.publishKeyboardStatus(
                            .error,
                            commandID: command.id,
                            message: "Pair Typeforme with your Mac before dictating."
                        )
                        KeyboardDiagnosticEventLog.record(
                            source: "host-app",
                            event: "start_keyboard_recording_failed_not_paired",
                            fields: ["command_id": command.id]
                        )
                        return
                    }
                    self.postKeyboardCommandReceipt(
                        commandID: command.id,
                        action: .start,
                        phase: .accepted,
                        reason: "darwin_start_received"
                    )
                    guard !self.isKeyboardCommandCanceled(command.id) else {
                        appLog.notice("darwin requestStart command was canceled command_id=\(command.id, privacy: .public)")
                        KeyboardDiagnosticEventLog.record(
                            source: "host-app",
                            event: "darwin_request_start_command_cancelled",
                            fields: ["command_id": command.id]
                        )
                        return
                    }
                    let readinessGeneration = self.captureGeneration
                    let bridgeReady = await self.ensureKeyboardLocalBridgeReady(
                        reason: "darwin_start",
                        showErrors: false,
                        forceProbe: true
                    )
                    guard self.isCaptureGenerationCurrent(readinessGeneration),
                          self.keyboardStandbyEnabled,
                          !self.audioSessionInterruptionActive,
                          !self.isKeyboardCommandCanceled(command.id)
                    else {
                        if !self.isKeyboardCommandCanceled(command.id) {
                            self.postKeyboardCommandReceipt(
                                commandID: command.id,
                                action: .start,
                                phase: .failed,
                                reason: "readiness_invalidated"
                            )
                        }
                        return
                    }
                    self.postKeyboardCommandReceipt(
                        commandID: command.id,
                        action: .start,
                        phase: bridgeReady ? .bridgeReady : .bridgeUnavailable,
                        reason: bridgeReady ? "bridge_ready" : "bridge_unavailable"
                    )
                    guard bridgeReady else {
                        self.publishKeyboardStatus(
                            .error,
                            commandID: command.id,
                            message: "Keyboard bridge is unavailable. Please try again."
                        )
                        return
                    }
                    await self.startKeyboardRecording(command: command, allowSessionStart: true)
                }
            },
            KeyboardDarwinBridge.observe(requestStopName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else { return }
                    guard let command = KeyboardSharedDefaults.consumeDarwinCommand(action: .stop)
                    else {
                        appLog.notice("darwin requestStop ignored: command missing or expired")
                        return
                    }
                    self.rememberCanceledKeyboardCommand(command.id)
                    guard self.keyboardCaptureOperationBelongs(to: command.id) else {
                        appLog.notice("darwin requestStop ignored: command does not own capture command_id=\(command.id, privacy: .public)")
                        return
                    }
                    _ = self.beginKeyboardStopAndSend(commandID: command.id)
                }
            },
            KeyboardDarwinBridge.observe(requestCancelName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let command = KeyboardSharedDefaults.consumeDarwinCommand(action: .cancel)
                    else { return }
                    guard self.rememberCanceledKeyboardCommand(command.id) else {
                        return
                    }
                    guard self.keyboardCaptureOperationBelongs(to: command.id) else {
                        appLog.notice("darwin requestCancel ignored: command does not own capture command_id=\(command.id, privacy: .public)")
                        return
                    }
                    await self.cancelActiveRecordingWithoutSending(
                        hostFailureMessage: nil,
                        keyboardCommandID: command.id,
                        keyboardMessage: "Ready",
                        resumeKeyboardStandby: true
                    )
                }
            },
            KeyboardDarwinBridge.observe(requestSessionStatusName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    appLog.notice("darwin requestSessionStatus received should_report=\(self.shouldReportKeyboardSessionStarted, privacy: .public) keyboard_recording=\(self.keyboardAudioSession.isRecording, privacy: .public) mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) bridge_state=\(self.keyboardBridgeStatus.state.rawValue, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "darwin_request_session_status_received",
                        fields: [
                            "should_report": "\(self.shouldReportKeyboardSessionStarted)",
                            "keyboard_recording": "\(self.keyboardAudioSession.isRecording)",
                            "mode": self.keyboardDictationCaptureMode.rawValue,
                            "pip_active": "\(self.pipDictationCoordinator.isActive)",
                            "bridge_state": self.keyboardBridgeStatus.state.rawValue,
                        ]
                    )
                    if self.shouldReportKeyboardSessionStarted {
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
                    }
                    if self.keyboardAudioSession.isRecording {
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
                    }
                }
            },
        ]
    }

    private var shouldReportKeyboardSessionStarted: Bool {
        if isSelectedKeyboardCaptureReady {
            return true
        }
        guard keyboardServer.isRunning else { return false }
        switch keyboardBridgeStatus.state {
        case .recording, .sending, .result:
            return true
        case .standby, .idle, .error:
            return false
        }
    }

    private func handleKeyboardCommand(_ command: KeyboardBridgeCommand) async -> KeyboardBridgeStatus {
        appLog.notice("local keyboard command received action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public) mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) standby=\(self.keyboardStandbyEnabled, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public) keyboard_recording=\(self.keyboardAudioSession.isRecording, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) bridge_state=\(self.keyboardBridgeStatus.state.rawValue, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "local_keyboard_command_received",
            fields: [
                "action": command.action.rawValue,
                "command_id": command.id,
                "mode": self.keyboardDictationCaptureMode.rawValue,
                "standby": "\(self.keyboardStandbyEnabled)",
                "keyboard_active": "\(self.keyboardAudioSession.isActive)",
                "keyboard_recording": "\(self.keyboardAudioSession.isRecording)",
                "pip_active": "\(self.pipDictationCoordinator.isActive)",
                "bridge_state": self.keyboardBridgeStatus.state.rawValue,
            ]
        )
        guard keyboardStandbyEnabled || keyboardAudioSession.isRecording else {
            appLog.notice("local keyboard command rejected: standby disabled action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "local_keyboard_command_rejected_standby_disabled",
                fields: [
                    "action": command.action.rawValue,
                    "command_id": command.id,
                ]
            )
            publishKeyboardStatus(.idle, commandID: command.id, message: "Keyboard standby is off")
            return keyboardBridgeStatus
        }
        guard Date().timeIntervalSince1970 - command.createdAt < 60 else {
            appLog.notice("local keyboard command rejected: expired action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "local_keyboard_command_rejected_expired",
                fields: [
                    "action": command.action.rawValue,
                    "command_id": command.id,
                ]
            )
            publishKeyboardStatus(.error, commandID: command.id, message: "Keyboard command expired")
            return keyboardBridgeStatus
        }
        if !isConfigured
            && (command.action == .start || command.action == .refineText) {
            publishKeyboardStatus(
                .error,
                commandID: command.id,
                message: "Pair Typeforme with your Mac before dictating."
            )
            return keyboardBridgeStatus
        }
        switch command.action {
        case .start:
            guard !isKeyboardCommandCanceled(command.id) else {
                appLog.notice("local start command canceled command_id=\(command.id, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "local_start_command_cancelled",
                    fields: ["command_id": command.id]
                )
                return keyboardBridgeStatus
            }
            guard phase == .recording || phase.allowsRecordingStart else {
                appLog.notice("local start command busy command_id=\(command.id, privacy: .public) bridge_state=\(self.keyboardBridgeStatus.state.rawValue, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "local_start_command_busy",
                    fields: [
                        "command_id": command.id,
                        "bridge_state": self.keyboardBridgeStatus.state.rawValue,
                    ]
                )
                publishKeyboardBusyStatus(for: command.id)
                return keyboardBridgeStatus
            }
            await startKeyboardRecording(command: command, allowSessionStart: true)
        case .stop:
            rememberCanceledKeyboardCommand(command.id)
            return beginKeyboardStopAndSend(commandID: command.id)
        case .cancel:
            guard rememberCanceledKeyboardCommand(command.id) else {
                return keyboardBridgeStatus
            }
            guard keyboardCaptureOperationBelongs(to: command.id) else {
                appLog.notice("local cancel ignored: command does not own capture command_id=\(command.id, privacy: .public)")
                return keyboardBridgeStatus
            }
            await cancelActiveRecordingWithoutSending(
                hostFailureMessage: nil,
                keyboardCommandID: command.id,
                keyboardMessage: "Ready",
                resumeKeyboardStandby: true
            )
            resetCorrectionModeToDefault()
        case .configure:
            let preservesActiveCommand = hasKeyboardCaptureOperation
                || isStopAndSendInFlight
                || phase.isBusy
            if let requestedMode = CorrectionMode(rawValue: command.correctionMode) {
                applyKeyboardDefaultCorrectionMode(
                    requestedMode,
                    updateActiveCorrectionMode: !preservesActiveCommand
                )
            } else if !preservesActiveCommand {
                resetCorrectionModeToDefault()
            }
            if !preservesActiveCommand {
                publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
            }
        case .refineText:
            await refineKeyboardText(command)
        }
        return keyboardBridgeStatus
    }

    private func beginKeyboardStopAndSend(commandID: String) -> KeyboardBridgeStatus {
        guard keyboardCaptureOperationBelongs(to: commandID) else {
            appLog.notice("keyboard stop ignored: command does not own capture command_id=\(commandID, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "keyboard_stop_owner_mismatch",
                fields: [
                    "command_id": commandID,
                    "active_command_id": activeKeyboardRecordingCommandID ?? "none",
                ]
            )
            return keyboardBridgeStatus
        }
        if captureStartInFlightOwner == .keyboard(commandID: commandID),
           captureStartInFlightGeneration != nil {
            // Stop can race the async audio/PiP preparation before a physical
            // recorder exists. Invalidate that exact start now; every start
            // continuation is generation-gated and will discard any resource
            // it created after returning from its await.
            captureGeneration &+= 1
            queuedKeyboardStopCommandID = nil
            if phase == .preparing {
                setPhase(.idle)
            }
            publishKeyboardStatus(.standby, commandID: commandID, message: "Ready")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "keyboard_start_cancelled_by_early_stop",
                fields: ["command_id": commandID]
            )
            return keyboardBridgeStatus
        }
        let recognitionStageLabels = Self.recognitionStageLabels(for: activeKeyboardTextEditContext)
        if isStopAndSendInFlight || queuedKeyboardStopCommandID != nil {
            return keyboardBridgeStatus
        }
        guard keyboardAudioSession.isRecording || recorder.isRecording else {
            return keyboardBridgeStatus
        }

        queuedKeyboardStopCommandID = commandID
        publishKeyboardStatus(
            .sending,
            commandID: commandID,
            message: recognitionStageLabels.transcribing,
            processingStage: .transcribing
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopAndSend(keyboardCommandID: commandID)
            if self.queuedKeyboardStopCommandID == commandID {
                self.queuedKeyboardStopCommandID = nil
            }
        }
        return keyboardBridgeStatus
    }

    private func refineKeyboardText(_ command: KeyboardBridgeCommand) async {
        guard !isBusy else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Typeforme is busy")
            return
        }
        let requestedCorrectionMode = CorrectionMode(rawValue: command.correctionMode) ?? config.correctionMode
        let expectedPairingRevision = pairingRevision
        guard let source = command.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty
        else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Nothing to refine")
            return
        }
        let existingResultText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingGeneratedText = lastGeneratedResultText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRefiningCurrentDictationResult = source == existingResultText
            || source == existingGeneratedText
        let preservedRawTranscript = rawTranscript
        let preservedSessionID = sessionID
        let preservedRawSource = preservedRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let refineSessionID = isRefiningCurrentDictationResult ? preservedSessionID : nil
        let refineSource: String
        if isRefiningCurrentDictationResult && !preservedRawSource.isEmpty {
            refineSource = preservedRawSource
        } else {
            refineSource = source
        }
        correctionMode = requestedCorrectionMode

        publishKeyboardStatus(
            .sending,
            commandID: command.id,
            message: NSLocalizedString("Refining", comment: "Bridge job stage")
        )
        do {
            await refreshRoute(
                force: false,
                probeAllEndpoints: false,
                showIndicator: false,
                reason: "keyboard_refine_route"
            )
            let client = try await activeBridgeClient()
            setPhase(.refining)
            publishKeyboardStatus(
                .sending,
                commandID: command.id,
                message: NSLocalizedString("Refining", comment: "Bridge job stage"),
                processingStage: .refining
            )
            let refineJobID = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            let keyboardCommandID = command.id
            activeBridgeRefineJobID = refineJobID
            defer {
                if activeBridgeRefineJobID == refineJobID {
                    activeBridgeRefineJobID = nil
                }
            }
            let response = try await client.refine(
                sessionID: refineSessionID,
                rawTranscript: refineSource,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode,
                clientJobID: refineJobID,
                onJobEvent: { [weak self] event in
                    await MainActor.run {
                        guard let self,
                              event.jobID == refineJobID,
                              self.activeBridgeRefineJobID == refineJobID,
                              self.pairingRevision == expectedPairingRevision,
                              self.keyboardBridgeStatus.commandID == keyboardCommandID
                        else { return }
                        self.applyBridgeJobStatus(
                            event,
                            keyboardCommandID: keyboardCommandID,
                            shouldAdvanceToRefineWhenTranscriptionCompletes: true
                        )
                    }
                }
            )
            guard pairingRevision == expectedPairingRevision,
                  keyboardBridgeStatus.commandID == command.id
            else { throw CancellationError() }
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                publishKeyboardStatus(.error, commandID: command.id, message: errorMessage ?? "Empty result")
                return
            }

            resultText = text
            lastGeneratedResultText = text
            rawTranscript = isRefiningCurrentDictationResult ? preservedRawTranscript : ""
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
                message: Self.isCorrectionDegradedStatus(response.correctionStatus)
                    ? Self.degradedCorrectionMessage(for: .inserted, status: response.correctionStatus)
                    : "Refined",
                resultText: text,
                rawTranscriptLength: isRefiningCurrentDictationResult
                    ? preservedRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count
                    : nil
            )
        } catch {
            guard pairingRevision == expectedPairingRevision,
                  keyboardBridgeStatus.commandID == command.id
            else { return }
            // Invalidate the route cache on both auth and network errors so
            // the next keyboard-edit attempt re-probes.
            if shouldRetryBridgeRequest(after: error) {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
            publishKeyboardStatus(.error, commandID: command.id, message: error.localizedDescription)
        }
    }

    private func waitForPreviousKeyboardCommandToFinish(
        commandID: String?
    ) async -> Bool {
        guard !hasAnyActiveRecordingCapture,
              (captureStartInFlightGeneration != nil
                || isStopAndSendInFlight
                || activeCaptureGeneration != nil)
        else { return false }

        let startedAt = Date().timeIntervalSince1970
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "keyboard_start_waiting_previous_command",
            fields: ["command_id": commandID ?? "none"]
        )
        while captureStartInFlightGeneration != nil
                || isStopAndSendInFlight
                || activeCaptureGeneration != nil {
            guard !Task.isCancelled,
                  keyboardStandbyEnabled,
                  commandID.map({ !isKeyboardCommandCanceled($0) }) ?? true,
                  Date().timeIntervalSince1970 - startedAt < Self.keyboardStartFinalizationWaitTimeout
            else {
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "keyboard_start_previous_command_wait_failed",
                    fields: [
                        "command_id": commandID ?? "none",
                        "cancelled": "\(Task.isCancelled)",
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                    ]
                )
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        guard captureStartInFlightGeneration == nil,
              !hasAnyActiveRecordingCapture
        else { return false }
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "keyboard_start_previous_command_finished",
            fields: [
                "command_id": commandID ?? "none",
                "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
            ]
        )
        if let commandID {
            postKeyboardCommandReceipt(
                commandID: commandID,
                action: .start,
                phase: .bridgeReady,
                reason: "previous_command_finished"
            )
        }
        return true
    }

    private func startKeyboardRecording(
        command: KeyboardBridgeCommand,
        allowSessionStart: Bool
    ) async {
        let commandID: String? = command.id
        let startAttemptedAt = Date().timeIntervalSince1970
        let audioSession = AVAudioSession.sharedInstance()
        let otherAudioPlaying = audioSession.isOtherAudioPlaying
        let secondaryAudioSilenced = audioSession.secondaryAudioShouldBeSilencedHint
        appLog.notice("start keyboard recording begin command_id=\(commandID ?? "none", privacy: .public) allow_session_start=\(allowSessionStart, privacy: .public) mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public) keyboard_recording=\(self.keyboardAudioSession.isRecording, privacy: .public) bridge_state=\(self.keyboardBridgeStatus.state.rawValue, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "start_keyboard_recording_begin",
            fields: [
                "command_id": commandID ?? "none",
                "allow_session_start": "\(allowSessionStart)",
                "mode": self.keyboardDictationCaptureMode.rawValue,
                "pip_active": "\(self.pipDictationCoordinator.isActive)",
                "keyboard_active": "\(self.keyboardAudioSession.isActive)",
                "keyboard_recording": "\(self.keyboardAudioSession.isRecording)",
                "bridge_state": self.keyboardBridgeStatus.state.rawValue,
                "other_audio_playing": "\(otherAudioPlaying)",
                "secondary_audio_silenced": "\(secondaryAudioSilenced)",
            ]
        )
        let pendingTextEditContext = command.textEditContext
        let pendingDictationContext = command.dictationContext
        let pendingCorrectionMode = CorrectionMode(rawValue: command.correctionMode) ?? config.correctionMode
        if keyboardAudioSession.isRecording {
            guard phase == .recording,
                  activeCaptureOwner == .keyboard(commandID: commandID)
            else {
                appLog.notice("start keyboard recording busy: audio already recording but phase not recording command_id=\(commandID ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "start_keyboard_recording_busy_audio_already_recording",
                    fields: [
                        "command_id": commandID ?? "none",
                        "bridge_state": self.keyboardBridgeStatus.state.rawValue,
                    ]
                )
                publishKeyboardBusyStatus(for: commandID)
                return
            }
            keyboardCaptureStartedFromKeyboard = true
            publishKeyboardStatus(.recording, commandID: commandID, message: "Recording")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
            postKeyboardRecordingStartedReceipt(commandID: commandID, reason: "active_recording_reused")
            appLog.notice("start keyboard recording reused active recording command_id=\(commandID ?? "none", privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "start_keyboard_recording_reused_active_recording",
                fields: ["command_id": commandID ?? "none"]
            )
            return
        }
        let captureOwner = CaptureOwner.keyboard(commandID: commandID)
        var pendingGeneration = beginCaptureStart(owner: captureOwner)
        if pendingGeneration == nil,
           await waitForPreviousKeyboardCommandToFinish(commandID: commandID) {
            pendingGeneration = beginCaptureStart(owner: captureOwner)
        }
        guard let generation = pendingGeneration else {
            guard !Task.isCancelled else { return }
            appLog.notice("start keyboard recording busy command_id=\(commandID ?? "none", privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "start_keyboard_recording_busy",
                fields: [
                    "command_id": commandID ?? "none",
                    "bridge_state": keyboardBridgeStatus.state.rawValue,
                    "stop_and_send": "\(isStopAndSendInFlight)",
                ]
            )
            if let commandID {
                postKeyboardCommandReceipt(
                    commandID: commandID,
                    action: .start,
                    phase: .failed,
                    reason: "capture_busy"
                )
            } else {
                publishKeyboardBusyStatus(for: nil)
            }
            return
        }
        activeKeyboardTextEditContext = pendingTextEditContext
        activeKeyboardDictationContext = pendingDictationContext
        keyboardCaptureStartedFromKeyboard = true
        activeKeyboardRecordingCommandID = commandID
        applyKeyboardDefaultCorrectionMode(pendingCorrectionMode)
        defer {
            finishCaptureStart(generation)
            if isCaptureGenerationCurrent(generation),
               activeCaptureGeneration != generation,
               !hasAnyActiveRecordingCapture {
                scheduleKeyboardStandbyRefresh(delay: 0.15)
            }
        }
        let didStartVisibleCapture = await startSelectedVisibleCaptureMode(
            showErrors: false,
            honorManualSuppression: false
        )
        guard isCaptureGenerationCurrent(generation) else {
            discardResourcesFromInvalidatedCaptureStart(generation)
            return
        }
        appLog.notice("start keyboard recording visible capture result command_id=\(commandID ?? "none", privacy: .public) did_start=\(didStartVisibleCapture, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "start_keyboard_recording_visible_capture_result",
            fields: [
                "command_id": commandID ?? "none",
                "did_start": "\(didStartVisibleCapture)",
                "pip_active": "\(self.pipDictationCoordinator.isActive)",
            ]
        )
        if keyboardDictationCaptureMode == .pictureInPicture,
           !didStartVisibleCapture {
            appLog.notice("start keyboard recording failed: visible capture unavailable command_id=\(commandID ?? "none", privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "start_keyboard_recording_failed_visible_capture_unavailable",
                fields: [
                    "command_id": commandID ?? "none",
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                ]
            )
            postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "visible_capture_unavailable")
            clearKeyboardCaptureContext()
            resetCorrectionModeToDefault()
            publishKeyboardStatus(.idle, commandID: commandID, message: keyboardMicrophonePreparationMessage)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            return
        }
        if keyboardDictationCaptureMode == .pictureInPicture {
            await startPictureInPictureKeyboardRecording(
                commandID: commandID,
                startAttemptedAt: startAttemptedAt,
                generation: generation
            )
            return
        }
        if !keyboardAudioSession.isActive {
            guard allowSessionStart else {
                appLog.notice("start keyboard recording failed: audio inactive and session start not allowed command_id=\(commandID ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "start_keyboard_recording_failed_audio_inactive_session_start_not_allowed",
                    fields: [
                        "command_id": commandID ?? "none",
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                    ]
                )
                postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "audio_inactive_session_start_not_allowed")
                clearKeyboardCaptureContext()
                resetCorrectionModeToDefault()
                publishKeyboardStatus(.idle, commandID: commandID, message: "Keyboard audio session is not active")
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                return
            }
            do {
                let isInputReady = try await prepareKeyboardInputStandby(
                    requestMicrophoneIfNeeded: false,
                    waitForApplicationActive: keyboardDictationCaptureMode != .pictureInPicture
                )
                guard isCaptureGenerationCurrent(generation) else {
                    discardResourcesFromInvalidatedCaptureStart(generation)
                    return
                }
                guard isInputReady else {
                    appLog.notice("start keyboard recording failed: input standby not ready command_id=\(commandID ?? "none", privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "start_keyboard_recording_failed_input_standby_not_ready",
                        fields: [
                            "command_id": commandID ?? "none",
                            "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                        ]
                    )
                    postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "input_standby_not_ready")
                    clearKeyboardCaptureContext()
                    resetCorrectionModeToDefault()
                    startSilentStandbyKeeperIfNeeded()
                    publishKeyboardStatus(.idle, commandID: commandID, message: keyboardMicrophonePreparationMessage)
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                    return
                }
                scheduleHostAudioSessionExpiry()
            } catch {
                guard isCaptureGenerationCurrent(generation) else {
                    discardResourcesFromInvalidatedCaptureStart(generation)
                    return
                }
                clearKeyboardCaptureContext()
                resetCorrectionModeToDefault()
                let message = keyboardAudioStatusMessage(for: error)
                appLog.notice("start keyboard recording failed: standby error command_id=\(commandID ?? "none", privacy: .public) error=\(message, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "start_keyboard_recording_failed_standby_error",
                    fields: [
                        "command_id": commandID ?? "none",
                        "error": message,
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                    ]
                )
                postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "standby_error")
                if IOSRecordingAudioSession.isPriorityConflict(error) {
                    startSilentStandbyKeeperIfNeeded()
                    publishKeyboardStatus(.idle, commandID: commandID, message: message)
                } else {
                    setFailure(message)
                    publishKeyboardStatus(.error, commandID: commandID, message: message)
                }
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                return
            }
        }
        // Keep the keyboard press-to-record path local-only for the same reason.
        // No correctionMode reset here either — match the host orb path.
        // While recording, the input engine itself keeps the host alive. Stop the
        // silent output keeper so it cannot compete with the voice-processing
        // graph or keep rendering after the stop transition.
        standbyKeeper.stop(deactivateSession: false)
        do {
            try await beginPreparedKeyboardAudioRecording(
                commandID: commandID,
                startAttemptedAt: startAttemptedAt,
                generation: generation
            )
        } catch {
            guard isCaptureGenerationCurrent(generation) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            clearKeyboardCaptureContext()
            let message = keyboardAudioStatusMessage(for: error)
            appLog.notice("start keyboard recording failed: begin recording error command_id=\(commandID ?? "none", privacy: .public) error=\(message, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "start_keyboard_recording_failed_begin_recording_error",
                fields: [
                    "command_id": commandID ?? "none",
                    "error": message,
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                ]
            )
            postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "begin_recording_error")
            if IOSRecordingAudioSession.isPriorityConflict(error) {
                startSilentStandbyKeeperIfNeeded()
                publishKeyboardStatus(.idle, commandID: commandID, message: message)
            } else {
                setFailure(message)
                publishKeyboardStatus(.error, commandID: commandID, message: message)
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
    }
    }

    private func startPictureInPictureKeyboardRecording(
        commandID: String?,
        startAttemptedAt: TimeInterval,
        generation: UInt64
    ) async {
        do {
            if keyboardAudioSession.isActive, !keyboardAudioSession.isRecording {
                keyboardAudioSession.discardInactiveInputEngine(
                    deactivateSession: true,
                    reason: "pip_fresh_start"
                )
            }
            guard try await startPictureInPictureRecordingAudioSessionIfNeeded() else {
                appLog.notice("start keyboard recording failed: pip recording audio unavailable command_id=\(commandID ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "start_keyboard_recording_failed_pip_audio_unavailable",
                    fields: [
                        "command_id": commandID ?? "none",
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                    ]
                )
                postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "pip_audio_unavailable")
                clearKeyboardCaptureContext()
                resetCorrectionModeToDefault()
                publishKeyboardStatus(.idle, commandID: commandID, message: keyboardMicrophonePreparationMessage)
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                return
            }
            guard isCaptureGenerationCurrent(generation) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            try await beginPreparedKeyboardAudioRecording(
                commandID: commandID,
                startAttemptedAt: startAttemptedAt,
                generation: generation
            )
        } catch {
            guard isCaptureGenerationCurrent(generation) else {
                discardResourcesFromInvalidatedCaptureStart(generation)
                return
            }
            clearKeyboardCaptureContext()
            resetCorrectionModeToDefault()
            if !keyboardAudioSession.isRecording {
                keyboardAudioSession.discardInactiveInputEngine(
                    deactivateSession: true,
                    reason: "pip_start_error"
                )
            }
            let message = keyboardAudioStatusMessage(for: error)
            appLog.notice("start keyboard recording failed: pip recording audio error command_id=\(commandID ?? "none", privacy: .public) error=\(message, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "start_keyboard_recording_failed_pip_audio_error",
                fields: [
                    "command_id": commandID ?? "none",
                    "error": message,
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                ]
            )
            postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "pip_audio_error")
            if IOSRecordingAudioSession.isPriorityConflict(error) {
                publishKeyboardStatus(.idle, commandID: commandID, message: message)
            } else {
                setFailure(message)
                publishKeyboardStatus(.error, commandID: commandID, message: message)
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        }
    }

    private func startPictureInPictureRecordingAudioSessionIfNeeded() async throws -> Bool {
        if keyboardAudioSession.isActive {
            keyboardAudioUnavailableMessage = nil
            return true
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            try await keyboardAudioSession.startWithFreshInputEngine(reuseActiveSession: false)
            keyboardAudioUnavailableMessage = nil
            return true
        case .undetermined:
            return false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func beginPreparedKeyboardAudioRecording(
        commandID: String?,
        startAttemptedAt: TimeInterval,
        generation: UInt64
    ) async throws {
        _ = try await keyboardAudioSession.beginRecording()
        guard markCaptureActive(
            generation,
            owner: .keyboard(commandID: commandID)
        ) else { throw CancellationError() }
        keyboardCaptureStartedFromKeyboard = true
        activeBridgeDictateJobID = Self.newBridgeJobID()
        startLivePartialPreviewIfAvailable()
        acquireIdleTimer()
        setPhase(.recording)
        publishKeyboardStatus(.recording, commandID: commandID, message: "Recording")
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
        postKeyboardRecordingStartedReceipt(commandID: commandID, reason: "begin_recording_succeeded")
        appLog.notice("start keyboard recording succeeded command_id=\(commandID ?? "none", privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "start_keyboard_recording_succeeded",
            fields: [
                "command_id": commandID ?? "none",
                "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
            ]
        )
    }

    private func publishKeyboardBusyStatus(for commandID: String?) {
        let state: KeyboardBridgeState
        switch keyboardBridgeStatus.state {
        case .recording, .sending:
            state = keyboardBridgeStatus.state
        default:
            state = phase == .recording ? .recording : .sending
        }
        let message = keyboardBridgeStatus.message.trimmingCharacters(in: .whitespacesAndNewlines)
        publishKeyboardStatus(
            state,
            commandID: keyboardBridgeStatus.commandID ?? commandID,
            message: message.isEmpty ? phase.label : message,
            processingStage: keyboardBridgeStatus.processingStage
        )
    }

    private func resumeKeyboardStandbyAfterCommand(retryCount: Int = 0) async {
        guard !Task.isCancelled,
              keyboardStandbyEnabled,
              foregroundCapturePreparationTask == nil,
              captureModeTransitionTask == nil,
              captureStartInFlightGeneration == nil,
              activeCaptureGeneration == nil,
              !hasAnyActiveRecordingCapture,
              !isStopAndSendInFlight,
              queuedKeyboardStopCommandID == nil,
              activeKeyboardRecordingCommandID == nil,
              !phase.isBusy
        else { return }

        let preserveCommandStatus = shouldPreserveKeyboardCommandStatusDuringStandbyResume
        let selectedMode = keyboardDictationCaptureMode
        let preparationGeneration = beginCapturePreparation()
        let didPrepare = await prepareSelectedHostCaptureMode(
            showErrors: false,
            preserveCommandStatus: preserveCommandStatus,
            preparationGeneration: preparationGeneration
        )
        guard capturePreparationIsCurrent(preparationGeneration, mode: selectedMode) else {
            discardResourcesFromStaleCapturePreparation(
                preparationGeneration,
                expectedMode: selectedMode
            )
            return
        }
        guard !didPrepare else { return }
        if !preserveCommandStatus {
            publishKeyboardCaptureNotReady()
        }
        // Immediate post-recording audio reactivation may fail while iOS is
        // settling the route. Retry only while this background-mic ownership is
        // still current; PiP visibility failures remain user-controlled.
        if selectedMode == .backgroundMic, retryCount < 2 {
            scheduleKeyboardStandbyRefresh(
                delay: 2.0 * Double(retryCount + 1),
                retryCount: retryCount + 1
            )
        }
    }

    private var shouldPreserveKeyboardCommandStatusDuringStandbyResume: Bool {
        guard keyboardBridgeStatus.commandID != nil else { return false }
        switch keyboardBridgeStatus.state {
        case .recording, .sending, .result, .error:
            // Standby maintenance cannot replace command-scoped work or a
            // terminal result before the keyboard has had a chance to fetch it.
            return true
        case .standby:
            let message = keyboardBridgeStatus.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return !message.isEmpty && message != "Ready"
        case .idle:
            return false
        }
    }

    private func scheduleKeyboardStandbyRefresh(delay: TimeInterval = 1.5, retryCount: Int = 0) {
        cancelKeyboardStandbyRefresh()
        let taskID = UUID()
        keyboardStandbyRefreshTaskID = taskID
        keyboardStandbyRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.keyboardStandbyRefreshTaskID == taskID
            else { return }
            await self.resumeKeyboardStandbyAfterCommand(retryCount: retryCount)
            guard self.keyboardStandbyRefreshTaskID == taskID else { return }
            self.keyboardStandbyRefreshTask = nil
            self.keyboardStandbyRefreshTaskID = nil
        }
    }

    private func cancelKeyboardStandbyRefresh() {
        keyboardStandbyRefreshTaskID = nil
        keyboardStandbyRefreshTask?.cancel()
        keyboardStandbyRefreshTask = nil
    }

    private func notifyKeyboardTranscriptionReady() {
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.transcriptionReady)
    }

    private func publishKeyboardStatus(
        _ state: KeyboardBridgeState,
        commandID: String? = nil,
        message: String? = nil,
        resultText: String? = nil,
        audioDurationSeconds: Double? = nil,
        audioByteCount: Int? = nil,
        rawTranscriptLength: Int? = nil,
        processingStage: KeyboardBridgeProcessingStage? = nil
    ) {
        if state == .result,
           let commandID,
           let resultText,
           !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let saved = KeyboardSharedKeychain.savePendingFinalResult(
                KeyboardPendingFinalResult(
                    commandID: commandID,
                    text: resultText,
                    message: message ?? "Result ready",
                    audioDurationSeconds: audioDurationSeconds,
                    audioByteCount: audioByteCount,
                    rawTranscriptLength: rawTranscriptLength
                )
            )
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: saved ? "pending_final_result_saved" : "pending_final_result_save_failed",
                fields: ["command_id": commandID]
            )
        }
        // Last-known Mac bridge reachability. `nil` (= never probed this
        // session) is intentionally NOT mapped to `false` — the keyboard's
        // ready dot treats `nil` optimistically (assume reachable) so a
        // fresh-keyboard cold start doesn't flash amber before the first
        // probe lands. A real failure flips this to `false` and the dot
        // turns amber on the next status stream update.
        let reachable: Bool? = {
            switch routeStatus.activeKind {
            case .local, .cloud: return true
            case .unavailable:
                return (routeStatus.localChecked || routeStatus.cloudChecked) ? false : nil
            }
        }()

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
            setKeyboardBridgeStatus(KeyboardBridgeStatus(
                commandID: preservedCommandID,
                state: .recording,
                message: "Recording",
                defaultCorrectionMode: config.correctionMode.rawValue,
                backendReachable: reachable,
                correctionTimeoutMs: keyboardCorrectionTimeoutMsForStatus()
            ))
            syncPiPDictationPresentation()
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
            livePartialTranscript: partial,
            backendReachable: reachable,
            processingStage: state == .sending ? processingStage : nil,
            correctionTimeoutMs: keyboardCorrectionTimeoutMsForStatus()
        )
        setKeyboardBridgeStatus(status)
        syncPiPDictationPresentation()
    }

    private func keyboardCorrectionTimeoutMsForStatus() -> Int {
        let hotTimeout = BridgeMacSettingsPayload.clampedCorrectionTimeoutMs(
            macSettings?.correctionTimeoutMs ?? 1500
        )
        let coldTimeout = BridgeMacSettingsPayload.clampedCorrectionColdTimeoutMs(
            macSettings?.correctionColdTimeoutMs ?? 8000
        )
        return max(hotTimeout, coldTimeout)
    }

    private func setKeyboardBridgeStatus(_ status: KeyboardBridgeStatus, persistSnapshot: Bool = true) {
        let orderedStatus = nextKeyboardStatusFrame(status)
        keyboardBridgeStatus = orderedStatus
        keyboardServer.publishStatus(orderedStatus)
        updateKeyboardStatusAudioLevelPush(for: orderedStatus)
        guard persistSnapshot else { return }
        KeyboardSharedDefaults.saveStatusSnapshot(orderedStatus)
    }

    private func nextKeyboardStatusFrame(_ status: KeyboardBridgeStatus) -> KeyboardBridgeStatus {
        keyboardStatusRevision &+= 1
        if keyboardStatusRevision == 0 {
            keyboardStatusRevision = 1
        }
        return status.withHostOrdering(
            hostInstanceID: keyboardStatusHostInstanceID,
            revision: keyboardStatusRevision
        )
    }

    /// Called from the selected preview source on every new hypothesis.
    /// Updates only the live partial field on the keyboard bridge status —
    /// keeps the existing state / message / commandID intact so the keyboard's
    /// stage indicator doesn't churn.
    private func publishLivePartialTranscriptToKeyboard() {
        guard keyboardBridgeStatus.state == .recording || keyboardBridgeStatus.state == .sending else { return }
        let next = livePartialTranscript.isEmpty ? nil : livePartialTranscript
        guard keyboardBridgeStatus.livePartialTranscript != next else { return }
        // Partials reach the keyboard through its live status stream; writing a
        // shared-defaults snapshot per speech hypothesis is main-actor disk
        // traffic several times a second with no reader that needs it.
        setKeyboardBridgeStatus(
            keyboardBridgeStatus.withLivePartialTranscript(next),
            persistSnapshot: false
        )
    }

    private func updateKeyboardStatusAudioLevelPush(for status: KeyboardBridgeStatus) {
        guard status.state == .recording else {
            stopKeyboardStatusAudioLevelPush()
            return
        }
        guard keyboardStatusAudioLevelTask == nil else { return }
        keyboardStatusAudioLevelTask = Task { @MainActor [weak self] in
            var lastPublishedLevel: Float?
            while !Task.isCancelled {
                guard let self else { return }
                guard self.keyboardBridgeStatus.state == .recording else {
                    self.stopKeyboardStatusAudioLevelPush()
                    return
                }
                let level = self.currentKeyboardStatusAudioLevel()
                if Self.shouldPublishKeyboardStatusAudioLevel(level, after: lastPublishedLevel) {
                    let status = self.nextKeyboardStatusFrame(
                        self.keyboardBridgeStatus.withAudioLevel(level)
                    )
                    self.keyboardServer.publishStatus(status)
                    lastPublishedLevel = level
                }
                try? await Task.sleep(nanoseconds: Self.keyboardStatusAudioLevelInterval)
            }
        }
    }

    private func currentKeyboardStatusAudioLevel() -> Float {
        let level = keyboardAudioSession.isRecording
            ? keyboardAudioSession.level
            : recorder.level
        return max(0, min(1, level))
    }

    private static func shouldPublishKeyboardStatusAudioLevel(_ level: Float, after previous: Float?) -> Bool {
        guard let previous else { return true }
        if abs(level - previous) >= keyboardStatusAudioLevelMinimumDelta {
            return true
        }
        return level <= 0.001 && previous > 0.001
    }

    private func stopKeyboardStatusAudioLevelPush() {
        keyboardStatusAudioLevelTask?.cancel()
        keyboardStatusAudioLevelTask = nil
    }

    private func cancelActiveRecordingWithoutSending(
        hostFailureMessage: String?,
        keyboardCommandID: String?,
        keyboardMessage: String,
        resumeKeyboardStandby: Bool
    ) async {
        invalidateCaptureLifecycle()
        let hadCapture = hasAnyActiveRecordingCapture
        if let fileURL = recorder.stop(deactivateSession: true) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if keyboardAudioSession.isRecording {
            keyboardAudioSession.cancelRecording()
            if keyboardDictationCaptureMode == .pictureInPicture {
                keyboardAudioSession.stop(discardInputEngine: true)
            }
        }
        teardownLivePartialPreview(clearText: true)
        hostRecordingUsesKeyboardAudioSession = false
        hostHoldReleasePending = false
        queuedKeyboardStopCommandID = nil
        clearKeyboardCaptureContext()
        if hadCapture || phase == .recording || phase == .preparing {
            releaseIdleTimer()
        }

        if let hostFailureMessage, hadCapture || phase == .recording || phase == .preparing {
            setPhase(.failure(hostFailureMessage))
        } else if phase == .recording || phase == .preparing {
            setPhase(.idle)
        }

        let nextKeyboardState: KeyboardBridgeState = (keyboardStandbyEnabled || keyboardAudioSession.isActive)
            ? .standby
            : .idle
        publishKeyboardStatus(
            nextKeyboardState,
            commandID: keyboardCommandID,
            message: nextKeyboardState == .standby ? keyboardMessage : KeyboardBridgeStatus.idle.message
        )
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "capture_cancel_cleanup_completed",
            fields: [
                "command_id": keyboardCommandID ?? "none",
                "keyboard_recording": "\(keyboardAudioSession.isRecording)",
                "recorder_recording": "\(recorder.isRecording)",
            ]
        )
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        if resumeKeyboardStandby {
            await resumeKeyboardStandbyAfterCommand()
        }
    }

    private func reconcileStaleRecordingStateIfNeeded(
        message: String,
        includePreparing: Bool = false
    ) {
        guard !hasAnyActiveRecordingCapture else { return }
        let representsActiveRecording = phase == .recording
            || (includePreparing && phase == .preparing)
            || keyboardBridgeStatus.state == .recording
        guard representsActiveRecording else { return }
        invalidateCaptureLifecycle()
        if phase == .recording || (includePreparing && phase == .preparing) {
            hostRecordingUsesKeyboardAudioSession = false
            hostHoldReleasePending = false
            clearKeyboardCaptureContext()
            teardownLivePartialPreview(clearText: true)
            releaseIdleTimer()
            setPhase(.failure(message))
        }
        if keyboardBridgeStatus.state == .recording {
            let commandID = keyboardBridgeStatus.commandID
            clearKeyboardCaptureContext()
            let nextKeyboardState: KeyboardBridgeState = (keyboardStandbyEnabled || keyboardAudioSession.isActive)
                ? .standby
                : .idle
            publishKeyboardStatus(
                nextKeyboardState,
                commandID: commandID,
                message: nextKeyboardState == .standby ? "Ready" : KeyboardBridgeStatus.idle.message
            )
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        }
    }

    private func applyBridgeJobStatus(
        _ event: BridgeJobStatusEvent,
        keyboardCommandID: String?,
        stageLabels: BridgeStageLabels = .dictation,
        shouldAdvanceToRefineWhenTranscriptionCompletes: Bool = true,
        recordingInfo: RecordingFileInfo? = nil
    ) {
        // HTTP response/error is the sole terminal authority. Job events are
        // progress hints only; letting both paths finish a command creates a
        // race where the keyboard sees Result while the Host still owns it.
        guard phase.isBusy, !event.stage.isTerminal else { return }
        let transcriptLength = event.rawTranscriptLength
            ?? event.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).count

        // Collapse the bridge's raw job stages into labels chosen by the
        // current workflow. Plain dictation says Transcribing/Refining; voice
        // commands say Understanding/Editing so the user sees what is actually
        // happening to the selected text.
        // The same string is the detailed stage payload for host processing UI
        // and keyboard primary/detail surfaces. The keyboard's small top-left
        // session indicator derives its coarse copy separately.
        if event.stage == .transcriptReady,
           let raw = event.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            rawTranscript = raw
            applyASRFinalPreview(raw)
        }

        let shouldPresentRefine = event.stage == .refining
            || (shouldAdvanceToRefineWhenTranscriptionCompletes && event.transcriptionReadyForRefine)
        let stageMessage: String
        let keyboardProcessingStage: KeyboardBridgeProcessingStage?
        switch event.stage {
        case .audioReceived:
            stageMessage = stageLabels.transcribingMessage(for: event)
            keyboardProcessingStage = .transcribing
        case .transcribing:
            stageMessage = shouldPresentRefine
                ? stageLabels.refining
                : stageLabels.transcribingMessage(for: event)
            keyboardProcessingStage = shouldPresentRefine ? .refining : .transcribing
        case .transcriptReady:
            stageMessage = shouldPresentRefine
                ? stageLabels.refining
                : stageLabels.transcribingMessage(for: event)
            keyboardProcessingStage = shouldPresentRefine ? .refining : .transcribing
        case .refining:
            stageMessage = stageLabels.refining
            keyboardProcessingStage = .refining
        case .resultReady, .failed:
            return
        }

        if shouldPresentRefine, phase == .sending {
            setPhase(.refining)
        }
        processingStatusMessage = stageMessage
        if let keyboardCommandID {
            publishKeyboardStatus(
                .sending,
                commandID: keyboardCommandID,
                message: stageMessage,
                audioDurationSeconds: recordingInfo?.durationSeconds,
                audioByteCount: recordingInfo?.byteCount,
                rawTranscriptLength: transcriptLength,
                processingStage: keyboardProcessingStage
            )
            if event.transcriptionReadyForRefine {
                notifyKeyboardTranscriptionReady()
            }
        }
    }

    private func scheduleBridgeProgressStatusDelay(
        keyboardCommandID: String?,
        message: String,
        recordingInfo: RecordingFileInfo
    ) {
        bridgeProgressStatusTask?.cancel()
        bridgeProgressStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.bridgeProgressStatusDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .sending else { return }
            guard self.shouldApplyBridgeProgressStatusDelay(keyboardCommandID: keyboardCommandID) else { return }
            self.processingStatusMessage = message
            if let keyboardCommandID {
                self.publishKeyboardStatus(
                    .sending,
                    commandID: keyboardCommandID,
                    message: message,
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount,
                    processingStage: .transcribing
                )
            }
        }
    }

    private func shouldApplyBridgeProgressStatusDelay(keyboardCommandID: String?) -> Bool {
        if Self.hasTranscriptionProgressSuffix(processingStatusMessage) {
            return false
        }
        guard let keyboardCommandID,
              keyboardBridgeStatus.commandID == keyboardCommandID,
              keyboardBridgeStatus.state == .sending
        else { return true }
        if keyboardBridgeStatus.processingStage == .refining {
            return false
        }
        return !Self.hasTranscriptionProgressSuffix(keyboardBridgeStatus.message)
    }

    private static func hasTranscriptionProgressSuffix(_ message: String?) -> Bool {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.range(of: #"\([0-9]+/[0-9]+\)$"#, options: .regularExpression) != nil
    }

    private func cancelBridgeProgressStatusDelay() {
        bridgeProgressStatusTask?.cancel()
        bridgeProgressStatusTask = nil
    }

    private func applyCorrectionMetadata(
        status correctionStatus: String?,
        error correctionError: String?,
        asrWarning: String? = nil,
        successKind: AppPhase.SuccessKind = .ready
    ) {
        let normalizedStatus = correctionStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let warning = Self.userVisibleASRWarning(asrWarning)
        if normalizedStatus == "error" {
            let message = correctionError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            setFailure(message.isEmpty ? "Mac refine failed." : message)
            return
        }
        if Self.isCorrectionDegradedStatus(normalizedStatus) {
            errorMessage = nil
            setPhase(.success(successKind))
            showTransient(Self.statusMessage(Self.degradedCorrectionMessage(for: successKind, status: normalizedStatus), warning: warning))
            return
        }
        errorMessage = nil
        setPhase(.success(successKind))
        showTransient(Self.statusMessage(Self.successMessage(for: successKind), warning: warning))
    }

    private static func isCorrectionDegradedStatus(_ status: String?) -> Bool {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "refine_error", "refine_timeout":
            return true
        default:
            return false
        }
    }

    private static func degradedCorrectionMessage(for successKind: AppPhase.SuccessKind, status: String?) -> String {
        let base: String
        switch successKind {
        case .ready:
            base = "Ready without refine"
        case .copied:
            base = "Copied without refine"
        case .inserted:
            base = "Inserted without refine"
        }
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "refine_timeout":
            return "\(base): refine timeout"
        case "refine_error":
            return "\(base): refine error"
        default:
            return base
        }
    }

    private static func successMessage(for successKind: AppPhase.SuccessKind) -> String {
        switch successKind {
        case .ready:
            return "Ready"
        case .copied:
            return "Copied"
        case .inserted:
            return "Inserted"
        }
    }

    private static func statusMessage(_ message: String, warning: String?) -> String {
        guard let warning, !warning.isEmpty else { return message }
        return "\(message) · \(warning)"
    }

    private func isBenignEmptyTranscript(_ error: Error) -> Bool {
        Self.isBenignASREmptyMessage(error.localizedDescription)
    }

    private static func userVisibleASRWarning(_ warning: String?) -> String? {
        let lines = warning?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isBenignASREmptyMessage($0) } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func isBenignASREmptyMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("empty transcript")
            || lower.contains("audio produced an empty transcript")
            || lower.contains("asr return empty")
            || lower.contains("no speech detected")
    }

    // MARK: - Phase / transient state

    private func syncPiPDictationPresentation() {
        let presentation = currentPiPDictationPresentation()

        pipDictationCoordinator.updatePresentation(PiPDictationPresentation(
            title: NSLocalizedString("Typeforme", comment: "Product name"),
            stateLabel: presentation.stateLabel,
            isRecording: presentation.isRecording,
            recordingStartedAt: presentation.recordingStartedAt
        ))
    }

    private func currentPiPDictationPresentation() -> (stateLabel: String, isRecording: Bool, recordingStartedAt: Date?) {
        func nonEmpty(_ value: String?, fallback: String) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? fallback : trimmed
        }

        if hasHostOwnedRecordingCapture || self.phase == .recording {
            return (NSLocalizedString("Recording", comment: "PiP recording state"), true, recordingStartedAt)
        }

        switch keyboardBridgeStatus.state {
        case .recording:
            return (NSLocalizedString("Recording", comment: "PiP recording state"), true, recordingStartedAt)
        case .sending:
            if keyboardBridgeStatus.processingStage == .refining {
                return (NSLocalizedString("Refining", comment: "PiP refining state"), false, nil)
            }
            return keyboardBridgeStatus.message.isEmpty
                ? (NSLocalizedString("Transcribing", comment: "PiP transcribing state"), false, nil)
                : (keyboardBridgeStatus.message, false, nil)
        case .result:
            return (NSLocalizedString("Result Ready", comment: "PiP result ready state"), false, nil)
        case .error:
            return (NSLocalizedString("Needs Attention", comment: "PiP error state"), false, nil)
        case .standby, .idle:
            switch self.phase {
            case .sending:
                return (nonEmpty(
                    processingStatusMessage,
                    fallback: NSLocalizedString("Transcribing", comment: "PiP transcribing state")
                ), false, nil)
            case .refining:
                return (nonEmpty(
                    processingStatusMessage,
                    fallback: NSLocalizedString("Refining", comment: "PiP refining state")
                ), false, nil)
            case .success:
                return (NSLocalizedString("Result Ready", comment: "PiP result ready state"), false, nil)
            case .failure:
                return (NSLocalizedString("Needs Attention", comment: "PiP error state"), false, nil)
            default:
                return (NSLocalizedString("Ready", comment: "PiP ready state"), false, nil)
            }
        }
    }

    private func setPhase(_ next: AppPhase) {
        phase = next
        if next == .recording {
            recordingStartedAt = Date()
        } else if !next.isBusy {
            recordingStartedAt = nil
        }
        if !next.isBusy {
            processingStatusMessage = nil
            cancelBridgeProgressStatusDelay()
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
        syncPiPDictationPresentation()
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
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleMediaServicesWereReset()
            }
        })
    }

    private func handleCaptureAudioInvalidation(reason: String) async {
        guard activeCaptureGeneration != nil
                || captureStartInFlightGeneration != nil
                || phase == .recording
                || phase == .preparing
        else { return }
        let commandID: String?
        let owner = activeCaptureOwner ?? captureStartInFlightOwner
        if case .keyboard(commandID: let ownedCommandID)? = owner {
            commandID = ownedCommandID
        } else {
            commandID = nil
        }
        let message: String
        switch reason {
        case "no_audio_frames", "audio_frames_stalled":
            message = "Recording stopped because the microphone stopped delivering audio. Please try again."
        default:
            message = "Recording stopped because the audio input changed. Please try again."
        }
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "capture_audio_invalidated",
            fields: [
                "reason": reason,
                "command_id": commandID ?? "none",
            ]
        )
        await cancelActiveRecordingWithoutSending(
            hostFailureMessage: message,
            keyboardCommandID: commandID,
            keyboardMessage: message,
            resumeKeyboardStandby: true
        )
    }

    private func handleMediaServicesWereReset() async {
        let hadRecorderCapture = recorder.isRecording
        recorder.discardPreWarm()
        standbyKeeper.stop(deactivateSession: false)
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "media_services_were_reset",
            fields: ["recorder_capture_was_active": "\(hadRecorderCapture)"]
        )
        if hadRecorderCapture {
            await cancelActiveRecordingWithoutSending(
                hostFailureMessage: "Recording stopped because iOS reset audio services. Please try again.",
                keyboardCommandID: nil,
                keyboardMessage: "Audio reset; try again",
                resumeKeyboardStandby: true
            )
        } else if keyboardStandbyEnabled {
            scheduleKeyboardStandbyRefresh(delay: 0.75)
        }
    }

    private func handleAudioSessionInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            handleAudioSessionInterruptionBegan()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            handleAudioSessionInterruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            handleAudioSessionInterruptionBegan()
        }
    }

    private func handleAudioSessionInterruptionBegan() {
        let hadRecorderCapture = recorder.isRecording
        let hadKeyboardCapture = keyboardAudioSession.isRecording
        let hadInputStandby = keyboardAudioSession.isActive
        let hadSilentStandby = standbyKeeper.isActive
        let hadPreWarm = recorder.isPreWarmed
        let wasPreparing = phase == .preparing || captureStartInFlightGeneration != nil
        let affectedAudioSession = hadRecorderCapture
            || hadKeyboardCapture
            || hadInputStandby
            || hadSilentStandby
            || hadPreWarm
            || wasPreparing
        guard affectedAudioSession else { return }

        let preservesPostCaptureCommand = isStopAndSendInFlight
            && !hadRecorderCapture
            && !hadKeyboardCapture
            && !wasPreparing
            && activeCaptureGeneration != nil
            && (phase == .sending
                || phase == .refining
                || keyboardBridgeStatus.state == .sending)
        if !preservesPostCaptureCommand {
            invalidateCaptureLifecycle()
        }
        audioSessionInterruptionActive = true
        keyboardAudioUnavailableMessage = "Microphone is in use by another app."
        appLog.notice("audio session interruption began; ending keyboard audio session")

        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        cancelKeyboardStandbyRefresh()
        recorderPreWarmTask?.cancel()
        recorderPreWarmTask = nil

        if let fileURL = recorder.stop(deactivateSession: false) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        recorder.discardPreWarm()
        if hadInputStandby || hadKeyboardCapture {
            keyboardAudioSession.stopForAudioInterruption()
        }
        standbyKeeper.stop(deactivateSession: false)
        if !preservesPostCaptureCommand {
            teardownLivePartialPreview(clearText: true)
        }

        if preservesPostCaptureCommand {
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "audio_interruption_preserved_post_capture_command",
                fields: [
                    "command_id": activeKeyboardRecordingCommandID
                        ?? keyboardBridgeStatus.commandID
                        ?? "none",
                    "phase": phase.label,
                ]
            )
            // The finalized audio file and Bridge job no longer depend on the
            // interrupted AVAudioSession. Keep their generation and terminal
            // status ownership intact; only the standby audio resources end.
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
            return
        }

        let wasRecordingStatus = keyboardBridgeStatus.state == .recording
        let hadCapture = hadRecorderCapture || hadKeyboardCapture || wasPreparing || wasRecordingStatus
        let commandID = activeKeyboardRecordingCommandID ?? keyboardBridgeStatus.commandID
        hostRecordingUsesKeyboardAudioSession = false
        hostHoldReleasePending = false
        queuedKeyboardStopCommandID = nil
        clearKeyboardCaptureContext()

        if hadCapture {
            releaseIdleTimer()
            setPhase(.failure("Recording stopped because another app is using the microphone."))
            publishKeyboardStatus(
                .idle,
                commandID: commandID,
                message: keyboardAudioUnavailableMessage
            )
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        } else if keyboardBridgeStatus.state != .sending, keyboardBridgeStatus.state != .result {
            publishKeyboardStatus(.idle, message: keyboardAudioUnavailableMessage)
        }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionEnded)
    }

    private func handleAudioSessionInterruptionEnded(shouldResume: Bool) {
        guard audioSessionInterruptionActive else { return }
        audioSessionInterruptionActive = false
        appLog.notice("audio session interruption ended shouldResume=\(shouldResume, privacy: .public)")

        guard keyboardStandbyEnabled else {
            scheduleHostRecorderPreWarm()
            return
        }
        guard !keyboardAudioSession.isRecording, !recorder.isRecording else { return }
        keyboardAudioUnavailableMessage = nil
        scheduleKeyboardStandbyRefresh(delay: shouldResume ? 0.5 : 1.0)
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
                    && !path.isExpensive
                    && !path.isConstrained
                    && !ProcessInfo.processInfo.isLowPowerModeEnabled
                    && self.routeStatus.activeKind == .local
                    && self.shouldRefreshRouteForSameSignaturePathUpdate(at: now)
                guard signatureChanged || shouldRefreshSameSignature else { return }
                if signatureChanged {
                    self.networkPathSignature = signature
                }
                self.lastNetworkPathRefreshAt = now
                self.routeFetchedAt = nil
                guard path.status == .satisfied else {
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "route_refresh_deferred",
                        fields: [
                            "reason": "network_path_unsatisfied",
                            "signature": signature,
                            "current_kind": self.routeStatus.activeKind.rawValue,
                        ]
                    )
                    return
                }
                if self.isConfigured {
                    await self.refreshRoute(
                        force: true,
                        showIndicator: false,
                        reason: "network_path"
                    )
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    private func shouldRefreshRouteForSameSignaturePathUpdate(at now: Date) -> Bool {
        guard let lastNetworkPathRefreshAt else { return true }
        return now.timeIntervalSince(lastNetworkPathRefreshAt) >= Self.networkPathSameSignatureRefreshInterval
    }

    private func shouldRefreshRouteOnForeground(at now: Date = Date()) -> Bool {
        guard isConfigured else { return false }
        guard routeStatus.activeURL != nil, let routeFetchedAt else { return true }
        guard now.timeIntervalSince(routeFetchedAt) >= Self.foregroundRouteRefreshTTL else { return false }
        guard let lastForegroundRouteRefreshAt else { return true }
        return now.timeIntervalSince(lastForegroundRouteRefreshAt) >= Self.foregroundRouteRefreshTTL
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
        // Backgrounding kills the AVAudioSession we're recording on. Cancel
        // the in-flight recording so we don't ship an empty / corrupted file
        // to the Bridge on resume.
        let hostStartIsInFlight = captureStartInFlightOwner == .host
        if hasHostOwnedRecordingCapture || hostStartIsInFlight {
            invalidateCaptureLifecycle()
            Task { @MainActor [weak self] in
                await self?.cancelActiveRecordingWithoutSending(
                    hostFailureMessage: "Recording stopped — app went to background.",
                    keyboardCommandID: nil,
                    keyboardMessage: "Ready",
                    resumeKeyboardStandby: false
                )
            }
            return
        }
        reconcileStaleRecordingStateIfNeeded(
            message: "Recording stopped because the audio session ended.",
            includePreparing: true
        )
    }

    private func handleWillEnterForeground() {
        if hasKeyboardCaptureLifecycleOwner,
           !keyboardAudioSession.isRecording,
           (phase == .preparing || phase == .recording) {
            Task { @MainActor [weak self] in
                await self?.cancelActiveRecordingWithoutSending(
                    hostFailureMessage: "Recording stopped — keyboard was closed.",
                    keyboardCommandID: nil,
                    keyboardMessage: "Ready",
                    resumeKeyboardStandby: true
                )
            }
        } else {
            reconcileStaleRecordingStateIfNeeded(
                message: "Recording stopped because the audio session ended.",
                includePreparing: true
            )
        }
        if audioSessionInterruptionActive {
            // iOS does not guarantee a matching `.ended` notification for every
            // interruption. Foregrounding is the next safe point to attempt
            // standby recovery; if the call still owns the mic, activation will
            // fail and keep the keyboard in the unavailable state.
            handleAudioSessionInterruptionEnded(shouldResume: false)
        }
        scheduleHostRecorderPreWarm()
        // Warm route status for the UI. Hot recording/rewrite paths request a
        // fast route separately so Cloud diagnostics never block input.
        let shouldRefreshRoute = shouldRefreshRouteOnForeground()
        if shouldRefreshRoute {
            lastForegroundRouteRefreshAt = Date()
            routeFetchedAt = nil
        }
        Task {
            await handleForegroundKeyboardHandoffIfNeeded()
            if shouldRefreshRoute {
                await refreshRoute(force: true, showIndicator: false, reason: "foreground")
            }
            _ = try? await refreshMacSettingsIfChanged()
            scheduleHostRecorderPreWarm()
        }
    }

    private func handleForegroundKeyboardHandoffIfNeeded() async {
        guard let handoff = KeyboardSharedDefaults.consumeLatestHostHandoff() else { return }
        appLog.notice("handleForegroundKeyboardHandoffIfNeeded: consumed action=\(handoff.action, privacy: .public)")
        await handleKeyboardHostHandoff(action: handoff.action, handoff: handoff)
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
            return durationSeconds < BridgeAudioRecordingContract.minimumDurationSeconds
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
