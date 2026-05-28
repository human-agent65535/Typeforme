import Foundation

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
        self.error = error
        self.updatedAt = updatedAt
    }
}
