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
    /// Optional supplementary transcription of the same audio from another ASR
    /// (e.g. iOS on-device Apple Speech, used for live preview before this
    /// request was sent). The prompt presents this as a neutral "alternate
    /// hypothesis" — never attributed by source name — and instructs the LLM
    /// to fall back on linguistic plausibility when raw_transcript and the
    /// alternate disagree. `nil` when no alternate was provided.
    var alternateTranscript: String?

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
        alternateTranscript: String? = nil
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
        self.alternateTranscript = alternateTranscript
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
            alternateTranscript: alternateTranscript
        )
    }
}
