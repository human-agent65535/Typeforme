import Foundation

enum CorrectorPipeline {
    private static let verifierInputCeiling = 12_000

    typealias Completion = (
        _ system: String,
        _ messages: [CorrectorChatMessage],
        _ timeoutMs: Int
    ) async throws -> String

    static func correct(
        request: CorrectionRequest,
        timeoutMs: Int,
        complete: Completion
    ) async throws -> CorrectorOutput {
        let (system, user) = PromptBuilder.build(for: request)
        let originalMessages: [CorrectorChatMessage] = [.user(user)]
        let rawOutput = try await complete(system, originalMessages, timeoutMs)
        var trace = CorrectionDebugTrace(rawModelOutput: rawOutput)

        return try await processCandidate(
            rawOutput: rawOutput,
            request: request,
            system: system,
            originalMessages: originalMessages,
            timeoutMs: timeoutMs,
            trace: trace,
            complete: complete
        )
    }

    private static func processCandidate(
        rawOutput: String,
        request: CorrectionRequest,
        system: String,
        originalMessages: [CorrectorChatMessage],
        timeoutMs: Int,
        trace: CorrectionDebugTrace,
        complete: Completion
    ) async throws -> CorrectorOutput {
        var trace = trace
        let parsed: CorrectionResult
        do {
            parsed = try CorrectionValidator.parse(rawOutput: rawOutput)
            trace.parsedText = parsed.text
        } catch let error as CorrectionValidationError {
            guard case .parseFailed = error else {
                trace.validationSignal = error.localizedDescription
                throw CorrectorError.validationFailed(error.localizedDescription, trace: trace)
            }
            return try await formatRepair(
                parseError: error,
                invalidOutput: rawOutput,
                request: request,
                system: system,
                originalMessages: originalMessages,
                timeoutMs: timeoutMs,
                trace: trace,
                complete: complete
            )
        }

        do {
            try CorrectionValidator.validate(parsed, for: request)
            return CorrectorOutput(result: parsed, debugTrace: trace)
        } catch let error as CorrectionValidationError {
            trace.validationSignal = error.localizedDescription
            return try await verifyCandidate(
                parsed,
                rawOutput: rawOutput,
                validationSignal: error,
                request: request,
                system: system,
                originalMessages: originalMessages,
                timeoutMs: timeoutMs,
                trace: trace,
                complete: complete
            )
        }
    }

    private static func formatRepair(
        parseError: CorrectionValidationError,
        invalidOutput: String,
        request: CorrectionRequest,
        system: String,
        originalMessages: [CorrectorChatMessage],
        timeoutMs: Int,
        trace: CorrectionDebugTrace,
        complete: Completion
    ) async throws -> CorrectorOutput {
        var trace = trace
        trace.validationSignal = parseError.localizedDescription
        trace.formatRepairAttempted = true
        let messages = originalMessages + [
            .assistant(invalidOutput),
            .user(PromptBuilder.formatRepairPrompt(parseError: parseError.localizedDescription)),
        ]

        let repairOutput: String
        do {
            repairOutput = try await complete(system, messages, timeoutMs)
        } catch {
            trace.formatRepairError = "Format repair request failed: \(error.localizedDescription)"
            throw CorrectorError.validationFailed(trace.formatRepairError ?? error.localizedDescription, trace: trace)
        }
        trace.formatRepairRawModelOutput = repairOutput

        let payload: FormatRepairPayload
        do {
            payload = try decodeStrictJSONObject(repairOutput)
        } catch {
            trace.formatRepairError = error.localizedDescription
            throw CorrectorError.validationFailed(error.localizedDescription, trace: trace)
        }
        trace.formatRepairDecision = payload.decision.rawValue
        trace.formatRepairText = payload.text

        guard payload.decision == .rewrap else {
            let message = "Format repair rejected output"
            trace.formatRepairError = message
            throw CorrectorError.validationFailed(message, trace: trace)
        }

        let result = CorrectionResult(
            action: .commit,
            text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
            risk: .low
        )
        do {
            try CorrectionValidator.validateForCommit(result)
        } catch let error as CorrectionValidationError {
            trace.formatRepairError = error.localizedDescription
            throw CorrectorError.validationFailed(error.localizedDescription, trace: trace)
        }
        trace.parsedText = result.text

        return try await verifyIfNeededAfterFormatRepair(
            result,
            repairOutput: repairOutput,
            request: request,
            system: system,
            originalMessages: originalMessages,
            timeoutMs: timeoutMs,
            trace: trace,
            complete: complete
        )
    }

    private static func verifyIfNeededAfterFormatRepair(
        _ result: CorrectionResult,
        repairOutput: String,
        request: CorrectionRequest,
        system: String,
        originalMessages: [CorrectorChatMessage],
        timeoutMs: Int,
        trace: CorrectionDebugTrace,
        complete: Completion
    ) async throws -> CorrectorOutput {
        var trace = trace
        do {
            try CorrectionValidator.validate(result, for: request)
            return CorrectorOutput(result: result, debugTrace: trace)
        } catch let error as CorrectionValidationError {
            trace.validationSignal = error.localizedDescription
            return try await verifyCandidate(
                result,
                rawOutput: repairOutput,
                validationSignal: error,
                request: request,
                system: system,
                originalMessages: originalMessages,
                timeoutMs: timeoutMs,
                trace: trace,
                complete: complete
            )
        }
    }

