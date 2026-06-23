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
        self.lanBridgeURL = localCandidates.first ?? ""
        self.lanBridgeURLs = localCandidates
        self.publicBridgeURL = PairingConfig.normalizedBaseURL(publicBridgeURL)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLANBridgeURL = try container.decodeIfPresent(String.self, forKey: .lanBridgeURL) ?? ""
        let decodedLANBridgeURLs = try container.decodeIfPresent([String].self, forKey: .lanBridgeURLs) ?? []
        let localCandidates = PairingConfig.uniqueBridgeURLs([decodedLANBridgeURL] + decodedLANBridgeURLs)
        self.lanBridgeURL = localCandidates.first ?? ""
        self.lanBridgeURLs = localCandidates
        self.publicBridgeURL = PairingConfig.normalizedBaseURL(
            try container.decodeIfPresent(String.self, forKey: .publicBridgeURL) ?? ""
        )
        self.token = try container.decode(String.self, forKey: .token)
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
        let candidate = PairingConfig.normalizedBaseURL(rawValue)
        guard !candidate.isEmpty, URL(string: candidate) != nil else { return }
        let existing = localBridgeURLCandidates
        lanBridgeURLs = PairingConfig.uniqueBridgeURLs([candidate] + existing)
        lanBridgeURL = lanBridgeURLs.first ?? candidate
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
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allLanguages,
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
            ?? PairingLanguageOption.allLanguages
        let languageIDs = try container.decodeIfPresent([String].self, forKey: .languageIDs)
            ?? ["zh-CN", "en-US"]
        self.init(
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: try container.decodeIfPresent(CorrectionModeID.self, forKey: .correctionMode) ?? .polish
        )
    }
}

typealias PairingPayload = BridgePairingPayload

