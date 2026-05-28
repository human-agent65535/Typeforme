import CryptoKit
import Foundation

enum TypeformeBundleConfiguration {
    static let fallbackBundlePrefix = "com.example"
    static let productIdentifier = "typeforme"

    static var bundlePrefix: String {
        infoString("TypeformeBundlePrefix") ?? fallbackBundlePrefix
    }

    static var hostBundleIdentifier: String {
        infoString("TypeformeHostBundleIdentifier") ?? "\(bundlePrefix).\(productIdentifier)"
    }

    static var keyboardBundleIdentifier: String {
        infoString("TypeformeKeyboardBundleIdentifier") ?? "\(hostBundleIdentifier).keyboard"
    }

    static var appGroupIdentifier: String {
        infoString("TypeformeAppGroupIdentifier") ?? "group.\(hostBundleIdentifier)"
    }

    static var keyboardNotificationNamespace: String {
        "\(hostBundleIdentifier).keyboard"
    }

    static func isOwnedBundleIdentifier(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == hostBundleIdentifier
            || trimmed == keyboardBundleIdentifier
            || trimmed.hasPrefix("\(hostBundleIdentifier).")
    }

    private static func infoString(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum KeyboardSharedDefaults {
    static var appGroupIdentifier: String { TypeformeBundleConfiguration.appGroupIdentifier }
    static let keyboardDefaultsKey = "keyboard.defaults.v1"
    private static let keyboardStatusKey = "keyboard.status.v1"
    private static let hostHandoffKey = "keyboard.host-handoff.v1"
    private static let hostForegroundKey = "keyboard.host-foreground.v1"

    static func suite() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func loadPayload() -> KeyboardDefaultsPayload? {
        loadCodable(KeyboardDefaultsPayload.self, key: keyboardDefaultsKey)
    }

    @discardableResult
    static func savePayload(_ payload: KeyboardDefaultsPayload) -> Bool {
        saveCodable(payload, key: keyboardDefaultsKey)
    }

    static func bridgeToken(from payload: KeyboardDefaultsPayload?) -> String? {
        guard let token = payload?.bridgeToken else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func saveStatusSnapshot(_ status: KeyboardBridgeStatus) -> Bool {
        saveCodable(status.redactedForSharedDefaults, key: keyboardStatusKey)
    }

    static func loadStatusSnapshot() -> KeyboardBridgeStatus? {
        loadCodable(KeyboardBridgeStatus.self, key: keyboardStatusKey)
    }

    @discardableResult
    static func saveHostForegroundActive(_ active: Bool, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let defaults = suite() else { return false }
        if active {
            defaults.set(now, forKey: hostForegroundKey)
        } else {
            defaults.removeObject(forKey: hostForegroundKey)
        }
        return defaults.synchronize()
    }

    static func isHostForegroundActive(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = 45
    ) -> Bool {
        guard let timestamp = suite()?.object(forKey: hostForegroundKey) as? TimeInterval,
              timestamp > 0
        else { return false }
        return now - timestamp <= maxAge
    }

    static func makeBridgeToken() -> String {
        "\(UUID().uuidString).\(UUID().uuidString)"
    }

    @discardableResult
    static func saveHostHandoff(_ handoff: KeyboardHostHandoff) -> Bool {
        saveCodable(handoff, key: hostHandoffKey)
    }

    static func consumeHostHandoff(id: String, now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardHostHandoff? {
        guard let defaults = suite(),
              let handoff = loadCodable(KeyboardHostHandoff.self, key: hostHandoffKey),
              handoff.id == id,
              handoff.isFresh(now: now)
        else { return nil }
        defaults.removeObject(forKey: hostHandoffKey)
        defaults.synchronize()
        return handoff
    }

    static func consumeLatestHostHandoff(now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardHostHandoff? {
        guard let defaults = suite(),
              let handoff = loadCodable(KeyboardHostHandoff.self, key: hostHandoffKey),
              handoff.isFresh(now: now)
        else { return nil }
        defaults.removeObject(forKey: hostHandoffKey)
        defaults.synchronize()
        return handoff
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let defaults = suite(),
              let text = defaults.string(forKey: key),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    private static func saveCodable<T: Encodable>(_ value: T, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8),
              let defaults = suite()
        else { return false }
        defaults.set(text, forKey: key)
        defaults.synchronize()
        return true
    }
}

enum KeyboardChinesePunctuationStyle: String, CaseIterable, Identifiable, Codable {
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

enum KeyboardRimeDictionaryTier: String, CaseIterable, Identifiable, Codable {
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

enum KeyboardDefaultTextInputLanguage: String, CaseIterable, Identifiable, Codable {
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

struct KeyboardDefaultsPayload: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var bridgeToken: String
    var correctionMode: CorrectionMode
    var autoCapitalizationEnabled: Bool
    var characterPreviewEnabled: Bool
    var chineseInputEnabled: Bool
    var chinesePunctuationStyle: KeyboardChinesePunctuationStyle
    var rimeDictionaryTier: KeyboardRimeDictionaryTier
    var rimeCorrectionEnabled: Bool
    var rimeUserPhrases: [String]
    var rimeUserPhrasesRevision: String
    var defaultTextInputLanguage: KeyboardDefaultTextInputLanguage
    var rimeLearningResetGeneration: Int
    var touchLearningResetGeneration: Int
    var updatedAt: TimeInterval

    init(
        version: Int = Self.currentVersion,
        bridgeToken: String,
        correctionMode: CorrectionMode,
        autoCapitalizationEnabled: Bool,
        characterPreviewEnabled: Bool,
        chineseInputEnabled: Bool,
        chinesePunctuationStyle: KeyboardChinesePunctuationStyle,
        rimeDictionaryTier: KeyboardRimeDictionaryTier,
        rimeCorrectionEnabled: Bool,
        rimeUserPhrases: [String],
        rimeUserPhrasesRevision: String? = nil,
        defaultTextInputLanguage: KeyboardDefaultTextInputLanguage,
        rimeLearningResetGeneration: Int,
        touchLearningResetGeneration: Int,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalizedPhrases = Self.normalizedRimeUserPhrases(rimeUserPhrases)
        self.version = version
        self.bridgeToken = bridgeToken
        self.correctionMode = correctionMode
        self.autoCapitalizationEnabled = autoCapitalizationEnabled
        self.characterPreviewEnabled = characterPreviewEnabled
        self.chineseInputEnabled = chineseInputEnabled
        self.chinesePunctuationStyle = chinesePunctuationStyle
        self.rimeDictionaryTier = rimeDictionaryTier
        self.rimeCorrectionEnabled = rimeCorrectionEnabled
        self.rimeUserPhrases = normalizedPhrases
        self.rimeUserPhrasesRevision = rimeUserPhrasesRevision ?? Self.rimeUserPhrasesRevision(normalizedPhrases)
        self.defaultTextInputLanguage = defaultTextInputLanguage
        self.rimeLearningResetGeneration = rimeLearningResetGeneration
        self.touchLearningResetGeneration = touchLearningResetGeneration
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phrases = try container.decodeIfPresent([String].self, forKey: .rimeUserPhrases) ?? []
        let normalizedPhrases = Self.normalizedRimeUserPhrases(phrases)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        bridgeToken = try container.decode(String.self, forKey: .bridgeToken)
        correctionMode = try container.decode(CorrectionMode.self, forKey: .correctionMode)
        autoCapitalizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCapitalizationEnabled) ?? true
        characterPreviewEnabled = try container.decodeIfPresent(Bool.self, forKey: .characterPreviewEnabled) ?? true
        chineseInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .chineseInputEnabled) ?? true
        chinesePunctuationStyle = try container.decodeIfPresent(
            KeyboardChinesePunctuationStyle.self,
            forKey: .chinesePunctuationStyle
        ) ?? .chinese
        rimeDictionaryTier = try container.decodeIfPresent(
            KeyboardRimeDictionaryTier.self,
            forKey: .rimeDictionaryTier
        ) ?? .standard
        rimeCorrectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .rimeCorrectionEnabled) ?? true
        rimeUserPhrases = normalizedPhrases
        rimeUserPhrasesRevision = try container.decodeIfPresent(String.self, forKey: .rimeUserPhrasesRevision)
            ?? Self.rimeUserPhrasesRevision(normalizedPhrases)
        defaultTextInputLanguage = try container.decodeIfPresent(
            KeyboardDefaultTextInputLanguage.self,
            forKey: .defaultTextInputLanguage
        ) ?? .lastUsed
        rimeLearningResetGeneration = try container.decodeIfPresent(Int.self, forKey: .rimeLearningResetGeneration) ?? 0
        touchLearningResetGeneration = try container.decodeIfPresent(Int.self, forKey: .touchLearningResetGeneration) ?? 0
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case version
        case bridgeToken = "bridge_token"
        case correctionMode = "correction_mode"
        case autoCapitalizationEnabled = "auto_capitalization_enabled"
        case characterPreviewEnabled = "character_preview_enabled"
        case chineseInputEnabled = "chinese_input_enabled"
        case chinesePunctuationStyle = "chinese_punctuation_style"
        case rimeDictionaryTier = "rime_dictionary_tier"
        case rimeCorrectionEnabled = "rime_correction_enabled"
        case rimeUserPhrases = "rime_user_phrases"
        case rimeUserPhrasesRevision = "rime_user_phrases_revision"
        case defaultTextInputLanguage = "default_text_input_language"
        case rimeLearningResetGeneration = "rime_learning_reset_generation"
        case touchLearningResetGeneration = "touch_learning_reset_generation"
        case updatedAt = "updated_at"
    }

    var stableSignature: String {
        var payload = self
        payload.updatedAt = 0
        guard let data = try? Self.sortedEncoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else { return UUID().uuidString }
        return text
    }

    private static var sortedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func normalizedRimeUserPhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for phrase in phrases {
            let cleaned = phrase
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return output.sorted()
    }

    private static func rimeUserPhrasesRevision(_ phrases: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: phrases, options: [.sortedKeys]) else {
            return ""
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum KeyboardDarwinNotificationName {
    private static let namespace = TypeformeBundleConfiguration.keyboardNotificationNamespace
    static let transcriptionReady = "\(namespace).transcriptionReady"
    static let dictationStarted = "\(namespace).dictationStarted"
    static let dictationStopped = "\(namespace).dictationStopped"
    static let sessionStarted = "\(namespace).sessionStarted"
    static let sessionEnded = "\(namespace).sessionEnded"
    static let requestSessionStatus = "\(namespace).requestSessionStatus"
    static let requestStartDictation = "\(namespace).requestStartDictation"
    static let requestStopDictation = "\(namespace).requestStopDictation"
    static let requestCancelDictation = "\(namespace).requestCancelDictation"
    static let keyboardDefaultsChanged = "\(namespace).defaultsChanged"
    static let fullAccessRequired = "\(namespace).fullAccessRequired"

    static func authenticatedRequest(_ name: String, token: String?) -> String? {
        guard let token,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return "\(name).\(token)"
    }
}

enum KeyboardDarwinBridge {
    static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, callback: @escaping () -> Void) -> KeyboardDarwinNotificationObserver {
        KeyboardDarwinNotificationObserver(name: name, callback: callback)
    }
}

final class KeyboardDarwinNotificationObserver {
    private let name: String
    private let callback: () -> Void
    private var isObserving = false

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let object = Unmanaged<KeyboardDarwinNotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                object.callback()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        isObserving = true
    }

    deinit {
        stopObserving()
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
    }
}

enum VoiceInputMode: String, CaseIterable, Identifiable, Codable {
    case hold
    case tap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: return NSLocalizedString("Hold", comment: "Voice input mode label")
        case .tap:  return NSLocalizedString("Tap", comment: "Voice input mode label")
        }
    }

    var idleTitle: String {
        switch self {
        case .hold: return NSLocalizedString("Hold to Speak", comment: "Voice input mode idle prompt")
        case .tap:  return NSLocalizedString("Tap to Speak", comment: "Voice input mode idle prompt")
        }
    }

    var recordingTitle: String {
        switch self {
        case .hold: return NSLocalizedString("Release to Send", comment: "Voice input mode recording prompt")
        case .tap:  return NSLocalizedString("Tap to Finish", comment: "Voice input mode recording prompt")
        }
    }

    var idleDetail: String {
        switch self {
        case .hold: return NSLocalizedString("Press and hold, then release to transcribe.", comment: "Voice input mode help text")
        case .tap:  return NSLocalizedString("Tap once to record, tap again to send.", comment: "Voice input mode help text")
        }
    }
}

enum KeyboardBridgeCommandAction: String, Codable {
    case start
    case stop
    case cancel
    case configure
    case restyleText = "restyle_text"
}

enum KeyboardTextEditIntent: String, Codable {
    case repairSelection = "repair_selection"
    case command = "command"
}

struct KeyboardTextEditContext: Codable, Equatable {
    let intent: KeyboardTextEditIntent
    let contextBefore: String
    let targetText: String
    let contextAfter: String

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
    }
}

struct KeyboardDictationContext: Codable, Equatable {
    let contextBefore: String
    let contextAfter: String

