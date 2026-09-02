import Foundation

struct BridgeAPIRoute: Equatable, Sendable {
    let method: String
    let path: String

    var methodAndPath: String {
        "\(method) \(path)"
    }
}

enum BridgeClientIdentityHeaders {
    static let id = "X-Typeforme-Client-ID"
    static let name = "X-Typeforme-Client-Name"
    static let platform = "X-Typeforme-Client-Platform"
    static let bundleID = "X-Typeforme-Client-Bundle-ID"
}

enum RecognitionSource: String, CaseIterable, Codable, Identifiable, Sendable {
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

    var qualitySpeedLabel: String {
        switch self {
        case .qwen:
            return NSLocalizedString("High quality / slower", comment: "Qwen ASR quality and speed rating")
        case .nvidiaNemotron:
            return NSLocalizedString("Low quality / medium speed", comment: "NVIDIA Nemotron ASR quality and speed rating")
        case .appleSpeech:
            return NSLocalizedString("Medium quality / fastest", comment: "Apple Speech ASR quality and speed rating")
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

    static let defaultEnabled: [RecognitionSource] = []

    static func recognizedSources(_ raw: [String]) -> [RecognitionSource] {
        var seen = Set<RecognitionSource>()
        let values = raw.compactMap { value -> RecognitionSource? in
            RecognitionSource(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return values.filter { seen.insert($0).inserted }
    }

    static func normalizedSources(_ raw: [String]) -> [RecognitionSource] {
        recognizedSources(raw)
    }

    static func rawValue(for sources: [RecognitionSource]) -> String {
        sources.map(\.rawValue).joined(separator: ",")
    }
}

extension CorrectionMode {
    func isAvailable(enabledRecognitionSources sources: [RecognitionSource]) -> Bool {
        true
    }
}

enum BridgeAPIEndpoint {
    static let health = BridgeAPIRoute(method: "GET", path: "/v1/health")
    static let pairing = BridgeAPIRoute(method: "GET", path: "/v1/pairing")
    static let settingsRead = BridgeAPIRoute(method: "GET", path: "/v1/settings")
    static let settingsWrite = BridgeAPIRoute(method: "POST", path: "/v1/settings")
    static let dictate = BridgeAPIRoute(method: "POST", path: "/v1/dictate")
    static let livePreviewStart = BridgeAPIRoute(method: "POST", path: "/v1/live-preview/start")
    static let refine = BridgeAPIRoute(method: "POST", path: "/v1/refine")
    static let editText = BridgeAPIRoute(method: "POST", path: "/v1/edit-text")

    static let jobEventsTemplate = BridgeAPIRoute(method: "WS", path: "/v1/jobs/:jobID/events")
    static let livePreviewSocketTemplate = BridgeAPIRoute(method: "WS", path: "/v1/live-preview/:sessionID/socket")
    static let livePreviewFinishTemplate = BridgeAPIRoute(method: "POST", path: "/v1/live-preview/:sessionID/finish")
    static let livePreviewCancelTemplate = BridgeAPIRoute(method: "POST", path: "/v1/live-preview/:sessionID/cancel")

    static func jobEvents(jobID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "WS", path: "/v1/jobs/\(jobID)/events")
    }

    static func livePreviewSocket(sessionID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "WS", path: "/v1/live-preview/\(sessionID)/socket")
    }

    static func livePreviewFinish(sessionID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "POST", path: "/v1/live-preview/\(sessionID)/finish")
    }

    static func livePreviewCancel(sessionID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "POST", path: "/v1/live-preview/\(sessionID)/cancel")
    }
}

struct BridgeHealthResponse: Codable, Sendable {
    let ok: Bool
    let service: String?
    let version: String?
    let bridgePort: Int?
    let settingsRevision: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case service
        case version
        case bridgePort = "bridge_port"
        case settingsRevision = "settings_revision"
    }

    init(
        ok: Bool,
        service: String? = nil,
        version: String? = nil,
        bridgePort: Int? = nil,
        settingsRevision: String? = nil
    ) {
        self.ok = ok
        self.service = service
        self.version = version
        self.bridgePort = bridgePort
        self.settingsRevision = settingsRevision
    }
}

struct BridgeSettingsEditableSnapshot: Codable, Equatable, Sendable {
    var enabledRecognitionSources: [String]
    var asrModelIDsByRecognitionSource: [String: String]
    var languageIDs: [String]
    var asrTimeoutSec: Double
    var fastASRSource: String
    var correctionBackend: String
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var externalLLMBaseURL: String?
    var externalLLMModel: String?
    var livePreviewSource: String
    var correctionMode: String
    var numberOutputPreference: String
    var punctuationPreference: String
    var autoCommit: Bool
    var aiWritingEnabled: Bool
    var userDictionary: [DictionaryEntry]

