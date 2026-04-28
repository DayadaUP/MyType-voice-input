import Testing
@testable import Lexicon

@Test("learns personal term after 10 corrections")
func learnsAfterThreshold() {
    let service = LexiconService(threshold: 10)

    for _ in 0..<9 {
        service.recordCorrection(wrong: "麦克风", corrected: "麦克峰")
    }
    #expect(service.containsInPersonalLexicon("麦克峰") == false)

    service.recordCorrection(wrong: "麦克风", corrected: "麦克峰")
    #expect(service.containsInPersonalLexicon("麦克峰") == true)
}

@Test("applies prioritized replacement after term is learned")
func appliesPrioritizedReplacement() {
    let service = LexiconService(threshold: 3)
    service.recordCorrection(wrong: "麦克风", corrected: "麦克峰")
    service.recordCorrection(wrong: "麦克风", corrected: "麦克峰")
    service.recordCorrection(wrong: "麦克风", corrected: "麦克峰")

    let result = service.prioritizedReplacement(in: "我的麦克风坏了")
    #expect(result == "我的麦克峰坏了")
}

@Test("applies latin replacement on word boundaries only")
func appliesLatinBoundaryReplacement() {
    let service = LexiconService(threshold: 3)
    service.recordCorrection(wrong: "cat", corrected: "dog")
    service.recordCorrection(wrong: "cat", corrected: "dog")
    service.recordCorrection(wrong: "cat", corrected: "dog")

    let result = service.prioritizedReplacement(in: "my cat catalog")
    #expect(result == "my dog catalog")
}

@Test("learns and applies phrase-level correction mapping")
func learnsPhraseLevelCorrection() {
    let service = LexiconService(threshold: 3)

    for _ in 0..<3 {
        service.recordCorrection(wrong: "请你帮我看一下", corrected: "麻烦看下")
    }

    let result = service.prioritizedReplacement(in: "请你帮我看一下这个问题")
    #expect(result == "麻烦看下这个问题")
}

@Test("manual terms can be added listed and removed")
func managesManualTerms() {
    let service = LexiconService(threshold: 3)
    service.addManualTerms(["豆包", "火山引擎", "豆包"])

    let listed = service.listManualTerms()
    #expect(listed.contains("豆包"))
    #expect(listed.contains("火山引擎"))

    service.removeManualTerm("豆包")
    let afterDelete = service.listManualTerms()
    #expect(!afterDelete.contains("豆包"))
    #expect(afterDelete.contains("火山引擎"))
}

@Test("manual term normalization merges spaced phrase in final text")
func manualTermNormalizationMergesSpacedPhrase() {
    let service = LexiconService(threshold: 3)
    service.addManualTerms(["豆包"])

    let result = service.prioritizedReplacement(in: "我在测试豆 包语音输入")
    #expect(result == "我在测试豆包语音输入")
}

@Test("manual term normalization applies conservative fuzzy correction for cjk terms")
func manualTermNormalizationAppliesConservativeFuzzyCorrection() {
    let service = LexiconService(threshold: 3)
    service.addManualTerms(["斯莫格", "唯卓仕"])

    let result = service.prioritizedReplacement(in: "我买了思莫格和维卓仕灯")
    #expect(result == "我买了斯莫格和唯卓仕灯")
}

@Test("preview mode skips fuzzy correction for manual terms")
func previewModeSkipsFuzzyCorrection() {
    let service = LexiconService(threshold: 3)
    service.addManualTerms(["斯莫格"])

    let result = service.prioritizedReplacement(
        in: "我买了思莫格",
        includeFuzzyManualReplacement: false
    )
    #expect(result == "我买了思莫格")
}

@Test("manual term fuzzy correction does not rewrite unrelated sentence")
func manualTermFuzzyCorrectionAvoidsUnrelatedText() {
    let service = LexiconService(threshold: 3)
    service.addManualTerms(["斯莫格"])

    let input = "今天下午天气很好，我们去公园散步。"
    let result = service.prioritizedReplacement(in: input)
    #expect(result == input)
}

@Test("manual terms keep priority over learned replacements")
func manualTermsKeepPriorityOverLearnedReplacements() {
    let service = LexiconService(threshold: 1)
    service.addManualTerms(["斯莫格"])
    service.recordCorrection(wrong: "斯莫格", corrected: "灯架")

    let result = service.prioritizedReplacement(in: "我买了斯莫格")
    #expect(result == "我买了斯莫格")
}

@Test("replacement trace reports learned and manual hits")
func replacementTraceReportsHits() {
    let service = LexiconService(threshold: 3)
    for _ in 0..<3 {
        service.recordCorrection(wrong: "麦克风", corrected: "麦克峰")
    }
    service.addManualTerms(["豆包"])

    let trace = service.prioritizedReplacementWithTrace(in: "麦克风和豆 包都在这里")
    #expect(trace.text == "麦克峰和豆包都在这里")

    let learnedHit = trace.hits.first { $0.source == .learnedRule }
    #expect(learnedHit?.original == "麦克风")
    #expect(learnedHit?.replacement == "麦克峰")
    #expect((learnedHit?.count ?? 0) >= 1)

    let manualHit = trace.hits.first { $0.source == .manualTerm }
    #expect(manualHit?.replacement == "豆包")
    #expect((manualHit?.count ?? 0) >= 1)
}

@Test("learns pronunciation mapping and rewrites unseen homophone variant")
func learnsPronunciationMappingAndRewritesVariant() {
    let service = LexiconService(threshold: 3)
    for _ in 0..<3 {
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
    }

    let result = service.prioritizedReplacement(in: "我买了私莫格和斯莫格灯")
    #expect(result == "我买了斯莫格和斯莫格灯")

    let trace = service.prioritizedReplacementWithTrace(in: "私莫格")
    let pronunciationHit = trace.hits.first { $0.source == .pronunciationRule }
    #expect(pronunciationHit?.replacement == "斯莫格")
    #expect((pronunciationHit?.count ?? 0) >= 1)
}
