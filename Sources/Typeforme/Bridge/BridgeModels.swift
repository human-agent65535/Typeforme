import CryptoKit
import Darwin
import Foundation

struct BridgeHealthResponse: Codable, Sendable {
    let ok: Bool
    let service: String
    let version: String
    let bridgePort: Int
    let settingsRevision: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case service
        case version
        case bridgePort = "bridge_port"
        case settingsRevision = "settings_revision"
    }
}

struct BridgeDictateRequest {
    var audioData: Data?
    var audioFileURL: URL?
    var audioExtension: String?
    var clientJobID: String?
    var languageIDs: [String]?
    var languageMode: String?
    var correctionMode: String?
    var appName: String?
    var bundleID: String?
    var appCategory: String?
    var contextBefore: String?
    var contextAfter: String?
    var includeRawTranscript: Bool?
    /// Optional additional transcription of the same audio from another ASR
    /// (e.g. live preview text). Neutral framing — not
    /// labelled as "source X" or "preview" in any prompt — Mac treats it as a
    /// supplementary hypothesis to resolve ambiguity in raw_transcript.
    var alternateTranscript: String?

    init(
        audioData: Data? = nil,
        audioFileURL: URL? = nil,
        audioExtension: String?,
        clientJobID: String? = nil,
        languageIDs: [String]?,
        languageMode: String? = nil,
        correctionMode: String?,
        appName: String?,
        bundleID: String?,
        appCategory: String?,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        includeRawTranscript: Bool?,
        alternateTranscript: String? = nil
    ) {
        self.audioData = audioData
        self.audioFileURL = audioFileURL
        self.audioExtension = audioExtension
        self.clientJobID = clientJobID
        self.languageIDs = languageIDs
        self.languageMode = languageMode
        self.correctionMode = correctionMode
        self.appName = appName
        self.bundleID = bundleID
        self.appCategory = appCategory
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.includeRawTranscript = includeRawTranscript
        self.alternateTranscript = alternateTranscript
    }
}

struct BridgeRestyleRequest: Decodable {
    var sessionID: String?
    var rawTranscript: String?
    var clientJobID: String?
    var languageIDs: [String]?
    var languageMode: String?
    var correctionMode: String?
    var appName: String?
    var bundleID: String?
    var appCategory: String?
    var contextBefore: String?
    var contextAfter: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case rawTranscript = "raw_transcript"
        case clientJobID = "client_job_id"
        case languageIDs = "language_ids"
        case languageMode = "language_mode"
        case correctionMode = "correction_mode"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

struct BridgeTextEditRequest: Decodable {
    var intent: String?
    var contextBefore: String?
    var targetText: String?
    var contextAfter: String?
    var spokenInstruction: String?
    var languageIDs: [String]?
    var languageMode: String?
    var appName: String?
    var bundleID: String?
    var appCategory: String?
    var clientJobID: String?

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
        case languageIDs = "language_ids"
        case languageMode = "language_mode"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case clientJobID = "client_job_id"
    }
}

struct BridgeDictateResponse: Codable, Sendable {
    let sessionID: String
    let text: String
    let correctionMode: String
    let languageIDs: [String]
    let latencyMs: Int
    let transcriptionLatencyMs: Int?
    let correctionLatencyMs: Int?
    let rawTranscript: String?
    let asrWarning: String?
    let correctionStatus: String
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
        case asrWarning = "asr_warning"
        case correctionStatus = "correction_status"
        case correctionError = "correction_error"
    }
}

struct BridgeRestyleResponse: Codable, Sendable {
    let sessionID: String
    let text: String
    let correctionMode: String
    let languageIDs: [String]
    let latencyMs: Int
    let correctionLatencyMs: Int?
    let correctionStatus: String
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

struct BridgeTextEditResponse: Codable, Sendable {
    let text: String
    let action: String
    let languageIDs: [String]
    let latencyMs: Int
    let editLatencyMs: Int?
    let editStatus: String
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

struct BridgeErrorResponse: Codable, Sendable {
    let error: String
}

struct BridgeSettingsPayload: Codable, Sendable {
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
    var externalLLMBaseURL: String?
    var externalLLMModel: String?
    var correctionMode: String
    var numberOutputPreference: String
    var punctuationPreference: String
    var autoCommit: Bool
    var debugMode: Bool
    var userDictionary: [DictionaryEntry]
    var rimeUserPhrases: [String]?
    var modelStatuses: [BridgeModelStatus]
    var settingsRevision: String?

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
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
        case userDictionary = "user_dictionary"
        case rimeUserPhrases = "rime_user_phrases"
        case modelStatuses = "model_statuses"
        case settingsRevision = "settings_revision"
    }

