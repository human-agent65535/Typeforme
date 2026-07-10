import Foundation
import FuzzyMatch
import os.lock

struct VocabularyCandidatePayload: Codable, Sendable, Equatable {
    let type: String
    let surface: String
    let speechHint: String
    let pronunciations: [String]
    let matchedSpan: String?
    let matchSource: String?
    let matchedStart: Int?
    let matchedEnd: Int?
    let matchKind: String
    let confidence: Double
    let evidenceSource: String

    enum CodingKeys: String, CodingKey {
        case type
        case surface
        case speechHint = "speech_hint"
        case pronunciations
        case matchedSpan = "matched_span"
        case matchSource = "match_source"
        case matchedStart = "matched_start"
        case matchedEnd = "matched_end"
        case matchKind = "match_kind"
        case confidence
        case evidenceSource = "evidence_source"
    }
}

enum VocabularyCandidateSelector {
    static let defaultLimit = 40

    private struct CacheKey: Hashable {
        let entriesHash: Int
        let rawText: String
        let alternateTranscripts: String
        let extraContext: String
        let limit: Int
    }

    private struct ContextSignals {
        var person = 0
        var project = 0
        var technical = 0
        var product = 0
        var organization = 0
        var place = 0
    }

    private enum EvidenceSourceKind: String {
        case rawTranscript
        case alternateTranscript
        case context

        var promptLabel: String {
            switch self {
            case .rawTranscript, .alternateTranscript:
                return "transcript"
            case .context:
                return "context"
            }
        }

        var matchSource: String {
            switch self {
            case .rawTranscript:
                return "raw_transcript"
            case .alternateTranscript:
                return "alternate_transcript"
            case .context:
                return "context"
            }
        }

        var sourceScore: Int {
            switch self {
            case .rawTranscript:
                return 25
            case .alternateTranscript:
                return 15
            case .context:
                return -20
            }
        }

        var isTranscript: Bool {
            self == .rawTranscript || self == .alternateTranscript
        }
    }

    private struct EvidenceText {
        let source: EvidenceSourceKind
        let text: String
        let normalized: String
        let compact: String
        let phonetic: String
        let loosePhonetic: String
        let latinTokens: [TokenSpan]
        let soundexTokens: [String: [TokenSpan]]
    }

    private struct TokenSpan {
        let token: String
        let span: String
        let startChar: Int
        let endChar: Int
    }

    private struct CandidateEvidence {
        let score: Int
        let matchedSpan: String?
        let matchSource: String?
        let matchedStart: Int?
        let matchedEnd: Int?
        let matchKind: String
        let confidence: Double
        let evidenceSource: String
    }

    private struct ScoredCandidate {
        let entry: DictionaryEntry
        let score: Int
        let evidence: CandidateEvidence
    }

    private struct ChineseWindow {
        let text: String
        let phonetic: String
        let loosePhonetic: String
        let startChar: Int
        let endChar: Int
    }

    private struct CJKRun {
        let text: String
        let startChar: Int
    }

    private struct SpokenVariant {
        let spoken: String
        let compact: String
    }

    private struct PinyinApproximation: Hashable {
        let syllables: [String]

        var key: String {
            syllables.joined()
        }

        var looseKey: String {
            loosenPinyin(key)
        }

        var spoken: String {
            syllables.joined(separator: " ")
        }
    }

    private struct MixedScriptPattern {
        let segments: [MixedScriptSegment]
        let hanAnchorCount: Int
        let slotCount: Int
        let minCJKLength: Int
        let maxCJKLength: Int
    }

    private enum MixedScriptSegment {
        case han(String)
        case slot(String, minChars: Int, maxChars: Int, pinyinOptions: [[String]])
    }

    private struct MixedScriptAlignment {
        let slotCharCount: Int
        let extraSlotChars: Int
    }

    static func select(
        from entries: [DictionaryEntry],
        rawText: String,
        alternateTranscripts: [String] = [],
        extraContext: [String] = [],
        limit: Int = defaultLimit
    ) -> [DictionaryEntry] {
        rankedCandidates(
            from: entries,
            rawText: rawText,
            alternateTranscripts: alternateTranscripts,
            extraContext: extraContext,
            limit: limit
        ).map(\.entry)
    }

    static func promptPayload(
        from entries: [DictionaryEntry],
        rawText: String,
        alternateTranscripts: [String] = [],
        extraContext: [String] = [],
        limit: Int = defaultLimit
    ) -> [VocabularyCandidatePayload] {
        rankedCandidates(
            from: entries,
            rawText: rawText,
            alternateTranscripts: alternateTranscripts,
            extraContext: extraContext,
            limit: limit
        ).map { candidate in
            VocabularyCandidatePayload(
                type: candidate.entry.type,
                surface: candidate.entry.surface,
                speechHint: phoneticKey(candidate.entry.surface),
                pronunciations: pronunciationHints(for: candidate.entry.surface),
                matchedSpan: candidate.evidence.matchedSpan,
                matchSource: candidate.evidence.matchSource,
                matchedStart: candidate.evidence.matchedStart,
                matchedEnd: candidate.evidence.matchedEnd,
                matchKind: candidate.evidence.matchKind,
                confidence: candidate.evidence.confidence,
                evidenceSource: candidate.evidence.evidenceSource
            )
        }
    }

