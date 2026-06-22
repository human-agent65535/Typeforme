import Foundation

struct CorrectionRequest: Codable, Sendable {
    var correctionMode: CorrectionMode
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var appCategory: AppCategory
    var languageIDs: [String]
    var rawTranscript: String
    var contextBefore: String
    var contextAfter: String
    var numberOutputPreference: NumberOutputPreference
    var punctuationPreference: PunctuationOutputPreference
    var userDictionary: [DictionaryEntry]
    /// Peer transcript hypotheses for the same audio. These are source-neutral
    /// and intentionally do not expose model/vendor names to the corrector.
    var asrHypotheses: [String]
    /// Optional supplementary transcriptions of the same audio. The prompt
    /// presents these as neutral hypotheses, never attributed by source name.
    var alternateTranscripts: [String]

    init(
        correctionMode: CorrectionMode,
        frontmostAppName: String?,
        frontmostBundleID: String?,
        appCategory: AppCategory,
        languageIDs: [String],
        rawTranscript: String,
        contextBefore: String = "",
        contextAfter: String = "",
        numberOutputPreference: NumberOutputPreference = .automatic,
        punctuationPreference: PunctuationOutputPreference = .normal,
        userDictionary: [DictionaryEntry],
        alternateTranscript: String? = nil,
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = []
    ) {
        self.correctionMode = correctionMode
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
        self.appCategory = appCategory
        self.languageIDs = languageIDs
        self.rawTranscript = rawTranscript
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.userDictionary = userDictionary
        let normalizedAlternates = Self.normalizedAlternateTranscripts(
            primaryTranscript: rawTranscript,
            candidates: alternateTranscripts.map(Optional.some) + [alternateTranscript]
        )
        self.alternateTranscripts = normalizedAlternates
        let explicitHypotheses = asrHypotheses.map(Optional.some)
        self.asrHypotheses = Self.normalizedASRHypotheses(
            candidates: explicitHypotheses + [rawTranscript] + normalizedAlternates.map(Optional.some)
        )
    }

    func replacingCorrectionMode(_ correctionMode: CorrectionMode) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: frontmostAppName,
            frontmostBundleID: frontmostBundleID,
            appCategory: appCategory,
            languageIDs: languageIDs,
            rawTranscript: rawTranscript,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            userDictionary: userDictionary,
            alternateTranscripts: alternateTranscripts,
            asrHypotheses: asrHypotheses
        )
    }

    var transcriptEvidenceText: String {
        Self.normalizedASRHypotheses(candidates: asrHypotheses.map(Optional.some) + [rawTranscript])
            .joined(separator: "\n")
    }

    static func normalizedAlternateTranscripts(
        primaryTranscript: String,
        candidates: [String?]
    ) -> [String] {
        let primary = primaryTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var alternates: [String] = []
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, value != primary else { continue }
            guard seen.insert(value).inserted else { continue }
            alternates.append(value)
        }
        return alternates
    }

    static func normalizedASRHypotheses(candidates: [String?]) -> [String] {
        var seen = Set<String>()
        var hypotheses: [String] = []
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { continue }
            guard seen.insert(value).inserted else { continue }
            hypotheses.append(value)
        }
        return hypotheses
    }
}