    static let controllableRecognitionSources: [BridgeSettingOption] = RecognitionSource.allCases.map {
        BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
    }

    static var controllableASRModelOptionsByRecognitionSource: [String: [BridgeSettingOption]] {
        let qwenOptions = QwenASRModelCatalog.all.map {
            BridgeSettingOption(id: $0.id, displayName: $0.label)
        }
        let nemotronOptions = NvidiaNemotronASRModelCatalog.all.map {
            BridgeSettingOption(id: $0.id, displayName: $0.label)
        }
        return [
            RecognitionSource.qwen.rawValue: defaultFirst(qwenOptions, defaultID: QwenASRModelCatalog.defaultID),
            RecognitionSource.nvidiaNemotron.rawValue: defaultFirst(nemotronOptions, defaultID: NvidiaNemotronASRModelCatalog.defaultID),
            RecognitionSource.appleSpeech.rawValue: [],
        ]
    }

    static var currentASRModelIDsByRecognitionSource: [String: String] {
        [
            RecognitionSource.qwen.rawValue: AppSettings.asrQwenLlamaModelID,
            RecognitionSource.nvidiaNemotron.rawValue: AppSettings.asrNvidiaNemotronModelID,
        ]
    }

    static var currentASRTimeoutSecByRecognitionSource: [String: Double] {
        [
            RecognitionSource.qwen.rawValue: AppSettings.asrQwenLlamaTimeoutSeconds,
            RecognitionSource.nvidiaNemotron.rawValue: AppSettings.asrNvidiaNemotronTimeoutSeconds,
        ]
    }