    private static func rankedCandidates(
        from entries: [DictionaryEntry],
        rawText: String,
        alternateTranscripts: [String],
        extraContext: [String],
        limit: Int
    ) -> [ScoredCandidate] {
        let cleanedAlternates = CorrectionRequest.normalizedAlternateTranscripts(
            primaryTranscript: rawText,
            candidates: alternateTranscripts.map(Optional.some)
        )
        let extraContextText = extraContext.joined(separator: " ")
        let cacheKey = CacheKey(
            entriesHash: hash(entries),
            rawText: rawText,
            alternateTranscripts: cleanedAlternates.joined(separator: "\u{1f}"),
            extraContext: extraContextText,
            limit: limit
        )
        if let cached = selectionCache.withLock({ cache in cache[cacheKey] }) {
            return cached
        }

        let evidenceTexts = evidenceTexts(
            rawText: rawText,
            alternateTranscripts: cleanedAlternates,
            extraContext: extraContextText
        )
        let signals = contextSignals(
            for: evidenceTexts
                .map(\.normalized)
                .joined(separator: " ")
        )

        let selected = entries.compactMap { entry in
            score(entry, evidenceTexts: evidenceTexts, signals: signals)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.evidence.confidence != $1.evidence.confidence {
                return $0.evidence.confidence > $1.evidence.confidence
            }
            if $0.entry.type != $1.entry.type { return $0.entry.type < $1.entry.type }
            return $0.entry.surface < $1.entry.surface
        }
        .prefix(limit)
        .map { $0 }

        selectionCache.withLock { cache in
            cache[cacheKey] = selected
            if cache.count > maxCachedSelections {
                cache.removeAll(keepingCapacity: true)
            }
        }
        return selected
    }

    private static func score(
        _ entry: DictionaryEntry,
        evidenceTexts: [EvidenceText],
        signals: ContextSignals
    ) -> ScoredCandidate? {
        var best: CandidateEvidence?

        for term in entry.searchTerms {
            for evidenceText in evidenceTexts {
                guard let evidence = bestEvidence(for: term, in: evidenceText) else { continue }
                best = bestEvidence(best, evidence)
            }
        }

        guard let evidence = best else { return nil }

        // A fuzzy near-pinyin window alone is not enough to turn ordinary
        // Chinese prose into a person's name. Require independent person-use
        // context (for example, calling, meeting, or confirming with someone);
        // exact/same-pinyin matches keep their stronger acoustic evidence.
        if entry.type == "person",
           evidence.matchKind == "near_pinyin",
           signals.person <= 0 {
            return nil
        }

        var score = basePriority(for: entry.type) + evidence.score
        if entry.type == "person" {
            score += 20
        }
        score += contextBonus(for: entry.type, signals: signals)

        return ScoredCandidate(entry: entry, score: score, evidence: evidence)
    }

    private static func bestEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        var best: CandidateEvidence?

        func consider(_ evidence: CandidateEvidence?) {
            guard let evidence else { return }
            best = bestEvidence(best, evidence)
        }

        consider(exactSurfaceEvidence(for: term, in: evidenceText))
        consider(compactSurfaceEvidence(for: term, in: evidenceText))
        consider(partialTokenEvidence(for: term, in: evidenceText))

        if evidenceText.source.isTranscript {
            consider(chinesePhoneticEvidence(for: term, in: evidenceText))
            consider(mixedScriptSkeletonEvidence(for: term, in: evidenceText))
            consider(englishPhoneticEvidence(for: term, in: evidenceText))
            consider(crossScriptEnglishPhoneticEvidence(for: term, in: evidenceText))
        }