    private static func verifyCandidate(
        _ candidate: CorrectionResult,
        rawOutput: String,
        validationSignal: CorrectionValidationError,
        request: CorrectionRequest,
        system: String,
        originalMessages: [CorrectorChatMessage],
        timeoutMs: Int,
        trace: CorrectionDebugTrace,
        complete: Completion
    ) async throws -> CorrectorOutput {
        var trace = trace
        guard rawOutput.count <= verifierInputCeiling,
              candidate.text.count <= verifierInputCeiling
        else {
            let message = "Verifier input too large"
            trace.verifierError = message
            throw CorrectorError.validationFailed(message, trace: trace)
        }

        trace.verifierAttempted = true
        let messages = originalMessages + [
            .assistant(rawOutput),
            .user(PromptBuilder.verifierPrompt(
                validationSignal: validationSignal.localizedDescription,
                candidateText: candidate.text
            )),
        ]

        let verifierOutput: String
        do {
            verifierOutput = try await complete(system, messages, timeoutMs)
        } catch {
            trace.verifierError = "Verifier request failed: \(error.localizedDescription)"
            throw CorrectorError.validationFailed(trace.verifierError ?? error.localizedDescription, trace: trace)
        }
        trace.verifierRawModelOutput = verifierOutput

        let payload: VerifierPayload
        do {
            payload = try decodeStrictJSONObject(verifierOutput)
        } catch {
            trace.verifierError = error.localizedDescription
            throw CorrectorError.validationFailed(error.localizedDescription, trace: trace)
        }
        trace.verifierDecision = payload.decision.rawValue
        trace.verifierReasonCode = payload.reasonCode
        trace.verifierText = payload.text

        switch payload.decision {
        case .accept:
            guard payload.text == candidate.text else {
                let message = "Verifier accept changed candidate text"
                trace.verifierError = message
                throw CorrectorError.validationFailed(message, trace: trace)
            }
            do {
                try CorrectionValidator.validateForCommit(candidate)
            } catch let error as CorrectionValidationError {
                trace.verifierError = error.localizedDescription
                throw CorrectorError.validationFailed(error.localizedDescription, trace: trace)
            }
            return CorrectorOutput(result: candidate, debugTrace: trace)
        case .replace:
            let replacement = CorrectionResult(
                action: .commit,
                text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
                risk: .low
            )
            do {
                try CorrectionValidator.validateForCommit(replacement)
            } catch let error as CorrectionValidationError {
                trace.verifierError = error.localizedDescription
                throw CorrectorError.validationFailed(error.localizedDescription, trace: trace)
            }
            return CorrectorOutput(result: replacement, debugTrace: trace)
        case .reject:
            let message = "Verifier rejected output"
            trace.verifierError = message
            throw CorrectorError.validationFailed(message, trace: trace)
        }
    }

    private static func decodeStrictJSONObject<Payload: Decodable>(_ rawOutput: String) throws -> Payload {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("```"),
              !trimmed.contains("<think>"),
              !trimmed.contains("</think>")
        else {
            throw CorrectionValidationError.parseFailed("output contains markup")
        }
        guard let jsonString = ModelOutputCleaner.extractFirstJSONObject(trimmed) else {
            throw CorrectionValidationError.parseFailed("no JSON object found")
        }
        guard jsonString == trimmed else {
            throw CorrectionValidationError.parseFailed("output must contain exactly one JSON object")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw CorrectionValidationError.parseFailed("not utf-8")
        }
        do {
            return try BridgeJSON.decode(Payload.self, from: data)
        } catch {
            throw CorrectionValidationError.parseFailed(error.localizedDescription)
        }
    }
}

private struct FormatRepairPayload: Decodable {
    enum Decision: String, Decodable {
        case rewrap
        case reject
    }

    var decision: Decision
    var text: String

    init(from decoder: Decoder) throws {
        try Self.validateKeys(decoder, allowed: ["decision", "text"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(Decision.self, forKey: .decision)
        text = try container.decode(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case text
    }
}

private struct VerifierPayload: Decodable {
    enum Decision: String, Decodable {
        case accept
        case replace
        case reject
    }

    var decision: Decision
    var reasonCode: String
    var text: String

    init(from decoder: Decoder) throws {
        try Self.validateKeys(decoder, allowed: ["decision", "reason_code", "text"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(Decision.self, forKey: .decision)
        reasonCode = try container.decode(String.self, forKey: .reasonCode)
        text = try container.decode(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case reasonCode = "reason_code"
        case text
    }
}

private extension Decodable {
    static func validateKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let keys = try decoder.container(keyedBy: DynamicCodingKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == allowed else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unexpected keys: \(keys.sorted().joined(separator: ","))"
                )
            )
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
