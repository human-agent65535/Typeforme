import Foundation

enum BridgeClientJobID {
    static let maxLength = 96

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let allowed = trimmed.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return allowed == trimmed ? trimmed : nil
    }
}

enum BridgeBaseURLNormalizer {
    static func uniqueBridgeURLs(_ rawValues: [String]) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for rawValue in rawValues {
            let normalized = normalizedBaseURL(rawValue)
            guard !normalized.isEmpty, URL(string: normalized) != nil else { continue }
            guard seen.insert(normalized).inserted else { continue }
            urls.append(normalized)
        }
        return urls
    }

    static func normalizedBaseURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if isLocalBridgeHost(trimmed) {
            return "http://\(trimmed)"
        }
        return "https://\(trimmed)"
    }

    private static func isLocalBridgeHost(_ value: String) -> Bool {
        if value.hasPrefix("[::1]") || value.hasPrefix("::1") {
            return true
        }
        let host = URLComponents(string: "http://\(value)")?.host ?? value
        return host == "localhost"
            || host.hasPrefix("127.")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
            || host == "::1"
    }
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

enum BridgeJobStatusStage: String, Codable, Sendable {
    case audioReceived = "audio_received"
    case transcribing
    case transcriptReady = "transcript_ready"
    case refining
    case resultReady = "result_ready"
    case failed

    var isTerminal: Bool {
        switch self {
        case .resultReady, .failed:
            return true
        default:
            return false
        }
    }
}

struct BridgeJobStatusEvent: Codable, Sendable {
    let jobID: String
    let stage: BridgeJobStatusStage
    let message: String
    let rawTranscript: String?
    let rawTranscriptLength: Int?
    let text: String?
    let latencyMs: Int?
    let transcriptionLatencyMs: Int?
    let refineLatencyMs: Int?
    let warning: String?
    let error: String?
    let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case stage
        case message
        case rawTranscript = "raw_transcript"
        case rawTranscriptLength = "raw_transcript_length"
        case text
        case latencyMs = "latency_ms"
        case transcriptionLatencyMs = "transcription_latency_ms"
        case refineLatencyMs = "refine_latency_ms"
        case warning
        case error
        case updatedAt = "updated_at"
    }

    init(
        jobID: String,
        stage: BridgeJobStatusStage,
        message: String,
        rawTranscript: String? = nil,
        rawTranscriptLength: Int? = nil,
        text: String? = nil,
        latencyMs: Int? = nil,
        transcriptionLatencyMs: Int? = nil,
        refineLatencyMs: Int? = nil,
        warning: String? = nil,
        error: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.jobID = jobID
        self.stage = stage
        self.message = message
        self.rawTranscript = rawTranscript
        self.rawTranscriptLength = rawTranscriptLength
        self.text = text
        self.latencyMs = latencyMs
        self.transcriptionLatencyMs = transcriptionLatencyMs
        self.refineLatencyMs = refineLatencyMs
        self.warning = warning
        self.error = error
        self.updatedAt = updatedAt
    }
}

struct BridgeLivePreviewStartRequest: Codable, Sendable {
    let clientJobID: String?
    let languageIDs: [String]?
    let languageMode: String?
    let appName: String?
    let bundleID: String?
    let appCategory: String?

    enum CodingKeys: String, CodingKey {
        case clientJobID = "client_job_id"
        case languageIDs = "language_ids"
        case languageMode = "language_mode"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
    }

    init(
        clientJobID: String? = nil,
        languageIDs: [String]? = nil,
        languageMode: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        appCategory: String? = nil
    ) {
        self.clientJobID = clientJobID
        self.languageIDs = languageIDs
        self.languageMode = languageMode
        self.appName = appName
        self.bundleID = bundleID
        self.appCategory = appCategory
    }
}

struct BridgeLivePreviewStartResponse: Codable, Sendable {
    let sessionID: String
    let provider: String
    let languageIDs: [String]
    let startedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case provider
        case languageIDs = "language_ids"
        case startedAt = "started_at"
    }
}

struct BridgeLivePreviewAudioAppendResponse: Codable, Sendable {
    let sessionID: String
    let text: String?
    let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case updatedAt = "updated_at"
    }
}

struct BridgeLivePreviewFinishResponse: Codable, Sendable {
    let sessionID: String
    let text: String?
    let finishedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case finishedAt = "finished_at"
    }
}
