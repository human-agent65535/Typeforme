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
    var languageIDs: [String]?
    var languageMode: String?
    var correctionMode: String?
    var appName: String?
    var bundleID: String?
    var appCategory: String?
    var contextBefore: String?
    var contextAfter: String?
    var includeRawTranscript: Bool?

    init(
        audioData: Data? = nil,
        audioFileURL: URL? = nil,
        audioExtension: String?,
        languageIDs: [String]?,
        languageMode: String? = nil,
        correctionMode: String?,
        appName: String?,
        bundleID: String?,
        appCategory: String?,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        includeRawTranscript: Bool?
    ) {
        self.audioData = audioData
        self.audioFileURL = audioFileURL
        self.audioExtension = audioExtension
        self.languageIDs = languageIDs
        self.languageMode = languageMode
        self.correctionMode = correctionMode
        self.appName = appName
        self.bundleID = bundleID
        self.appCategory = appCategory
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.includeRawTranscript = includeRawTranscript
    }
}

struct BridgeRestyleRequest: Decodable {
    var sessionID: String?
    var rawTranscript: String?
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

struct BridgeSettingOption: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct BridgeModelStatus: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let kind: String
    let displayName: String
    let installed: Bool
    let installing: Bool
    let detail: String

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName = "display_name"
        case installed
        case installing
        case detail
    }
}

