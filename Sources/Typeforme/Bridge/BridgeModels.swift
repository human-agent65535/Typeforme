import CryptoKit
import Darwin
import Foundation

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
    /// Optional client-provided transcription of the same audio. Current clients
    /// do not send live-preview text here; preview is display-only.
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

struct BridgeSettingsPayload: Codable, Sendable {
    var enabledRecognitionSources: [String]
    var recognitionSourceOptions: [BridgeSettingOption]
    var asrModelIDsByRecognitionSource: [String: String]
    var asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]]
    var languageIDs: [String]
    var supportedLanguages: [BridgeLanguageOption]
    var supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]]
    var asrTimeoutSec: Double
    var correctionBackend: String
    var correctionBackendOptions: [BridgeSettingOption]
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var externalLLMBaseURL: String?
    var externalLLMModel: String?
    var livePreviewSource: String
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
        case asrTimeoutSec = "asr_timeout_sec"
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

    static func currentASRTimeoutSec(for sources: [RecognitionSource] = AppSettings.configuredRecognitionSources) -> Double {
        clampedASRTimeoutSec(AppSettings.asrTimeoutSeconds(for: sources))
    }

    static var supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]] {
        Dictionary(
            uniqueKeysWithValues: RecognitionSource.allCases.map { source in
                (source.rawValue, source.supportedLanguages().map(BridgeLanguageOption.init))
            }
        )
    }

    var enabledSources: [RecognitionSource] {
        RecognitionSource.recognizedSources(enabledRecognitionSources)
    }

    func isRecognitionSourceEnabled(_ source: RecognitionSource) -> Bool {
        enabledSources.contains(source)
    }

    var supportsServerASRPreview: Bool {
        guard let source = VoiceLivePreviewSource(rawValue: livePreviewSource) else {
            return false
        }
        switch source {
        case .qwen:
            return isRecognitionSourceEnabled(.qwen)
        case .nvidiaNemotron:
            return isRecognitionSourceEnabled(.nvidiaNemotron)
        case .off, .appleSpeech:
            return false
        }
    }

    static let controllableCorrectionBackends: [CorrectionBackendKind] = [
        .qwen35_2B,
        .qwen35_4B,
        .qwen35_9B,
        .externalOpenAICompatible,
        .externalAnthropicCompatible,
    ]

    static let asrTimeoutRangeSec = BridgeSettingsNormalization.asrTimeoutSecondsRange
    static let correctionTimeoutRangeMs = BridgeSettingsNormalization.correctionTimeoutMillisecondsRange
    static let correctionColdTimeoutRangeMs = BridgeSettingsNormalization.correctionColdTimeoutMillisecondsRange

    static func clampedASRTimeoutSec(_ value: Double) -> Double {
        BridgeSettingsNormalization.clampedASRTimeoutSec(value)
    }

    static func clampedCorrectionTimeoutMs(_ value: Int) -> Int {
        BridgeSettingsNormalization.clampedCorrectionTimeoutMs(value)
    }

    static func clampedCorrectionColdTimeoutMs(_ value: Int) -> Int {
        BridgeSettingsNormalization.clampedCorrectionColdTimeoutMs(value)
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
            asrTimeoutSec: currentASRTimeoutSec(for: resolved.sources),
            correctionBackend: resolved.correctionBackend.rawValue,
            correctionBackendOptions: controllableCorrectionBackends.map {
                BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
            },
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            correctionColdTimeoutMs: AppSettings.correctionColdTimeoutMs,
            externalLLMBaseURL: AppSettings.externalLLMBaseURL,
            externalLLMModel: AppSettings.externalLLMModel,
            livePreviewSource: resolved.livePreviewSource.rawValue,
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

    var editableSnapshot: BridgeSettingsEditableSnapshot {
        BridgeSettingsEditableSnapshot(
            enabledRecognitionSources: enabledRecognitionSources,
            asrModelIDsByRecognitionSource: asrModelIDsByRecognitionSource,
            languageIDs: languageIDs,
            asrTimeoutSec: asrTimeoutSec,
            correctionBackend: correctionBackend,
            correctionTimeoutMs: correctionTimeoutMs,
            correctionColdTimeoutMs: correctionColdTimeoutMs,
            externalLLMBaseURL: externalLLMBaseURL,
            externalLLMModel: externalLLMModel,
            livePreviewSource: livePreviewSource,
            correctionMode: correctionMode,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            autoCommit: autoCommit,
            userDictionary: userDictionary
        )
    }

    static func settingsRevision(for payload: BridgeSettingsPayload) -> String {
        settingsRevision(for: BridgeSettingsRevisionPayload(payload))
    }

    private static func currentResolvedSettings() -> BridgeResolvedSettings {
        let sources = AppSettings.configuredRecognitionSources
        let supportedBySource = supportedLanguagesByRecognitionSource
        let supportedLanguages = ASRLanguageSelection.supportedOptions(for: sources).map(BridgeLanguageOption.init)
        let languageIDs = ASRLanguageSelection.validatedIDs(
            AppSettings.asrLanguageIDs,
            sources: sources
        )
        let configuredCorrectionMode = AppSettings.correctionMode
        let correctionMode = configuredCorrectionMode
        let correctionBackend = normalizedCorrectionBackend(AppSettings.correctionBackend)
        let livePreviewSource = normalizedLivePreviewSource(
            AppSettings.voiceLivePreviewSource,
            sources: sources,
            correctionMode: correctionMode
        )
        return BridgeResolvedSettings(
            sources: sources,
            supportedBySource: supportedBySource,
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            correctionMode: correctionMode,
            correctionBackend: correctionBackend,
            livePreviewSource: livePreviewSource
        )
    }

    private static func settingsRevision(for payload: BridgeSettingsRevisionPayload) -> String {
        let data: Data
        do {
            data = try BridgeJSON.encodeSorted(payload)
        } catch {
            preconditionFailure("Could not encode bridge settings revision payload: \(error)")
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedUserDictionary(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        DictionaryEntry.normalizedEntries(entries)
    }

    private static func rimeUserPhrases(from entries: [DictionaryEntry]) -> [String] {
        BridgeSettingsNormalization.rimeUserPhrases(from: entries.map(\.surface))
    }

    private static func selectedModelStatuses(
        sources: [RecognitionSource],
        correctionBackend: CorrectionBackendKind
    ) -> [BridgeModelStatus] {
        selectedASRModelStatuses(sources: sources)
            + [selectedRefineModelStatus(correctionBackend: correctionBackend)]
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

    private static func selectedRefineModelStatus(
        correctionBackend: CorrectionBackendKind
    ) -> BridgeModelStatus {
        guard !correctionBackend.isExternalCompatible else {
            return BridgeModelStatus(
                id: "refine:\(correctionBackend.rawValue)",
                kind: "refine",
                displayName: correctionBackend.displayName,
                installed: true,
                installing: false,
                detail: "External server"
            )
        }

        let modelPath = refineModelPath(for: correctionBackend)
        let installed = FileManager.default.fileExists(atPath: modelPath)
        let installing = ModelInstallRegistry.isInstalling(path: modelPath)
        return BridgeModelStatus(
            id: "refine:\(correctionBackend.rawValue)",
            kind: "refine",
            displayName: correctionBackend.displayName,
            installed: installed,
            installing: installing,
            detail: modelStatusDetail(installed: installed, installing: installing)
        )
    }

    private static func refineModelPath(for backend: CorrectionBackendKind) -> String {
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

    static func normalizedLivePreviewSource(
        _ source: VoiceLivePreviewSource,
        sources: [RecognitionSource],
        correctionMode: CorrectionMode
    ) -> VoiceLivePreviewSource {
        VoiceLivePreviewSource.options(
            forRecognitionSources: sources,
            correctionMode: correctionMode
        ).contains(source) ? source : .off
    }

    static func bridgeLivePreviewSource(
        configuredSource source: VoiceLivePreviewSource,
        sources: [RecognitionSource],
        correctionMode: CorrectionMode
    ) -> VoiceLivePreviewSource {
        return normalizedLivePreviewSource(source, sources: sources, correctionMode: correctionMode)
    }

    mutating func normalize() {
        recognitionSourceOptions = Self.controllableRecognitionSources
        enabledRecognitionSources = AppSettings.normalizedServerRecognitionSources(
            RecognitionSource.recognizedSources(enabledRecognitionSources)
        ).map(\.rawValue)

        asrModelOptionsByRecognitionSource = Self.controllableASRModelOptionsByRecognitionSource
        asrModelIDsByRecognitionSource = BridgeSettingsNormalization.normalizedASRModelIDs(
            currentModelIDs: Self.currentASRModelIDsByRecognitionSource,
            incomingModelIDs: asrModelIDsByRecognitionSource,
            optionsBySource: asrModelOptionsByRecognitionSource,
            defaultID: Self.defaultASRModelID(sourceID:)
        )

        asrTimeoutSec = Self.clampedASRTimeoutSec(asrTimeoutSec)

        supportedLanguagesByRecognitionSource = Self.supportedLanguagesByRecognitionSource
        supportedLanguages = ASRLanguageSelection.supportedOptions(for: enabledSources).map(BridgeLanguageOption.init)
        if !correctionBackendOptions.isEmpty && !correctionBackendOptions.contains(where: { $0.id == correctionBackend }) {
            correctionBackend = correctionBackendOptions[0].id
        }
        var resolvedCorrectionMode: CorrectionMode
        if let mode = CorrectionMode(rawValue: correctionMode) {
            resolvedCorrectionMode = mode
        } else {
            correctionMode = CorrectionMode.polish.rawValue
            resolvedCorrectionMode = .polish
        }
        numberOutputPreference = NumberOutputPreference.normalized(numberOutputPreference).rawValue
        punctuationPreference = PunctuationOutputPreference.normalized(punctuationPreference).rawValue
        externalLLMBaseURL = externalLLMBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        externalLLMModel = externalLLMModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        livePreviewSource = Self.normalizedLivePreviewSource(
            VoiceLivePreviewSource(rawValue: livePreviewSource.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .off,
            sources: enabledSources,
            correctionMode: resolvedCorrectionMode
        ).rawValue
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
        asrModelIDsByRecognitionSource[sourceID] ?? Self.defaultASRModelID(sourceID: sourceID)
    }

    mutating func setRecognitionSource(_ source: RecognitionSource, enabled: Bool) {
        guard source != .appleSpeech else { return }
        var sources = enabledSources
        if enabled {
            if !sources.contains(source) {
                sources.append(source)
            }
        } else {
            sources.removeAll { $0 == source }
        }
        let resolvedSources = RecognitionSource.recognizedSources(sources.map(\.rawValue))
        guard !resolvedSources.isEmpty else { return }
        enabledRecognitionSources = resolvedSources.map(\.rawValue)
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
    let livePreviewSource: VoiceLivePreviewSource

    init(
        sources: [RecognitionSource],
        supportedBySource: [String: [BridgeLanguageOption]],
        languageIDs: [String],
        supportedLanguages: [BridgeLanguageOption],
        correctionMode: CorrectionMode,
        correctionBackend: CorrectionBackendKind,
        livePreviewSource: VoiceLivePreviewSource
    ) {
        self.sources = sources
        self.supportedBySource = supportedBySource
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.correctionMode = correctionMode
        self.correctionBackend = correctionBackend
        self.livePreviewSource = livePreviewSource
    }

    func revisionPayload(userDictionary: [DictionaryEntry]) -> BridgeSettingsRevisionPayload {
        let editableSnapshot = BridgeSettingsEditableSnapshot(
            enabledRecognitionSources: sources.map(\.rawValue),
            asrModelIDsByRecognitionSource: BridgeSettingsPayload.currentASRModelIDsByRecognitionSource,
            languageIDs: languageIDs,
            asrTimeoutSec: BridgeSettingsPayload.currentASRTimeoutSec(for: sources),
            correctionBackend: correctionBackend.rawValue,
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            correctionColdTimeoutMs: AppSettings.correctionColdTimeoutMs,
            externalLLMBaseURL: AppSettings.externalLLMBaseURL,
            externalLLMModel: AppSettings.externalLLMModel,
            livePreviewSource: livePreviewSource.rawValue,
            correctionMode: correctionMode.rawValue,
            numberOutputPreference: AppSettings.numberOutputPreference.rawValue,
            punctuationPreference: AppSettings.punctuationPreference.rawValue,
            autoCommit: AppSettings.autoCommit,
            userDictionary: userDictionary
        )
        return BridgeSettingsRevisionPayload(
            editableSnapshot: editableSnapshot,
            recognitionSourceOptions: BridgeSettingsPayload.controllableRecognitionSources,
            asrModelOptionsByRecognitionSource: BridgeSettingsPayload.controllableASRModelOptionsByRecognitionSource,
            supportedLanguages: supportedLanguages,
            supportedLanguagesByRecognitionSource: supportedBySource,
            correctionBackendOptions: BridgeSettingsPayload.controllableCorrectionBackends.map {
                BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
            }
        )
    }
}

private struct BridgeSettingsRevisionPayload: Encodable {
    let editableSnapshot: BridgeSettingsEditableSnapshot
    let recognitionSourceOptions: [BridgeSettingOption]
    let asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]]
    let supportedLanguages: [BridgeLanguageOption]
    let supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]]
    let correctionBackendOptions: [BridgeSettingOption]

    enum CodingKeys: String, CodingKey {
        case enabledRecognitionSources = "enabled_recognition_sources"
        case recognitionSourceOptions = "recognition_source_options"
        case asrModelIDsByRecognitionSource = "asr_model_ids_by_recognition_source"
        case asrModelOptionsByRecognitionSource = "asr_model_options_by_recognition_source"
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case supportedLanguagesByRecognitionSource = "supported_languages_by_recognition_source"
        case asrTimeoutSec = "asr_timeout_sec"
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
    }

    init(
        editableSnapshot: BridgeSettingsEditableSnapshot,
        recognitionSourceOptions: [BridgeSettingOption],
        asrModelOptionsByRecognitionSource: [String: [BridgeSettingOption]],
        supportedLanguages: [BridgeLanguageOption],
        supportedLanguagesByRecognitionSource: [String: [BridgeLanguageOption]],
        correctionBackendOptions: [BridgeSettingOption]
    ) {
        self.editableSnapshot = editableSnapshot
        self.recognitionSourceOptions = recognitionSourceOptions
        self.asrModelOptionsByRecognitionSource = asrModelOptionsByRecognitionSource
        self.supportedLanguages = supportedLanguages
        self.supportedLanguagesByRecognitionSource = supportedLanguagesByRecognitionSource
        self.correctionBackendOptions = correctionBackendOptions
    }

    init(_ payload: BridgeSettingsPayload) {
        self.init(
            editableSnapshot: payload.editableSnapshot,
            recognitionSourceOptions: payload.recognitionSourceOptions,
            asrModelOptionsByRecognitionSource: payload.asrModelOptionsByRecognitionSource,
            supportedLanguages: payload.supportedLanguages,
            supportedLanguagesByRecognitionSource: payload.supportedLanguagesByRecognitionSource,
            correctionBackendOptions: payload.correctionBackendOptions
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(editableSnapshot.enabledRecognitionSources, forKey: .enabledRecognitionSources)
        try container.encode(recognitionSourceOptions, forKey: .recognitionSourceOptions)
        try container.encode(editableSnapshot.asrModelIDsByRecognitionSource, forKey: .asrModelIDsByRecognitionSource)
        try container.encode(asrModelOptionsByRecognitionSource, forKey: .asrModelOptionsByRecognitionSource)
        try container.encode(editableSnapshot.languageIDs, forKey: .languageIDs)
        try container.encode(supportedLanguages, forKey: .supportedLanguages)
        try container.encode(supportedLanguagesByRecognitionSource, forKey: .supportedLanguagesByRecognitionSource)
        try container.encode(editableSnapshot.asrTimeoutSec, forKey: .asrTimeoutSec)
        try container.encode(editableSnapshot.correctionBackend, forKey: .correctionBackend)
        try container.encode(correctionBackendOptions, forKey: .correctionBackendOptions)
        try container.encode(editableSnapshot.correctionTimeoutMs, forKey: .correctionTimeoutMs)
        try container.encode(editableSnapshot.correctionColdTimeoutMs, forKey: .correctionColdTimeoutMs)
        try container.encodeIfPresent(editableSnapshot.externalLLMBaseURL, forKey: .externalLLMBaseURL)
        try container.encodeIfPresent(editableSnapshot.externalLLMModel, forKey: .externalLLMModel)
        try container.encode(editableSnapshot.livePreviewSource, forKey: .livePreviewSource)
        try container.encode(editableSnapshot.correctionMode, forKey: .correctionMode)
        try container.encode(editableSnapshot.numberOutputPreference, forKey: .numberOutputPreference)
        try container.encode(editableSnapshot.punctuationPreference, forKey: .punctuationPreference)
        try container.encode(editableSnapshot.autoCommit, forKey: .autoCommit)
        try container.encode(editableSnapshot.userDictionary, forKey: .userDictionary)
    }
}

struct BridgeLANAdapter: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let ip: String

    var displayName: String {
        "\(id) - \(ip)"
    }
}

extension BridgePairingPayload {
    static func current() -> BridgePairingPayload {
        let port = AppSettings.bridgePort
        let lanURLs = AppSettings.bridgeLANEnabled ? lanBridgeURLs(port: port) : []
        let publicURL = AppSettings.bridgePublicEnabled ? publicBridgeURL() : nil

        return BridgePairingPayload(
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