extension BridgePairingPayload {
    func config(
        languageIDs: [String] = ["zh-CN", "en-US"],
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allLanguages,
        correctionMode: CorrectionModeID = .polish
    ) -> PairingConfig {
        let localCandidates = localBridgeURLCandidates
        let primaryLocalURL = localCandidates.first ?? ""
        return PairingConfig(
            lanBridgeURL: primaryLocalURL,
            lanBridgeURLs: localCandidates,
            publicBridgeURL: normalizedPublicBridgeURL,
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
        supportedLanguages: PairingLanguageOption.allLanguages,
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
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allLanguages,
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
        normalize()
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

    mutating func normalize() {
        normalizeBridgeEndpoints()
        normalizeLanguageIDs()
    }

    mutating func normalizeBridgeEndpoints() {
        bridgeEndpoints = BridgeEndpoints(
            lanBridgeURL: lanBridgeURL,
            lanBridgeURLs: lanBridgeURLs,
            publicBridgeURL: publicBridgeURL,
            token: token
        )
    }

    mutating func normalizeLanguageIDs() {
        languageIDs = validatedLanguageIDs
    }

    mutating func promoteLocalBridgeURL(_ rawValue: String) {
        bridgeEndpoints.promoteLocalBridgeURL(rawValue)
    }

    static func uniqueBridgeURLs(_ values: [String]) -> [String] {
        BridgeBaseURLNormalizer.uniqueBridgeURLs(values)
    }

    static func normalizedBaseURL(_ rawValue: String) -> String {
        BridgeBaseURLNormalizer.normalizedBaseURL(rawValue)
    }
}

struct PairingLanguageOption: Codable, Equatable, Identifiable, BridgeLanguageOptionRepresentable {
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

    static let allLanguages = ASRLanguageSelection.all.map(PairingLanguageOption.init)

    static func asASROptions(_ options: [PairingLanguageOption]) -> [ASRLanguageOption] {
        let resolved = options.compactMap { option -> ASRLanguageOption? in
            if let known = ASRLanguageSelection.option(for: option.id) {
                return known
            }
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return ASRLanguageOption(id: id, displayName: name, languageCode: id)
        }
        return resolved.isEmpty ? ASRLanguageSelection.all : resolved
    }
}

typealias BridgeUserDictionaryEntry = DictionaryEntry

enum RecognitionSource: String, CaseIterable, Codable, Identifiable, Equatable {
    case qwen = "qwen3-asr-llama"
    case nvidiaNemotron = "nvidia-nemotron-asr"
    case appleSpeech = "apple-speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen:
            return "Qwen3-ASR"
        case .nvidiaNemotron:
            return "NVIDIA Nemotron 3.5 ASR"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    var hasModelConfiguration: Bool {
        switch self {
        case .qwen, .nvidiaNemotron:
            return true
        case .appleSpeech:
            return false
        }
    }

    func supportedLanguages() -> [ASRLanguageOption] {
        switch self {
        case .qwen:
            return ASRLanguageSelection.qwenASRSupportedLanguages
        case .nvidiaNemotron:
            return ASRLanguageSelection.nvidiaNemotronASRSupportedLanguages
        case .appleSpeech:
            return ASRLanguageSelection.all
        }
    }

    static let defaultEnabled: [RecognitionSource] = [.qwen]

    static func normalizedSources(_ raw: [String]) -> [RecognitionSource] {
        var seen = Set<RecognitionSource>()
        let values = raw.compactMap {
            RecognitionSource(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let result = values.filter { seen.insert($0).inserted }
        return result.isEmpty ? defaultEnabled : result
    }
}

enum MacLivePreviewSource: String, CaseIterable, Identifiable, Equatable {
    case off
    case nvidiaNemotron = "nvidia-nemotron"
    case appleSpeech = "apple-speech"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .nvidiaNemotron:
            return "NVIDIA Nemotron 3.5"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    static let pickerOptions: [MacLivePreviewSource] = [
        .off,
        .nvidiaNemotron,
        .appleSpeech,
    ]

    static func options(forRecognitionSources sources: [RecognitionSource]) -> [MacLivePreviewSource] {
        var options: [MacLivePreviewSource] = [.off]
        if sources.contains(.nvidiaNemotron) {
            options.append(.nvidiaNemotron)
        }
        if sources.contains(.appleSpeech) {
            options.append(.appleSpeech)
        }
        return options
    }

    func isEnabled(forRecognitionSources sources: [RecognitionSource]) -> Bool {
        Self.options(forRecognitionSources: sources).contains(self)
    }
}

struct BridgeMacSettingsPayload: Codable, Equatable {
    var enabledRecognitionSources: [String]
    var recognitionSourceOptions: [BridgeSettingOption]
    var asrModelIDsByRecognitionSource: [String: String]
    var asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]]
    var languageIDs: [String]
    var supportedLanguages: [PairingLanguageOption]
    var supportedLanguagesByRecognitionSource: [String: [PairingLanguageOption]]
    var asrTimeoutSecByRecognitionSource: [String: Double]
    var correctionBackend: String
    var correctionBackendOptions: [BridgeSettingOption]
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var externalLLMBaseURL: String
    var externalLLMModel: String
    var livePreviewSource: String
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

    var enabledSources: [RecognitionSource] {
        RecognitionSource.normalizedSources(enabledRecognitionSources)
    }

    func isRecognitionSourceEnabled(_ source: RecognitionSource) -> Bool {
        enabledSources.contains(source)
    }

    var usesNvidiaNemotronASR: Bool {
        isRecognitionSourceEnabled(.nvidiaNemotron)
    }

    var supportsServerNemotronPreview: Bool {
        isRecognitionSourceEnabled(.nvidiaNemotron)
    }

    var livePreviewSourceOptions: [MacLivePreviewSource] {
        MacLivePreviewSource.options(forRecognitionSources: enabledSources)
    }

    var livePreviewPickerOptions: [MacLivePreviewSource] {
        MacLivePreviewSource.pickerOptions
    }

    func isLivePreviewSourceEnabled(_ source: MacLivePreviewSource) -> Bool {
        source.isEnabled(forRecognitionSources: enabledSources)
    }

    var editableSnapshot: BridgeSettingsEditableSnapshot {
        BridgeSettingsEditableSnapshot(
            enabledRecognitionSources: enabledRecognitionSources,
            asrModelIDsByRecognitionSource: asrModelIDsByRecognitionSource,
            languageIDs: languageIDs,
            asrTimeoutSecByRecognitionSource: asrTimeoutSecByRecognitionSource,
            correctionBackend: correctionBackend,
            correctionTimeoutMs: correctionTimeoutMs,
            correctionColdTimeoutMs: correctionColdTimeoutMs,
            externalLLMBaseURL: externalLLMBaseURL,
            externalLLMModel: externalLLMModel,
            livePreviewSource: livePreviewSource,
            correctionMode: correctionMode.rawValue,
            numberOutputPreference: numberOutputPreference.rawValue,
            punctuationPreference: punctuationPreference.rawValue,
            autoCommit: autoCommit,
            userDictionary: userDictionary
        )
    }

    enum CodingKeys: String, CodingKey {
        case enabledRecognitionSources = "enabled_recognition_sources"
        case recognitionSourceOptions = "recognition_source_options"
        case asrModelIDsByRecognitionSource = "asr_model_ids_by_recognition_source"
        case asrModelOptionsByRecognitionSource = "asr_model_options_by_recognition_source"
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case supportedLanguagesByRecognitionSource = "supported_languages_by_recognition_source"
        case asrTimeoutSecByRecognitionSource = "asr_timeout_sec_by_recognition_source"
        case correctionBackend = "correction_backend"
        case correctionBackendOptions = "correction_backend_options"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case externalLLMBaseURL = "external_llm_base_url"
        case externalLLMModel = "external_llm_model"
        case livePreviewSource = "live_preview_source"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case userDictionary = "user_dictionary"
        case modelStatuses = "model_statuses"
        case settingsRevision = "settings_revision"
    }

    static let asrTimeoutSecondsRange = BridgeSettingsNormalization.asrTimeoutSecondsRange
    static let correctionTimeoutMillisecondsRange = BridgeSettingsNormalization.correctionTimeoutMillisecondsRange
    static let correctionColdTimeoutMillisecondsRange = BridgeSettingsNormalization.correctionColdTimeoutMillisecondsRange

    static var correctionTimeoutSecondsRange: ClosedRange<Double> {
        BridgeSettingsNormalization.correctionTimeoutSecondsRange
    }

    static var correctionColdTimeoutSecondsRange: ClosedRange<Double> {
        BridgeSettingsNormalization.correctionColdTimeoutSecondsRange
    }

    static func clampedASRTimeoutSec(_ value: Double) -> Double {
        BridgeSettingsNormalization.clampedASRTimeoutSec(value)
    }

    static func clampedCorrectionTimeoutMs(_ value: Int) -> Int {
        BridgeSettingsNormalization.clampedCorrectionTimeoutMs(value)
    }

    static func clampedCorrectionColdTimeoutMs(_ value: Int) -> Int {
        BridgeSettingsNormalization.clampedCorrectionColdTimeoutMs(value)
    }

    static func correctionTimeoutMs(fromSeconds value: Double) -> Int {
        BridgeSettingsNormalization.correctionTimeoutMs(fromSeconds: value)
    }

    static func correctionColdTimeoutMs(fromSeconds value: Double) -> Int {
        BridgeSettingsNormalization.correctionColdTimeoutMs(fromSeconds: value)
    }

    init(
        enabledRecognitionSources: [String],
        recognitionSourceOptions: [BridgeSettingOption],
        asrModelIDsByRecognitionSource: [String: String] = [:],
        asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]] = [:],
        languageIDs: [String],
        supportedLanguages: [PairingLanguageOption],
        supportedLanguagesByRecognitionSource: [String: [PairingLanguageOption]],
        asrTimeoutSecByRecognitionSource: [String: Double] = [:],
        correctionBackend: String,
        correctionBackendOptions: [BridgeSettingOption],
        correctionTimeoutMs: Int = 1500,
        correctionColdTimeoutMs: Int = 8000,
        externalLLMBaseURL: String = "",
        externalLLMModel: String = "",
        livePreviewSource: String = MacLivePreviewSource.off.rawValue,
        correctionMode: CorrectionModeID,
        numberOutputPreference: NumberOutputPreferenceID = .automatic,
        punctuationPreference: PunctuationPreferenceID = .normal,
        autoCommit: Bool,
        userDictionary: [BridgeUserDictionaryEntry] = [],
        modelStatuses: [BridgeModelStatus] = [],
        settingsRevision: String? = nil
    ) {
        self.enabledRecognitionSources = enabledRecognitionSources
        self.recognitionSourceOptions = recognitionSourceOptions
        self.asrModelIDsByRecognitionSource = asrModelIDsByRecognitionSource
        self.asrModelOptionsByRecognitionSource = asrModelOptionsByRecognitionSource
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.supportedLanguagesByRecognitionSource = supportedLanguagesByRecognitionSource
        self.asrTimeoutSecByRecognitionSource = asrTimeoutSecByRecognitionSource
        self.correctionBackend = correctionBackend
        self.correctionBackendOptions = correctionBackendOptions
        self.correctionTimeoutMs = Self.clampedCorrectionTimeoutMs(correctionTimeoutMs)
        self.correctionColdTimeoutMs = Self.clampedCorrectionColdTimeoutMs(correctionColdTimeoutMs)
        self.externalLLMBaseURL = externalLLMBaseURL
        self.externalLLMModel = externalLLMModel
        self.livePreviewSource = livePreviewSource
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.userDictionary = BridgeUserDictionaryEntry.normalizedEntries(userDictionary)
        self.modelStatuses = modelStatuses
        self.settingsRevision = settingsRevision
        normalize()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabledRecognitionSources = try container.decode([String].self, forKey: .enabledRecognitionSources)
        self.recognitionSourceOptions = try container.decode([BridgeSettingOption].self, forKey: .recognitionSourceOptions)
        self.asrModelIDsByRecognitionSource = try container.decode(
            [String: String].self,
            forKey: .asrModelIDsByRecognitionSource
        )
        self.asrModelOptionsByRecognitionSource = try container.decode(
            [String: [BridgeSettingOption]].self,
            forKey: .asrModelOptionsByRecognitionSource
        )
        self.supportedLanguages = try container.decode([PairingLanguageOption].self, forKey: .supportedLanguages)
        self.supportedLanguagesByRecognitionSource = try container.decode([String: [PairingLanguageOption]].self, forKey: .supportedLanguagesByRecognitionSource)
        self.languageIDs = try container.decode([String].self, forKey: .languageIDs)
        self.asrTimeoutSecByRecognitionSource = try container.decode([String: Double].self, forKey: .asrTimeoutSecByRecognitionSource)
        self.correctionBackend = try container.decode(String.self, forKey: .correctionBackend)
        self.correctionBackendOptions = try container.decode([BridgeSettingOption].self, forKey: .correctionBackendOptions)
        self.correctionTimeoutMs = try container.decode(Int.self, forKey: .correctionTimeoutMs)
        self.correctionColdTimeoutMs = try container.decode(Int.self, forKey: .correctionColdTimeoutMs)
        self.externalLLMBaseURL = try container.decodeIfPresent(String.self, forKey: .externalLLMBaseURL) ?? ""
        self.externalLLMModel = try container.decodeIfPresent(String.self, forKey: .externalLLMModel) ?? ""
        self.livePreviewSource = try container.decode(String.self, forKey: .livePreviewSource)
        self.correctionMode = try container.decode(CorrectionModeID.self, forKey: .correctionMode)
        self.numberOutputPreference = try container.decode(NumberOutputPreferenceID.self, forKey: .numberOutputPreference)
        self.punctuationPreference = try container.decode(PunctuationPreferenceID.self, forKey: .punctuationPreference)
        self.autoCommit = try container.decode(Bool.self, forKey: .autoCommit)
        self.userDictionary = BridgeUserDictionaryEntry.normalizedEntries(
            try container.decodeIfPresent([BridgeUserDictionaryEntry].self, forKey: .userDictionary) ?? []
        )
        self.modelStatuses = try container.decodeIfPresent([BridgeModelStatus].self, forKey: .modelStatuses) ?? []
        self.settingsRevision = try container.decodeIfPresent(String.self, forKey: .settingsRevision)
        normalize()
    }