struct BridgeSettingsPayload: Codable, Sendable {
    var asrProvider: String
    var asrProviderOptions: [BridgeSettingOption]
    var languageIDs: [String]
    var supportedLanguages: [BridgeLanguageOption]
    var supportedLanguagesByASRProvider: [String: [BridgeLanguageOption]]
    var asrTimeoutSec: Int
    var correctionBackend: String
    var correctionBackendOptions: [BridgeSettingOption]
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var lmStudioBaseURL: String?
    var lmStudioModel: String?
    var correctionMode: String
    var numberOutputPreference: String
    var punctuationPreference: String
    var autoCommit: Bool
    var debugMode: Bool
    var modelStatuses: [BridgeModelStatus]
    var settingsRevision: String?

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
        case lmStudioBaseURL = "lm_studio_base_url"
        case lmStudioModel = "lm_studio_model"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
        case modelStatuses = "model_statuses"
        case settingsRevision = "settings_revision"
    }

    static let controllableASRProviders: [BridgeSettingOption] = [
        BridgeSettingOption(id: "qwen3-asr-llama", displayName: "Qwen3-ASR (default)"),
        BridgeSettingOption(id: "whisperkit", displayName: "WhisperKit"),
    ]

    static let controllableCorrectionBackends: [CorrectionBackendKind] = [
        .qwen35_2B,
        .qwen35_4B,
        .qwen35_9B,
        .externalLMStudio,
    ]

    static func current() -> BridgeSettingsPayload {
        let resolved = currentResolvedSettings()
        let settingsRevision = settingsRevision(for: resolved.revisionPayload)
        return BridgeSettingsPayload(
            asrProvider: resolved.provider,
            asrProviderOptions: controllableASRProviders,
            languageIDs: resolved.languageIDs,
            supportedLanguages: resolved.supportedLanguages,
            supportedLanguagesByASRProvider: resolved.supportedByProvider,
            asrTimeoutSec: currentASRTimeoutSec(provider: resolved.provider),
            correctionBackend: resolved.correctionBackend.rawValue,
            correctionBackendOptions: controllableCorrectionBackends.map {
                BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
            },
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            correctionColdTimeoutMs: AppSettings.correctionColdTimeoutMs,
            lmStudioBaseURL: AppSettings.lmStudioBaseURL,
            lmStudioModel: AppSettings.lmStudioModel,
            correctionMode: resolved.correctionMode.rawValue,
            numberOutputPreference: AppSettings.numberOutputPreference.rawValue,
            punctuationPreference: AppSettings.punctuationPreference.rawValue,
            autoCommit: AppSettings.autoCommit,
            debugMode: AppSettings.diagnosticsDebugMode,
            modelStatuses: selectedModelStatuses(
                asrProvider: resolved.provider,
                correctionBackend: resolved.correctionBackend
            ),
            settingsRevision: settingsRevision
        )
    }

    static func currentSettingsRevision() -> String {
        settingsRevision(for: currentResolvedSettings().revisionPayload)
    }

    static func settingsRevision(for payload: BridgeSettingsPayload) -> String {
        settingsRevision(for: BridgeSettingsRevisionPayload(payload))
    }

    private static func currentResolvedSettings() -> BridgeResolvedSettings {
        let provider = normalizedASRProvider(AppSettings.asrProvider)
        let supportedByProvider = Dictionary(
            uniqueKeysWithValues: controllableASRProviders.map { option in
                (option.id, ASRLanguageSelection.supportedOptions(forProvider: option.id).map(BridgeLanguageOption.init))
            }
        )
        let supportedLanguages = supportedByProvider[provider] ?? ASRLanguageSelection.all.map(BridgeLanguageOption.init)
        let languageIDs = ASRLanguageSelection.validatedIDs(
            AppSettings.asrLanguageIDs,
            supportedOptions: ASRLanguageSelection.supportedOptions(forProvider: provider)
        )
        let correctionMode = AppSettings.correctionMode
        let correctionBackend = normalizedCorrectionBackend(AppSettings.correctionBackend)
        return BridgeResolvedSettings(
            asrProvider: provider,
            supportedByProvider: supportedByProvider,
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

    private static func selectedModelStatuses(
        asrProvider: String,
        correctionBackend: CorrectionBackendKind
    ) -> [BridgeModelStatus] {
        [
            selectedASRModelStatus(asrProvider: asrProvider),
            selectedRestyleModelStatus(correctionBackend: correctionBackend),
        ]
    }

    fileprivate static func currentASRTimeoutSec(provider: String) -> Int {
        if provider == "whisperkit" {
            return Int(AppSettings.asrWhisperKitTimeoutSeconds)
        }
        return Int(AppSettings.asrQwenLlamaTimeoutSeconds)
    }

    private static func selectedASRModelStatus(asrProvider: String) -> BridgeModelStatus {
        let fileManager = FileManager.default
        if asrProvider == "qwen3-asr-llama" {
            let spec = QwenASRModelCatalog.spec(for: AppSettings.asrQwenLlamaModelID)
            let modelPath = AppSettings.asrQwenLlamaModelPath
            let mmprojPath = AppSettings.asrQwenLlamaMMProjPath
            let installed = fileManager.fileExists(atPath: modelPath)
                && fileManager.fileExists(atPath: mmprojPath)
            let installing = ModelInstallRegistry.isInstalling(path: modelPath)
                || ModelInstallRegistry.isInstalling(path: mmprojPath)
            return BridgeModelStatus(
                id: "asr:\(asrProvider):\(spec.id)",
                kind: "asr",
                displayName: spec.label,
                installed: installed,
                installing: installing,
                detail: modelStatusDetail(installed: installed, installing: installing)
            )
        }

        let modelName = AppSettings.asrModel
        let installed = WhisperKitASRService.cachedModelInfo(for: modelName) != nil
        return BridgeModelStatus(
            id: "asr:whisperkit:\(modelName)",
            kind: "asr",
            displayName: "WhisperKit \(modelName)",
            installed: installed,
            installing: false,
            detail: installed ? "Ready" : "Managed by WhisperKit"
        )
    }

    private static func selectedRestyleModelStatus(
        correctionBackend: CorrectionBackendKind
    ) -> BridgeModelStatus {
        guard correctionBackend != .externalLMStudio else {
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
        case .externalLMStudio:
            return ""
        }
    }

    private static func modelStatusDetail(installed: Bool, installing: Bool) -> String {
        if installing { return "Installing" }
        return installed ? "Ready" : "Not installed"
    }

    static func normalizedASRProvider(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if controllableASRProviders.contains(where: { $0.id == value }) {
            return value
        }
        return "qwen3-asr-llama"
    }

    static func normalizedCorrectionBackend(_ backend: CorrectionBackendKind) -> CorrectionBackendKind {
        controllableCorrectionBackends.contains(backend) ? backend : .qwen35_2B
    }

    mutating func normalize() {
        if !asrProviderOptions.isEmpty && !asrProviderOptions.contains(where: { $0.id == asrProvider }) {
            asrProvider = asrProviderOptions[0].id
        }
        if !correctionBackendOptions.isEmpty && !correctionBackendOptions.contains(where: { $0.id == correctionBackend }) {
            correctionBackend = correctionBackendOptions[0].id
        }
        if CorrectionMode(rawValue: correctionMode) == nil {
            correctionMode = CorrectionMode.polish.rawValue
        }
        numberOutputPreference = NumberOutputPreference.normalized(numberOutputPreference).rawValue
        punctuationPreference = PunctuationOutputPreference.normalized(punctuationPreference).rawValue
        lmStudioBaseURL = lmStudioBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        lmStudioModel = lmStudioModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        asrTimeoutSec = min(max(asrTimeoutSec, 10), 300)
        correctionTimeoutMs = min(max(correctionTimeoutMs, 100), 30_000)
        correctionColdTimeoutMs = min(max(correctionColdTimeoutMs, 1_000), 60_000)
        languageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: supportedLanguageOptions(for: asrProvider)
        )
    }

    func supportedLanguageOptions(for provider: String) -> [ASRLanguageOption] {
        let options = supportedLanguagesByASRProvider[provider] ?? supportedLanguages
        return BridgeLanguageOption.asASROptions(options)
    }
}