    enum CodingKeys: String, CodingKey {
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

struct KeyboardBridgeCommand: Codable, Equatable {
    let id: String
    let action: KeyboardBridgeCommandAction
    let correctionMode: String
    let text: String?
    let textEditContext: KeyboardTextEditContext?
    let dictationContext: KeyboardDictationContext?
    let createdAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        action: KeyboardBridgeCommandAction,
        correctionMode: String,
        text: String? = nil,
        textEditContext: KeyboardTextEditContext? = nil,
        dictationContext: KeyboardDictationContext? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.action = action
        self.correctionMode = correctionMode
        self.text = text
        self.textEditContext = textEditContext
        self.dictationContext = dictationContext
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case correctionMode
        case text
        case textEditContext = "text_edit_context"
        case dictationContext = "dictation_context"
        case createdAt
    }
}

struct KeyboardHostHandoff: Codable, Equatable {
    static let maxAge: TimeInterval = 30

    let id: String
    let action: String
    let shouldReturnToKeyboard: Bool
    let correctionMode: String
    let returnBundleID: String?
    let returnProcessID: Int32?
    let createdAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        action: String,
        shouldReturnToKeyboard: Bool,
        correctionMode: String,
        returnBundleID: String?,
        returnProcessID: Int32?,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.action = action
        self.shouldReturnToKeyboard = shouldReturnToKeyboard
        self.correctionMode = correctionMode
        self.returnBundleID = returnBundleID
        self.returnProcessID = returnProcessID
        self.createdAt = createdAt
    }

