import Testing
@testable import Lexicon
import Foundation

@Test("detects single token replacement in chinese text")
func detectsChineseReplacement() {
    let pairs = CorrectionDiffDetector.detectPairs(from: "今天真好", to: "今天挺好")
    #expect(pairs.count == 1)
    #expect(pairs.first?.wrongTerm == "真")
    #expect(pairs.first?.correctedTerm == "挺")
}

@Test("detects word replacement in latin text")
func detectsLatinReplacement() {
    let pairs = CorrectionDiffDetector.detectPairs(from: "hello cat", to: "hello dog")
    #expect(pairs.count == 1)
    #expect(pairs.first?.wrongTerm == "cat")
    #expect(pairs.first?.correctedTerm == "dog")
}

@Test("ignores punctuation-only changes")
func ignoresPunctuationOnlyChanges() {
    let pairs = CorrectionDiffDetector.detectPairs(from: "你好,世界", to: "你好，世界")
    #expect(pairs.isEmpty)
}

@Test("ignores han to pinyin intermediate replacement")
func ignoresHanToPinyinIntermediate() {
    let pairs = CorrectionDiffDetector.detectPairs(from: "今天似莫格", to: "今天si")
    #expect(pairs.isEmpty)
}

@Test("ignores pinyin to han intermediate replacement")
func ignoresPinyinToHanIntermediate() {
    let pairs = CorrectionDiffDetector.detectPairs(from: "今天wei", to: "今天唯卓仕")
    #expect(pairs.isEmpty)
}

@Test("detects phrase-level replacement for larger rewrite")
func detectsPhraseReplacement() {
    let pairs = CorrectionDiffDetector.detectPairs(
        from: "请你帮我看一下这个问题",
        to: "麻烦看下这个问题"
    )
    #expect(pairs.contains { pair in
        pair.wrongTerm.hasPrefix("请你帮我看")
            && pair.correctedTerm.hasPrefix("麻烦看")
            && pair.wrongTerm.count >= 5
            && pair.correctedTerm.count >= 3
    })
}

@Test("extracts punctuation diff events with context")
func detectsPunctuationDiffEvents() {
    let events = CorrectionDiffDetector.detectPunctuationEvents(
        from: "我们先走。然后看结果",
        to: "我们先走，然后看结果！",
        appIdentifier: "com.example.app",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let hasCommaReplacement = events.contains { event in
        event.sourcePunctuation == "。"
            && event.targetPunctuation == "，"
            && event.appIdentifier == "com.example.app"
            && event.contextBefore.contains("我们先走")
    }
    #expect(hasCommaReplacement)
}

@Test("numeric punctuation noise is low confidence for conservative learning")
func numericPunctuationNoiseHasLowConfidence() {
    let events = CorrectionDiffDetector.detectPunctuationEvents(
        from: "价格12.5元",
        to: "价格12,5元"
    )

    #expect(events.isEmpty || events.allSatisfy { $0.confidence < 0.58 })
}
