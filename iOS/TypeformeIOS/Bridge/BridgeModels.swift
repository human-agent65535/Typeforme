import Foundation

typealias CorrectionModeID = CorrectionMode
typealias NumberOutputPreferenceID = NumberOutputPreference
typealias PunctuationPreferenceID = PunctuationOutputPreference

extension CorrectionMode {
    var title: String {
        displayName
    }
}

extension NumberOutputPreference {
    var title: String {
        displayName
    }
}

extension PunctuationOutputPreference {
    var title: String {
        displayName
    }
}

struct BridgeEndpoints: Codable, Equatable {
    var lanBridgeURL: String
    var lanBridgeURLs: [String]
    var publicBridgeURL: String
    var token: String

    enum CodingKeys: String, CodingKey {
        case lanBridgeURL = "lan_bridge_url"
        case lanBridgeURLs = "lan_bridge_urls"
        case publicBridgeURL = "public_bridge_url"
        case token
    }

    init(
        lanBridgeURL: String,
        lanBridgeURLs: [String] = [],
        publicBridgeURL: String,
        token: String
    ) {
        let localCandidates = PairingConfig.uniqueBridgeURLs([lanBridgeURL] + lanBridgeURLs)
        self.lanBridgeURL = lanBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lanBridgeURLs = localCandidates
        self.publicBridgeURL = publicBridgeURL
        self.token = token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLANBridgeURL = try container.decodeIfPresent(String.self, forKey: .lanBridgeURL) ?? ""
        let decodedLANBridgeURLs = try container.decodeIfPresent([String].self, forKey: .lanBridgeURLs) ?? []
        let localCandidates = PairingConfig.uniqueBridgeURLs([decodedLANBridgeURL] + decodedLANBridgeURLs)
        self.lanBridgeURL = decodedLANBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (localCandidates.first ?? "")
            : decodedLANBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lanBridgeURLs = localCandidates
        self.publicBridgeURL = (try container.decodeIfPresent(String.self, forKey: .publicBridgeURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (try container.decodeIfPresent(String.self, forKey: .token) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasAnyBridgeURL: Bool {
        !localBridgeURLCandidates.isEmpty ||
            !publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var localBridgeURLCandidates: [String] {
        PairingConfig.uniqueBridgeURLs([lanBridgeURL] + lanBridgeURLs)
    }

    mutating func promoteLocalBridgeURL(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = localBridgeURLCandidates
        lanBridgeURL = trimmed
        lanBridgeURLs = PairingConfig.uniqueBridgeURLs([trimmed] + existing)
    }
}

struct UserPreferences: Codable, Equatable {
    var languageIDs: [String]
    var supportedLanguages: [PairingLanguageOption]
    var correctionMode: CorrectionModeID

    enum CodingKeys: String, CodingKey {
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case correctionMode = "correction_mode"
    }

    init(
        languageIDs: [String] = ["zh-CN", "en-US"],
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allWhisperLanguages,
        correctionMode: CorrectionModeID = .polish
    ) {
        self.supportedLanguages = supportedLanguages
        self.languageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: PairingLanguageOption.asASROptions(supportedLanguages)
        )
        self.correctionMode = correctionMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let supportedLanguages = try container.decodeIfPresent([PairingLanguageOption].self, forKey: .supportedLanguages)
            ?? PairingLanguageOption.allWhisperLanguages
        let languageIDs = try container.decodeIfPresent([String].self, forKey: .languageIDs)
            ?? ["zh-CN", "en-US"]
        self.init(
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: try container.decodeIfPresent(CorrectionModeID.self, forKey: .correctionMode) ?? .polish
        )
    }
}

struct PairingPayload: Decodable, Equatable {
    let lanBridgeURL: String
    let lanBridgeURLs: [String]
    let publicBridgeURL: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case lanBridgeURL = "lan_bridge_url"
        case lanBridgeURLs = "lan_bridge_urls"
        case publicBridgeURL = "public_bridge_url"
        case token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lanBridgeURL = (try container.decodeIfPresent(String.self, forKey: .lanBridgeURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lanBridgeURLs = try container.decodeIfPresent([String].self, forKey: .lanBridgeURLs) ?? []
        publicBridgeURL = (try container.decodeIfPresent(String.self, forKey: .publicBridgeURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        token = (try container.decodeIfPresent(String.self, forKey: .token) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func config(
        languageIDs: [String] = ["zh-CN", "en-US"],
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allWhisperLanguages,
        correctionMode: CorrectionModeID = .polish
    ) -> PairingConfig {
        let localCandidates = PairingConfig.uniqueBridgeURLs([lanBridgeURL] + lanBridgeURLs)
        let primaryLocalURL = lanBridgeURL.isEmpty ? (localCandidates.first ?? "") : lanBridgeURL
        return PairingConfig(
            lanBridgeURL: primaryLocalURL,
            lanBridgeURLs: localCandidates,
            publicBridgeURL: publicBridgeURL,
            token: token,
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: correctionMode
        )
    }
}

struct PairingConfig: Codable, Equatable {
    var bridgeEndpoints: BridgeEndpoints
    var userPreferences: UserPreferences

    var lanBridgeURL: String {
        get { bridgeEndpoints.lanBridgeURL }
        set { bridgeEndpoints.lanBridgeURL = newValue }
    }

    var lanBridgeURLs: [String] {
        get { bridgeEndpoints.lanBridgeURLs }
        set { bridgeEndpoints.lanBridgeURLs = newValue }
    }

    var publicBridgeURL: String {
        get { bridgeEndpoints.publicBridgeURL }
        set { bridgeEndpoints.publicBridgeURL = newValue }
    }

    var token: String {
        get { bridgeEndpoints.token }
        set { bridgeEndpoints.token = newValue }
    }

    var languageIDs: [String] {
        get { userPreferences.languageIDs }
        set { userPreferences.languageIDs = newValue }
    }

    var supportedLanguages: [PairingLanguageOption] {
        get { userPreferences.supportedLanguages }
        set { userPreferences.supportedLanguages = newValue }
    }

    var correctionMode: CorrectionModeID {
        get { userPreferences.correctionMode }
        set { userPreferences.correctionMode = newValue }
    }

    static let empty = PairingConfig(
        lanBridgeURL: "",
        lanBridgeURLs: [],
        publicBridgeURL: "",
        token: "",
        languageIDs: ["zh-CN", "en-US"],
        supportedLanguages: PairingLanguageOption.allWhisperLanguages,
        correctionMode: .polish
    )

    enum CodingKeys: String, CodingKey {
        case bridgeEndpoints = "bridge_endpoints"
        case userPreferences = "user_preferences"
    }

    init(
        lanBridgeURL: String,
        lanBridgeURLs: [String] = [],
        publicBridgeURL: String,
        token: String,
        languageIDs: [String],
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allWhisperLanguages,
        correctionMode: CorrectionModeID
    ) {
        self.bridgeEndpoints = BridgeEndpoints(
            lanBridgeURL: lanBridgeURL,
            lanBridgeURLs: lanBridgeURLs,
            publicBridgeURL: publicBridgeURL,
            token: token
        )
        self.userPreferences = UserPreferences(
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: correctionMode
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bridgeEndpoints = try container.decode(BridgeEndpoints.self, forKey: .bridgeEndpoints)
        self.userPreferences = try container.decode(UserPreferences.self, forKey: .userPreferences)
        normalizeLanguageIDs()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bridgeEndpoints, forKey: .bridgeEndpoints)
        try container.encode(userPreferences, forKey: .userPreferences)
    }

    var hasAnyBridgeURL: Bool {
        bridgeEndpoints.hasAnyBridgeURL
    }

    var localBridgeURLCandidates: [String] {
        bridgeEndpoints.localBridgeURLCandidates
    }

    var supportedLanguageOptions: [ASRLanguageOption] {
        PairingLanguageOption.asASROptions(supportedLanguages)
    }

    var validatedLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supportedLanguageOptions)
    }

    mutating func normalizeLanguageIDs() {
        languageIDs = validatedLanguageIDs
    }

    mutating func promoteLocalBridgeURL(_ rawValue: String) {
        bridgeEndpoints.promoteLocalBridgeURL(rawValue)
    }

    static func uniqueBridgeURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            urls.append(trimmed)
        }
        return urls
    }
}

struct PairingLanguageOption: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(_ option: ASRLanguageOption) {
        self.id = option.id
        self.displayName = option.displayName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    static let allWhisperLanguages = ASRLanguageSelection.all.map(PairingLanguageOption.init)

    static func asASROptions(_ options: [PairingLanguageOption]) -> [ASRLanguageOption] {
        let resolved = options.compactMap { option -> ASRLanguageOption? in
            if let known = ASRLanguageSelection.option(for: option.id) {
                return known
            }
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return ASRLanguageOption(id: id, displayName: name, whisperCode: id)
        }
        return resolved.isEmpty ? ASRLanguageSelection.all : resolved
    }
}

struct BridgeHealthResponse: Decodable {
    let ok: Bool
    let service: String?
    let version: String?
    let settingsRevision: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case service
        case version
        case settingsRevision = "settings_revision"
    }
}

struct BridgeUserDictionaryEntry: Codable, Equatable, Identifiable, Hashable {
    static let suggestedTypes = [
        "person",
        "organization",
        "product",
        "project",
        "place",
        "technical_term",
        "acronym",
        "phrase",
        "other",
    ]

    var id: UUID
    var type: String
    var surface: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case surface
    }

    init(
        id: UUID = UUID(),
        type: String = "other",
        surface: String
    ) {
        self.id = id
        self.type = Self.normalizedType(type)
        self.surface = Self.cleanedSurface(surface)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "other",
            surface: try container.decodeIfPresent(String.self, forKey: .surface) ?? ""
        )
    }

    var isValid: Bool {
        !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayType: String {
        type.replacingOccurrences(of: "_", with: " ")
    }

    static func cleanedSurface(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedType(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "other" }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}

struct BridgeMacSettingsPayload: Codable, Equatable {
    var asrProvider: String
    var asrProviderOptions: [BridgeSettingOption]
    var languageIDs: [String]
    var supportedLanguages: [PairingLanguageOption]
    var supportedLanguagesByASRProvider: [String: [PairingLanguageOption]]
    var asrTimeoutSec: Double
    var correctionBackend: String
    var correctionBackendOptions: [BridgeSettingOption]
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var correctionMode: CorrectionModeID
    var numberOutputPreference: NumberOutputPreferenceID
    var punctuationPreference: PunctuationPreferenceID
    var autoCommit: Bool
    var userDictionary: [BridgeUserDictionaryEntry]
    var modelStatuses: [BridgeModelStatus]
    var settingsRevision: String?

    var rimeUserPhrases: [String] {
        Self.rimeUserPhrases(from: userDictionary)
    }

    enum CodingKeys: String, CodingKey {
        case asrProvider = "asr_provider"
        case asrProviderOptions = "asr_provider_options"
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case supportedLanguagesByASRProvider = "supported_languages_by_asr_provider"
        case asrTimeoutSec = "asr_timeout_sec"
        case correctionBackend = "correction_backend"
        case correctionBackendOptions = "correction_backend_options"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case userDictionary = "user_dictionary"
        case modelStatuses = "model_statuses"
        case settingsRevision = "settings_revision"
    }

    init(
        asrProvider: String,
        asrProviderOptions: [BridgeSettingOption],
        languageIDs: [String],
        supportedLanguages: [PairingLanguageOption],
        supportedLanguagesByASRProvider: [String: [PairingLanguageOption]],
        asrTimeoutSec: Double = 120,
        correctionBackend: String,
        correctionBackendOptions: [BridgeSettingOption],
        correctionTimeoutMs: Int = 1500,
        correctionColdTimeoutMs: Int = 8000,
        correctionMode: CorrectionModeID,
        numberOutputPreference: NumberOutputPreferenceID = .automatic,
        punctuationPreference: PunctuationPreferenceID = .normal,
        autoCommit: Bool,
        userDictionary: [BridgeUserDictionaryEntry] = [],
        modelStatuses: [BridgeModelStatus] = [],
        settingsRevision: String? = nil
    ) {
        self.asrProvider = asrProvider
        self.asrProviderOptions = asrProviderOptions
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.supportedLanguagesByASRProvider = supportedLanguagesByASRProvider
        self.asrTimeoutSec = min(max(asrTimeoutSec, 10), 300)
        self.correctionBackend = correctionBackend
        self.correctionBackendOptions = correctionBackendOptions
        self.correctionTimeoutMs = min(max(correctionTimeoutMs, 100), 30_000)
        self.correctionColdTimeoutMs = min(max(correctionColdTimeoutMs, 1_000), 60_000)
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.userDictionary = Self.normalizedUserDictionary(userDictionary)
        self.modelStatuses = modelStatuses
        self.settingsRevision = settingsRevision
        normalize()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.asrProvider = try container.decodeIfPresent(String.self, forKey: .asrProvider) ?? "qwen3-asr-llama"
        self.asrProviderOptions = try container.decodeIfPresent([BridgeSettingOption].self, forKey: .asrProviderOptions) ?? []
        self.supportedLanguages = try container.decodeIfPresent([PairingLanguageOption].self, forKey: .supportedLanguages)
            ?? PairingLanguageOption.allWhisperLanguages
        self.supportedLanguagesByASRProvider = try container.decodeIfPresent([String: [PairingLanguageOption]].self, forKey: .supportedLanguagesByASRProvider) ?? [:]
        self.languageIDs = try container.decodeIfPresent([String].self, forKey: .languageIDs) ?? ["zh-CN", "en-US"]
        self.asrTimeoutSec = try container.decodeIfPresent(Double.self, forKey: .asrTimeoutSec) ?? 120
        self.correctionBackend = try container.decodeIfPresent(String.self, forKey: .correctionBackend) ?? "qwen35_2b"
        self.correctionBackendOptions = try container.decodeIfPresent([BridgeSettingOption].self, forKey: .correctionBackendOptions) ?? []
        self.correctionTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .correctionTimeoutMs) ?? 1500
        self.correctionColdTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .correctionColdTimeoutMs) ?? 8000
        self.correctionMode = try container.decodeIfPresent(CorrectionModeID.self, forKey: .correctionMode) ?? .polish
        self.numberOutputPreference = try container.decodeIfPresent(NumberOutputPreferenceID.self, forKey: .numberOutputPreference) ?? .automatic
        self.punctuationPreference = try container.decodeIfPresent(PunctuationPreferenceID.self, forKey: .punctuationPreference) ?? .normal
        self.autoCommit = try container.decodeIfPresent(Bool.self, forKey: .autoCommit) ?? true
        self.userDictionary = Self.normalizedUserDictionary(
            try container.decodeIfPresent([BridgeUserDictionaryEntry].self, forKey: .userDictionary) ?? []
        )
        self.modelStatuses = try container.decodeIfPresent([BridgeModelStatus].self, forKey: .modelStatuses) ?? []
        self.settingsRevision = try container.decodeIfPresent(String.self, forKey: .settingsRevision)
        normalize()
    }

    mutating func normalize() {
        let supported = supportedLanguageOptions(for: asrProvider)
        languageIDs = ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supported)
        asrTimeoutSec = min(max(asrTimeoutSec, 10), 300)
        correctionTimeoutMs = min(max(correctionTimeoutMs, 100), 30_000)
        correctionColdTimeoutMs = min(max(correctionColdTimeoutMs, 1_000), 60_000)
        userDictionary = Self.normalizedUserDictionary(userDictionary)
    }

    func supportedLanguageOptions(for provider: String) -> [ASRLanguageOption] {
        let options = supportedLanguagesByASRProvider[provider] ?? supportedLanguages
        return PairingLanguageOption.asASROptions(options)
    }

    private static func normalizedUserDictionary(_ entries: [BridgeUserDictionaryEntry]) -> [BridgeUserDictionaryEntry] {
        var seenIDs = Set<UUID>()
        return entries.compactMap { incoming in
            let entry = BridgeUserDictionaryEntry(
                id: incoming.id,
                type: incoming.type,
                surface: incoming.surface
            )
            guard entry.isValid else { return nil }
            guard seenIDs.insert(entry.id).inserted else { return nil }
            return entry
        }
        .sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            if $0.surface != $1.surface { return $0.surface < $1.surface }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func rimeUserPhrases(from entries: [BridgeUserDictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for entry in entries {
            let cleaned = BridgeUserDictionaryEntry.cleanedSurface(entry.surface)
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
}

struct BridgeSettingsUpdateRequest: Encodable {
    let asrProvider: String
    let languageIDs: [String]
    let asrTimeoutSec: Double
    let correctionBackend: String
    let correctionTimeoutMs: Int
    let correctionColdTimeoutMs: Int
    let correctionMode: String
    let numberOutputPreference: String
    let punctuationPreference: String
    let autoCommit: Bool
    let userDictionary: [BridgeUserDictionaryEntry]

    enum CodingKeys: String, CodingKey {
        case asrProvider = "asr_provider"
        case languageIDs = "language_ids"
        case asrTimeoutSec = "asr_timeout_sec"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case userDictionary = "user_dictionary"
    }
}

struct BridgeDictateResponse: Decodable {
    let sessionID: String
    let text: String
    let correctionMode: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let transcriptionLatencyMs: Int?
    let correctionLatencyMs: Int?
    let rawTranscript: String?
    let correctionStatus: String?
    let correctionError: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case correctionMode = "correction_mode"
        case languageIDs = "language_ids"
        case latencyMs = "latency_ms"
        case transcriptionLatencyMs = "transcription_latency_ms"
        case correctionLatencyMs = "correction_latency_ms"
        case rawTranscript = "raw_transcript"
        case correctionStatus = "correction_status"
        case correctionError = "correction_error"
    }
}

struct BridgeRestyleRequest: Encodable {
    let sessionID: String?
    let rawTranscript: String?
    let clientJobID: String?
    let languageIDs: [String]
    let correctionMode: String
    let appName: String
    let appCategory: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case rawTranscript = "raw_transcript"
        case clientJobID = "client_job_id"
        case languageIDs = "language_ids"
        case correctionMode = "correction_mode"
        case appName = "app_name"
        case appCategory = "app_category"
    }
}

struct BridgeTextEditRequest: Encodable {
    let intent: String
    let contextBefore: String
    let targetText: String
    let contextAfter: String
    let spokenInstruction: String
    let languageIDs: [String]
    let clientJobID: String?
    let appName: String
    let appCategory: String

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
        case languageIDs = "language_ids"
        case clientJobID = "client_job_id"
        case appName = "app_name"
        case appCategory = "app_category"
    }
}

struct BridgeRestyleResponse: Decodable {
    let sessionID: String
    let text: String
    let correctionMode: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let correctionLatencyMs: Int?
    let correctionStatus: String?
    let correctionError: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case correctionMode = "correction_mode"
        case languageIDs = "language_ids"
        case latencyMs = "latency_ms"
        case correctionLatencyMs = "correction_latency_ms"
        case correctionStatus = "correction_status"
        case correctionError = "correction_error"
    }
}

struct BridgeTextEditResponse: Decodable {
    let text: String
    let action: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let editLatencyMs: Int?
    let editStatus: String?
    let editError: String?

    enum CodingKeys: String, CodingKey {
        case text
        case action
        case languageIDs = "language_ids"
        case latencyMs = "latency_ms"
        case editLatencyMs = "edit_latency_ms"
        case editStatus = "edit_status"
        case editError = "edit_error"
    }
}