    func isFresh(now: TimeInterval) -> Bool {
        createdAt <= now && now - createdAt <= Self.maxAge
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case shouldReturnToKeyboard = "return_to_keyboard"
        case correctionMode = "correction_mode"
        case returnBundleID = "return_bundle"
        case returnProcessID = "return_pid"
        case createdAt = "created_at"
    }
}

struct KeyboardLocalBridgeHello: Codable, Equatable {
    let version: Int
    let nonce: String
    let proof: String
}

struct KeyboardLocalBridgeProof: Codable, Equatable {
    let nonce: String
    let proof: String
}

enum KeyboardLocalBridgeAuth {
    private static let version = 1
    private static let serverPurpose = "server"
    private static let clientPurpose = "client"

    static func makeServerHello(bridgeToken: String) -> KeyboardLocalBridgeHello? {
        let nonce = makeNonce()
        guard let proof = proof(bridgeToken: bridgeToken, purpose: serverPurpose, nonce: nonce) else { return nil }
        return KeyboardLocalBridgeHello(version: version, nonce: nonce, proof: proof)
    }

    static func verifyServerHello(_ hello: KeyboardLocalBridgeHello, bridgeToken: String) -> Bool {
        guard hello.version == version else { return false }
        return verify(proof: hello.proof, bridgeToken: bridgeToken, purpose: serverPurpose, nonce: hello.nonce)
    }

