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
    private var activeKeyboardRecordingCommandID: String?
    private var activeBridgeDictateJobID: String?
    private var queuedKeyboardStopCommandID: String?
    @ObservationIgnored private var hostAudioSessionExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardStandbyRefreshTask: Task<Void, Never>?
    private var routeFetchedAt: Date?
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

    /// Force-refresh cloud/unavailable routes if cached probe is older than
    /// this. Local routes get a shorter TTL because stale LAN IPs hurt more
    /// than the extra probe.
    private static let routeCacheTTL: TimeInterval = 30
    private static let localRouteCacheTTL: TimeInterval = 5
    private static let foregroundRouteRefreshTTL: TimeInterval = 20
    private static let networkPathSameSignatureRefreshInterval: TimeInterval = 15
    private static let canceledKeyboardCommandTTL: TimeInterval = 10
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

    private var hasAnyActiveRecordingCapture: Bool {
        recorder.isRecording || keyboardAudioSession.isRecording
    }

    private var hasHostOwnedRecordingCapture: Bool {
        recorder.isRecording || (hostRecordingUsesKeyboardAudioSession && keyboardAudioSession.isRecording)
    }

    private var hasKeyboardOwnedRecordingCapture: Bool {
        keyboardAudioSession.isRecording && !hostRecordingUsesKeyboardAudioSession
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

    func isCorrectionModeAvailable(_: CorrectionMode) -> Bool {
        true
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
        configureKeyboardServer()
        configureKeyboardDarwinBridge()
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
        recorderPreWarmTask?.cancel()
        keyboardStatusAudioLevelTask?.cancel()
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
        await prepareHostForegroundCapture()
        await refreshRoute(force: true, showIndicator: false, reason: "bootstrap")
        _ = try? await refreshMacSettingsIfChanged()
        scheduleHostRecorderPreWarm()
    }

    func prepareHostForegroundCapture(honorRecentPiPStop: Bool = true) async {
        await waitForInitialRenderOpportunity()
        refreshSetupReadinessStatuses()
        let honorManualSuppression = keyboardDictationCaptureMode == .pictureInPicture
            && honorRecentPiPStop
            && shouldHonorRecentPiPStopForForegroundActivation
        await prepareSelectedHostCaptureMode(
            showErrors: false,
            honorManualSuppression: honorManualSuppression
        )
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

    func saveConfig(_ newConfig: PairingConfig) {
        var normalized = newConfig
        normalized.normalize()
        config = normalized
        correctionMode = normalized.correctionMode
        selectedLanguageIDs = Set(normalized.validatedLanguageIDs)
        store.save(normalized)
        publishKeyboardDefaults()
        routeFetchedAt = nil
        Task {
            await refreshRoute(force: true, syncPairingEndpoints: true, reason: "save_config")
            _ = try? await refreshMacSettings()
        }
    }

    func saveBridgeEndpoints(_ bridgeEndpoints: BridgeEndpoints) {
        var normalized = config
        normalized.bridgeEndpoints = bridgeEndpoints
        normalized.normalizeBridgeEndpoints()
        guard normalized.bridgeEndpoints != config.bridgeEndpoints else { return }
        config.bridgeEndpoints = normalized.bridgeEndpoints
        store.save(config)
        publishKeyboardDefaults()
        routeFetchedAt = nil
        Task {
            await refreshRoute(force: true, syncPairingEndpoints: true, reason: "save_bridge_endpoints")
        }
    }

    func unpair() {
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
        selectedLanguageIDs = Set(ordered)
        config.languageIDs = ordered
        store.save(config)
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
        guard updateStoredRawPreference(
            \.keyboardDictationCaptureMode,
            to: mode,
            key: Self.keyboardDictationCaptureModeKey
        ) else { return }
        syncPiPDictationPresentation()
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
        let generation = nextRouteRefreshGeneration()
        let startedAt = Date()
        let shouldSyncPairingEndpoints = syncPairingEndpoints ?? showIndicator
        beginRouteRefresh(showIndicator: showIndicator)
        recordRouteRefreshBegin(
            generation: generation,
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
            reason: reason,
            config: configSnapshot,
            startedAt: startedAt
        ) else {
            return
        }

        guard shouldSyncPairingEndpoints,
              shouldRefreshPairingEndpointsAfterRouteRefresh(force: force, status: routeStatus),
              routeRefreshGeneration == generation,
              await refreshPairingEndpointsFromActiveRoute(status: routeStatus)
        else { return }

        guard routeRefreshGeneration == generation else {
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
        timeout: TimeInterval = 4
    ) async -> Bool {
        guard let activeURL = status.activeURL else { return false }
        let previous = config.bridgeEndpoints
        do {
            let refreshed = try await BridgeClient(baseURL: activeURL, token: config.token).pairing(timeout: timeout)
            config.bridgeEndpoints = refreshed.bridgeEndpoints
            recordRouteEndpointSyncResult(
                changed: config.bridgeEndpoints != previous,
                previous: previous,
                refreshed: config.bridgeEndpoints,
                activeKind: status.activeKind.rawValue,
                error: nil
            )
            if config.bridgeEndpoints != previous {
                store.save(config)
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
        constrainKeyboardLivePreviewSourceToMacSettings()
        config.supportedLanguages = settings.supportedLanguages
        config.languageIDs = ASRLanguageSelection.validatedIDs(
            config.languageIDs,
            supportedOptions: config.supportedLanguageOptions
        )
        selectedLanguageIDs = Set(config.validatedLanguageIDs)
        store.save(config)
        publishKeyboardDefaults()
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

    private func applyKeyboardDefaultCorrectionMode(_ mode: CorrectionMode) {
        let configChanged = config.correctionMode != mode
        let visibleChanged = correctionMode != mode
        guard configChanged || visibleChanged else { return }
        config.correctionMode = mode
        correctionMode = mode
        constrainKeyboardLivePreviewSourceToMacSettings()
        if configChanged {
            store.save(config)
            publishKeyboardDefaults()
        }
    }

    func setDefaultCorrectionMode(_ mode: CorrectionMode) {
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
        config.promoteLocalBridgeURL(activeURL)
        if config.localBridgeURLCandidates != previous {
            store.save(config)
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
        await startSelectedVisibleCaptureMode(showErrors: false, honorManualSuppression: false)

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
            setFailure(keyboardAudioStatusMessage(for: error))
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
        await startSelectedVisibleCaptureMode(showErrors: false, honorManualSuppression: false)

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
            setFailure(keyboardAudioStatusMessage(for: error))
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
        // PiP mode uses the same FLAC writer as keyboard dictation. Do not
        // fall through to AVAudioRecorder here: PiP keeps an AV playback
        // session alive and device logs show host AVAudioRecorder can leave an
        // unreadable FLAC under that session.
        if keyboardDictationCaptureMode == .pictureInPicture {
            path = keyboardAudioSession.isActive ? "keyboard-session" : "keyboard-session-cold"
            if !keyboardAudioSession.isActive {
                try await keyboardAudioSession.start(reuseActiveSession: hadSilentStandby)
            }
            _ = try await keyboardAudioSession.beginRecording()
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
        defer { activeBridgeDictateJobID = nil }
        await waitForMinimumRecordingDurationIfNeeded()

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
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        try? await Task.sleep(nanoseconds: BridgeAudioRecordingContract.stopTailBufferNanoseconds)
        let fileURL = isKeyboardCapture
            ? keyboardAudioSession.finishRecording()
            : recorder.stop(deactivateSession: true)
        if isKeyboardCapture {
            switch keyboardDictationCaptureMode {
            case .pictureInPicture:
                if keyboardAudioSession.isActive {
                    keyboardAudioSession.stop()
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
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                    await resumeKeyboardStandbyAfterCommand()
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
                let editResponse = try await client.editText(
                    intent: editContext.intent.rawValue,
                    contextBefore: editContext.contextBefore,
                    targetText: editContext.targetText,
                    contextAfter: editContext.contextAfter,
                    spokenInstruction: spokenTranscript,
                    languageIDs: activeLanguageIDs,
                    clientJobID: editJobID,
                    onJobEvent: { [weak self] event in
                        await self?.applyBridgeJobStatus(
                            event,
                            keyboardCommandID: effectiveKeyboardCommandID,
                            stageLabels: editingStageLabels,
                            shouldAdvanceToRefineWhenTranscriptionCompletes: true,
                            recordingInfo: recordingInfo
                        )
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
                finalCorrectionStatus = editResponse.editStatus
                finalCorrectionError = editResponse.editError
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
            let response = try await client.refine(
                sessionID: source.sessionID,
                rawTranscript: source.rawTranscript,
                languageIDs: activeLanguageIDs,
                correctionMode: newMode,
                clientJobID: refineJobID,
                onJobEvent: { [weak self] event in
                    await self?.applyBridgeJobStatus(
                        event,
                        keyboardCommandID: nil,
                        shouldAdvanceToRefineWhenTranscriptionCompletes: true
                    )
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
            notifyKeyboardTranscriptionReady()
            errorMessage = nil
            applyCorrectionMetadata(
                status: response.correctionStatus,
                error: response.correctionError
            )
        } catch {
            // Invalidate the route cache on both auth and network errors so
            // the next Refine tap re-probes instead of reusing a dead route.
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
            } else {
                guard applyKeyboardParameters(items, allowCorrectionMode: action == "record") else { return }
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
            await toggleRecording()
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
        preserveCommandStatus: Bool = false
    ) async -> Bool {
        appLog.notice("prepare selected capture begin mode=\(self.keyboardDictationCaptureMode.rawValue, privacy: .public) show_errors=\(showErrors, privacy: .public) honor_suppression=\(honorManualSuppression, privacy: .public) request_mic=\(requestMicrophoneIfNeeded, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) keyboard_active=\(self.keyboardAudioSession.isActive, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "prepare_selected_capture_begin",
            fields: [
                "mode": self.keyboardDictationCaptureMode.rawValue,
                "show_errors": "\(showErrors)",
                "honor_suppression": "\(honorManualSuppression)",
                "request_mic": "\(requestMicrophoneIfNeeded)",
                "preserve_command_status": "\(preserveCommandStatus)",
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
            if pipDictationCoordinator.isActive {
                pipDictationCoordinator.stop()
            }
            let didPrepareKeyboardSession = await setKeyboardStandby(
                true,
                requestMicrophoneIfNeeded: requestMicrophoneIfNeeded,
                surfaceAudioSessionErrors: showErrors,
                warmInputEngine: true
            )
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
            guard didStartVisibleCapture else {
                appLog.notice("prepare selected capture result mode=picture_in_picture ready=false reason=visible_capture_failed pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "prepare_selected_capture_result",
                    fields: [
                        "mode": "picture_in_picture",
                        "ready": "false",
                        "reason": "visible_capture_failed",
                        "preserve_command_status": "\(preserveCommandStatus)",
                        "pip_active": "\(self.pipDictationCoordinator.isActive)",
                        "host_session_active": "\(self.isKeyboardHostSessionActive)",
                        "server_running": "\(self.keyboardServer.isRunning)",
                        "selected_capture_ready": "\(self.isSelectedKeyboardCaptureReady)",
                    ]
                )
                if !preserveCommandStatus {
                    publishKeyboardCaptureNotReady()
                }
                return false
            }
            let bridgeReady = await prepareKeyboardBridgeForOnDemandCapture(
                showErrors: showErrors,
                preserveCommandStatus: preserveCommandStatus
            )
            appLog.notice("prepare selected capture result mode=picture_in_picture ready=\(bridgeReady, privacy: .public) pip_active=\(self.pipDictationCoordinator.isActive, privacy: .public) server_running=\(self.keyboardServer.isRunning, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "prepare_selected_capture_result",
                fields: [
                    "mode": "picture_in_picture",
                    "ready": "\(bridgeReady)",
                    "preserve_command_status": "\(preserveCommandStatus)",
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
        preserveCommandStatus: Bool = false
    ) async -> Bool {
        keyboardStandbyEnabled = true
        configureKeyboardServer()
        guard await ensureKeyboardLocalBridgeReady(
            reason: "prepare_on_demand_capture",
            showErrors: showErrors,
            forceProbe: true
        ) else {
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

    private func stopBackgroundAudioCaptureForVisibleMode() {
        guard !keyboardAudioSession.isRecording, !recorder.isRecording else { return }
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        keyboardStandbyRefreshTask?.cancel()
        keyboardStandbyRefreshTask = nil
        stopKeyboardStatusAudioLevelPush()
        if keyboardAudioSession.isActive {
            keyboardAudioSession.stop()
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
        automaticPiPStartAttemptsRemaining = 0
        automaticPiPStartShowsErrors = false
    }

    private func scheduleAutomaticPiPVisibilityStart(showErrors: Bool) {
        guard autoStartPiPTask == nil else { return }
        guard automaticPiPStartAttemptsRemaining > 0 else { return }
        autoStartPiPTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.autoStartPiPTask = nil
            await self.startAutomaticPiPVisibilityIfNeeded(showErrors: showErrors)
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
        if automaticPiPStartAttemptsRemaining > 0,
           !suppressAutomaticPiPStart {
            scheduleAutomaticPiPVisibilityStart(showErrors: showErrors)
        } else {
            automaticPiPStartShowsErrors = false
        }
        return false
    }

    private func clearKeyboardHostSessionTimers() {
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        keyboardStandbyRefreshTask?.cancel()
        keyboardStandbyRefreshTask = nil
        stopKeyboardStatusAudioLevelPush()
    }

    @discardableResult
    private func startSelectedVisibleCaptureMode(
        showErrors: Bool,
        honorManualSuppression: Bool = true
    ) async -> Bool {
        switch keyboardDictationCaptureMode {
        case .backgroundMic:
            return true
        case .pictureInPicture:
            guard !honorManualSuppression || showErrors || !suppressAutomaticPiPStart else { return false }
            suppressAutomaticPiPStart = false
            if showErrors || !honorManualSuppression {
                cancelAutomaticPiPStart()
                return await startPiPVisibilityWithForegroundRetry(showErrors: showErrors)
            }
            requestAutomaticPiPVisibilityStart(showErrors: showErrors)
            return await startAutomaticPiPVisibilityIfNeeded(showErrors: showErrors)
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
        stopBackgroundAudioCaptureForVisibleMode()
        publishKeyboardCaptureNotReady()
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
        warmInputEngine: Bool = true
    ) async -> Bool {
        keyboardStandbyEnabled = enabled
        configureKeyboardServer()

        if enabled {
            do {
                guard await ensureKeyboardLocalBridgeReady(
                    reason: "set_keyboard_standby",
                    showErrors: surfaceAudioSessionErrors,
                    forceProbe: true
                ) else {
                    return false
                }
                let isInputReady = try await prepareKeyboardInputStandby(
                    requestMicrophoneIfNeeded: requestMicrophoneIfNeeded,
                    warmInputEngine: warmInputEngine
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
                let message = keyboardAudioStatusMessage(for: error)
                if surfaceAudioSessionErrors {
                    if IOSRecordingAudioSession.isPriorityConflict(error) {
                        appLog.notice("setKeyboardStandby: \(message, privacy: .public)")
                        startSilentStandbyKeeperIfNeeded()
                        publishKeyboardStatus(.idle, message: message)
                    } else {
                        errorMessage = "Keyboard audio session unavailable: \(message)"
                        appLog.error("setKeyboardStandby: \(self.errorMessage ?? message, privacy: .public)")
                        publishKeyboardStatus(.error, message: errorMessage)
                    }
                } else {
                    // App bootstrap uses keyboard standby as a best-effort
                    // prewarm. Audio-session activation can legitimately fail
                    // while iOS is settling routes after launch; keep the local
                    // bridge/silent standby available and let the keyboard mic
                    // handoff surface any real user-action failure.
                    appLog.notice("setKeyboardStandby bootstrap deferred: \(message, privacy: .public)")
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
            stopKeyboardStatusAudioLevelPush()
            keyboardServer.stop()
            pipDictationCoordinator.stop()
            standbyKeeper.stop()
            keyboardAudioSession.stop()
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
        waitForApplicationActive: Bool = true
    ) async throws -> Bool {
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

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            let reuseActiveSession = standbyKeeper.isActive
            standbyKeeper.stop(deactivateSession: false)
            try await keyboardAudioSession.start(reuseActiveSession: reuseActiveSession)
            keyboardAudioUnavailableMessage = nil
            startKeyboardSessionKeepAlive()
            return true
        case .undetermined:
            guard requestMicrophoneIfNeeded else { return false }
            guard await requestMicrophonePermission() == .granted else { return false }
            let reuseActiveSession = standbyKeeper.isActive
            standbyKeeper.stop(deactivateSession: false)
            try await keyboardAudioSession.start(reuseActiveSession: reuseActiveSession)
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

    @discardableResult
    private func applyKeyboardParameters(_ items: [URLQueryItem], allowCorrectionMode: Bool) -> Bool {
        for item in items {
            switch item.name {
            case "correction_mode":
                guard allowCorrectionMode, let value = item.value else { break }
                guard let nextMode = CorrectionMode(rawValue: value) else {
                    setFailure("Unsupported correction mode: \(value)")
                    return false
                }
                correctionMode = nextMode
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
        return true
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
            if macSettings?.isRecognitionSourceEnabled(.qwen) == true {
                return startServerASRLivePreviewIfAvailable(source: .qwen, generation: generation)
            }
            return startAppleSpeechLivePreviewIfAvailable(generation: generation)
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
                if self.shouldReportKeyboardCaptureNotReady(for: base) {
                    return self.keyboardCaptureNotReadyStatus(from: base)
                }
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
                        self.clearKeyboardCaptureContext()
                        self.publishKeyboardStatus(.error, message: "Keyboard start command expired")
                        return
                    }
                    appLog.notice("darwin requestStart command consumed command_id=\(command.id, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "host-app",
                        event: "darwin_request_start_command_consumed",
                        fields: ["command_id": command.id]
                    )
                    self.postKeyboardCommandReceipt(
                        commandID: command.id,
                        action: .start,
                        phase: .accepted,
                        reason: "darwin_start_received"
                    )
                    if let requestedMode = CorrectionMode(rawValue: command.correctionMode) {
                        self.applyKeyboardDefaultCorrectionMode(requestedMode)
                    }
                    guard !self.consumeCanceledKeyboardCommand(command.id) else {
                        appLog.notice("darwin requestStart command was canceled command_id=\(command.id, privacy: .public)")
                        KeyboardDiagnosticEventLog.record(
                            source: "host-app",
                            event: "darwin_request_start_command_cancelled",
                            fields: ["command_id": command.id]
                        )
                        self.clearKeyboardCaptureContext()
                        self.publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                        return
                    }
                    self.activeKeyboardTextEditContext = command.textEditContext
                    self.activeKeyboardDictationContext = command.dictationContext
                    self.keyboardCaptureStartedFromKeyboard = true
                    let bridgeReady = await self.ensureKeyboardLocalBridgeReady(
                        reason: "darwin_start",
                        showErrors: false,
                        forceProbe: true
                    )
                    self.postKeyboardCommandReceipt(
                        commandID: command.id,
                        action: .start,
                        phase: bridgeReady ? .bridgeReady : .bridgeUnavailable,
                        reason: bridgeReady ? "bridge_ready" : "bridge_unavailable"
                    )
                    await self.startKeyboardRecording(commandID: command.id, allowSessionStart: true)
                }
            },
            KeyboardDarwinBridge.observe(requestStopName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else { return }
                    let command = KeyboardSharedDefaults.consumeDarwinCommand(action: .stop)
                    if let command {
                        self.rememberCanceledKeyboardCommand(command.id)
                    }
                    await self.stopAndSend(keyboardCommandID: command?.id)
                }
            },
            KeyboardDarwinBridge.observe(requestCancelName) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let command = KeyboardSharedDefaults.consumeDarwinCommand(action: .cancel)
                    if let command {
                        self.rememberCanceledKeyboardCommand(command.id)
                    }
                    self.clearKeyboardCaptureContext()
                    await self.cancelActiveRecordingWithoutSending(
                        hostFailureMessage: nil,
                        keyboardCommandID: command?.id,
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
        switch command.action {
        case .start:
            guard !consumeCanceledKeyboardCommand(command.id) else {
                appLog.notice("local start command canceled command_id=\(command.id, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-app",
                    event: "local_start_command_cancelled",
                    fields: ["command_id": command.id]
                )
                clearKeyboardCaptureContext()
                publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
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
            if let requestedMode = CorrectionMode(rawValue: command.correctionMode) {
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
            await cancelActiveRecordingWithoutSending(
                hostFailureMessage: nil,
                keyboardCommandID: command.id,
                keyboardMessage: "Ready",
                resumeKeyboardStandby: true
            )
            resetCorrectionModeToDefault()
        case .configure:
            if let requestedMode = CorrectionMode(rawValue: command.correctionMode) {
                applyKeyboardDefaultCorrectionMode(requestedMode)
            } else {
                resetCorrectionModeToDefault()
            }
            clearKeyboardCaptureContext()
            publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
        case .refineText:
            await refineKeyboardText(command)
        }
        return keyboardBridgeStatus
    }

    private func beginKeyboardStopAndSend(commandID: String) -> KeyboardBridgeStatus {
        let recognitionStageLabels = Self.recognitionStageLabels(for: activeKeyboardTextEditContext)
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
                    message: recognitionStageLabels.transcribing,
                    processingStage: .transcribing
                )
            }
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
            let response = try await client.refine(
                sessionID: refineSessionID,
                rawTranscript: refineSource,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode,
                clientJobID: refineJobID,
                onJobEvent: { [weak self] event in
                    await self?.applyBridgeJobStatus(
                        event,
                        keyboardCommandID: keyboardCommandID,
                        shouldAdvanceToRefineWhenTranscriptionCompletes: true
                    )
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
        if let commandID {
            activeKeyboardRecordingCommandID = commandID
        }
        if keyboardDictationCaptureMode == .pictureInPicture,
           !pipDictationCoordinator.isActive {
            appLog.notice("start keyboard recording failed: pip inactive command_id=\(commandID ?? "none", privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-app",
                event: "start_keyboard_recording_failed_pip_inactive",
                fields: [
                    "command_id": commandID ?? "none",
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startAttemptedAt) * 1_000))",
                ]
            )
            postKeyboardCaptureNotReadyReceipt(commandID: commandID, reason: "pip_inactive")
            clearKeyboardCaptureContext()
            resetCorrectionModeToDefault()
            publishKeyboardStatus(.idle, commandID: commandID, message: keyboardMicrophonePreparationMessage)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            return
        }
        let didStartVisibleCapture = await startSelectedVisibleCaptureMode(showErrors: false)
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
        if keyboardAudioSession.isRecording {
            guard phase == .recording else {
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
        if keyboardDictationCaptureMode == .pictureInPicture {
            await startPictureInPictureKeyboardRecording(
                commandID: commandID,
                startAttemptedAt: startAttemptedAt
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
                await resumeKeyboardStandbyAfterCommand()
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
                startAttemptedAt: startAttemptedAt
            )
        } catch {
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
            await resumeKeyboardStandbyAfterCommand()
        }
    }

    private func startPictureInPictureKeyboardRecording(
        commandID: String?,
        startAttemptedAt: TimeInterval
    ) async {
        do {
            if !keyboardAudioSession.isActive {
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
            }
            try await beginPreparedKeyboardAudioRecording(
                commandID: commandID,
                startAttemptedAt: startAttemptedAt
            )
        } catch {
            clearKeyboardCaptureContext()
            resetCorrectionModeToDefault()
            if keyboardAudioSession.isActive, !keyboardAudioSession.isRecording {
                keyboardAudioSession.stop()
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
            try await keyboardAudioSession.start(reuseActiveSession: false)
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
        startAttemptedAt: TimeInterval
    ) async throws {
        _ = try await keyboardAudioSession.beginRecording()
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
        guard keyboardStandbyEnabled else { return }
        guard !keyboardAudioSession.isRecording else { return }
        guard !phase.isBusy else { return }

        let preserveCommandStatus = shouldPreserveKeyboardCommandStatusDuringStandbyResume
        guard keyboardDictationCaptureMode == .backgroundMic else {
            stopBackgroundAudioCaptureForVisibleMode()
            let didPrepare = await prepareSelectedHostCaptureMode(
                showErrors: false,
                preserveCommandStatus: preserveCommandStatus
            )
            if !didPrepare, !preserveCommandStatus {
                publishKeyboardCaptureNotReady()
            }
            return
        }

        do {
            guard await ensureKeyboardLocalBridgeReady(
                reason: "resume_keyboard_standby",
                showErrors: false,
                forceProbe: true
            ) else {
                if !preserveCommandStatus {
                    publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
                }
                return
            }
            let isInputReady = try await prepareKeyboardInputStandby(requestMicrophoneIfNeeded: false)
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
        } catch {
            // This tail runs after recording/transcription has already
            // succeeded. iOS can reject immediate audio-session reactivation
            // while the recorder/route is still settling, so do not surface it
            // as a user-visible failure. Keep the bridge process warm if
            // possible and retry in the background; the next keyboard press can
            // still open the host if input standby is not ready yet.
            appLog.notice("keyboard standby refresh deferred: \(error.localizedDescription, privacy: .public)")
            startSilentStandbyKeeperIfNeeded()
            if !preserveCommandStatus {
                publishKeyboardStatus(.idle, message: keyboardMicrophonePreparationMessage)
            }
            guard retryCount < 2 else { return }
            scheduleKeyboardStandbyRefresh(delay: 2.0 * Double(retryCount + 1), retryCount: retryCount + 1)
        }
    }

    private var shouldPreserveKeyboardCommandStatusDuringStandbyResume: Bool {
        guard keyboardBridgeStatus.commandID != nil else { return false }
        switch keyboardBridgeStatus.state {
        case .error:
            return true
        case .standby:
            let message = keyboardBridgeStatus.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return !message.isEmpty && message != "Ready"
        default:
            return false
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
        BridgeMacSettingsPayload.clampedCorrectionTimeoutMs(macSettings?.correctionTimeoutMs ?? 1500)
    }

    private func setKeyboardBridgeStatus(_ status: KeyboardBridgeStatus, persistSnapshot: Bool = true) {
        keyboardBridgeStatus = status
        keyboardServer.publishStatus(status)
        updateKeyboardStatusAudioLevelPush(for: status)
        guard persistSnapshot else { return }
        KeyboardSharedDefaults.saveStatusSnapshot(status)
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
                    self.keyboardServer.publishStatus(self.keyboardBridgeStatus.withAudioLevel(level))
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
        let hadCapture = hasAnyActiveRecordingCapture
        if let fileURL = recorder.stop(deactivateSession: true) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if keyboardAudioSession.isRecording {
            keyboardAudioSession.cancelRecording()
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
        guard phase.isBusy else { return }
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
        let stageMessage: String?
        let keyboardState: KeyboardBridgeState
        let keyboardProcessingStage: KeyboardBridgeProcessingStage?
        switch event.stage {
        case .audioReceived:
            stageMessage = stageLabels.transcribingMessage(for: event)
            keyboardState = .sending
            keyboardProcessingStage = .transcribing
        case .transcribing:
            stageMessage = shouldPresentRefine
                ? stageLabels.refining
                : stageLabels.transcribingMessage(for: event)
            keyboardState = .sending
            keyboardProcessingStage = shouldPresentRefine ? .refining : .transcribing
        case .transcriptReady:
            stageMessage = shouldPresentRefine
                ? stageLabels.refining
                : stageLabels.transcribingMessage(for: event)
            keyboardState = .sending
            keyboardProcessingStage = shouldPresentRefine ? .refining : .transcribing
        case .refining:
            stageMessage = stageLabels.refining
            keyboardState = .sending
            keyboardProcessingStage = .refining
        case .resultReady:
            stageMessage = stageLabels.resultReady
            keyboardState = .sending
            keyboardProcessingStage = .refining
        case .failed:
            let trimmedError = event.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let failureMessage = trimmedError.isEmpty ? event.message : trimmedError
            stageMessage = Self.isBenignASREmptyMessage(failureMessage) ? nil : failureMessage
            keyboardState = stageMessage == nil ? .standby : .error
            keyboardProcessingStage = nil
        }

        guard let stageMessage else { return }
        if shouldPresentRefine, phase == .sending {
            setPhase(.refining)
        }
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
        let wasPreparing = phase == .preparing
        let affectedAudioSession = hadRecorderCapture
            || hadKeyboardCapture
            || hadInputStandby
            || hadSilentStandby
            || hadPreWarm
            || wasPreparing
        guard affectedAudioSession else { return }

        audioSessionInterruptionActive = true
        keyboardAudioUnavailableMessage = "Microphone is in use by another app."
        appLog.notice("audio session interruption began; ending keyboard audio session")

        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        keyboardStandbyRefreshTask?.cancel()
        keyboardStandbyRefreshTask = nil
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
        teardownLivePartialPreview(clearText: true)

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
        if hasHostOwnedRecordingCapture {
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
        if hasKeyboardOwnedRecordingCapture,
           !keyboardAudioSession.isRecording {
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