    mutating func normalize() {
        enabledRecognitionSources = RecognitionSource.normalizedSources(enabledRecognitionSources).map(\.rawValue)
        asrModelIDsByRecognitionSource = BridgeSettingsNormalization.normalizedASRModelIDs(
            currentModelIDs: asrModelIDsByRecognitionSource,
            incomingModelIDs: asrModelIDsByRecognitionSource,
            optionsBySource: asrModelOptionsByRecognitionSource,
            defaultID: { sourceID in asrModelOptionsByRecognitionSource[sourceID]?.first?.id ?? "" }
        )
        asrTimeoutSecByRecognitionSource = BridgeSettingsNormalization.clampedASRTimeoutSeconds(
            asrTimeoutSecByRecognitionSource
        )
        languageIDs = ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supportedLanguageOptionsForEnabledSources())
        correctionTimeoutMs = Self.clampedCorrectionTimeoutMs(correctionTimeoutMs)
        correctionColdTimeoutMs = Self.clampedCorrectionColdTimeoutMs(correctionColdTimeoutMs)
        externalLLMBaseURL = externalLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        externalLLMModel = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        livePreviewSource = normalizedLivePreviewSource(rawValue: livePreviewSource).rawValue
        userDictionary = BridgeUserDictionaryEntry.normalizedEntries(userDictionary)
    }

    func hasSameEditableSettings(as other: BridgeMacSettingsPayload) -> Bool {
        var left = self
        var right = other
        left.normalize()
        right.normalize()
        return left.editableSnapshot == right.editableSnapshot
    }

    private func normalizedLivePreviewSource(rawValue: String) -> MacLivePreviewSource {
        let source = MacLivePreviewSource(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .off
        return livePreviewSourceOptions.contains(source) ? source : .off
    }

    func supportedLanguageOptions(for sourceID: String) -> [ASRLanguageOption] {
        let options = supportedLanguagesByRecognitionSource[sourceID] ?? supportedLanguages
        return PairingLanguageOption.asASROptions(options)
    }

    func supportedLanguageOptionsForEnabledSources() -> [ASRLanguageOption] {
        let sourceOptions = enabledSources.flatMap { source in
            supportedLanguagesByRecognitionSource[source.rawValue] ?? []
        }
        let options = Self.orderedUniqueLanguageOptions(sourceOptions)
        return PairingLanguageOption.asASROptions(options.isEmpty ? supportedLanguages : options)
    }

    private static func orderedUniqueLanguageOptions(_ options: [PairingLanguageOption]) -> [PairingLanguageOption] {
        BridgeSettingsNormalization.orderedUniqueLanguageOptions(options)
    }

    func asrModelOptions(for sourceID: String) -> [BridgeSettingOption] {
        asrModelOptionsByRecognitionSource[sourceID] ?? []
    }

    func asrModelID(for sourceID: String) -> String {
        asrModelIDsByRecognitionSource[sourceID] ?? asrModelOptions(for: sourceID).first?.id ?? ""
    }

    func asrTimeoutSec(for sourceID: String) -> Double {
        asrTimeoutSecByRecognitionSource[sourceID] ?? 120
    }

    mutating func setRecognitionSource(_ source: RecognitionSource, enabled: Bool) {
        var sources = enabledSources
        if enabled {
            if !sources.contains(source) {
                sources.append(source)
            }
        } else {
            sources.removeAll { $0 == source }
        }
        enabledRecognitionSources = RecognitionSource.normalizedSources(sources.map(\.rawValue)).map(\.rawValue)
        normalize()
    }

    private static func rimeUserPhrases(from entries: [BridgeUserDictionaryEntry]) -> [String] {
        BridgeSettingsNormalization.rimeUserPhrases(from: entries.map(\.surface))
    }
}