        return best
    }

    private static func exactSurfaceEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        let normalizedTerm = normalize(term)
        guard !normalizedTerm.isEmpty else { return nil }
        guard evidenceText.normalized.contains(normalizedTerm) else { return nil }
        let isContext = evidenceText.source == .context
        let matchRange = firstRangeMatch(of: term, in: evidenceText.text)
        let span = matchRange.map { String(evidenceText.text[$0]) } ?? term
        let offsets = matchRange.map { characterOffsets(for: $0, in: evidenceText.text) }
        return candidateEvidence(
            score: (isContext ? 55 : 120) + evidenceText.source.sourceScore,
            matchedSpan: span,
            matchKind: isContext ? "context_surface" : "exact_surface",
            confidence: isContext ? 0.78 : 0.98,
            evidenceText: evidenceText,
            matchedStart: offsets?.start,
            matchedEnd: offsets?.end
        )
    }

    private static func compactSurfaceEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        let compactTerm = compactNormalized(term)
        guard compactTerm.count >= 4, evidenceText.compact.contains(compactTerm) else { return nil }
        return candidateEvidence(
            score: 105 + evidenceText.source.sourceScore,
            matchedSpan: term,
            matchKind: evidenceText.source == .context ? "context_compact_surface" : "compact_surface",
            confidence: evidenceText.source == .context ? 0.74 : 0.9,
            evidenceText: evidenceText
        )
    }

    private static func partialTokenEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        let tokens = latinTokens(in: term)
            .filter { $0.count >= 3 }
        guard tokens.count > 1 else { return nil }
        guard let span = tokens.first(where: { evidenceText.normalized.contains($0) }),
              let tokenSpan = evidenceText.latinTokens.first(where: { $0.token == span })
        else { return nil }
        let isContext = evidenceText.source == .context
        return candidateEvidence(
            score: (isContext ? 35 : 60) + evidenceText.source.sourceScore,
            matchedSpan: tokenSpan.span,
            matchKind: isContext ? "context_partial_token" : "partial_token",
            confidence: isContext ? 0.58 : 0.68,
            evidenceText: evidenceText,
            matchedStart: tokenSpan.startChar,
            matchedEnd: tokenSpan.endChar
        )
    }

    private static func chinesePhoneticEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        guard UnicodeScriptClassifier.hanBMPCount(in: term) >= 2 else { return nil }
        let termPhonetic = phoneticKey(term)
        guard termPhonetic.count >= 4 else { return nil }

        let looseTerm = loosenPinyin(termPhonetic)
        if let windowEvidence = bestChineseWindowEvidence(
            termPhonetic: termPhonetic,
            looseTermPhonetic: looseTerm,
            termCJKCount: UnicodeScriptClassifier.hanBMPCount(in: term),
            evidenceText: evidenceText
        ) {
            return windowEvidence
        }

        if termPhonetic.count >= 3, evidenceText.phonetic.contains(termPhonetic) {
            return candidateEvidence(
                score: 90 + evidenceText.source.sourceScore,
                matchedSpan: nil,
                matchKind: "same_pinyin",
                confidence: 0.9,
                evidenceText: evidenceText
            )
        }

        if looseTerm.count >= 4, evidenceText.loosePhonetic.contains(looseTerm) {
            return candidateEvidence(
                score: 78 + evidenceText.source.sourceScore,
                matchedSpan: nil,
                matchKind: "loose_pinyin",
                confidence: 0.82,
                evidenceText: evidenceText
            )
        }
        return nil
    }

    private static func bestChineseWindowEvidence(
        termPhonetic: String,
        looseTermPhonetic: String,
        termCJKCount: Int,
        evidenceText: EvidenceText
    ) -> CandidateEvidence? {
        let minLength = max(2, termCJKCount - 1)
        let maxLength = termCJKCount + 1
        var best: CandidateEvidence?

        for window in cjkWindows(in: evidenceText.text, minLength: minLength, maxLength: maxLength) {
            if window.phonetic == termPhonetic {
                let candidate = candidateEvidence(
                    score: 95 + evidenceText.source.sourceScore,
                    matchedSpan: window.text,
                    matchKind: "same_pinyin",
                    confidence: 0.92,
                    evidenceText: evidenceText,
                    matchedStart: window.startChar,
                    matchedEnd: window.endChar
                )
                best = bestEvidence(best, candidate)
                continue
            }
            if window.loosePhonetic == looseTermPhonetic {
                let candidate = candidateEvidence(
                    score: 82 + evidenceText.source.sourceScore,
                    matchedSpan: window.text,
                    matchKind: "loose_pinyin",
                    confidence: 0.84,
                    evidenceText: evidenceText,
                    matchedStart: window.startChar,
                    matchedEnd: window.endChar
                )
                best = bestEvidence(best, candidate)
                continue
            }
            guard let match = phoneticMatcher.score(window.phonetic, against: termPhonetic),
                  match.score >= 0.74
            else { continue }
            let candidate = candidateEvidence(
                score: Int((70.0 + match.score * 15.0).rounded()) + evidenceText.source.sourceScore,
                matchedSpan: window.text,
                matchKind: "near_pinyin",
                confidence: roundedConfidence(min(0.82, match.score)),
                evidenceText: evidenceText,
                matchedStart: window.startChar,
                matchedEnd: window.endChar
            )
            best = bestEvidence(best, candidate)
        }

        return best
    }

    private static func englishPhoneticEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        guard UnicodeScriptClassifier.containsASCIILatinLetter(term) else { return nil }
        var best: CandidateEvidence?

        for variant in acronymSpokenVariants(for: term) where variant.compact.count >= 3 {
            guard evidenceText.compact.contains(variant.compact) else { continue }
            let candidate = candidateEvidence(
                score: 82 + evidenceText.source.sourceScore,
                matchedSpan: variant.spoken,
                matchKind: "acronym_spoken",
                confidence: 0.86,
                evidenceText: evidenceText
            )
            best = bestEvidence(best, candidate)
        }

        for token in latinTokens(in: term) where token.count >= 4 {
            if let code = soundex(token),
               let spans = evidenceText.soundexTokens[code],
               let span = spans.first {
                let candidate = candidateEvidence(
                    score: 65 + evidenceText.source.sourceScore,
                    matchedSpan: span.span,
                    matchKind: "english_soundex",
                    confidence: 0.68,
                    evidenceText: evidenceText,
                    matchedStart: span.startChar,
                    matchedEnd: span.endChar
                )
                best = bestEvidence(best, candidate)
            }

            for rawToken in evidenceText.latinTokens where rawToken.token.count >= 4 {
                guard rawToken.token != token,
                      let match = phoneticMatcher.score(rawToken.token, against: token),
                      match.score >= 0.78
                else { continue }
                let candidate = candidateEvidence(
                    score: Int((62.0 + match.score * 18.0).rounded()) + evidenceText.source.sourceScore,
                    matchedSpan: rawToken.span,
                    matchKind: "english_fuzzy",
                    confidence: roundedConfidence(min(0.84, match.score)),
                    evidenceText: evidenceText,
                    matchedStart: rawToken.startChar,
                    matchedEnd: rawToken.endChar
                )
                best = bestEvidence(best, candidate)
            }
        }

        return best
    }

    private static func crossScriptEnglishPhoneticEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        guard UnicodeScriptClassifier.containsASCIILatinLetter(term),
              UnicodeScriptClassifier.containsHanBMP(evidenceText.text)
        else { return nil }

        let approximations = englishPinyinApproximations(for: term)
        guard !approximations.isEmpty else { return nil }

        let maxSyllables = min(6, max(2, approximations.map(\.syllables.count).max() ?? 2) + 1)
        var best: CandidateEvidence?
        for window in cjkWindows(in: evidenceText.text, minLength: 2, maxLength: maxSyllables) {
            for approximation in approximations {
                if window.phonetic == approximation.key || window.loosePhonetic == approximation.looseKey {
                    let candidate = candidateEvidence(
                        score: 88 + evidenceText.source.sourceScore,
                        matchedSpan: window.text,
                        matchKind: "cross_script_phonetic",
                        confidence: 0.88,
                        evidenceText: evidenceText,
                        matchedStart: window.startChar,
                        matchedEnd: window.endChar
                    )
                    best = bestEvidence(best, candidate)
                    continue
                }

                guard approximation.key.count >= 5,
                      window.phonetic.count >= 5,
                      let match = phoneticMatcher.score(window.phonetic, against: approximation.key),
                      match.score >= 0.82
                else { continue }
                let candidate = candidateEvidence(
                    score: Int((68.0 + match.score * 14.0).rounded()) + evidenceText.source.sourceScore,
                    matchedSpan: window.text,
                    matchKind: "cross_script_near_phonetic",
                    confidence: roundedConfidence(min(0.82, match.score)),
                    evidenceText: evidenceText,
                    matchedStart: window.startChar,
                    matchedEnd: window.endChar
                )
                best = bestEvidence(best, candidate)
            }
        }
        return best
    }

    private static func mixedScriptSkeletonEvidence(for term: String, in evidenceText: EvidenceText) -> CandidateEvidence? {
        guard UnicodeScriptClassifier.containsHanBMP(evidenceText.text),
              let pattern = mixedScriptPattern(for: term)
        else { return nil }

        let approximations = mixedScriptPinyinApproximations(for: pattern)
        guard !approximations.isEmpty else { return nil }

        var best: CandidateEvidence?
        for window in cjkWindows(
            in: evidenceText.text,
            minLength: pattern.minCJKLength,
            maxLength: pattern.maxCJKLength
        ) {
            guard let alignment = mixedScriptAlignment(for: pattern, windowText: window.text) else {
                continue
            }

            for approximation in approximations {
                let penalty = min(10, alignment.extraSlotChars * 3 + max(0, pattern.slotCount - 1) * 2)
                if window.phonetic == approximation.key || window.loosePhonetic == approximation.looseKey {
                    let candidate = candidateEvidence(
                        score: 92 + evidenceText.source.sourceScore - penalty,
                        matchedSpan: window.text,
                        matchKind: "mixed_script_skeleton",
                        confidence: roundedConfidence(max(0.82, 0.9 - Double(penalty) / 100.0)),
                        evidenceText: evidenceText,
                        matchedStart: window.startChar,
                        matchedEnd: window.endChar
                    )
                    best = bestEvidence(best, candidate)
                    continue
                }

                guard approximation.key.count >= 5,
                      window.phonetic.count >= 5,
                      let match = phoneticMatcher.score(window.phonetic, against: approximation.key),
                      match.score >= 0.8
                else { continue }
                let candidate = candidateEvidence(
                    score: Int((66.0 + match.score * 18.0).rounded()) + evidenceText.source.sourceScore - penalty,
                    matchedSpan: window.text,
                    matchKind: "mixed_script_near_skeleton",
                    confidence: roundedConfidence(min(0.84, match.score)),
                    evidenceText: evidenceText,
                    matchedStart: window.startChar,
                    matchedEnd: window.endChar
                )
                best = bestEvidence(best, candidate)
            }
        }
        return best
    }

    private static func candidateEvidence(
        score: Int,
        matchedSpan: String?,
        matchKind: String,
        confidence: Double,
        evidenceText: EvidenceText,
        matchedStart: Int? = nil,
        matchedEnd: Int? = nil
    ) -> CandidateEvidence {
        CandidateEvidence(
            score: score,
            matchedSpan: matchedSpan,
            matchSource: matchedSpan == nil ? nil : evidenceText.source.matchSource,
            matchedStart: matchedStart,
            matchedEnd: matchedEnd,
            matchKind: matchKind,
            confidence: confidence,
            evidenceSource: evidenceText.source.promptLabel
        )
    }

    private static func bestEvidence(_ left: CandidateEvidence?, _ right: CandidateEvidence) -> CandidateEvidence {
        guard let left else { return right }
        if right.score != left.score {
            return right.score > left.score ? right : left
        }
        if right.confidence != left.confidence {
            return right.confidence > left.confidence ? right : left
        }
        let leftLength = left.matchedSpan?.count ?? 0
        let rightLength = right.matchedSpan?.count ?? 0
        if rightLength != leftLength {
            return rightLength > leftLength ? right : left
        }
        return left
    }

    private static func evidenceTexts(
        rawText: String,
        alternateTranscripts: [String],
        extraContext: String
    ) -> [EvidenceText] {
        var output: [EvidenceText] = []
        if let text = makeEvidenceText(rawText, source: .rawTranscript) {
            output.append(text)
        }
        for transcript in alternateTranscripts {
            if let text = makeEvidenceText(transcript, source: .alternateTranscript) {
                output.append(text)
            }
        }
        if let text = makeEvidenceText(extraContext, source: .context) {
            output.append(text)
        }
        return output
    }

    private static func makeEvidenceText(_ text: String, source: EvidenceSourceKind) -> EvidenceText? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokenSpans = latinTokenSpans(in: trimmed)
        var soundexTokens: [String: [TokenSpan]] = [:]
        for token in tokenSpans {
            guard let code = soundex(token.token) else { continue }
            soundexTokens[code, default: []].append(token)
        }
        return EvidenceText(
            source: source,
            text: trimmed,
            normalized: normalize(trimmed),
            compact: compactNormalized(trimmed),
            phonetic: phoneticKey(trimmed),
            loosePhonetic: loosePinyinKey(trimmed),
            latinTokens: tokenSpans,
            soundexTokens: soundexTokens
        )
    }

    private static func hash(_ entries: [DictionaryEntry]) -> Int {
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry)
        }
        return hasher.finalize()
    }

    private static func basePriority(for type: String) -> Int {
        switch type {
        case "person": return 75
        case "organization", "product", "project", "technical_term", "acronym": return 65
        case "place": return 60
        default: return 50
        }
    }

    private static func contextBonus(for type: String, signals: ContextSignals) -> Int {
        switch type {
        case "person":
            return signals.person
        case "project":
            return signals.project
        case "technical_term", "acronym":
            return max(signals.technical, signals.project / 2)
        case "product":
            return max(signals.product, signals.technical / 2)
        case "organization":
            return signals.organization
        case "place":
            return signals.place
        default:
            return 0
        }
    }

    private static func contextSignals(for text: String) -> ContextSignals {
        var signals = ContextSignals()
        if containsAny(text, [
            "ask", "tell", "call", "message", "ping", "reply", "meet", "with",
            "teammate", "manager", "coworker", "colleague",
            "找", "问", "跟", "和", "叫", "发给", "回复", "同事", "老板", "经理", "确认",
        ]) {
            signals.person += 55
        }
        if containsAny(text, [
            "project", "repo", "repository", "issue", "ticket", "pr", "pull request",
            "milestone", "roadmap", "release", "sprint", "linear", "github",
            "项目", "仓库", "需求", "工单", "版本", "迭代", "发布", "里程碑",
        ]) {
            signals.project += 60
        }
        if containsAny(text, [
            "api", "sdk", "server", "client", "latency", "runtime", "deploy", "build",
            "commit", "push", "branch", "debug", "log", "cache", "token", "model",
            "prompt", "asr", "llm", "endpoint", "database", "schema", "json",
            "接口", "服务", "延迟", "部署", "构建", "提交", "分支", "调试", "日志", "模型", "缓存",
        ]) {
            signals.technical += 60
        }
        if containsAny(text, [
            "product", "app", "platform", "feature", "plan", "pricing", "subscription",
            "产品", "应用", "平台", "功能", "定价", "套餐",
        ]) {
            signals.product += 45
        }
        if containsAny(text, [
            "company", "team", "org", "organization", "vendor", "customer", "client",
            "公司", "团队", "组织", "供应商", "客户",
        ]) {
            signals.organization += 45
        }
        if containsAny(text, [
            "at", "in", "from", "to", "office", "room", "meeting room", "address", "city",
            "在", "去", "从", "到", "会议室", "办公室", "地址", "城市",
        ]) {
            signals.place += 45
        }
        return signals
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactNormalized(_ text: String) -> String {
        normalize(text)
            .filter { $0.isLetter || $0.isNumber }
            .map(String.init)
            .joined()
    }

    private static func phoneticKey(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: UnicodeScriptClassifier.isHanBMP) else {
            return compactNormalized(text)
        }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return compactNormalized(mutable as String)
    }

    private static func spacedPinyinKey(_ text: String) -> String {
        guard UnicodeScriptClassifier.containsHanBMP(text) else { return normalize(text) }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return normalize(mutable as String)
    }

    private static func loosePinyinKey(_ text: String) -> String {
        guard UnicodeScriptClassifier.containsHanBMP(text) else { return compactNormalized(text) }
        return loosenPinyin(phoneticKey(text))
    }

    private static func loosenPinyin(_ key: String) -> String {
        var output = key
        for (from, to) in [
            ("zh", "z"),
            ("ch", "c"),
            ("sh", "s"),
            ("iang", "ian"),
            ("uang", "uan"),
            ("ang", "an"),
            ("eng", "en"),
            ("ing", "in"),
            ("ong", "on"),
        ] {
            output = output.replacingOccurrences(of: from, with: to)
        }
        return output
    }

    private static func cjkWindows(in text: String, minLength: Int, maxLength: Int) -> [ChineseWindow] {
        guard minLength <= maxLength else { return [] }
        var windows: [ChineseWindow] = []
        for run in cjkRuns(in: text) {
            let chars = Array(run.text)
            guard chars.count >= minLength else { continue }
            for length in minLength...min(maxLength, chars.count) {
                guard chars.count >= length else { continue }
                for start in 0...(chars.count - length) {
                    let text = String(chars[start..<(start + length)])
                    let phonetic = phoneticKey(text)
                    windows.append(ChineseWindow(
                        text: text,
                        phonetic: phonetic,
                        loosePhonetic: loosenPinyin(phonetic),
                        startChar: run.startChar + start,
                        endChar: run.startChar + start + length
                    ))
                }
            }
        }
        return windows
    }

    private static func cjkRuns(in text: String) -> [CJKRun] {
        var runs: [CJKRun] = []
        var current = ""
        var currentStart: Int?
        for (offset, character) in text.enumerated() {
            if character.unicodeScalars.contains(where: UnicodeScriptClassifier.isHanBMP) {
                if current.isEmpty {
                    currentStart = offset
                }
                current.append(character)
            } else if !current.isEmpty {
                runs.append(CJKRun(text: current, startChar: currentStart ?? offset - current.count))
                current = ""
                currentStart = nil
            }
        }
        if !current.isEmpty {
            runs.append(CJKRun(text: current, startChar: currentStart ?? 0))
        }
        return runs
    }

    private static func mixedScriptPattern(for term: String) -> MixedScriptPattern? {
        guard UnicodeScriptClassifier.containsHanBMP(term),
              term.contains(where: isASCIILetterOrNumber)
        else { return nil }

        var segments: [MixedScriptSegment] = []
        var hanBuffer = ""
        var slotBuffer = ""

        func flushHan() {
            guard !hanBuffer.isEmpty else { return }
            segments.append(.han(hanBuffer))
            hanBuffer = ""
        }

        func flushSlot() {
            guard !slotBuffer.isEmpty else { return }
            let pinyinOptions = acronymPinyinSyllables(for: slotBuffer)
            let maxChars = min(
                4,
                max(1, pinyinOptions.map(\.count).max() ?? slotBuffer.count)
            )
            segments.append(.slot(
                slotBuffer,
                minChars: 1,
                maxChars: maxChars,
                pinyinOptions: pinyinOptions
            ))
            slotBuffer = ""
        }

        for character in term {
            if character.unicodeScalars.contains(where: UnicodeScriptClassifier.isHanBMP) {
                flushSlot()
                hanBuffer.append(character)
            } else if isASCIILetterOrNumber(character) {
                flushHan()
                slotBuffer.append(character)
            } else {
                flushHan()
                flushSlot()
            }
        }
        flushHan()
        flushSlot()

        var hanAnchorCount = 0
        var slotCount = 0
        var maxSlotChars = 0
        for segment in segments {
            switch segment {
            case .han(let text):
                hanAnchorCount += UnicodeScriptClassifier.hanBMPCount(in: text)
            case .slot(_, _, let maxChars, _):
                slotCount += 1
                maxSlotChars += maxChars
            }
        }

        guard slotCount > 0, hanAnchorCount >= 2 else { return nil }
        return MixedScriptPattern(
            segments: segments,
            hanAnchorCount: hanAnchorCount,
            slotCount: slotCount,
            minCJKLength: hanAnchorCount + slotCount,
            maxCJKLength: hanAnchorCount + maxSlotChars
        )
    }

    private static func mixedScriptPinyinApproximations(for pattern: MixedScriptPattern) -> [PinyinApproximation] {
        var variants: [[String]] = [[]]
        for segment in pattern.segments {
            let options: [[String]]
            switch segment {
            case .han(let text):
                let syllables = spacedPinyinKey(text)
                    .split(separator: " ")
                    .map(String.init)
                options = [syllables]
            case .slot(_, _, _, let pinyinOptions):
                options = pinyinOptions
            }
            guard !options.isEmpty else { continue }
            variants = variants.flatMap { prefix in
                options.map { prefix + $0 }
            }
            if variants.count > 32 {
                variants = Array(variants.prefix(32))
            }
        }

        return cleanedPinyinLists(variants)
            .map { syllables in
                syllables
                    .map { compactNormalized($0) }
                    .filter { !$0.isEmpty }
            }
            .filter { $0.count >= 2 && $0.count <= 10 && $0.joined().count >= 4 }
            .map { PinyinApproximation(syllables: $0) }
            .reduce(into: []) { output, approximation in
                guard !output.contains(approximation) else { return }
                output.append(approximation)
            }
    }

    private static func mixedScriptAlignment(
        for pattern: MixedScriptPattern,
        windowText: String
    ) -> MixedScriptAlignment? {
        let chars = Array(windowText)

        func match(
            segmentIndex: Int,
            charIndex: Int,
            slotCharCount: Int,
            extraSlotChars: Int
        ) -> MixedScriptAlignment? {
            guard segmentIndex < pattern.segments.count else {
                guard charIndex == chars.count else { return nil }
                return MixedScriptAlignment(
                    slotCharCount: slotCharCount,
                    extraSlotChars: extraSlotChars
                )
            }

            switch pattern.segments[segmentIndex] {
            case .han(let text):
                let anchor = Array(text)
                guard charIndex + anchor.count <= chars.count else { return nil }
                let candidateAnchorChars = Array(chars[charIndex..<(charIndex + anchor.count)])
                let candidateAnchor = String(candidateAnchorChars)
                guard candidateAnchorChars == anchor || phoneticKey(candidateAnchor) == phoneticKey(text) else { return nil }
                return match(
                    segmentIndex: segmentIndex + 1,
                    charIndex: charIndex + anchor.count,
                    slotCharCount: slotCharCount,
                    extraSlotChars: extraSlotChars
                )
            case .slot(_, let minChars, let maxChars, _):
                guard charIndex < chars.count else { return nil }
                let remaining = chars.count - charIndex
                guard remaining >= minChars else { return nil }
                for length in minChars...min(maxChars, remaining) {
                    if let result = match(
                        segmentIndex: segmentIndex + 1,
                        charIndex: charIndex + length,
                        slotCharCount: slotCharCount + length,
                        extraSlotChars: extraSlotChars + max(0, length - minChars)
                    ) {
                        return result
                    }
                }
                return nil
            }
        }

        return match(segmentIndex: 0, charIndex: 0, slotCharCount: 0, extraSlotChars: 0)
    }

    private static func pronunciationHints(for surface: String) -> [String] {
        var hints: [String] = []
        if UnicodeScriptClassifier.containsHanBMP(surface) {
            hints.append(spacedPinyinKey(surface))
        }
        if let pattern = mixedScriptPattern(for: surface) {
            hints.append(contentsOf: mixedScriptPinyinApproximations(for: pattern).prefix(6).map(\.spoken))
        }
        if UnicodeScriptClassifier.containsASCIILatinLetter(surface) {
            hints.append(normalize(splitCamelCase(surface)))
            hints.append(compactNormalized(surface))
            hints.append(contentsOf: acronymSpokenVariants(for: surface).map(\.spoken))
            hints.append(contentsOf: englishPinyinApproximations(for: surface).map(\.spoken))
        }
        return DictionaryEntry.cleanedList(hints)
    }

    private static func englishPinyinApproximations(for term: String) -> [PinyinApproximation] {
        var approximations = Set<PinyinApproximation>()
        let components = englishComponents(in: term)

        for component in components {
            for syllables in englishPinyinSyllables(for: component) {
                insertPinyinApproximation(syllables, into: &approximations)
            }
        }

        let phraseComponents = englishPhraseComponents(in: term)
        if phraseComponents.count > 1 {
            let perComponent = phraseComponents.map { component in
                englishPinyinSyllables(for: component).prefix(3)
            }
            var combined: [[String]] = [[]]
            for componentOptions in perComponent {
                guard !componentOptions.isEmpty else { continue }
                combined = combined.flatMap { prefix in
                    componentOptions.map { prefix + $0 }
                }
                if combined.count > 12 {
                    combined = Array(combined.prefix(12))
                }
            }
            for syllables in combined {
                insertPinyinApproximation(syllables, into: &approximations)
            }
        }

        return approximations
            .sorted {
                if $0.syllables.count != $1.syllables.count {
                    return $0.syllables.count > $1.syllables.count
                }
                return $0.key < $1.key
            }
    }

    private static func insertPinyinApproximation(
        _ syllables: [String],
        into approximations: inout Set<PinyinApproximation>
    ) {
        let cleaned = syllables
            .map { compactNormalized($0) }
            .filter { !$0.isEmpty }
        guard cleaned.count >= 2, cleaned.count <= 6 else { return }
        let approximation = PinyinApproximation(syllables: cleaned)
        guard approximation.key.count >= 4 else { return }
        approximations.insert(approximation)
    }

    private static func englishComponents(in term: String) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        func append(_ component: String) {
            let normalized = compactNormalized(component)
            guard normalized.count >= 2, seen.insert(normalized).inserted else { return }
            output.append(component)
        }

        for run in uppercaseRuns(in: term) {
            append(run.text)
        }
        for token in latinTokens(in: term) {
            append(token)
        }
        for component in englishPhraseComponents(in: term) {
            append(component)
        }
        let compact = compactNormalized(term)
        append(compact)
        return output
    }

    private static func englishPhraseComponents(in term: String) -> [String] {
        latinTokens(in: splitCamelCase(term))
    }

    private static func englishPinyinSyllables(for component: String) -> [[String]] {
        let key = compactNormalized(component)
        guard key.count >= 2 else { return [] }

        var output = englishPinyinOverrides[key] ?? []
        output.append(contentsOf: EnglishPronunciationLexicon.pinyinSyllableLists(for: key))
        if isLikelyAcronymComponent(component) {
            output.append(contentsOf: acronymPinyinSyllables(for: key))
        }

        if key.hasSuffix("ex"), key.count > 2 {
            let prefix = String(key.dropLast(2))
            for prefixSyllables in englishPinyinOverrides[prefix] ?? [] {
                output.append(prefixSyllables + ["ke"])
                output.append(prefixSyllables + ["ke", "si"])
            }
        }

        if key.hasSuffix("x"), key.count > 1 {
            let prefix = String(key.dropLast())
            for prefixSyllables in englishPinyinOverrides[prefix] ?? [] {
                output.append(prefixSyllables + ["ke"])
                output.append(prefixSyllables + ["ke", "si"])
            }
        }

        return cleanedPinyinLists(output)
    }

    private static func cleanedPinyinLists(_ values: [[String]]) -> [[String]] {
        var seen = Set<String>()
        var output: [[String]] = []
        for value in values {
            let cleaned = value
                .map { compactNormalized($0) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.joined(separator: " ")
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return output
    }

    private static func isLikelyAcronymComponent(_ component: String) -> Bool {
        let letters = component.filter { $0.isLetter }
        guard letters.count >= 2, letters.count <= 5 else { return false }
        return letters.allSatisfy(isASCIIUppercase) || letters.count <= 2
    }

    private static func acronymPinyinSyllables(for component: String) -> [[String]] {
        var variants: [[String]] = [[]]
        for character in component.lowercased() {
            let options = letterPinyinSequences(for: character)
            variants = variants.flatMap { prefix in
                options.map { prefix + $0 }
            }
            if variants.count > 16 {
                variants = Array(variants.prefix(16))
            }
        }
        return variants
    }

    private static func letterPinyinSequences(for character: Character) -> [[String]] {
        ZhCNAlnumReadingProvider.pinyinSyllableOptions(for: character)
    }

    private static func splitCamelCase(_ text: String) -> String {
        var output = ""
        var previous: Character?
        for character in text {
            if let previous,
               isASCIILetterOrNumber(previous),
               isASCIIUppercase(character),
               !isASCIIUppercase(previous) {
                output.append(" ")
            }
            output.append(character)
            previous = character
        }
        return output
    }

    private static func acronymSpokenVariants(for term: String) -> [SpokenVariant] {
        let runs = uppercaseRuns(in: term)
        guard !runs.isEmpty else { return [] }
        var variants = Set<String>()
        for run in runs {
            let before = String(term[..<run.range.lowerBound])
            let after = String(term[run.range.upperBound...])
            for spoken in spokenLetterCombinations(for: run.text) {
                let combined = [before, spoken, after]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                variants.insert(combined)
            }
        }
        return variants
            .sorted()
            .map { SpokenVariant(spoken: $0, compact: compactNormalized($0)) }
    }

    private static func uppercaseRuns(in term: String) -> [(range: Range<String.Index>, text: String)] {
        var runs: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var current = term.startIndex
        while current < term.endIndex {
            let character = term[current]
            let isUpper = isASCIIUppercase(character)
            if isUpper {
                if start == nil { start = current }
            } else if let runStart = start {
                let runText = String(term[runStart..<current])
                if runText.count >= 2 { runs.append((runStart..<current, runText)) }
                start = nil
            }
            current = term.index(after: current)
        }
        if let runStart = start {
            let runText = String(term[runStart..<term.endIndex])
            if runText.count >= 2 { runs.append((runStart..<term.endIndex, runText)) }
        }
        return runs
    }

    private static func spokenLetterCombinations(for acronym: String) -> [String] {
        var variants = [""]
        for character in acronym.lowercased() {
            let options = letterNameOptions(for: character)
            variants = variants.flatMap { prefix in
                options.map { option in
                    [prefix, option]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
            }
            if variants.count > 24 {
                variants = Array(variants.prefix(24))
            }
        }
        return variants
    }

    private static func letterNameOptions(for character: Character) -> [String] {
        switch character {
        case "a": return ["a", "ay"]
        case "b": return ["bee"]
        case "c": return ["see"]
        case "d": return ["dee"]
        case "e": return ["ee"]
        case "f": return ["eff"]
        case "g": return ["gee"]
        case "h": return ["aitch", "h"]
        case "i": return ["eye"]
        case "j": return ["jay"]
        case "k": return ["kay"]
        case "l": return ["ell"]
        case "m": return ["em"]
        case "n": return ["en"]
        case "o": return ["o", "oh"]
        case "p": return ["pee"]
        case "q": return ["cue", "queue"]
        case "r": return ["are"]
        case "s": return ["ess"]
        case "t": return ["tee"]
        case "u": return ["u", "you"]
        case "v": return ["vee"]
        case "w": return ["double u", "double you"]
        case "x": return ["ex"]
        case "y": return ["why"]
        case "z": return ["zee", "zed"]
        case "0": return ["zero", "oh"]
        case "1": return ["one"]
        case "2": return ["two"]
        case "3": return ["three"]
        case "4": return ["four"]
        case "5": return ["five"]
        case "6": return ["six"]
        case "7": return ["seven"]
        case "8": return ["eight"]
        case "9": return ["nine"]
        default: return [String(character)]
        }
    }

    private static func soundex(_ token: String) -> String? {
        let letters = token.lowercased().filter(\.isLetter)
        guard let first = letters.first, letters.count >= 4 else { return nil }
        let firstLetter = String(first).uppercased()
        var previous = soundexDigit(first)
        var digits: [Character] = []
        for character in letters.dropFirst() {
            let digit = soundexDigit(character)
            if digit != "0", digit != previous {
                digits.append(digit)
            }
            previous = digit
        }
        let padded = String(digits).padding(toLength: 3, withPad: "0", startingAt: 0)
        return firstLetter + String(padded.prefix(3))
    }

    private static func soundexDigit(_ character: Character) -> Character {
        switch character {
        case "b", "f", "p", "v": return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t": return "3"
        case "l": return "4"
        case "m", "n": return "5"
        case "r": return "6"
        default: return "0"
        }
    }

    private static func latinTokenSpans(in text: String) -> [TokenSpan] {
        var tokens: [TokenSpan] = []
        var current = ""
        var currentStart: Int?
        for (offset, character) in text.enumerated() {
            if isASCIILetterOrNumber(character) {
                if current.isEmpty {
                    currentStart = offset
                }
                current.append(character)
            } else if !current.isEmpty {
                appendLatinToken(
                    current,
                    startChar: currentStart ?? offset - current.count,
                    endChar: offset,
                    to: &tokens
                )
                current = ""
                currentStart = nil
            }
        }
        if !current.isEmpty {
            appendLatinToken(
                current,
                startChar: currentStart ?? text.count - current.count,
                endChar: text.count,
                to: &tokens
            )
        }
        return tokens
    }

    private static func appendLatinToken(
        _ token: String,
        startChar: Int,
        endChar: Int,
        to tokens: inout [TokenSpan]
    ) {
        let normalized = normalize(token)
        guard normalized.contains(where: \.isLetter) else { return }
        tokens.append(TokenSpan(token: normalized, span: token, startChar: startChar, endChar: endChar))
    }

    private static func latinTokens(in text: String) -> [String] {
        latinTokenSpans(in: text).map(\.token)
    }

    private static func firstRangeMatch(of needle: String, in haystack: String) -> Range<String.Index>? {
        haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        )
    }

    private static func characterOffsets(
        for range: Range<String.Index>,
        in text: String
    ) -> (start: Int, end: Int) {
        (
            start: text.distance(from: text.startIndex, to: range.lowerBound),
            end: text.distance(from: text.startIndex, to: range.upperBound)
        )
    }

    private static func isASCIIUppercase(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (65...90).contains(Int(value))
    }

    private static func isASCIILetterOrNumber(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(Int(value)) ||
            (65...90).contains(Int(value)) ||
            (97...122).contains(Int(value))
    }

    private static func roundedConfidence(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static let phoneticMatcher = FuzzyMatcher(
        config: MatchConfig(
            minScore: 0.72,
            algorithm: .editDistance(
                EditDistanceConfig(
                    maxEditDistance: 2,
                    longQueryMaxEditDistance: 3,
                    prefixWeight: 1.0,
                    substringWeight: 1.0,
                    wordBoundaryBonus: 0.0,
                    consecutiveBonus: 0.0,
                    gapPenalty: .none,
                    firstMatchBonus: 0.0,
                    lengthPenalty: 0.0,
                    acronymWeight: 0.0,
                    isSubsequenceMatchingEnabled: false
                )
            )
        )
    )

    private static let englishPinyinOverrides: [String: [[String]]] = [
        "apollo": [["a", "bo", "luo"], ["a", "po", "luo"]],
        "claude": [["ke", "lao", "de"], ["ke", "lao"]],
        "code": [["kou", "dai"], ["kou", "de"]],
        "codex": [["kou", "dai", "ke"], ["kou", "de", "ke"], ["kou", "de", "ke", "si"]],
        "cursor": [["ke", "se"], ["ke", "suo"]],
        "docker": [["dao", "ke"], ["duo", "ke"]],
        "figma": [["fei", "ge", "ma"], ["fei", "ma"]],
        "github": [["ji", "te", "ha", "bu"], ["ji", "ha", "bu"]],
        "grafana": [["ge", "la", "fa", "na"], ["ge", "la", "fu", "na"]],
        "linear": [["li", "ni", "er"], ["lin", "er"]],
        "notion": [["nou", "shen"], ["luo", "shen"]],
        "open": [["ou", "pen"], ["ao", "pen"]],
        "openai": [["ou", "pen", "ei", "ai"], ["ao", "pen", "ei", "ai"], ["ou", "pen"]],
        "slack": [["si", "lai", "ke"], ["shi", "lai", "ke"]],
        "swift": [["si", "wei", "fu", "te"], ["si", "wei", "te"]],
        "xcode": [["ai", "ke", "si", "kou", "de"], ["cha", "kou", "de"], ["kou", "de"]],
    ]

    private static let selectionCache = OSAllocatedUnfairLock(initialState: [CacheKey: [ScoredCandidate]]())
    private static let maxCachedSelections = 64
}