private struct BridgeResolvedSettings {
    let provider: String
    let supportedByProvider: [String: [BridgeLanguageOption]]
    let languageIDs: [String]
    let supportedLanguages: [BridgeLanguageOption]
    let correctionMode: CorrectionMode
    let correctionBackend: CorrectionBackendKind

    init(
        asrProvider: String,
        supportedByProvider: [String: [BridgeLanguageOption]],
        languageIDs: [String],
        supportedLanguages: [BridgeLanguageOption],
        correctionMode: CorrectionMode,
        correctionBackend: CorrectionBackendKind
    ) {
        self.provider = asrProvider
        self.supportedByProvider = supportedByProvider
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.correctionMode = correctionMode
        self.correctionBackend = correctionBackend
    }

    var revisionPayload: BridgeSettingsRevisionPayload {
        BridgeSettingsRevisionPayload(
            asrProvider: provider,
            asrProviderOptions: BridgeSettingsPayload.controllableASRProviders,
            languageIDs: languageIDs,
            supportedLanguages: supportedLanguages,
            supportedLanguagesByASRProvider: supportedByProvider,
            asrTimeoutSec: BridgeSettingsPayload.currentASRTimeoutSec(provider: provider),
            correctionBackend: correctionBackend.rawValue,
            correctionBackendOptions: BridgeSettingsPayload.controllableCorrectionBackends.map {
                BridgeSettingOption(id: $0.rawValue, displayName: $0.displayName)
            },
            correctionTimeoutMs: AppSettings.correctionTimeoutMs,
            correctionColdTimeoutMs: AppSettings.correctionColdTimeoutMs,
            lmStudioBaseURL: AppSettings.lmStudioBaseURL,
            lmStudioModel: AppSettings.lmStudioModel,
            correctionMode: correctionMode.rawValue,
            numberOutputPreference: AppSettings.numberOutputPreference.rawValue,
            punctuationPreference: AppSettings.punctuationPreference.rawValue,
            autoCommit: AppSettings.autoCommit,
            debugMode: AppSettings.diagnosticsDebugMode
        )
    }
}

