import CryptoKit
import Foundation
import Security

enum TypeformeBundleConfiguration {
    static let productIdentifier = "typeforme"

    static var bundlePrefix: String {
        requiredInfoString("TypeformeBundlePrefix")
    }

    static var hostBundleIdentifier: String {
        requiredInfoString("TypeformeHostBundleIdentifier")
    }

    static var keyboardBundleIdentifier: String {
        requiredInfoString("TypeformeKeyboardBundleIdentifier")
    }

    static var appGroupIdentifier: String {
        requiredInfoString("TypeformeAppGroupIdentifier")
    }

    static var keychainAccessGroup: String? {
        infoString("TypeformeKeychainAccessGroup")
    }

    static var currentBundleIdentifier: String {
        guard let identifier = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !identifier.isEmpty
        else {
            preconditionFailure("Typeforme requires CFBundleIdentifier at runtime")
        }
        return identifier
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

    private static func requiredInfoString(_ key: String) -> String {
        guard let value = infoString(key) else {
            preconditionFailure("Typeforme requires \(key) in Info.plist")
        }
        return value
    }
}

enum KeyboardDiagnosticEventLog {
    private struct Entry: Encodable {
        var timestamp: TimeInterval
        var bundle: String
        var source: String
        var event: String
        var fields: [String: String]
    }

    private static let maxBytes: UInt64 = 256 * 1024
    private static let lock = NSLock()

    static func record(source: String, event: String, fields: [String: String] = [:]) {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TypeformeBundleConfiguration.appGroupIdentifier
        ) else { return }

        let directory = baseURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("KeyboardDiagnostics", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(fileComponent(source)).jsonl")
        let entry = Entry(
            timestamp: Date().timeIntervalSince1970,
            bundle: TypeformeBundleConfiguration.currentBundleIdentifier,
            source: sanitized(source),
            event: sanitized(event),
            fields: fields.mapValues(sanitized)
        )

        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded(fileURL, fileManager: fileManager)
            var data = try JSONEncoder().encode(entry)
            data.append(0x0A)
            if fileManager.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Diagnostics must never affect keyboard availability.
        }
    }

    private static func rotateIfNeeded(_ fileURL: URL, fileManager: FileManager) throws {
        guard let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
              size >= maxBytes
        else { return }
        let rotatedURL = fileURL.deletingPathExtension().appendingPathExtension("previous.jsonl")
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try? fileManager.removeItem(at: rotatedURL)
        }
        try? fileManager.moveItem(at: fileURL, to: rotatedURL)
    }

    private static func fileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return result.isEmpty ? "unknown" : result
    }

    private static func sanitized(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(normalized.prefix(240))
    }
}

enum KeyboardSharedDefaults {
    static var appGroupIdentifier: String { TypeformeBundleConfiguration.appGroupIdentifier }
    static let keyboardDefaultsKey = "keyboard.defaults.v3"
    private static let keyboardStatusKey = "keyboard.status.v1"
    private static let hostHandoffKey = "keyboard.host-handoff.v1"
    private static let hostForegroundKey = "keyboard.host-foreground.v1"
    private static let commandReceiptKey = "keyboard.command-receipt.v1"
    private static let keyboardHostIssueKey = "keyboard.host-issue.v1"
    private static let touchLearningStatsKey = "keyboard.touchLearningStats.v1"
    private static let chineseLearningKey = "keyboard.chineseLearning.v1"

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
        return true
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

    @discardableResult
    static func saveKeyboardHostIssue(_ issue: KeyboardHostIssueReport) -> Bool {
        saveCodable(issue, key: keyboardHostIssueKey, flush: true)
    }