    static func makeClientProof(bridgeToken: String) -> KeyboardLocalBridgeProof? {
        let nonce = makeNonce()
        guard let proof = proof(bridgeToken: bridgeToken, purpose: clientPurpose, nonce: nonce) else { return nil }
        return KeyboardLocalBridgeProof(nonce: nonce, proof: proof)
    }

    static func verifyClientProof(_ authentication: KeyboardLocalBridgeProof?, bridgeToken: String) -> Bool {
        guard let authentication else { return false }
        return verify(
            proof: authentication.proof,
            bridgeToken: bridgeToken,
            purpose: clientPurpose,
            nonce: authentication.nonce
        )
    }

    private static func makeNonce() -> String {
        "\(UUID().uuidString).\(UUID().uuidString)"
    }

    private static func proof(bridgeToken: String, purpose: String, nonce: String) -> String? {
        let token = bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              !nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let message = "typeforme.keyboard.local.\(purpose).v\(version).\(nonce)"
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func verify(proof suppliedProof: String, bridgeToken: String, purpose: String, nonce: String) -> Bool {
        guard let expectedProof = proof(bridgeToken: bridgeToken, purpose: purpose, nonce: nonce) else { return false }
        return constantTimeEquals(suppliedProof, expectedProof)
    }

    private static func constantTimeEquals(_ supplied: String, _ expected: String) -> Bool {
        let suppliedBytes = Array(supplied.utf8)
        let expectedBytes = Array(expected.utf8)
        var diff = suppliedBytes.count ^ expectedBytes.count
        let count = max(suppliedBytes.count, expectedBytes.count)
        for index in 0..<count {
            let suppliedByte = index < suppliedBytes.count ? suppliedBytes[index] : 0
            let expectedByte = index < expectedBytes.count ? expectedBytes[index] : 0
            diff |= Int(suppliedByte ^ expectedByte)
        }
        return diff == 0
    }
}

struct KeyboardLocalBridgeRequest: Codable, Equatable {
    enum Action: String, Codable {
        case status
        case command
    }