private struct BridgeSettingsRevisionPayload: Encodable {
    let asrProvider: String
    let asrProviderOptions: [BridgeSettingOption]
    let languageIDs: [String]
    let supportedLanguages: [BridgeLanguageOption]
    let supportedLanguagesByASRProvider: [String: [BridgeLanguageOption]]
    let asrTimeoutSec: Int
    let correctionBackend: String
    let correctionBackendOptions: [BridgeSettingOption]
    let correctionTimeoutMs: Int
    let correctionColdTimeoutMs: Int
    let lmStudioBaseURL: String?
    let lmStudioModel: String?
    let correctionMode: String
    let numberOutputPreference: String
    let punctuationPreference: String
    let autoCommit: Bool
    let debugMode: Bool

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
        case lmStudioBaseURL = "lm_studio_base_url"
        case lmStudioModel = "lm_studio_model"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
    }

    init(
        asrProvider: String,
        asrProviderOptions: [BridgeSettingOption],
        languageIDs: [String],
        supportedLanguages: [BridgeLanguageOption],
        supportedLanguagesByASRProvider: [String: [BridgeLanguageOption]],
        asrTimeoutSec: Int,
        correctionBackend: String,
        correctionBackendOptions: [BridgeSettingOption],
        correctionTimeoutMs: Int,
        correctionColdTimeoutMs: Int,
        lmStudioBaseURL: String?,
        lmStudioModel: String?,
        correctionMode: String,
        numberOutputPreference: String,
        punctuationPreference: String,
        autoCommit: Bool,
        debugMode: Bool
    ) {
        self.asrProvider = asrProvider
        self.asrProviderOptions = asrProviderOptions
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.supportedLanguagesByASRProvider = supportedLanguagesByASRProvider
        self.asrTimeoutSec = asrTimeoutSec
        self.correctionBackend = correctionBackend
        self.correctionBackendOptions = correctionBackendOptions
        self.correctionTimeoutMs = correctionTimeoutMs
        self.correctionColdTimeoutMs = correctionColdTimeoutMs
        self.lmStudioBaseURL = lmStudioBaseURL
        self.lmStudioModel = lmStudioModel
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.debugMode = debugMode
    }

    init(_ payload: BridgeSettingsPayload) {
        self.init(
            asrProvider: payload.asrProvider,
            asrProviderOptions: payload.asrProviderOptions,
            languageIDs: payload.languageIDs,
            supportedLanguages: payload.supportedLanguages,
            supportedLanguagesByASRProvider: payload.supportedLanguagesByASRProvider,
            asrTimeoutSec: payload.asrTimeoutSec,
            correctionBackend: payload.correctionBackend,
            correctionBackendOptions: payload.correctionBackendOptions,
            correctionTimeoutMs: payload.correctionTimeoutMs,
            correctionColdTimeoutMs: payload.correctionColdTimeoutMs,
            lmStudioBaseURL: payload.lmStudioBaseURL,
            lmStudioModel: payload.lmStudioModel,
            correctionMode: payload.correctionMode,
            numberOutputPreference: payload.numberOutputPreference,
            punctuationPreference: payload.punctuationPreference,
            autoCommit: payload.autoCommit,
            debugMode: payload.debugMode
        )
    }
}

struct BridgeSettingsUpdateRequest: Decodable {
    var asrProvider: String?
    var languageIDs: [String]?
    var asrTimeoutSec: Int?
    var correctionBackend: String?
    var correctionTimeoutMs: Int?
    var correctionColdTimeoutMs: Int?
    var lmStudioBaseURL: String?
    var lmStudioModel: String?
    var correctionMode: String?
    var numberOutputPreference: String?
    var punctuationPreference: String?
    var autoCommit: Bool?
    var debugMode: Bool?

    enum CodingKeys: String, CodingKey {
        case asrProvider = "asr_provider"
        case languageIDs = "language_ids"
        case asrTimeoutSec = "asr_timeout_sec"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case lmStudioBaseURL = "lm_studio_base_url"
        case lmStudioModel = "lm_studio_model"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
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

            let ip = String(cString: host)
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
            return ASRLanguageOption(id: id, displayName: name, whisperCode: id)
        }
        return resolved.isEmpty ? ASRLanguageSelection.all : resolved
    }
}