    enum CodingKeys: String, CodingKey {
        case enabledRecognitionSources = "enabled_recognition_sources"
        case asrModelIDsByRecognitionSource = "asr_model_ids_by_recognition_source"
        case languageIDs = "language_ids"
        case asrTimeoutSec = "asr_timeout_sec"
        case fastASRSource = "fast_asr_source"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case externalLLMBaseURL = "external_llm_base_url"
        case externalLLMModel = "external_llm_model"
        case livePreviewSource = "live_preview_source"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case aiWritingEnabled = "ai_writing_enabled"
        case userDictionary = "user_dictionary"
    }

    init(
        enabledRecognitionSources: [String],
        asrModelIDsByRecognitionSource: [String: String],
        languageIDs: [String],
        asrTimeoutSec: Double,
        fastASRSource: String,
        correctionBackend: String,
        correctionTimeoutMs: Int,
        correctionColdTimeoutMs: Int,
        externalLLMBaseURL: String?,
        externalLLMModel: String?,
        livePreviewSource: String,
        correctionMode: String,
        numberOutputPreference: String,
        punctuationPreference: String,
        autoCommit: Bool,
        aiWritingEnabled: Bool = false,
        userDictionary: [DictionaryEntry]
    ) {
        self.enabledRecognitionSources = enabledRecognitionSources
        self.asrModelIDsByRecognitionSource = asrModelIDsByRecognitionSource
        self.languageIDs = languageIDs
        self.asrTimeoutSec = asrTimeoutSec
        self.fastASRSource = fastASRSource
        self.correctionBackend = correctionBackend
        self.correctionTimeoutMs = correctionTimeoutMs
        self.correctionColdTimeoutMs = correctionColdTimeoutMs
        self.externalLLMBaseURL = externalLLMBaseURL
        self.externalLLMModel = externalLLMModel
        self.livePreviewSource = livePreviewSource
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.aiWritingEnabled = aiWritingEnabled
        self.userDictionary = DictionaryEntry.normalizedEntries(userDictionary)
    }
}

struct BridgeSettingsUpdateRequest: Codable, Sendable {
    var expectedSettingsRevision: String
    var enabledRecognitionSources: [String]?
    var asrModelIDsByRecognitionSource: [String: String]?
    var languageIDs: [String]?
    var asrTimeoutSec: Double?
    var fastASRSource: String?
    var correctionBackend: String?
    var correctionTimeoutMs: Int?
    var correctionColdTimeoutMs: Int?
    var externalLLMBaseURL: String?
    var externalLLMModel: String?
    var livePreviewSource: String?
    var correctionMode: String?
    var numberOutputPreference: String?
    var punctuationPreference: String?
    var autoCommit: Bool?
    var aiWritingEnabled: Bool?
    var userDictionary: [DictionaryEntry]?

    enum CodingKeys: String, CodingKey {
        case expectedSettingsRevision = "expected_settings_revision"
        case enabledRecognitionSources = "enabled_recognition_sources"
        case asrModelIDsByRecognitionSource = "asr_model_ids_by_recognition_source"
        case languageIDs = "language_ids"
        case asrTimeoutSec = "asr_timeout_sec"
        case fastASRSource = "fast_asr_source"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case externalLLMBaseURL = "external_llm_base_url"
        case externalLLMModel = "external_llm_model"
        case livePreviewSource = "live_preview_source"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case aiWritingEnabled = "ai_writing_enabled"
        case userDictionary = "user_dictionary"
    }

    init(
        expectedSettingsRevision: String,
        enabledRecognitionSources: [String]? = nil,
        asrModelIDsByRecognitionSource: [String: String]? = nil,
        languageIDs: [String]? = nil,
        asrTimeoutSec: Double? = nil,
        fastASRSource: String? = nil,
        correctionBackend: String? = nil,
        correctionTimeoutMs: Int? = nil,
        correctionColdTimeoutMs: Int? = nil,
        externalLLMBaseURL: String? = nil,
        externalLLMModel: String? = nil,
        livePreviewSource: String? = nil,
        correctionMode: String? = nil,
        numberOutputPreference: String? = nil,
        punctuationPreference: String? = nil,
        autoCommit: Bool? = nil,
        aiWritingEnabled: Bool? = nil,
        userDictionary: [DictionaryEntry]? = nil
    ) {
        self.expectedSettingsRevision = expectedSettingsRevision
        self.enabledRecognitionSources = enabledRecognitionSources
        self.asrModelIDsByRecognitionSource = asrModelIDsByRecognitionSource
        self.languageIDs = languageIDs
        self.asrTimeoutSec = asrTimeoutSec
        self.fastASRSource = fastASRSource
        self.correctionBackend = correctionBackend
        self.correctionTimeoutMs = correctionTimeoutMs
        self.correctionColdTimeoutMs = correctionColdTimeoutMs
        self.externalLLMBaseURL = externalLLMBaseURL
        self.externalLLMModel = externalLLMModel
        self.livePreviewSource = livePreviewSource
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.aiWritingEnabled = aiWritingEnabled
        self.userDictionary = userDictionary
    }

