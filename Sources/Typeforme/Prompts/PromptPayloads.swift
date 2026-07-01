import Foundation

struct PromptOutputPreferencesPayload: Codable, Sendable, Equatable {
    let numbers: String
    let numberInstruction: String
    let punctuation: String
    let punctuationInstruction: String

    enum CodingKeys: String, CodingKey {
        case numbers
        case numberInstruction = "number_instruction"
        case punctuation
        case punctuationInstruction = "punctuation_instruction"
    }

    var isDefault: Bool {
        numbers == NumberOutputPreference.automatic.rawValue
            && punctuation == PunctuationOutputPreference.normal.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numbers, forKey: .numbers)
        if numberInstruction != "natural" {
            try container.encode(numberInstruction, forKey: .numberInstruction)
        }
        try container.encode(punctuation, forKey: .punctuation)
        if punctuationInstruction != "natural" {
            try container.encode(punctuationInstruction, forKey: .punctuationInstruction)
        }
    }
}

struct DictationPromptContextPayload: Codable, Sendable, Equatable {
    let appName: String
    let bundleID: String
    let appCategory: String
    let languageCodes: [String]
    let languageInstruction: String
    let correctionMode: String
    let outputPreferences: PromptOutputPreferencesPayload

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case languageCodes = "language_codes"
        case languageInstruction = "language_instruction"
        case correctionMode = "correction_mode"
        case outputPreferences = "output_preferences"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !appName.isEmpty {
            try container.encode(appName, forKey: .appName)
        }
        if !bundleID.isEmpty {
            try container.encode(bundleID, forKey: .bundleID)
        }
        if appCategory != AppCategory.unknown.rawValue {
            try container.encode(appCategory, forKey: .appCategory)
        }
        try container.encode(languageCodes, forKey: .languageCodes)
        try container.encode(languageInstruction, forKey: .languageInstruction)
        try container.encode(correctionMode, forKey: .correctionMode)
        if !outputPreferences.isDefault {
            try container.encode(outputPreferences, forKey: .outputPreferences)
        }
    }
}

struct DictationPromptInputPayload: Codable, Sendable, Equatable {
    let context: DictationPromptContextPayload
    let contextBefore: String
    let contextAfter: String
    let vocabularyCandidates: [VocabularyCandidatePayload]
    let rawTranscript: String
    let audioDurationMs: Int?
    /// Source-aware ASR hypotheses. Source is evidence metadata, not authority.
    let asrHypotheses: [ASRSourceHypothesis]

    enum CodingKeys: String, CodingKey {
        case context
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case vocabularyCandidates = "vocabulary_candidates"
        case rawTranscript = "raw_transcript"
        case audioDurationMs = "audio_duration_ms"
        case asrHypotheses = "asr_hypotheses"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        if !contextBefore.isEmpty {
            try container.encode(contextBefore, forKey: .contextBefore)
        }
        if !contextAfter.isEmpty {
            try container.encode(contextAfter, forKey: .contextAfter)
        }
        if !vocabularyCandidates.isEmpty {
            try container.encode(vocabularyCandidates, forKey: .vocabularyCandidates)
        }
        try container.encode(rawTranscript, forKey: .rawTranscript)
        if let audioDurationMs {
            try container.encode(audioDurationMs, forKey: .audioDurationMs)
        }
        if shouldEncodeASRHypotheses {
            try container.encode(asrHypotheses, forKey: .asrHypotheses)
        }
    }

    private var shouldEncodeASRHypotheses: Bool {
        guard !asrHypotheses.isEmpty else { return false }
        if asrHypotheses.count == 1,
           asrHypotheses[0].source == ASRSourceHypothesis.unattributedSource,
           asrHypotheses[0].text == rawTranscript {
            return false
        }
        return true
    }
}

struct DictationRepairPromptPayload: Codable, Sendable, Equatable {
    let validationError: String

    enum CodingKeys: String, CodingKey {
        case validationError = "validation_error"
    }
}

struct DictationVerifierPromptPayload: Codable, Sendable, Equatable {
    let validationSignal: String
    let candidateText: String

    enum CodingKeys: String, CodingKey {
        case validationSignal = "validation_signal"
        case candidateText = "candidate_text"
    }
}

struct TextEditPromptContextPayload: Codable, Sendable, Equatable {
    let appName: String
    let bundleID: String
    let appCategory: String
    let languages: [String]
    let languageCodes: [String]
    let languageInstruction: String
    let targetLanguageHint: String
    let outputPreferences: PromptOutputPreferencesPayload

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case languages
        case languageCodes = "language_codes"
        case languageInstruction = "language_instruction"
        case targetLanguageHint = "target_language_hint"
        case outputPreferences = "output_preferences"
    }
}

struct TextEditPromptInputPayload: Codable, Sendable, Equatable {
    let task: String
    let intent: String
    let context: TextEditPromptContextPayload
    let vocabularyCandidates: [VocabularyCandidatePayload]
    let contextBefore: String
    let targetText: String
    let contextAfter: String
    let spokenInstruction: String

    enum CodingKeys: String, CodingKey {
        case task
        case intent
        case context
        case vocabularyCandidates = "vocabulary_candidates"
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
    }
}

enum PromptPayloadEncoder {
    static func jsonString<T: Encodable>(_ payload: T) -> String {
        let data: Data
        do {
            data = try BridgeJSON.encodeSorted(payload)
        } catch {
            preconditionFailure("Could not encode prompt payload: \(error)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("Prompt payload JSON was not UTF-8")
        }
        return text
            .replacingOccurrences(of: "</", with: "<\\/")
    }
}
