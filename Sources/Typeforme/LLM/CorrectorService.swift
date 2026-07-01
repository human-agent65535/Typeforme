import Foundation

struct CorrectionDebugTrace: Codable, Sendable, Equatable {
    var rawModelOutput: String?
    var parsedText: String?
    var validationSignal: String?
    var formatRepairAttempted: Bool
    var formatRepairRawModelOutput: String?
    var formatRepairDecision: String?
    var formatRepairText: String?
    var formatRepairError: String?
    var verifierAttempted: Bool
    var verifierRawModelOutput: String?
    var verifierDecision: String?
    var verifierReasonCode: String?
    var verifierText: String?
    var verifierError: String?

    init(
        rawModelOutput: String? = nil,
        parsedText: String? = nil,
        validationSignal: String? = nil,
        formatRepairAttempted: Bool = false,
        formatRepairRawModelOutput: String? = nil,
        formatRepairDecision: String? = nil,
        formatRepairText: String? = nil,
        formatRepairError: String? = nil,
        verifierAttempted: Bool = false,
        verifierRawModelOutput: String? = nil,
        verifierDecision: String? = nil,
        verifierReasonCode: String? = nil,
        verifierText: String? = nil,
        verifierError: String? = nil
    ) {
        self.rawModelOutput = rawModelOutput
        self.parsedText = parsedText
        self.validationSignal = validationSignal
        self.formatRepairAttempted = formatRepairAttempted
        self.formatRepairRawModelOutput = formatRepairRawModelOutput
        self.formatRepairDecision = formatRepairDecision
        self.formatRepairText = formatRepairText
        self.formatRepairError = formatRepairError
        self.verifierAttempted = verifierAttempted
        self.verifierRawModelOutput = verifierRawModelOutput
        self.verifierDecision = verifierDecision
        self.verifierReasonCode = verifierReasonCode
        self.verifierText = verifierText
        self.verifierError = verifierError
    }

    enum CodingKeys: String, CodingKey {
        case rawModelOutput = "raw_model_output"
        case parsedText = "parsed_text"
        case validationSignal = "validation_signal"
        case formatRepairAttempted = "format_repair_attempted"
        case formatRepairRawModelOutput = "format_repair_raw_model_output"
        case formatRepairDecision = "format_repair_decision"
        case formatRepairText = "format_repair_text"
        case formatRepairError = "format_repair_error"
        case verifierAttempted = "verifier_attempted"
        case verifierRawModelOutput = "verifier_raw_model_output"
        case verifierDecision = "verifier_decision"
        case verifierReasonCode = "verifier_reason_code"
        case verifierText = "verifier_text"
        case verifierError = "verifier_error"
    }
}

struct CorrectorOutput: Sendable, Equatable {
    var result: CorrectionResult
    var debugTrace: CorrectionDebugTrace
}

/// Backends transform a `CorrectionRequest` into a `CorrectionResult`.
/// Every backend receives a hard request timeout; cold starts use a separate
/// warmup timeout before the chat request.
protocol CorrectorService: Sendable {
    var kind: CorrectionBackendKind { get }
    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput
    func complete(system: String, messages: [CorrectorChatMessage], timeoutMs: Int) async throws -> String
}

struct CorrectorChatMessage: Sendable, Equatable {
    let role: String
    let content: String

    static func user(_ content: String) -> CorrectorChatMessage {
        CorrectorChatMessage(role: "user", content: content)
    }

    static func assistant(_ content: String) -> CorrectorChatMessage {
        CorrectorChatMessage(role: "assistant", content: content)
    }
}

extension CorrectorService {
    func complete(system: String, user: String, timeoutMs: Int) async throws -> String {
        try await complete(system: system, messages: [.user(user)], timeoutMs: timeoutMs)
    }
}

enum CorrectorError: LocalizedError, Equatable {
    case timeout
    case unavailable(String)
    case validationFailed(String, trace: CorrectionDebugTrace?)
    case requestFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .timeout:               return "Correction timed out"
        case .unavailable(let why):  return "Backend unavailable: \(why)"
        case .validationFailed(let why, _): return "Output validation failed: \(why)"
        case .requestFailed(let why):    return "Backend error: \(why)"
        case .empty:                 return "Backend returned no usable output"
        }
    }

    var correctionDebugTrace: CorrectionDebugTrace? {
        switch self {
        case .validationFailed(_, let trace):
            return trace
        default:
            return nil
        }
    }
}