    static var supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]] {
        Dictionary(
            uniqueKeysWithValues: RecognitionSource.allCases.map { source in
                (source.rawValue, source.supportedLanguages().map(BridgeLanguageOption.init))
            }
        )
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

    static let controllableCorrectionBackends: [CorrectionBackendKind] = [
        .qwen35_2B,
        .qwen35_4B,
        .qwen35_9B,
        .externalOpenAICompatible,
        .externalAnthropicCompatible,
    ]

    static let asrTimeoutRangeSec: ClosedRange<Double> = 10...300
    static let correctionTimeoutRangeMs: ClosedRange<Int> = 100...30_000
    static let correctionColdTimeoutRangeMs: ClosedRange<Int> = 1_000...60_000

    static func clampedASRTimeoutSec(_ value: Double) -> Double {
        min(max(value, asrTimeoutRangeSec.lowerBound), asrTimeoutRangeSec.upperBound)
    }

    static func clampedCorrectionTimeoutMs(_ value: Int) -> Int {
        min(max(value, correctionTimeoutRangeMs.lowerBound), correctionTimeoutRangeMs.upperBound)
    }

    static func clampedCorrectionColdTimeoutMs(_ value: Int) -> Int {
        min(max(value, correctionColdTimeoutRangeMs.lowerBound), correctionColdTimeoutRangeMs.upperBound)
    }

    static func current(userDictionary: [DictionaryEntry] = []) -> BridgeSettingsPayload {
        let resolved = currentResolvedSettings()
        let sortedUserDictionary = normalizedUserDictionary(userDictionary)
        let rimeUserPhrases = rimeUserPhrases(from: sortedUserDictionary)
        let settingsRevision = settingsRevision(
            for: resolved.revisionPayload(userDictionary: sortedUserDictionary)
        )
        return BridgeSettingsPayload(
            enabledRecognitionSources: resolved.sources.map(\.rawValue),
            recognitionSourceOptions: controllableRecognitionSources,
            asrModelIDsByRecognitionSource: currentASRModelIDsByRecognitionSource,
            asrModelOptionsByRecognitionSource: controllableASRModelOptionsByRecognitionSource,
            languageIDs: resolved.languageIDs,
            supportedLanguages: resolved.supportedLanguages,
            supportedLanguagesByRecognitionSource: resolved.supportedBySource,
            asrTimeoutSecByRecognitionSource: currentASRTimeoutSecByRecognitionSource,
            correctionBackend: resolved.correctionBackend.rawValue,
            correctionBackendOptions: controllableCorrectionBackends.map {
                BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
            },
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            correctionColdTimeoutMs: AppSettings.correctionColdTimeoutMs,
            externalLLMBaseURL: AppSettings.externalLLMBaseURL,
            externalLLMModel: AppSettings.externalLLMModel,
            correctionMode: resolved.correctionMode.rawValue,
            numberOutputPreference: AppSettings.numberOutputPreference.rawValue,
            punctuationPreference: AppSettings.punctuationPreference.rawValue,
            autoCommit: AppSettings.autoCommit,
            debugMode: AppSettings.diagnosticsDebugMode,
            userDictionary: sortedUserDictionary,
            rimeUserPhrases: rimeUserPhrases,
            modelStatuses: selectedModelStatuses(
                sources: resolved.sources,
                correctionBackend: resolved.correctionBackend
            ),
            settingsRevision: settingsRevision
        )
    }

    static func currentSettingsRevision(userDictionary: [DictionaryEntry] = []) -> String {
        settingsRevision(
            for: currentResolvedSettings().revisionPayload(
                userDictionary: normalizedUserDictionary(userDictionary)
            )
        )
    }

    static func settingsRevision(for payload: BridgeSettingsPayload) -> String {
        settingsRevision(for: BridgeSettingsRevisionPayload(payload))
    }

    private static func currentResolvedSettings() -> BridgeResolvedSettings {
        let sources = AppSettings.enabledRecognitionSources
        let supportedBySource = supportedLanguagesByRecognitionSource
        let supportedLanguages = ASRLanguageSelection.supportedOptions(for: sources).map(BridgeLanguageOption.init)
        let languageIDs = ASRLanguageSelection.validatedIDs(
            AppSettings.asrLanguageIDs,
            sources: sources
        )
        let correctionMode = AppSettings.correctionMode
        let correctionBackend = normalizedCorrectionBackend(AppSettings.correctionBackend)
        return BridgeResolvedSettings(
            sources: sources,
            supportedBySource: supportedBySource,
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: correctionMode,
            correctionBackend: correctionBackend
        )
    }

    private static func settingsRevision(for payload: BridgeSettingsRevisionPayload) -> String {
        let data = (try? BridgeJSON.encodeSorted(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedUserDictionary(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var seenIDs = Set<UUID>()
        return entries.compactMap { entry in
            let normalized = DictionaryEntry(
                id: entry.id,
                type: entry.type,
                surface: entry.surface
            )
            guard normalized.isValid else { return nil }
            guard seenIDs.insert(normalized.id).inserted else { return nil }
            return normalized
        }
        .sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            if $0.surface != $1.surface { return $0.surface < $1.surface }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func rimeUserPhrases(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var phrases: [String] = []
        for entry in entries {
            let phrase = entry.surface
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }
            let key = phrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            phrases.append(phrase)
        }
        return phrases.sorted()
    }

    private static func selectedModelStatuses(
        sources: [RecognitionSource],
        correctionBackend: CorrectionBackendKind
    ) -> [BridgeModelStatus] {
        selectedASRModelStatuses(sources: sources)
            + [selectedRestyleModelStatus(correctionBackend: correctionBackend)]
    }

    fileprivate static func currentASRTimeoutSec(sourceID: String) -> Double {
        currentASRTimeoutSecByRecognitionSource[sourceID] ?? AppSettings.asrQwenLlamaTimeoutSeconds
    }

    fileprivate static func currentASRModelID(sourceID: String) -> String {
        currentASRModelIDsByRecognitionSource[sourceID] ?? defaultASRModelID(sourceID: sourceID)
    }

    private static func selectedASRModelStatuses(sources: [RecognitionSource]) -> [BridgeModelStatus] {
        sources.map(selectedASRModelStatus(source:))
    }

    private static func selectedASRModelStatus(source: RecognitionSource) -> BridgeModelStatus {
        let fileManager = FileManager.default
        if source == .qwen {
            let spec = QwenASRModelCatalog.spec(for: AppSettings.asrQwenLlamaModelID)
            let modelPath = AppSettings.asrQwenLlamaModelPath
            let mmprojPath = AppSettings.asrQwenLlamaMMProjPath
            let installed = fileManager.fileExists(atPath: modelPath)
                && fileManager.fileExists(atPath: mmprojPath)
            let installing = ModelInstallRegistry.isInstalling(path: modelPath)
                || ModelInstallRegistry.isInstalling(path: mmprojPath)
            return BridgeModelStatus(
                id: "asr:\(source.rawValue):\(spec.id)",
                kind: "asr",
                displayName: spec.label,
                installed: installed,
                installing: installing,
                detail: modelStatusDetail(installed: installed, installing: installing)
            )
        }

        if source == .nvidiaNemotron {
            let spec = NvidiaNemotronASRModelCatalog.spec(for: AppSettings.asrNvidiaNemotronModelID)
            let status = NvidiaNemotronASRService.bundledRuntimeStatus()
            let installing = spec.files.contains {
                ModelInstallRegistry.isInstalling(path: AppSettings.asrNvidiaNemotronPath(for: $0))
            }
            return BridgeModelStatus(
                id: "asr:\(source.rawValue):\(spec.id)",
                kind: "asr",
                displayName: spec.label,
                installed: status.isReady,
                installing: installing,
                detail: installing ? "Installing" : status.detail
            )
        }
        return BridgeModelStatus(
            id: "asr:\(source.rawValue):on-device",
            kind: "asr",
            displayName: "Apple Speech",
            installed: true,
            installing: false,
            detail: "System on-device recognizer"
        )
    }

    private static func selectedRestyleModelStatus(
        correctionBackend: CorrectionBackendKind
    ) -> BridgeModelStatus {
        guard !correctionBackend.isExternalCompatible else {
            return BridgeModelStatus(
                id: "restyle:\(correctionBackend.rawValue)",
                kind: "restyle",
                displayName: correctionBackend.displayName,
                installed: true,
                installing: false,
                detail: "External server"
            )
        }

        let modelPath = restyleModelPath(for: correctionBackend)
        let installed = FileManager.default.fileExists(atPath: modelPath)
        let installing = ModelInstallRegistry.isInstalling(path: modelPath)
        return BridgeModelStatus(
            id: "restyle:\(correctionBackend.rawValue)",
            kind: "restyle",
            displayName: correctionBackend.displayName,
            installed: installed,
            installing: installing,
            detail: modelStatusDetail(installed: installed, installing: installing)
        )
    }

    private static func restyleModelPath(for backend: CorrectionBackendKind) -> String {
        switch backend {
        case .qwen35_2B:
            return AppSettings.llama2BPath
        case .qwen35_4B:
            return AppSettings.llama4BPath
        case .qwen35_9B:
            return AppSettings.llama9BPath
        case .externalOpenAICompatible, .externalAnthropicCompatible:
            return ""
        }
    }

    private static func modelStatusDetail(installed: Bool, installing: Bool) -> String {
        if installing { return "Installing" }
        return installed ? "Ready" : "Not installed"
    }

    static func defaultASRModelID(sourceID: String) -> String {
        if sourceID == RecognitionSource.nvidiaNemotron.rawValue {
            return NvidiaNemotronASRModelCatalog.defaultID
        }
        if sourceID == RecognitionSource.appleSpeech.rawValue {
            return ""
        }
        return QwenASRModelCatalog.defaultID
    }

    private static func defaultFirst(
        _ options: [BridgeSettingOption],
        defaultID: String
    ) -> [BridgeSettingOption] {
        guard let defaultOption = options.first(where: { $0.id == defaultID }) else {
            return options
        }
        return [defaultOption] + options.filter { $0.id != defaultID }
    }

    static func normalizedCorrectionBackend(_ backend: CorrectionBackendKind) -> CorrectionBackendKind {
        controllableCorrectionBackends.contains(backend) ? backend : .qwen35_2B
    }

    mutating func normalize() {
        recognitionSourceOptions = Self.controllableRecognitionSources
        enabledRecognitionSources = RecognitionSource.normalizedSources(enabledRecognitionSources).map(\.rawValue)

        asrModelOptionsByRecognitionSource = Self.controllableASRModelOptionsByRecognitionSource
        var normalizedModelIDs = Self.currentASRModelIDsByRecognitionSource
        for (sourceID, options) in asrModelOptionsByRecognitionSource {
            guard !options.isEmpty else {
                normalizedModelIDs.removeValue(forKey: sourceID)
                continue
            }
            let rawModelID = asrModelIDsByRecognitionSource[sourceID] ?? Self.defaultASRModelID(sourceID: sourceID)
            if options.contains(where: { $0.id == rawModelID }) {
                normalizedModelIDs[sourceID] = rawModelID
            } else {
                let defaultID = Self.defaultASRModelID(sourceID: sourceID)
                normalizedModelIDs[sourceID] = options.first(where: { $0.id == defaultID })?.id ?? options[0].id
            }
        }
        asrModelIDsByRecognitionSource = normalizedModelIDs

        var normalizedTimeouts = Self.currentASRTimeoutSecByRecognitionSource
        for (sourceID, timeout) in asrTimeoutSecByRecognitionSource {
            guard normalizedTimeouts[sourceID] != nil else { continue }
            normalizedTimeouts[sourceID] = Self.clampedASRTimeoutSec(timeout)
        }
        asrTimeoutSecByRecognitionSource = normalizedTimeouts

        supportedLanguagesByRecognitionSource = Self.supportedLanguagesByRecognitionSource
        supportedLanguages = ASRLanguageSelection.supportedOptions(for: enabledSources).map(BridgeLanguageOption.init)
        if !correctionBackendOptions.isEmpty && !correctionBackendOptions.contains(where: { $0.id == correctionBackend }) {
            correctionBackend = correctionBackendOptions[0].id
        }
        if CorrectionMode(rawValue: correctionMode) == nil {
            correctionMode = CorrectionMode.polish.rawValue
        }
        numberOutputPreference = NumberOutputPreference.normalized(numberOutputPreference).rawValue
        punctuationPreference = PunctuationOutputPreference.normalized(punctuationPreference).rawValue
        externalLLMBaseURL = externalLLMBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        externalLLMModel = externalLLMModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        correctionTimeoutMs = Self.clampedCorrectionTimeoutMs(correctionTimeoutMs)
        correctionColdTimeoutMs = Self.clampedCorrectionColdTimeoutMs(correctionColdTimeoutMs)
        languageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: BridgeLanguageOption.asASROptions(supportedLanguages)
        )
    }

    func supportedLanguageOptions(for sourceID: String) -> [ASRLanguageOption] {
        let options = supportedLanguagesByRecognitionSource[sourceID] ?? supportedLanguages
        return BridgeLanguageOption.asASROptions(options)
    }

    func supportedLanguageOptionsForEnabledSources() -> [ASRLanguageOption] {
        BridgeLanguageOption.asASROptions(supportedLanguages)
    }

    func asrModelOptions(for sourceID: String) -> [BridgeSettingOption] {
        asrModelOptionsByRecognitionSource[sourceID] ?? []
    }

    func asrModelID(for sourceID: String) -> String {
        asrModelIDsByRecognitionSource[sourceID] ?? Self.defaultASRModelID(sourceID: sourceID)
    }

    func asrTimeoutSec(for sourceID: String) -> Double {
        asrTimeoutSecByRecognitionSource[sourceID] ?? Self.currentASRTimeoutSec(sourceID: sourceID)
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
}

private struct BridgeResolvedSettings {
    let sources: [RecognitionSource]
    let supportedBySource: [String: [BridgeLanguageOption]]
    let languageIDs: [String]
    let supportedLanguages: [BridgeLanguageOption]
    let correctionMode: CorrectionMode
    let correctionBackend: CorrectionBackendKind

    init(
        sources: [RecognitionSource],
        supportedBySource: [String: [BridgeLanguageOption]],
        languageIDs: [String],
        supportedLanguages: [BridgeLanguageOption],
        correctionMode: CorrectionMode,
        correctionBackend: CorrectionBackendKind
    ) {
        self.sources = sources
        self.supportedBySource = supportedBySource
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.correctionMode = correctionMode
        self.correctionBackend = correctionBackend
    }

    func revisionPayload(userDictionary: [DictionaryEntry]) -> BridgeSettingsRevisionPayload {
        BridgeSettingsRevisionPayload(
            enabledRecognitionSources: sources.map(\.rawValue),
            recognitionSourceOptions: BridgeSettingsPayload.controllableRecognitionSources,
            asrModelIDsByRecognitionSource: BridgeSettingsPayload.currentASRModelIDsByRecognitionSource,
            asrModelOptionsByRecognitionSource: BridgeSettingsPayload.controllableASRModelOptionsByRecognitionSource,
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            supportedLanguagesByRecognitionSource: supportedBySource,
            asrTimeoutSecByRecognitionSource: BridgeSettingsPayload.currentASRTimeoutSecByRecognitionSource,
            correctionBackend: correctionBackend.rawValue,
            correctionBackendOptions: BridgeSettingsPayload.controllableCorrectionBackends.map {
                BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
            },
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            correctionColdTimeoutMs: AppSettings.correctionColdTimeoutMs,
            externalLLMBaseURL: AppSettings.externalLLMBaseURL,
            externalLLMModel: AppSettings.externalLLMModel,
            correctionMode: correctionMode.rawValue,
            numberOutputPreference: AppSettings.numberOutputPreference.rawValue,
            punctuationPreference: AppSettings.punctuationPreference.rawValue,
            autoCommit: AppSettings.autoCommit,
            debugMode: AppSettings.diagnosticsDebugMode,
            userDictionary: userDictionary
        )
    }
}

private struct BridgeSettingsRevisionPayload: Encodable {
    let enabledRecognitionSources: [String]
    let recognitionSourceOptions: [BridgeSettingOption]
    let asrModelIDsByRecognitionSource: [String: String]
    let asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]]
    let languageIDs: [String]
    let supportedLanguages: [BridgeLanguageOption]
    let supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]]
    let asrTimeoutSecByRecognitionSource: [String: Double]
    let correctionBackend: String
    let correctionBackendOptions: [BridgeSettingOption]
    let correctionTimeoutMs: Int
    let correctionColdTimeoutMs: Int
    let externalLLMBaseURL: String?
    let externalLLMModel: String?
    let correctionMode: String
    let numberOutputPreference: String
    let punctuationPreference: String
    let autoCommit: Bool
    let debugMode: Bool
    let userDictionary: [DictionaryEntry]

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
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
        case userDictionary = "user_dictionary"
    }

    init(
        enabledRecognitionSources: [String],
        recognitionSourceOptions: [BridgeSettingOption],
        asrModelIDsByRecognitionSource: [String: String],
        asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]],
        languageIDs: [String],
        supportedLanguages: [BridgeLanguageOption],
        supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]],
        asrTimeoutSecByRecognitionSource: [String: Double],
        correctionBackend: String,
        correctionBackendOptions: [BridgeSettingOption],
        correctionTimeoutMs: Int,
        correctionColdTimeoutMs: Int,
        externalLLMBaseURL: String?,
        externalLLMModel: String?,
        correctionMode: String,
        numberOutputPreference: String,
        punctuationPreference: String,
        autoCommit: Bool,
        debugMode: Bool,
        userDictionary: [DictionaryEntry]
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
        self.correctionTimeoutMs = correctionTimeoutMs
        self.correctionColdTimeoutMs = correctionColdTimeoutMs
        self.externalLLMBaseURL = externalLLMBaseURL
        self.externalLLMModel = externalLLMModel
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.debugMode = debugMode
        self.userDictionary = userDictionary
    }

    init(_ payload: BridgeSettingsPayload) {
        self.init(
            enabledRecognitionSources: payload.enabledRecognitionSources,
            recognitionSourceOptions: payload.recognitionSourceOptions,
            asrModelIDsByRecognitionSource: payload.asrModelIDsByRecognitionSource,
            asrModelOptionsByRecognitionSource: payload.asrModelOptionsByRecognitionSource,
            languageIDs: payload.languageIDs,
            supportedLanguages: payload.supportedLanguages,
            supportedLanguagesByRecognitionSource: payload.supportedLanguagesByRecognitionSource,
            asrTimeoutSecByRecognitionSource: payload.asrTimeoutSecByRecognitionSource,
            correctionBackend: payload.correctionBackend,
            correctionBackendOptions: payload.correctionBackendOptions,
            correctionTimeoutMs: payload.correctionTimeoutMs,
            correctionColdTimeoutMs: payload.correctionColdTimeoutMs,
            externalLLMBaseURL: payload.externalLLMBaseURL,
            externalLLMModel: payload.externalLLMModel,
            correctionMode: payload.correctionMode,
            numberOutputPreference: payload.numberOutputPreference,
            punctuationPreference: payload.punctuationPreference,
            autoCommit: payload.autoCommit,
            debugMode: payload.debugMode,
            userDictionary: payload.userDictionary
        )
    }
}

