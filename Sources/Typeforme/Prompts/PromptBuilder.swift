import Foundation

/// Conservative capacity check for the embedded Qwen chat template. The
/// estimator deliberately prices ASCII above typical BPE density and
/// non-ASCII text above one token per scalar, then leaves a fixed reserve for
/// the chat template, no-think controls, and tokenizer variance.
struct CorrectionPromptBudget: Sendable, Equatable {
    static let safetyReserveTokens = 96
    static let chatCapacityFailurePrefix = "Correction chat exceeds embedded context capacity"
    private static let chatFramingTokens = 64
    private static let messageFramingTokens = 8

    let contextSize: Int
    let maxOutputTokens: Int

    func canFit(system: String, user: String) -> Bool {
        canFit(system: system, messages: [.user(user)])
    }

    func canFit(system: String, messages: [CorrectorChatMessage]) -> Bool {
        estimatedInputTokens(system: system, messages: messages)
            + max(0, maxOutputTokens)
            + Self.safetyReserveTokens
            <= max(0, contextSize)
    }

    func estimatedInputTokens(system: String, user: String) -> Int {
        estimatedInputTokens(system: system, messages: [.user(user)])
    }

    func estimatedInputTokens(system: String, messages: [CorrectorChatMessage]) -> Int {
        Self.chatFramingTokens
            + Self.estimatedTextTokens(system)
            + messages.count * Self.messageFramingTokens
            + messages.reduce(into: 0) { count, message in
                count += Self.estimatedTextTokens(message.content)
            }
    }

    private static func estimatedTextTokens(_ text: String) -> Int {
        var asciiBytes = 0
        var nonASCIIBytes = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                asciiBytes += 1
            } else {
                nonASCIIBytes += String(scalar).utf8.count
            }
        }
        let baseEstimate = ((asciiBytes + 3) / 4) + ((nonASCIIBytes + 1) / 2)
        return (baseEstimate * 9 + 7) / 8
    }
}

/// Builds prompts with stable system content separated from volatile transcript
/// data so the reusable portions remain cacheable.
enum PromptBuilder {
    static func build(for request: CorrectionRequest) -> (system: String, user: String) {
        (systemPrompt(for: request), userPrompt(for: request))
    }

    /// The bounded form is used only by the embedded runtime. External APIs
    /// intentionally keep the complete request payload.
    static func build(
        for request: CorrectionRequest,
        budget: CorrectionPromptBudget
    ) throws -> (system: String, user: String) {
        let system = systemPrompt(for: request)
        let user = try budgetedUserPrompt(for: request, system: system, budget: budget)
        return (system, user)
    }

