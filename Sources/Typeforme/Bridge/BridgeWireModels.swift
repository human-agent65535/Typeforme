import Foundation

struct BridgeAPIRoute: Equatable, Sendable {
    let method: String
    let path: String

    var methodAndPath: String {
        "\(method) \(path)"
    }
}

enum BridgeAPIEndpoint {
    static let health = BridgeAPIRoute(method: "GET", path: "/v1/health")
    static let pairing = BridgeAPIRoute(method: "GET", path: "/v1/pairing")
    static let settingsRead = BridgeAPIRoute(method: "GET", path: "/v1/settings")
    static let settingsWrite = BridgeAPIRoute(method: "POST", path: "/v1/settings")
    static let dictate = BridgeAPIRoute(method: "POST", path: "/v1/dictate")
    static let livePreviewStart = BridgeAPIRoute(method: "POST", path: "/v1/live-preview/start")
    static let restyle = BridgeAPIRoute(method: "POST", path: "/v1/restyle")
    static let editText = BridgeAPIRoute(method: "POST", path: "/v1/edit-text")

    static let jobEventsTemplate = BridgeAPIRoute(method: "GET", path: "/v1/jobs/:jobID/events")
    static let livePreviewSocketTemplate = BridgeAPIRoute(method: "WS", path: "/v1/live-preview/:sessionID/socket")
    static let livePreviewFinishTemplate = BridgeAPIRoute(method: "POST", path: "/v1/live-preview/:sessionID/finish")

    static func jobEvents(jobID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "GET", path: "/v1/jobs/\(jobID)/events")
    }

    static func livePreviewSocket(sessionID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "GET", path: "/v1/live-preview/\(sessionID)/socket")
    }

    static func livePreviewFinish(sessionID: String) -> BridgeAPIRoute {
        BridgeAPIRoute(method: "POST", path: "/v1/live-preview/\(sessionID)/finish")
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

struct BridgeRestyleRequest: Codable, Sendable {
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

struct BridgeRestyleResponse: Codable, Sendable {
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