    init(
        editableSnapshot: BridgeSettingsEditableSnapshot,
        expectedSettingsRevision: String
    ) {
        self.init(
            expectedSettingsRevision: expectedSettingsRevision,
            enabledRecognitionSources: editableSnapshot.enabledRecognitionSources,
            asrModelIDsByRecognitionSource: editableSnapshot.asrModelIDsByRecognitionSource,
            languageIDs: editableSnapshot.languageIDs,
            asrTimeoutSec: editableSnapshot.asrTimeoutSec,
            fastASRSource: editableSnapshot.fastASRSource,
            correctionBackend: editableSnapshot.correctionBackend,
            correctionTimeoutMs: editableSnapshot.correctionTimeoutMs,
            correctionColdTimeoutMs: editableSnapshot.correctionColdTimeoutMs,
            externalLLMBaseURL: editableSnapshot.externalLLMBaseURL,
            externalLLMModel: editableSnapshot.externalLLMModel,
            livePreviewSource: editableSnapshot.livePreviewSource,
            correctionMode: editableSnapshot.correctionMode,
            numberOutputPreference: editableSnapshot.numberOutputPreference,
            punctuationPreference: editableSnapshot.punctuationPreference,
            autoCommit: editableSnapshot.autoCommit,
            aiWritingEnabled: editableSnapshot.aiWritingEnabled,
            userDictionary: editableSnapshot.userDictionary
        )
    }
}

struct BridgeRefineRequest: Codable, Sendable {
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

    init(
        sessionID: String? = nil,
        rawTranscript: String? = nil,
        clientJobID: String? = nil,
        languageIDs: [String]? = nil,
        languageMode: String? = nil,
        correctionMode: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        appCategory: String? = nil,
        contextBefore: String? = nil,
        contextAfter: String? = nil
    ) {
        self.sessionID = sessionID
        self.rawTranscript = rawTranscript
        self.clientJobID = clientJobID
        self.languageIDs = languageIDs
        self.languageMode = languageMode
        self.correctionMode = correctionMode
        self.appName = appName
        self.bundleID = bundleID
        self.appCategory = appCategory
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

struct BridgeTextEditRequest: Codable, Sendable {
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

    init(
        intent: String? = nil,
        contextBefore: String? = nil,
        targetText: String? = nil,
        contextAfter: String? = nil,
        spokenInstruction: String? = nil,
        languageIDs: [String]? = nil,
        languageMode: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        appCategory: String? = nil,
        clientJobID: String? = nil
    ) {
        self.intent = intent
        self.contextBefore = contextBefore
        self.targetText = targetText
        self.contextAfter = contextAfter
        self.spokenInstruction = spokenInstruction
        self.languageIDs = languageIDs
        self.languageMode = languageMode
        self.appName = appName
        self.bundleID = bundleID
        self.appCategory = appCategory
        self.clientJobID = clientJobID
    }
}

struct BridgeDictateResponse: Codable, Sendable {
    let sessionID: String
    let text: String
    let correctionMode: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let transcriptionLatencyMs: Int?
    let correctionLatencyMs: Int?
    let rawTranscript: String?
    let asrWarning: String?
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
        case asrWarning = "asr_warning"
        case correctionStatus = "correction_status"
        case correctionError = "correction_error"
    }

    init(
        sessionID: String,
        text: String,
        correctionMode: String? = nil,
        languageIDs: [String],
        latencyMs: Int? = nil,
        transcriptionLatencyMs: Int? = nil,
        correctionLatencyMs: Int? = nil,
        rawTranscript: String? = nil,
        asrWarning: String? = nil,
        correctionStatus: String? = nil,
        correctionError: String? = nil
    ) {
        self.sessionID = sessionID
        self.text = text
        self.correctionMode = correctionMode
        self.languageIDs = languageIDs
        self.latencyMs = latencyMs
        self.transcriptionLatencyMs = transcriptionLatencyMs
        self.correctionLatencyMs = correctionLatencyMs
        self.rawTranscript = rawTranscript
        self.asrWarning = asrWarning
        self.correctionStatus = correctionStatus
        self.correctionError = correctionError
    }
}

struct BridgeRefineResponse: Codable, Sendable {
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

    init(
        sessionID: String,
        text: String,
        correctionMode: String? = nil,
        languageIDs: [String],
        latencyMs: Int? = nil,
        correctionLatencyMs: Int? = nil,
        correctionStatus: String? = nil,
        correctionError: String? = nil
    ) {
        self.sessionID = sessionID
        self.text = text
        self.correctionMode = correctionMode
        self.languageIDs = languageIDs
        self.latencyMs = latencyMs
        self.correctionLatencyMs = correctionLatencyMs
        self.correctionStatus = correctionStatus
        self.correctionError = correctionError
    }
}

struct BridgeTextEditResponse: Codable, Sendable {
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

    init(
        text: String,
        action: String? = nil,
        languageIDs: [String],
        latencyMs: Int? = nil,
        editLatencyMs: Int? = nil,
        editStatus: String? = nil,
        editError: String? = nil
    ) {
        self.text = text
        self.action = action
        self.languageIDs = languageIDs
        self.latencyMs = latencyMs
        self.editLatencyMs = editLatencyMs
        self.editStatus = editStatus
        self.editError = editError
    }
}

struct BridgeErrorResponse: Codable, Sendable {
    let error: String
}