struct BridgeSettingsUpdateRequest: Decodable {
    var enabledRecognitionSources: [String]?
    var asrModelIDsByRecognitionSource: [String: String]?
    var languageIDs: [String]?
    var asrTimeoutSecByRecognitionSource: [String: Double]?
    var correctionBackend: String?
    var correctionTimeoutMs: Int?
    var correctionColdTimeoutMs: Int?
    var externalLLMBaseURL: String?
    var externalLLMModel: String?
    var correctionMode: String?
    var numberOutputPreference: String?
    var punctuationPreference: String?
    var autoCommit: Bool?
    var debugMode: Bool?
    var userDictionary: [DictionaryEntry]?

    enum CodingKeys: String, CodingKey {
        case enabledRecognitionSources = "enabled_recognition_sources"
        case asrModelIDsByRecognitionSource = "asr_model_ids_by_recognition_source"
        case languageIDs = "language_ids"
        case asrTimeoutSecByRecognitionSource = "asr_timeout_sec_by_recognition_source"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case externalLLMBaseURL = "external_llm_base_url"
        case externalLLMModel = "external_llm_model"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
        case userDictionary = "user_dictionary"
    }
}

struct BridgeLANAdapter: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let ip: String

    var displayName: String {
        "\(id) - \(ip)"
    }
}

