import Foundation

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
    var lanBridgeURLs: [String]
    var publicBridgeURL: String
    var token: String

    enum CodingKeys: String, CodingKey {
        case lanBridgeURLs = "lan_bridge_urls"
        case publicBridgeURL = "public_bridge_url"
        case token
    }

    init(
        lanBridgeURLs: [String] = [],
        publicBridgeURL: String,
        token: String
    ) {
        self.lanBridgeURLs = PairingConfig.uniqueBridgeURLs(lanBridgeURLs)
        self.publicBridgeURL = PairingConfig.normalizedBaseURL(publicBridgeURL)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lanBridgeURLs = PairingConfig.uniqueBridgeURLs(
            try container.decode([String].self, forKey: .lanBridgeURLs)
        )
        self.publicBridgeURL = PairingConfig.normalizedBaseURL(
            try container.decode(String.self, forKey: .publicBridgeURL)
        )
        self.token = try container.decode(String.self, forKey: .token)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasAnyBridgeURL: Bool {
        !localBridgeURLCandidates.isEmpty ||
            !publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var localBridgeURLCandidates: [String] {
        PairingConfig.uniqueBridgeURLs(lanBridgeURLs)
    }

    mutating func promoteLocalBridgeURL(_ rawValue: String) {
        let candidate = PairingConfig.normalizedBaseURL(rawValue)
        guard !candidate.isEmpty, URL(string: candidate) != nil else { return }
        let existing = localBridgeURLCandidates
        lanBridgeURLs = PairingConfig.uniqueBridgeURLs([candidate] + existing)
    }
}

struct UserPreferences: Codable, Equatable {
    var languageIDs: [String]
    var supportedLanguages: [BridgeLanguageOption]
    var correctionMode: CorrectionMode

    enum CodingKeys: String, CodingKey {
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case correctionMode = "correction_mode"
    }

    init(
        languageIDs: [String] = ["zh-CN", "en-US"],
        supportedLanguages: [BridgeLanguageOption] = BridgeLanguageOption.allLanguages,
        correctionMode: CorrectionMode = .polish
    ) {
        self.supportedLanguages = supportedLanguages
        self.languageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: BridgeLanguageOption.asASROptions(supportedLanguages)
        )
        self.correctionMode = correctionMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let supportedLanguages = try container.decode([BridgeLanguageOption].self, forKey: .supportedLanguages)
        let languageIDs = try container.decode([String].self, forKey: .languageIDs)
        self.init(
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: try container.decode(CorrectionMode.self, forKey: .correctionMode)
        )
    }
}

