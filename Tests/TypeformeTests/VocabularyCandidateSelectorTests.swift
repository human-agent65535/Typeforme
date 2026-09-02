import Testing
@testable import Typeforme

@Suite("VocabularyCandidateSelector")
struct VocabularyCandidateSelectorTests {
    @Test func selectsPersonByPhoneticConfusion() {
        let entries = [
            DictionaryEntry(type: "person", surface: "样例甲"),
            DictionaryEntry(type: "project", surface: "Apollo"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "我刚刚和样例佳确认了这个 bug"
        )

        #expect(result.map(\.surface) == ["样例甲"])
    }

    @Test func selectsChineseHomophoneByPinyin() {
        let entries = [
            DictionaryEntry(type: "person", surface: "样例甲"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "这个问题要问一下样例佳"
        )

        #expect(result.first?.surface == "样例甲")
    }

    @Test func selectsChinesePersonNameBySamePinyinAndSharedSurname() {
        let entries = [
            DictionaryEntry(type: "person", surface: "郭霁"),
            DictionaryEntry(type: "product", surface: "Sleep Cycle"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "郭基，你昨天作业写得怎么样？",
            alternateTranscripts: ["国基里昨天作业写的怎么样"]
        )

        #expect(payload.first?.surface == "郭霁")
        #expect(payload.first?.matchedSpan == "郭基")
        #expect(payload.first?.matchSource == "raw_transcript")
        #expect(payload.first?.matchedStart == 0)
        #expect(payload.first?.matchedEnd == 2)
        #expect(payload.first?.matchKind == "same_pinyin")
        #expect(payload.first?.pronunciations == ["guo ji"])
        #expect(!payload.contains { $0.surface == "Sleep Cycle" })
    }

    @Test func selectsChineseNearPhoneticCandidate() {
        let entries = [
            DictionaryEntry(type: "person", surface: "样例山"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "找样例散确认一下"
        )

        #expect(payload.first?.surface == "样例山")
        #expect(payload.first?.matchedSpan == "样例散")
        #expect(payload.first?.matchedStart == 1)
        #expect(payload.first?.matchedEnd == 4)
    }

    @Test func nearPinyinAloneDoesNotInsertPersonIntoCoherentProse() {
        let entries = [
            DictionaryEntry(type: "person", surface: "郭霁"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "他没有啊，他不是医生啊，他走开路进去的。他是小孩，他可以到任何地方住。"
        )

        #expect(payload.isEmpty)
    }

    @Test func typedPinyinNamesDoNotUseTranscriptPersonFilteringOrItsCache() {
        let entries = [
            DictionaryEntry(type: "person", surface: "林霁"),
            DictionaryEntry(type: "product", surface: "Typeforme"),
        ]
        for pinyin in ["linjinideshoujinalimaide", "lin ji ni de shou ji na li mai de", "lin'ji nideshoujinalimaide"] {
            #expect(VocabularyCandidateSelector.promptPayload(from: entries, rawText: pinyin).isEmpty)
            let payload = VocabularyCandidateSelector.pinyinPromptPayload(from: entries, pinyin: pinyin)
            #expect(payload.map(\.surface) == ["林霁"])
            #expect(payload.first?.speechHint == "linji")
            #expect(payload.first?.matchSource == "pinyin")
            #expect(payload.first?.evidenceSource == "typed_pinyin")
            #expect(VocabularyCandidateSelector.promptPayload(from: entries, rawText: pinyin).isEmpty)
        }
    }

    @Test func rejectsChinesePersonHomophonesWithoutPersonUseContext() {
        let entries = [DictionaryEntry(type: "person", surface: "郭霁")]
        let transcripts = [
            "你的国籍是什么？",
            "锅鸡很好吃。",
            "用户名是 guoji。",
            "国家机器简称国机。",
            "国机集团今天发布财报。",
            "请确认你的国籍。",
            "中国和国际社会合作。",
            "我喜欢锅鸡和米饭。",
            "请问国机集团怎么走？",
        ]

        for transcript in transcripts {
            let payload = VocabularyCandidateSelector.promptPayload(
                from: entries,
                rawText: transcript
            )
            #expect(payload.isEmpty, "Unexpected person candidate for: \(transcript)")
        }
    }

    @Test func pinyinVocabularyDoesNotMatchInsideProtectedLiterals() {
        let entries = [DictionaryEntry(type: "person", surface: "林霁")]
        for pinyin in [
            "dakai https://example.test/linji?x=3.5",
            "fa you jian gei linji@example.test",
            "shuru `linji`",
        ] {
            #expect(VocabularyCandidateSelector.pinyinPromptPayload(from: entries, pinyin: pinyin).isEmpty)
        }
        let mixed = VocabularyCandidateSelector.pinyinPromptPayload(
            from: entries,
            pinyin: "dakai https://example.test/linji ranhougaosulinji"
        )
        #expect(mixed.map(\.surface) == ["林霁"])
    }

    @Test func keepsChinesePersonHomophonesWithIndependentPersonUseEvidence() {
        let entries = [DictionaryEntry(type: "person", surface: "郭霁")]
        let transcripts = [
            "郭吉，你吃饭了吗？",
            "国际，你吃饭了吗？",
            "我刚和国际确认过。",
            "guoji, you can check this later.",
        ]

        for transcript in transcripts {
            let payload = VocabularyCandidateSelector.promptPayload(
                from: entries,
                rawText: transcript
            )
            #expect(payload.first?.surface == "郭霁", "Missing person candidate for: \(transcript)")
        }
    }

    @Test func anchorsLatinPinyinPersonMatchToTheTranscriptSpan() {
        let entries = [DictionaryEntry(type: "person", surface: "郭霁")]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "guoji, you can check this later."
        )

        #expect(payload.first?.matchedSpan == "guoji")
        #expect(payload.first?.matchedStart == 0)
        #expect(payload.first?.matchedEnd == 5)
        #expect(payload.first?.matchKind == "same_pinyin")
    }

    @Test func selectsSpokenEnglishAcronym() {
        let entries = [
            DictionaryEntry(type: "acronym", surface: "CLI"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "run the see ell eye command"
        )

        #expect(result.first?.surface == "CLI")
    }

    @Test func selectsEnglishPhoneticCandidate() {
        let entries = [
            DictionaryEntry(type: "product", surface: "Grafana"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "check the graphana dashboard"
        )

        #expect(result.first?.surface == "Grafana")
    }

    @Test func selectsEnglishVocabularyFromChineseASRPhonetics() {
        let entries = [
            DictionaryEntry(type: "product", surface: "codex"),
            DictionaryEntry(type: "product", surface: "Cursor"),
            DictionaryEntry(type: "product", surface: "Claude"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "打开扣带可看一下"
        )

        #expect(payload.first?.surface == "codex")
        #expect(payload.first?.matchedSpan == "扣带可")
        #expect(payload.first?.matchedStart == 2)
        #expect(payload.first?.matchedEnd == 5)
        #expect(payload.first?.matchKind == "cross_script_phonetic")
        #expect(payload.first?.pronunciations.contains("kou dai ke") == true)
    }

    @Test func selectsCursorFromChineseASRPhonetics() {
        let entries = [
            DictionaryEntry(type: "product", surface: "Cursor"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "课色今天又更新了"
        )

        #expect(payload.count == 1)
        #expect(payload[0].surface == "Cursor")
        #expect(payload[0].matchedSpan == "课色")
        #expect(payload[0].matchKind == "cross_script_phonetic")
    }

    @Test func selectsEnglishPhraseFromChineseASRPhoneticsUsingPronunciationLexicon() {
        let entries = [
            DictionaryEntry(type: "product", surface: "Sleep Cycle"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "打开斯利普赛扣看一下"
        )

        #expect(payload.count == 1)
        #expect(payload[0].surface == "Sleep Cycle")
        #expect(payload[0].matchedSpan == "斯利普赛扣")
        #expect(payload[0].matchKind == "cross_script_phonetic")
        #expect(payload[0].pronunciations.contains("si li pu sai kou"))
    }

    @Test func selectsMixedScriptTermFromChineseASRSlot() {
        let entries = [
            DictionaryEntry(type: "technical_term", surface: "样例V词条"),
            DictionaryEntry(type: "product", surface: "示例AR设备"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "刚刚测试样例微词条这个词",
            alternateTranscripts: ["刚刚测试样例维词条这个词"]
        )

        #expect(payload.first?.surface == "样例V词条")
        #expect(payload.first?.matchedSpan == "样例微词条")
        #expect(payload.first?.matchedStart == 4)
        #expect(payload.first?.matchedEnd == 9)
        #expect(payload.first?.matchKind == "mixed_script_skeleton")
        #expect(payload.first?.pronunciations.contains("yang li wei ci tiao") == true)
        #expect(!payload.contains { $0.surface == "示例AR设备" })

        let homophoneAnchorPayload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "刚刚测试洋例微词条这个词"
        )
        #expect(homophoneAnchorPayload.first?.surface == "样例V词条")
        #expect(homophoneAnchorPayload.first?.matchedSpan == "洋例微词条")
        #expect(homophoneAnchorPayload.first?.matchKind == "mixed_script_skeleton")
    }

    @Test func doesNotSelectUnrelatedEnglishVocabularyFromChineseTranscript() {
        let entries = [
            DictionaryEntry(type: "product", surface: "codex"),
            DictionaryEntry(type: "product", surface: "Cursor"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "今天开会讨论项目进度"
        )

        #expect(payload.isEmpty)
    }

    @Test func doesNotSelectMixedScriptTermByGlobalTopicSimilarity() {
        let entries = [
            DictionaryEntry(type: "technical_term", surface: "样例V词条"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "普通问题只是在讨论示例设备"
        )

        #expect(payload.isEmpty)
    }

    @Test func textContextReranksMatchedCandidatesButDoesNotSummonUnmatchedTerms() {
        let ambiguous = [
            DictionaryEntry(type: "person", surface: "Apollo"),
            DictionaryEntry(type: "project", surface: "Apollo"),
        ]

        let projectResult = VocabularyCandidateSelector.select(
            from: ambiguous,
            rawText: "Apollo issue PR release"
        )
        #expect(projectResult.first?.type == "project")

        let personResult = VocabularyCandidateSelector.select(
            from: ambiguous,
            rawText: "ask Apollo to confirm"
        )
        #expect(personResult.first?.type == "person")

        let unrelated = VocabularyCandidateSelector.select(
            from: [DictionaryEntry(type: "technical_term", surface: "GraphRAG")],
            rawText: "server latency is high"
        )
        #expect(unrelated.isEmpty)
    }

    @Test func promptPayloadUsesVocabularyCandidateShape() {
        let entries = [
            DictionaryEntry(type: "person", surface: "样例甲"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "和样例佳对一下"
        )

        #expect(payload.count == 1)
        #expect(payload[0].type == "person")
        #expect(payload[0].surface == "样例甲")
        #expect(payload[0].speechHint == "yanglijia")
        #expect(payload[0].pronunciations == ["yang li jia"])
        #expect(payload[0].matchedSpan == "样例佳")
        #expect(payload[0].matchSource == "raw_transcript")
        #expect(payload[0].matchedStart == 1)
        #expect(payload[0].matchedEnd == 4)
        #expect(payload[0].matchKind == "same_pinyin")
        #expect(payload[0].confidence >= 0.9)
        #expect(payload[0].evidenceSource == "transcript")
        let json = PromptPayloadEncoder.jsonString(payload)
        #expect(json.contains("\"speech_hint\":\"yanglijia\""))
        #expect(json.contains("\"matched_span\":\"样例佳\""))
        #expect(json.contains("\"match_source\":\"raw_transcript\""))
        #expect(json.contains("\"matched_start\":1"))
        #expect(json.contains("\"matched_end\":4"))
        #expect(json.contains("\"match_kind\":\"same_pinyin\""))
        #expect(json.contains("\"evidence_source\":\"transcript\""))
        #expect(json.contains("\"pronunciations\":[\"yang li jia\"]"))
        #expect(!json.contains("spoken_forms"))
        #expect(!json.contains("common_confusions"))
        #expect(!json.contains("priority"))
    }

    @Test func promptPayloadUsesAlternateTranscriptsForVocabularyRecall() {
        let entries = [
            DictionaryEntry(type: "person", surface: "样例甲"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "这个问题要问一下项目负责人",
            alternateTranscripts: ["这个问题要问一下样例佳"],
            extraContext: ["Notes"]
        )

        #expect(payload.count == 1)
        #expect(payload[0].surface == "样例甲")
        #expect(payload[0].matchedSpan == "样例佳")
        #expect(payload[0].matchSource == "alternate_transcript")
        #expect(payload[0].matchedStart == 8)
        #expect(payload[0].matchedEnd == 11)
        #expect(payload[0].evidenceSource == "transcript")
    }

    @Test func promptPayloadCarriesAutomaticEnglishEvidence() {
        let entries = [
            DictionaryEntry(type: "product", surface: "Grafana"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "check the graphana dashboard"
        )

        #expect(payload.count == 1)
        #expect(payload[0].surface == "Grafana")
        #expect(payload[0].pronunciations.contains("grafana"))
        #expect(payload[0].matchedSpan == "graphana")
        #expect(payload[0].matchedStart == 10)
        #expect(payload[0].matchedEnd == 18)
        #expect(["english_soundex", "english_fuzzy"].contains(payload[0].matchKind))
        #expect(payload[0].confidence >= 0.68)
    }

    @Test func promptPayloadIncludesSyntheticChineseTermForSamePronunciationCommonWord() {
        let entries = [
            DictionaryEntry(type: "person", surface: "样例乙"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "这个安排需要样例一吗？看到新闻了吗？"
        )

        #expect(payload.count == 1)
        #expect(payload[0].surface == "样例乙")
        #expect(payload[0].type == "person")
        #expect(payload[0].speechHint == "yangliyi")
    }

    @Test func doesNotReturnUnrelatedLargeVocabularyItems() {
        let entries = (0..<100).map {
            DictionaryEntry(type: "person", surface: "测试用户\($0)")
        }

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "今天讨论 server latency"
        )

        #expect(result.isEmpty)
    }
}