struct BridgePairingPayload: Codable, Sendable {
    let lanBridgeURL: String?
    let lanBridgeURLs: [String]?
    let publicBridgeURL: String?
    let token: String

    enum CodingKeys: String, CodingKey {
        case lanBridgeURL = "lan_bridge_url"
        case lanBridgeURLs = "lan_bridge_urls"
        case publicBridgeURL = "public_bridge_url"
        case token
    }

    init(
        lanBridgeURL: String?,
        lanBridgeURLs: [String]? = nil,
        publicBridgeURL: String?,
        token: String
    ) {
        self.lanBridgeURL = lanBridgeURL
        self.lanBridgeURLs = lanBridgeURLs?.isEmpty == false ? lanBridgeURLs : nil
        self.publicBridgeURL = publicBridgeURL
        self.token = token
    }

    static func current() -> BridgePairingPayload {
        let port = AppSettings.bridgePort
        let lanURLs = AppSettings.bridgeLANEnabled ? lanBridgeURLs(port: port) : []
        let publicURL = AppSettings.bridgePublicEnabled ? publicBridgeURL() : nil

        return BridgePairingPayload(
            lanBridgeURL: lanURLs.first,
            lanBridgeURLs: lanURLs.isEmpty ? nil : lanURLs,
            publicBridgeURL: publicURL,
            token: AppSettings.ensureBridgeAuthToken()
        )
    }