    static func consumeKeyboardHostIssue(
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> KeyboardHostIssueReport? {
        guard let defaults = suite(),
              let issue = loadCodable(KeyboardHostIssueReport.self, key: keyboardHostIssueKey)
        else { return nil }
        defaults.removeObject(forKey: keyboardHostIssueKey)
        return issue.isFresh(now: now) ? issue : nil
    }

    static func makeBridgeToken() -> String {
        "\(UUID().uuidString).\(UUID().uuidString)"
    }

    /// The keyboard mirrors its per-key touch-offset stats here so the host
    /// app can display them — the extension's own UserDefaults are invisible
    /// to the host, which made touch learning unverifiable from the UI.
    @discardableResult
    static func saveTouchLearningSnapshot(_ snapshot: KeyboardTouchLearningSnapshot) -> Bool {
        saveCodable(snapshot, key: touchLearningStatsKey)
    }

    static func loadTouchLearningSnapshot() -> KeyboardTouchLearningSnapshot? {
        loadCodable(KeyboardTouchLearningSnapshot.self, key: touchLearningStatsKey)
    }

    static func clearTouchLearningSnapshot() {
        suite()?.removeObject(forKey: touchLearningStatsKey)
    }

    /// Recently committed Chinese phrases — the host-visible proxy for rime's
    /// self-learning, whose user dictionary lives inside the extension
    /// sandbox and cannot be enumerated from the host.
    @discardableResult
    static func saveChineseLearningSnapshot(_ snapshot: KeyboardChineseLearningSnapshot) -> Bool {
        saveCodable(snapshot, key: chineseLearningKey)
    }

    static func loadChineseLearningSnapshot() -> KeyboardChineseLearningSnapshot? {
        loadCodable(KeyboardChineseLearningSnapshot.self, key: chineseLearningKey)
    }

    static func clearChineseLearningSnapshot() {
        suite()?.removeObject(forKey: chineseLearningKey)
    }

    @discardableResult
    static func saveHostHandoff(_ handoff: KeyboardHostHandoff) -> Bool {
        saveCodable(handoff, key: hostHandoffKey, flush: true)
    }

    static func consumeHostHandoff(id: String, now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardHostHandoff? {
        guard let defaults = suite(),
              let handoff = loadCodable(KeyboardHostHandoff.self, key: hostHandoffKey),
              handoff.id == id,
              handoff.isFresh(now: now)
        else { return nil }
        defaults.removeObject(forKey: hostHandoffKey)
        return handoff
    }

    static func consumeLatestHostHandoff(now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardHostHandoff? {
        guard let defaults = suite(),
              let handoff = loadCodable(KeyboardHostHandoff.self, key: hostHandoffKey),
              handoff.isFresh(now: now)
        else { return nil }
        defaults.removeObject(forKey: hostHandoffKey)
        return handoff
    }

    @discardableResult
    static func saveCommandReceipt(_ receipt: KeyboardCommandReceipt) -> Bool {
        saveCodable(receipt, key: commandReceiptKey, flush: true)
    }

    static func loadCommandReceipt(now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardCommandReceipt? {
        guard let defaults = suite(),
              let receipt = loadCodable(KeyboardCommandReceipt.self, key: commandReceiptKey)
        else { return nil }
        guard receipt.isFresh(now: now) else {
            defaults.removeObject(forKey: commandReceiptKey)
            return nil
        }
        return receipt
    }

    static func clearCommandReceipt() {
        suite()?.removeObject(forKey: commandReceiptKey)
    }

    @discardableResult
    static func saveDarwinCommand(_ command: KeyboardBridgeCommand) -> Bool {
        saveCodable(command, key: darwinCommandKey(for: command.action), flush: true)
    }

    static func consumeDarwinCommand(
        action: KeyboardBridgeCommandAction,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> KeyboardBridgeCommand? {
        guard let defaults = suite(),
              let command = loadCodable(KeyboardBridgeCommand.self, key: darwinCommandKey(for: action))
        else { return nil }
        guard command.action == action, command.isFresh(now: now) else {
            defaults.removeObject(forKey: darwinCommandKey(for: action))
            return nil
        }
        defaults.removeObject(forKey: darwinCommandKey(for: action))
        return command
    }

    private static func darwinCommandKey(for action: KeyboardBridgeCommandAction) -> String {
        "keyboard.darwin-command.\(action.rawValue).v1"
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let defaults = suite(),
              let text = defaults.string(forKey: key),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    private static func saveCodable<T: Encodable>(_ value: T, key: String, flush: Bool = false) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8),
              let defaults = suite()
        else { return false }
        defaults.set(text, forKey: key)
        if flush {
            // One-shot handoff/command payloads are consumed immediately by the
            // other process after a URL open or Darwin notification. Pay the
            // blocking flush cost only for those control-plane writes; high-rate
            // status snapshots keep the default async propagation.
            defaults.synchronize()
        }
        return true
    }
}

enum KeyboardSharedKeychain {
    private static let keyboardBridgeService = "\(TypeformeBundleConfiguration.hostBundleIdentifier).keyboard-bridge"
    private static let keyboardBridgeAccount = "keyboard-bridge-token"

    static func keyboardBridgeToken() -> String? {
        string(service: keyboardBridgeService, account: keyboardBridgeAccount)
    }

    @discardableResult
    static func saveKeyboardBridgeToken(_ token: String) -> Bool {
        save(token, service: keyboardBridgeService, account: keyboardBridgeAccount)
    }

    @discardableResult
    static func deleteKeyboardBridgeToken() -> Bool {
        delete(service: keyboardBridgeService, account: keyboardBridgeAccount)
    }

    private static func string(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private static func save(_ token: String, service: String, account: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(service: service, account: account)
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup = TypeformeBundleConfiguration.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
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
            return NSLocalizedString("Extra Large", comment: "Rime dictionary tier")
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
    static let currentVersion = 3

    var version: Int
    var correctionMode: CorrectionMode
    var autoCapitalizationEnabled: Bool
    var characterPreviewEnabled: Bool
    var keySoundEnabled: Bool
    var keyHapticsEnabled: Bool
    var chineseInputEnabled: Bool
    var chinesePunctuationStyle: KeyboardChinesePunctuationStyle
    var rimeDictionaryTier: KeyboardRimeDictionaryTier
    var rimeLearningEnabled: Bool
    var rimeCorrectionEnabled: Bool
    var touchLearningEnabled: Bool
    var rimeUserPhrases: [String]
    var rimeUserPhrasesRevision: String
    var defaultTextInputLanguage: KeyboardDefaultTextInputLanguage
    var rimeLearningResetGeneration: Int
    var touchLearningResetGeneration: Int
    var updatedAt: TimeInterval

    init(
        version: Int = Self.currentVersion,
        correctionMode: CorrectionMode,
        autoCapitalizationEnabled: Bool,
        characterPreviewEnabled: Bool,
        keySoundEnabled: Bool = true,
        keyHapticsEnabled: Bool = true,
        chineseInputEnabled: Bool,
        chinesePunctuationStyle: KeyboardChinesePunctuationStyle,
        rimeDictionaryTier: KeyboardRimeDictionaryTier,
        rimeLearningEnabled: Bool = true,
        rimeCorrectionEnabled: Bool,
        touchLearningEnabled: Bool = true,
        rimeUserPhrases: [String],
        rimeUserPhrasesRevision: String? = nil,
        defaultTextInputLanguage: KeyboardDefaultTextInputLanguage,
        rimeLearningResetGeneration: Int,
        touchLearningResetGeneration: Int,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalizedPhrases = Self.normalizedRimeUserPhrases(rimeUserPhrases)
        self.version = version
        self.correctionMode = correctionMode
        self.autoCapitalizationEnabled = autoCapitalizationEnabled
        self.characterPreviewEnabled = characterPreviewEnabled
        self.keySoundEnabled = keySoundEnabled
        self.keyHapticsEnabled = keyHapticsEnabled
        self.chineseInputEnabled = chineseInputEnabled
        self.chinesePunctuationStyle = chinesePunctuationStyle
        self.rimeDictionaryTier = rimeDictionaryTier
        self.rimeLearningEnabled = rimeLearningEnabled
        self.rimeCorrectionEnabled = rimeCorrectionEnabled
        self.touchLearningEnabled = touchLearningEnabled
        self.rimeUserPhrases = normalizedPhrases
        self.rimeUserPhrasesRevision = rimeUserPhrasesRevision ?? Self.rimeUserPhrasesRevision(normalizedPhrases)
        self.defaultTextInputLanguage = defaultTextInputLanguage
        self.rimeLearningResetGeneration = rimeLearningResetGeneration
        self.touchLearningResetGeneration = touchLearningResetGeneration
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phrases = try container.decode([String].self, forKey: .rimeUserPhrases)
        let normalizedPhrases = Self.normalizedRimeUserPhrases(phrases)
        version = try container.decode(Int.self, forKey: .version)
        correctionMode = try container.decode(CorrectionMode.self, forKey: .correctionMode)
        autoCapitalizationEnabled = try container.decode(Bool.self, forKey: .autoCapitalizationEnabled)
        characterPreviewEnabled = try container.decode(Bool.self, forKey: .characterPreviewEnabled)
        keySoundEnabled = try container.decode(Bool.self, forKey: .keySoundEnabled)
        keyHapticsEnabled = try container.decode(Bool.self, forKey: .keyHapticsEnabled)
        chineseInputEnabled = try container.decode(Bool.self, forKey: .chineseInputEnabled)
        chinesePunctuationStyle = try container.decode(
            KeyboardChinesePunctuationStyle.self,
            forKey: .chinesePunctuationStyle
        )
        rimeDictionaryTier = try container.decode(
            KeyboardRimeDictionaryTier.self,
            forKey: .rimeDictionaryTier
        )
        rimeLearningEnabled = try container.decode(Bool.self, forKey: .rimeLearningEnabled)
        rimeCorrectionEnabled = try container.decode(Bool.self, forKey: .rimeCorrectionEnabled)
        touchLearningEnabled = try container.decode(Bool.self, forKey: .touchLearningEnabled)
        rimeUserPhrases = normalizedPhrases
        rimeUserPhrasesRevision = try container.decode(String.self, forKey: .rimeUserPhrasesRevision)
        defaultTextInputLanguage = try container.decode(
            KeyboardDefaultTextInputLanguage.self,
            forKey: .defaultTextInputLanguage
        )
        rimeLearningResetGeneration = try container.decode(Int.self, forKey: .rimeLearningResetGeneration)
        touchLearningResetGeneration = try container.decode(Int.self, forKey: .touchLearningResetGeneration)
        updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case correctionMode = "correction_mode"
        case autoCapitalizationEnabled = "auto_capitalization_enabled"
        case characterPreviewEnabled = "character_preview_enabled"
        case keySoundEnabled = "key_sound_enabled"
        case keyHapticsEnabled = "key_haptics_enabled"
        case chineseInputEnabled = "chinese_input_enabled"
        case chinesePunctuationStyle = "chinese_punctuation_style"
        case rimeDictionaryTier = "rime_dictionary_tier"
        case rimeLearningEnabled = "rime_learning_enabled"
        case rimeCorrectionEnabled = "rime_correction_enabled"
        case touchLearningEnabled = "touch_learning_enabled"
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
        let data: Data
        do {
            data = try Self.sortedEncoder.encode(payload)
        } catch {
            preconditionFailure("Could not encode keyboard defaults signature: \(error)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("Keyboard defaults signature JSON was not UTF-8")
        }
        return text
    }

    private static var sortedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func normalizedRimeUserPhrases(_ phrases: [String]) -> [String] {
        RimeUserPhraseNormalizer.normalized(phrases)
    }

    private static func rimeUserPhrasesRevision(_ phrases: [String]) -> String {
        RimeUserPhraseNormalizer.revision(forNormalized: phrases)
    }
}

/// Read-only mirror of the keyboard's touch-learning model. Written by the
/// keyboard extension on a throttled stats mirror; read by the host app's
/// Keyboard Settings inspector. Offsets are normalized to key size
/// (positive x = right of key center, positive y = below key center).
struct KeyboardTouchLearningKeyStats: Codable, Equatable {
    let sampleCount: Double
    let meanX: Double
    let meanY: Double
    let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sampleCount = "sample_count"
        case meanX = "mean_x"
        case meanY = "mean_y"
        case updatedAt = "updated_at"
    }
}

struct KeyboardTouchLearningSnapshot: Codable, Equatable {
    let version: Int
    let updatedAt: TimeInterval
    let keys: [String: KeyboardTouchLearningKeyStats]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case keys
    }
}

struct KeyboardChineseLearningEntry: Codable, Equatable {
    let text: String
    let count: Int
    let lastUsedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case text
        case count
        case lastUsedAt = "last_used_at"
    }
}

struct KeyboardChineseLearningSnapshot: Codable, Equatable {
    let updatedAt: TimeInterval
    let entries: [KeyboardChineseLearningEntry]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case entries
    }
}

struct KeyboardHostIssueReport: Codable, Equatable, Sendable {
    static let maxAge: TimeInterval = 5 * 60

    let id: String
    let commandID: String?
    let message: String
    let createdAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        commandID: String?,
        message: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.commandID = commandID
        self.message = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        self.createdAt = createdAt
    }

    func isFresh(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let age = now - createdAt
        return age >= 0 && age <= Self.maxAge
    }

    enum CodingKeys: String, CodingKey {
        case id
        case commandID = "command_id"
        case message
        case createdAt = "created_at"
    }
}

enum KeyboardCommandReceiptPhase: String, Codable, Sendable {
    case accepted
    case bridgeReady = "bridge_ready"
    case bridgeUnavailable = "bridge_unavailable"
    case captureNotReady = "capture_not_ready"
    case failed
}

struct KeyboardCommandReceipt: Codable, Equatable, Sendable {
    static let maxAge: TimeInterval = 10

    let id: String
    let commandID: String
    let action: KeyboardBridgeCommandAction
    let phase: KeyboardCommandReceiptPhase
    let reason: String?
    let createdAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        commandID: String,
        action: KeyboardBridgeCommandAction,
        phase: KeyboardCommandReceiptPhase,
        reason: String? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.commandID = commandID
        self.action = action
        self.phase = phase
        self.reason = reason.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        self.createdAt = createdAt
    }

    func isFresh(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let age = now - createdAt
        return age >= 0 && age <= Self.maxAge
    }

    enum CodingKeys: String, CodingKey {
        case id
        case commandID = "command_id"
        case action
        case phase
        case reason
        case createdAt = "created_at"
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
    static let keyboardIssueReported = "\(namespace).issueReported"
    static let commandReceiptUpdated = "\(namespace).commandReceiptUpdated"

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

enum KeyboardBridgeCommandAction: String, Codable, Sendable {
    case start
    case stop
    case cancel
    case configure
    case refineText = "refine_text"
}

struct KeyboardTextEditContext: Codable, Equatable, Sendable {
    let intent: TextEditIntent
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

struct KeyboardDictationContext: Codable, Equatable, Sendable {
    let contextBefore: String
    let contextAfter: String

    enum CodingKeys: String, CodingKey {
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

struct KeyboardBridgeCommand: Codable, Equatable, Sendable {
    static let maxAge: TimeInterval = 60

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

    func isFresh(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        now - createdAt < Self.maxAge
    }
}

struct KeyboardHostHandoff: Codable, Equatable {
    static let maxAge: TimeInterval = 30

    let id: String
    let action: String
    let correctionMode: String
    let createdAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        action: String,
        correctionMode: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.action = action
        self.correctionMode = correctionMode
        self.createdAt = createdAt
    }

    func isFresh(now: TimeInterval) -> Bool {
        createdAt <= now && now - createdAt <= Self.maxAge
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case correctionMode = "correction_mode"
        case createdAt = "created_at"
    }
}

struct KeyboardLocalBridgeHello: Codable, Equatable, Sendable {
    let version: Int
    let nonce: String
    let proof: String
}

struct KeyboardLocalBridgeProof: Codable, Equatable, Sendable {
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

struct KeyboardLocalBridgeRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case statusStream = "status_stream"
        case statusSnapshot = "status_snapshot"
        case command
    }

    let action: Action
    let authentication: KeyboardLocalBridgeProof?
    let command: KeyboardBridgeCommand?

    static func statusStream(bridgeToken: String?) -> KeyboardLocalBridgeRequest {
        KeyboardLocalBridgeRequest(
            action: .statusStream,
            authentication: bridgeToken.flatMap { KeyboardLocalBridgeAuth.makeClientProof(bridgeToken: $0) },
            command: nil
        )
    }

    static func statusSnapshot(bridgeToken: String?) -> KeyboardLocalBridgeRequest {
        KeyboardLocalBridgeRequest(
            action: .statusSnapshot,
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

enum KeyboardBridgeState: String, Codable, Sendable {
    case idle
    case standby
    case recording
    case sending
    case result
    case error
}

enum KeyboardBridgeProcessingStage: String, Codable, Equatable, Sendable {
    case transcribing
    case refining
}

struct KeyboardBridgeStatus: Codable, Equatable, Sendable {
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
    /// Live partial transcript from the host-selected preview source, fed
    /// continuously while recording. The keyboard renders this as the user
    /// speaks; the Mac final result later replaces it. `nil` / empty when no
    /// preview is available.
    let livePartialTranscript: String?
    /// Host's last-known Mac bridge reachability — `true` if the last route
    /// probe found a usable bridge URL (local LAN or Cloudflare), `false` if
    /// the last probe failed, `nil` if the host hasn't probed yet this
    /// session. Keyboard treats `nil` optimistically (assume reachable) —
    /// the orb's failure path surfaces the real error if dictation fails.
    let backendReachable: Bool?
    /// Non-sensitive status metadata used by the keyboard extension to apply
    /// the same refine timeout the Mac backend is using. `processingStage` is
    /// explicit so command/editing workflows do not depend on localized text.
    let processingStage: KeyboardBridgeProcessingStage?
    let correctionTimeoutMs: Int?
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
        processingStage: KeyboardBridgeProcessingStage? = nil,
        correctionTimeoutMs: Int? = nil,
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
        self.processingStage = processingStage
        self.correctionTimeoutMs = correctionTimeoutMs
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
            processingStage: processingStage,
            correctionTimeoutMs: correctionTimeoutMs,
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
            processingStage: processingStage,
            correctionTimeoutMs: correctionTimeoutMs,
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
            processingStage: processingStage,
            correctionTimeoutMs: correctionTimeoutMs,
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
            livePartialTranscript: nil,
            backendReachable: backendReachable,
            processingStage: processingStage,
            correctionTimeoutMs: correctionTimeoutMs,
            updatedAt: updatedAt
        )
    }
}
