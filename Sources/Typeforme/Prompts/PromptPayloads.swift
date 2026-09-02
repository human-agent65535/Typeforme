import Foundation

struct PromptOutputPreferencesPayload: Codable, Sendable, Equatable {
    let numbers: String
    let punctuation: String

    enum CodingKeys: String, CodingKey {
        case numbers
        case punctuation
    }

    var isDefault: Bool {
        numbers == NumberOutputPreference.automatic.rawValue
            && punctuation == PunctuationOutputPreference.normal.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numbers, forKey: .numbers)
        try container.encode(punctuation, forKey: .punctuation)
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

/// Prompt-only representation of an ASR result. Embedded requests may replace
/// text that is already present in `raw_transcript`, or a completed empty
/// result, with an explicit status. This preserves the evidence without paying
/// to encode the same transcript twice.
struct DictationPromptASRHypothesisPayload: Codable, Sendable, Equatable {
    let source: String
    let text: String?
    let matchesRawTranscript: Bool
    let completedEmpty: Bool

    enum CodingKeys: String, CodingKey {
        case source
        case text
        case matchesRawTranscript = "matches_raw_transcript"
        case completedEmpty = "completed_empty"
    }

    private init(
        source: String,
        text: String?,
        matchesRawTranscript: Bool,
        completedEmpty: Bool
    ) {
        self.source = source
        self.text = text
        self.matchesRawTranscript = matchesRawTranscript
        self.completedEmpty = completedEmpty
    }

    static func full(_ hypothesis: ASRSourceHypothesis) -> Self {
        Self(
            source: hypothesis.source,
            text: hypothesis.text,
            matchesRawTranscript: false,
            completedEmpty: false
        )
    }

    static func compact(_ hypothesis: ASRSourceHypothesis, rawTranscript: String) -> Self {
        if hypothesis.text == rawTranscript {
            return Self(
                source: hypothesis.source,
                text: nil,
                matchesRawTranscript: true,
                completedEmpty: false
            )
        }
        if hypothesis.text.isEmpty {
            return Self(
                source: hypothesis.source,
                text: nil,
                matchesRawTranscript: false,
                completedEmpty: true
            )
        }
        return Self(
            source: hypothesis.source,
            text: hypothesis.text,
            matchesRawTranscript: false,
            completedEmpty: false
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        matchesRawTranscript = try container.decodeIfPresent(Bool.self, forKey: .matchesRawTranscript) ?? false
        completedEmpty = try container.decodeIfPresent(Bool.self, forKey: .completedEmpty) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        if let text {
            try container.encode(text, forKey: .text)
        }
        if matchesRawTranscript {
            try container.encode(true, forKey: .matchesRawTranscript)
        }
        if completedEmpty {
            try container.encode(true, forKey: .completedEmpty)
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
    let asrHypotheses: [DictationPromptASRHypothesisPayload]

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
           (asrHypotheses[0].text == rawTranscript || asrHypotheses[0].matchesRawTranscript) {
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

struct PinyinTextEditPromptInputPayload: Encodable, Sendable {
    let pinyin: String
    let inputSegments: [String]
    let contextBefore: String
    let contextAfter: String
    let vocabularyCandidates: [VocabularyCandidatePayload]
    let protectedLiterals: [String]

    enum CodingKeys: String, CodingKey {
        case pinyin
        case inputSegments = "input_segments"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case vocabularyCandidates = "vocabulary_candidates"
        case protectedLiterals = "protected_literals"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pinyin, forKey: .pinyin)
        try container.encode(inputSegments, forKey: .inputSegments)
        try container.encode(contextBefore, forKey: .contextBefore)
        try container.encode(contextAfter, forKey: .contextAfter)
        if !vocabularyCandidates.isEmpty {
            try container.encode(vocabularyCandidates, forKey: .vocabularyCandidates)
        }
        if !protectedLiterals.isEmpty {
            try container.encode(protectedLiterals, forKey: .protectedLiterals)
        }
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