    let action: Action
    let authentication: KeyboardLocalBridgeProof?
    let command: KeyboardBridgeCommand?

    static func status(bridgeToken: String?) -> KeyboardLocalBridgeRequest {
        KeyboardLocalBridgeRequest(
            action: .status,
            authentication: bridgeToken.flatMap { KeyboardLocalBridgeAuth.makeClientProof(bridgeToken: $0) },
            command: nil
        )
    }

    static func command(_ command: KeyboardBridgeCommand, bridgeToken: String?) -> KeyboardLocalBridgeRequest {
        KeyboardLocalBridgeRequest(
            action: .command,
            authentication: bridgeToken.flatMap { KeyboardLocalBridgeAuth.makeClientProof(bridgeToken: $0) },
            command: command
        )
    }

    enum CodingKeys: String, CodingKey {
        case action
        case authentication = "authentication"
        case command
    }
}

enum KeyboardBridgeState: String, Codable {
    case idle
    case standby
    case recording
    case sending
    case result
    case error
}

struct KeyboardBridgeStatus: Codable, Equatable {
    let commandID: String?
    let state: KeyboardBridgeState
    let message: String
    let resultText: String?
    let audioDurationSeconds: Double?
    let audioByteCount: Int?
    let rawTranscriptLength: Int?
    let defaultCorrectionMode: String?
    /// Normalized 0...1 RMS-ish microphone level captured by the host app's
    /// `AudioRecorder` and surfaced on every `/status` poll. `nil` when the
    /// host can't sample (e.g. before recording starts).
    let audioLevel: Float?
    /// Live partial transcript from Apple Speech recognition, fed continuously
    /// while recording. The keyboard renders this as the user speaks; the Mac
    /// final result later replaces it. `nil` / empty when no preview is
    /// available (unsupported locale, denied permission, or not recording).
    let livePartialTranscript: String?
    /// Host's last-known Mac bridge reachability — `true` if the last route
    /// probe found a usable bridge URL (local LAN or Cloudflare), `false` if
    /// the last probe failed, `nil` if the host hasn't probed yet this
    /// session. Keyboard treats `nil` optimistically (assume reachable) —
    /// the orb's failure path surfaces the real error if dictation fails.
    let backendReachable: Bool?
    let updatedAt: TimeInterval

    init(
        commandID: String? = nil,
        state: KeyboardBridgeState,
        message: String,
        resultText: String? = nil,
        audioDurationSeconds: Double? = nil,
        audioByteCount: Int? = nil,
        rawTranscriptLength: Int? = nil,
        defaultCorrectionMode: String? = nil,
        audioLevel: Float? = nil,
        livePartialTranscript: String? = nil,
        backendReachable: Bool? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.commandID = commandID
        self.state = state
        self.message = message
        self.resultText = resultText
        self.audioDurationSeconds = audioDurationSeconds
        self.audioByteCount = audioByteCount
        self.rawTranscriptLength = rawTranscriptLength
        self.defaultCorrectionMode = defaultCorrectionMode
        self.audioLevel = audioLevel
        self.livePartialTranscript = livePartialTranscript
        self.backendReachable = backendReachable
        self.updatedAt = updatedAt
    }

    func withAudioLevel(_ level: Float?) -> KeyboardBridgeStatus {
        KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message,
            resultText: resultText,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: defaultCorrectionMode,
            audioLevel: level,
            livePartialTranscript: livePartialTranscript,
            backendReachable: backendReachable,
            updatedAt: updatedAt
        )
    }

    func withLivePartialTranscript(_ text: String?) -> KeyboardBridgeStatus {
        KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message,
            resultText: resultText,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: defaultCorrectionMode,
            audioLevel: audioLevel,
            livePartialTranscript: text?.isEmpty == true ? nil : text,
            backendReachable: backendReachable,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    func withBackendReachable(_ reachable: Bool?) -> KeyboardBridgeStatus {
        KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message,
            resultText: resultText,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: defaultCorrectionMode,
            audioLevel: audioLevel,
            livePartialTranscript: livePartialTranscript,
            backendReachable: reachable,
            updatedAt: updatedAt
        )
    }

    static let idle = KeyboardBridgeStatus(state: .idle, message: "Keyboard standby is off")

    var redactedForSharedDefaults: KeyboardBridgeStatus {
        KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message,
            resultText: nil,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: defaultCorrectionMode,
            audioLevel: nil,
            livePartialTranscript: livePartialTranscript,
            backendReachable: backendReachable,
            updatedAt: updatedAt
        )
    }
}