extension BridgePairingPayload {
    func config(
        languageIDs: [String] = ["zh-CN", "en-US"],
        supportedLanguages: [BridgeLanguageOption] = BridgeLanguageOption.allLanguages,
        correctionMode: CorrectionMode = .polish
    ) -> PairingConfig {
        let localCandidates = localBridgeURLCandidates
        return PairingConfig(
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

    var primaryLANBridgeURL: String {
        get { bridgeEndpoints.lanBridgeURLs.first ?? "" }
        set { bridgeEndpoints.lanBridgeURLs = PairingConfig.uniqueBridgeURLs([newValue]) }
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

    var supportedLanguages: [BridgeLanguageOption] {
        get { userPreferences.supportedLanguages }
        set { userPreferences.supportedLanguages = newValue }
    }

    var correctionMode: CorrectionMode {
        get { userPreferences.correctionMode }
        set { userPreferences.correctionMode = newValue }
    }

    static let empty = PairingConfig(
        lanBridgeURLs: [],
        publicBridgeURL: "",
        token: "",
        languageIDs: ["zh-CN", "en-US"],
        supportedLanguages: BridgeLanguageOption.allLanguages,
        correctionMode: .polish
    )

    enum CodingKeys: String, CodingKey {
        case bridgeEndpoints = "bridge_endpoints"
        case userPreferences = "user_preferences"
    }

    init(
        lanBridgeURLs: [String] = [],
        publicBridgeURL: String,
        token: String,
        languageIDs: [String],
        supportedLanguages: [BridgeLanguageOption] = BridgeLanguageOption.allLanguages,
        correctionMode: CorrectionMode
    ) {
        self.bridgeEndpoints = BridgeEndpoints(
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
        BridgeLanguageOption.asASROptions(supportedLanguages)
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

extension RecognitionSource {
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
}

extension VoiceLivePreviewSource {
    var title: String { displayName }
}

struct BridgeMacSettingsPayload: Codable, Equatable {
    var enabledRecognitionSources: [String]
    var recognitionSourceOptions: [BridgeSettingOption]
    var asrModelIDsByRecognitionSource: [String: String]
    var asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]]
    var languageIDs: [String]
    var supportedLanguages: [BridgeLanguageOption]
    var supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]]
    var asrTimeoutSecByRecognitionSource: [String: Double]
    var correctionBackend: String
    var correctionBackendOptions: [BridgeSettingOption]
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var externalLLMBaseURL: String
    var externalLLMModel: String
    var livePreviewSource: String
    var correctionMode: CorrectionMode
    var numberOutputPreference: NumberOutputPreference
    var punctuationPreference: PunctuationOutputPreference
    var autoCommit: Bool
    var userDictionary: [DictionaryEntry]
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

    var livePreviewSourceOptions: [VoiceLivePreviewSource] {
        VoiceLivePreviewSource.options(forRecognitionSources: enabledSources)
    }

    var livePreviewPickerOptions: [VoiceLivePreviewSource] {
        VoiceLivePreviewSource.pickerOptions
    }

    func isLivePreviewSourceEnabled(_ source: VoiceLivePreviewSource) -> Bool {
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
        supportedLanguages: [BridgeLanguageOption],
        supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]],
        asrTimeoutSecByRecognitionSource: [String: Double] = [:],
        correctionBackend: String,
        correctionBackendOptions: [BridgeSettingOption],
        correctionTimeoutMs: Int = 1500,
        correctionColdTimeoutMs: Int = 8000,
        externalLLMBaseURL: String = "",
        externalLLMModel: String = "",
        livePreviewSource: String = VoiceLivePreviewSource.off.rawValue,
        correctionMode: CorrectionMode,
        numberOutputPreference: NumberOutputPreference = .automatic,
        punctuationPreference: PunctuationOutputPreference = .normal,
        autoCommit: Bool,
        userDictionary: [DictionaryEntry] = [],
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
        self.userDictionary = DictionaryEntry.normalizedEntries(userDictionary)
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
        self.supportedLanguages = try container.decode([BridgeLanguageOption].self, forKey: .supportedLanguages)
        self.supportedLanguagesByRecognitionSource = try container.decode([String: [BridgeLanguageOption]].self, forKey: .supportedLanguagesByRecognitionSource)
        self.languageIDs = try container.decode([String].self, forKey: .languageIDs)
        self.asrTimeoutSecByRecognitionSource = try container.decode([String: Double].self, forKey: .asrTimeoutSecByRecognitionSource)
        self.correctionBackend = try container.decode(String.self, forKey: .correctionBackend)
        self.correctionBackendOptions = try container.decode([BridgeSettingOption].self, forKey: .correctionBackendOptions)
        self.correctionTimeoutMs = try container.decode(Int.self, forKey: .correctionTimeoutMs)
        self.correctionColdTimeoutMs = try container.decode(Int.self, forKey: .correctionColdTimeoutMs)
        self.externalLLMBaseURL = try container.decode(String.self, forKey: .externalLLMBaseURL)
        self.externalLLMModel = try container.decode(String.self, forKey: .externalLLMModel)
        self.livePreviewSource = try container.decode(String.self, forKey: .livePreviewSource)
        self.correctionMode = try container.decode(CorrectionMode.self, forKey: .correctionMode)
        self.numberOutputPreference = try container.decode(NumberOutputPreference.self, forKey: .numberOutputPreference)
        self.punctuationPreference = try container.decode(PunctuationOutputPreference.self, forKey: .punctuationPreference)
        self.autoCommit = try container.decode(Bool.self, forKey: .autoCommit)
        self.userDictionary = DictionaryEntry.normalizedEntries(
            try container.decode([DictionaryEntry].self, forKey: .userDictionary)
        )
        self.modelStatuses = try container.decode([BridgeModelStatus].self, forKey: .modelStatuses)
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
        userDictionary = DictionaryEntry.normalizedEntries(userDictionary)
    }

    func hasSameEditableSettings(as other: BridgeMacSettingsPayload) -> Bool {
        var left = self
        var right = other
        left.normalize()
        right.normalize()
        return left.editableSnapshot == right.editableSnapshot
    }

    private func normalizedLivePreviewSource(rawValue: String) -> VoiceLivePreviewSource {
        let source = VoiceLivePreviewSource(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .off
        return livePreviewSourceOptions.contains(source) ? source : .off
    }

    func supportedLanguageOptions(for sourceID: String) -> [ASRLanguageOption] {
        let options = supportedLanguagesByRecognitionSource[sourceID] ?? supportedLanguages
        return BridgeLanguageOption.asASROptions(options)
    }

    func supportedLanguageOptionsForEnabledSources() -> [ASRLanguageOption] {
        let sourceOptions = enabledSources.flatMap { source in
            supportedLanguagesByRecognitionSource[source.rawValue] ?? []
        }
        let options = Self.orderedUniqueLanguageOptions(sourceOptions)
        return BridgeLanguageOption.asASROptions(options.isEmpty ? supportedLanguages : options)
    }

    private static func orderedUniqueLanguageOptions(_ options: [BridgeLanguageOption]) -> [BridgeLanguageOption] {
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

    private static func rimeUserPhrases(from entries: [DictionaryEntry]) -> [String] {
        BridgeSettingsNormalization.rimeUserPhrases(from: entries.map(\.surface))
    }
}