    static func localBridgeURL(port: Int) -> String {
        return "http://127.0.0.1:\(port)"
    }

    static let allLANAdaptersID = "all"

    static func availableLANAdapters() -> [BridgeLANAdapter] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var seen = Set<String>()
        var adapters: [BridgeLANAdapter] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard !ip.hasPrefix("169.254.") else { continue }
            let name = String(cString: current.pointee.ifa_name)
            let key = "\(name)|\(ip)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            adapters.append(BridgeLANAdapter(id: name, ip: ip))
        }

        return adapters.sorted { lhs, rhs in
            adapterSortKey(lhs) < adapterSortKey(rhs)
        }
    }

    static func lanBridgeURLs(port: Int, adapterID: String = AppSettings.bridgeLANAdapter) -> [String] {
        let adapters = availableLANAdapters()
        let selected = adapterID == allLANAdaptersID
            ? adapters
            : adapters.filter { $0.id == adapterID }
        return selected.map { "http://\($0.ip):\(port)" }
    }

    static func lanBridgeURL(port: Int) -> String? {
        lanBridgeURLs(port: port).first
    }

    static func publicBridgeURL() -> String? {
        let trimmed = AppSettings.bridgeHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    static func primaryLANIPv4() -> String? {
        availableLANAdapters().first?.ip
    }

    private static func adapterSortKey(_ adapter: BridgeLANAdapter) -> (Int, String, String) {
        if adapter.id == "en0" { return (0, adapter.id, adapter.ip) }
        if adapter.id.hasPrefix("en") { return (1, adapter.id, adapter.ip) }
        return (2, adapter.id, adapter.ip)
    }
}

struct BridgeLanguageOption: Codable, Sendable, Identifiable, Hashable {
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

    static func asASROptions(_ options: [BridgeLanguageOption]) -> [ASRLanguageOption] {
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
