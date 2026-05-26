import CryptoKit
import Foundation

enum KeyboardSharedDefaults {
    static let appGroupIdentifier = "group.com.example.typeforme"
    static let keyboardDefaultsKey = "keyboard.defaults.v1"
    private static let hostHandoffKey = "keyboard.host-handoff.v1"

    static func suite() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func loadPayload() -> [String: Any]? {
        guard let defaults = suite(),
              let text = defaults.string(forKey: keyboardDefaultsKey),
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload
    }

    @discardableResult
    static func savePayload(_ payload: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8),
              let defaults = suite()
        else { return false }
        defaults.set(text, forKey: keyboardDefaultsKey)
        defaults.synchronize()
        return true
    }

    static func bridgeToken(from payload: [String: Any]?) -> String? {
        guard let token = payload?["bridge_token"] as? String else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func makeBridgeToken() -> String {
        "\(UUID().uuidString).\(UUID().uuidString)"
    }

    @discardableResult
    static func saveHostHandoff(_ handoff: KeyboardHostHandoff) -> Bool {
        guard let data = try? JSONEncoder().encode(handoff),
              let text = String(data: data, encoding: .utf8),
              let defaults = suite()
        else { return false }
        defaults.set(text, forKey: hostHandoffKey)
        defaults.synchronize()
        return true
    }

    static func consumeHostHandoff(id: String, now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardHostHandoff? {
        guard let defaults = suite(),
              let text = defaults.string(forKey: hostHandoffKey),
              let data = text.data(using: .utf8),
              let handoff = try? JSONDecoder().decode(KeyboardHostHandoff.self, from: data),
              handoff.id == id,
              handoff.isFresh(now: now)
        else { return nil }
        defaults.removeObject(forKey: hostHandoffKey)
        defaults.synchronize()
        return handoff
    }
}

enum KeyboardDarwinNotificationName {
    static let transcriptionReady = "com.example.typeforme.keyboard.transcriptionReady"
    static let dictationStarted = "com.example.typeforme.keyboard.dictationStarted"
    static let dictationStopped = "com.example.typeforme.keyboard.dictationStopped"
    static let sessionStarted = "com.example.typeforme.keyboard.sessionStarted"
    static let sessionEnded = "com.example.typeforme.keyboard.sessionEnded"
    static let requestSessionStatus = "com.example.typeforme.keyboard.requestSessionStatus"
    static let requestStartDictation = "com.example.typeforme.keyboard.requestStartDictation"
    static let requestStopDictation = "com.example.typeforme.keyboard.requestStopDictation"
    static let requestCancelDictation = "com.example.typeforme.keyboard.requestCancelDictation"
    static let keyboardDefaultsChanged = "com.example.typeforme.keyboard.defaultsChanged"
    static let fullAccessRequired = "com.example.typeforme.keyboard.fullAccessRequired"

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
            updatedAt: Date().timeIntervalSince1970
        )
    }

    static let idle = KeyboardBridgeStatus(state: .idle, message: "Keyboard standby is off")
}