    static func systemPrompt(for request: CorrectionRequest) -> String {
        let systemPrompt = PromptOverrideStore.readSystemPrompt() ?? BuiltInPrompts.baseSystem
        let modePrompt = PromptOverrideStore.readModePrompt(for: request.correctionMode)
            ?? BuiltInPrompts.modePrompt(request.correctionMode)
        var parts = [
            systemPrompt,
            modePrompt,
            OutputPreferencePrompt.systemPrompt(
                numbers: request.numberOutputPreference,
                punctuation: request.punctuationPreference
            ),
        ]

        let additional = AppSettings.promptAdditionalSystem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !additional.isEmpty {
            parts.append("""
            <user_preferences>
            Follow these preferences when they do not conflict with the core editing rules:
            \(additional)
            </user_preferences>
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    static func userPrompt(for request: CorrectionRequest) -> String {
        let input = dictationInput(
            for: request,
            includeAppMetadata: true,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            vocabularyCandidates: vocabularyCandidates(for: request),
            asrHypotheses: request.sourceHypotheses.map(DictationPromptASRHypothesisPayload.full)
        )
        return renderUserPrompt(input)
    }

    static func budgetedUserPrompt(
        for request: CorrectionRequest,
        system: String,
        budget: CorrectionPromptBudget
    ) throws -> String {
        let compactHypotheses = request.sourceHypotheses.map {
            DictationPromptASRHypothesisPayload.compact($0, rawTranscript: request.rawTranscript)
        }
        let allVocabulary = vocabularyCandidates(for: request)

        let fullInput = dictationInput(
            for: request,
            includeAppMetadata: true,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            vocabularyCandidates: allVocabulary,
            asrHypotheses: compactHypotheses
        )
        let fullUser = renderUserPrompt(fullInput)
        if budget.canFit(system: system, user: fullUser) {
            return fullUser
        }

        // Raw text, language/output controls, duration, and source completion
        // statuses form the irreducible request. Distinct alternatives are
        // added separately below so they are never partially truncated.
        var evidence = BudgetedPromptEvidence(
            hypothesisIndices: Set(
                compactHypotheses.indices.filter {
                    compactHypotheses[$0].matchesRawTranscript || compactHypotheses[$0].completedEmpty
                }
            ),
            vocabulary: [],
            contextBefore: "",
            contextAfter: "",
            includesAppMetadata: false
        )

        func userPrompt(_ candidateEvidence: BudgetedPromptEvidence) -> String {
            let hypotheses = compactHypotheses.indices.compactMap {
                candidateEvidence.hypothesisIndices.contains($0) ? compactHypotheses[$0] : nil
            }
            return renderUserPrompt(dictationInput(
                for: request,
                includeAppMetadata: candidateEvidence.includesAppMetadata,
                contextBefore: candidateEvidence.contextBefore,
                contextAfter: candidateEvidence.contextAfter,
                vocabularyCandidates: candidateEvidence.vocabulary,
                asrHypotheses: hypotheses
            ))
        }

        var selectedUser = userPrompt(evidence)
        guard budget.canFit(system: system, user: selectedUser) else {
            let estimated = budget.estimatedInputTokens(system: system, user: selectedUser)
            throw CorrectorError.requestFailed(
                "Correction request exceeds embedded context capacity "
                    + "(estimated input \(estimated), output \(max(0, budget.maxOutputTokens)), "
                    + "context \(max(0, budget.contextSize)))"
            )
        }

        // Source alternatives carry stronger acoustic evidence than optional
        // UI context. Keep each selected text whole and preserve source order.
        for index in compactHypotheses.indices
        where compactHypotheses[index].text != nil && !evidence.hypothesisIndices.contains(index) {
            var candidateEvidence = evidence
            candidateEvidence.hypothesisIndices.insert(index)
            let candidate = userPrompt(candidateEvidence)
            if budget.canFit(system: system, user: candidate) {
                evidence = candidateEvidence
                selectedUser = candidate
            }
        }

        // Context closest to the insertion point is most useful: retain a
        // suffix before the cursor and a prefix after it, balanced by distance.
        let beforeCharacters = Array(request.contextBefore)
        let afterCharacters = Array(request.contextAfter)
        var lowerBound = 0
        var upperBound = beforeCharacters.count + afterCharacters.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound + 1) / 2
            let lengths = balancedContextLengths(
                evidenceCharacterCount: midpoint,
                beforeCount: beforeCharacters.count,
                afterCount: afterCharacters.count
            )
            let before = String(beforeCharacters.suffix(lengths.before))
            let after = String(afterCharacters.prefix(lengths.after))
            var candidateEvidence = evidence
            candidateEvidence.contextBefore = before
            candidateEvidence.contextAfter = after
            if budget.canFit(
                system: system,
                user: userPrompt(candidateEvidence)
            ) {
                lowerBound = midpoint
            } else {
                upperBound = midpoint - 1
            }
        }
        let contextLengths = balancedContextLengths(
            evidenceCharacterCount: lowerBound,
            beforeCount: beforeCharacters.count,
            afterCount: afterCharacters.count
        )
        evidence.contextBefore = String(beforeCharacters.suffix(contextLengths.before))
        evidence.contextAfter = String(afterCharacters.prefix(contextLengths.after))
        selectedUser = userPrompt(evidence)

        // Only transcript-anchored vocabulary survives a constrained payload;
        // selector ranking determines the deterministic prefix count.
        for vocabulary in allVocabulary where vocabulary.isTranscriptAnchored {
            var candidateEvidence = evidence
            candidateEvidence.vocabulary.append(vocabulary)
            let candidate = userPrompt(candidateEvidence)
            guard budget.canFit(system: system, user: candidate) else { break }
            evidence = candidateEvidence
            selectedUser = candidate
        }

        // App identity/category is useful style context but the lowest-priority
        // evidence in an embedded request, so add it only after speech evidence.
        var appEvidence = evidence
        appEvidence.includesAppMetadata = true
        let appCandidate = userPrompt(appEvidence)
        if budget.canFit(system: system, user: appCandidate) {
            evidence = appEvidence
            selectedUser = appCandidate
        }

        return selectedUser
    }

    private static func dictationInput(
        for request: CorrectionRequest,
        includeAppMetadata: Bool,
        contextBefore: String,
        contextAfter: String,
        vocabularyCandidates: [VocabularyCandidatePayload],
        asrHypotheses: [DictationPromptASRHypothesisPayload]
    ) -> DictationPromptInputPayload {
        let languageIDs = ASRLanguageSelection.validatedIDs(request.languageIDs)

        let outputPreferences = PromptOutputPreferencesPayload(
            numbers: request.numberOutputPreference.rawValue,
            punctuation: request.punctuationPreference.rawValue
        )
        let context = DictationPromptContextPayload(
            appName: includeAppMetadata ? request.frontmostAppName ?? "" : "",
            bundleID: includeAppMetadata ? request.frontmostBundleID ?? "" : "",
            appCategory: includeAppMetadata ? request.appCategory.rawValue : AppCategory.unknown.rawValue,
            languageCodes: ASRLanguageSelection.languageCodes(for: languageIDs),
            languageInstruction: LocaleTextNormalizer.promptInstruction(for: languageIDs),
            correctionMode: request.correctionMode.rawValue,
            outputPreferences: outputPreferences
        )
        return DictationPromptInputPayload(
            context: context,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            vocabularyCandidates: vocabularyCandidates,
            rawTranscript: request.rawTranscript,
            audioDurationMs: request.audioDurationMs,
            asrHypotheses: asrHypotheses
        )
    }

    private static func renderUserPrompt(_ input: DictationPromptInputPayload) -> String {
        let json = PromptPayloadEncoder.jsonString(input)
        return """
        <input_json>
        \(json)
        </input_json>
        \(OutputPreferencePrompt.finalReminder(
            numbers: NumberOutputPreference.normalized(input.context.outputPreferences.numbers),
            punctuation: PunctuationOutputPreference.normalized(input.context.outputPreferences.punctuation)
        ))
        Return exactly one JSON object and nothing else: {"text":"corrected transcript"}.
        """
    }

    private static func balancedContextLengths(
        evidenceCharacterCount: Int,
        beforeCount: Int,
        afterCount: Int
    ) -> (before: Int, after: Int) {
        var before = min(beforeCount, (evidenceCharacterCount + 1) / 2)
        var after = min(afterCount, evidenceCharacterCount / 2)
        var remaining = evidenceCharacterCount - before - after
        if remaining > 0 {
            let extraBefore = min(remaining, beforeCount - before)
            before += extraBefore
            remaining -= extraBefore
        }
        if remaining > 0 {
            after += min(remaining, afterCount - after)
        }
        return (before, after)
    }

    private struct BudgetedPromptEvidence {
        var hypothesisIndices: Set<Int>
        var vocabulary: [VocabularyCandidatePayload]
        var contextBefore: String
        var contextAfter: String
        var includesAppMetadata: Bool
    }

    static func formatRepairPrompt(parseError: String) -> String {
        let repair = DictationRepairPromptPayload(
            validationError: parseError
        )
        return """
        Your previous output did not satisfy the JSON contract.

        <format_error_json>
        \(PromptPayloadEncoder.jsonString(repair))
        </format_error_json>

        Rewrap the same intended final transcript from your previous output.
        Do not re-edit, improve, translate, summarize, or regenerate from input_json.
        If your previous output does not contain a determinate intended final transcript, return {"decision":"reject","text":""}.
        Otherwise return exactly one JSON object and nothing else: {"decision":"rewrap","text":"same intended final transcript"}.
        """
    }

    static func verifierPrompt(validationSignal: String, candidateText: String) -> String {
        let payload = DictationVerifierPromptPayload(
            validationSignal: validationSignal,
            candidateText: candidateText
        )
        return """
        Check whether your previous candidate text is safe to commit.

        <verification_json>
        \(PromptPayloadEncoder.jsonString(payload))
        </verification_json>

        You are checking, not editing. Default to accept unless there is clear evidence that the candidate violates the original task or validation signal.
        Return exactly one JSON object and nothing else:
        {"decision":"accept","reason_code":"ok","text":"candidate text exactly"}
        {"decision":"replace","reason_code":"minimal_fix","text":"minimal corrected text"}
        {"decision":"reject","reason_code":"unsafe","text":""}

        Rules:
        - For accept, text must exactly equal candidate_text.
        - Use replace only for a minimal fix to a clear violation such as duplicated content, concatenated ASR hypotheses, or unsafe markup.
        - Do not make stylistic improvements or re-run correction.
        - Reject if the safe final transcript is not determinate.
        """
    }

    static func vocabularyCandidates(for request: CorrectionRequest) -> [VocabularyCandidatePayload] {
        VocabularyCandidateSelector.promptPayload(
            from: request.userDictionary,
            rawText: request.rawTranscript,
            alternateTranscripts: request.asrHypotheses,
            extraContext: [
                request.frontmostAppName ?? "",
                request.frontmostBundleID ?? "",
                request.appCategory.rawValue,
                request.contextBefore,
                request.contextAfter,
            ]
        )
    }
}

private extension VocabularyCandidatePayload {
    var isTranscriptAnchored: Bool {
        matchedSpan != nil
            && evidenceSource == "transcript"
            && (matchSource == "raw_transcript" || matchSource == "alternate_transcript")
    }
}
