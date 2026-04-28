import Testing
@testable import IMEHost

@Test("stream finalization accepts identical preview text")
func streamFinalizationAcceptsIdenticalPreviewText() {
    let decision = CloudStreamingFinalizationGuard.evaluate(
        previewText: "今天下午三点和产品一起过需求",
        streamedPreviewText: "今天下午三点和产品一起过需求"
    )

    #expect(decision.accept)
    #expect(decision.reason == "preview_equal")
}

@Test("stream finalization accepts longer final text that contains preview")
func streamFinalizationAcceptsSupersetPreviewText() {
    let decision = CloudStreamingFinalizationGuard.evaluate(
        previewText: "今天下午三点和产品一起过需求",
        streamedPreviewText: "今天下午三点和产品一起过需求，然后同步一下排期"
    )

    #expect(decision.accept)
    #expect(decision.reason == "stream_superset")
}

@Test("stream finalization rejects severe truncation")
func streamFinalizationRejectsTruncation() {
    let decision = CloudStreamingFinalizationGuard.evaluate(
        previewText: "今天下午三点和产品一起过需求，然后同步一下排期",
        streamedPreviewText: "今天下午三点和产品"
    )

    #expect(!decision.accept)
    #expect(decision.reason == "preview_contains_stream_truncated")
}

@Test("stream finalization rejects unrelated text")
func streamFinalizationRejectsUnrelatedText() {
    let decision = CloudStreamingFinalizationGuard.evaluate(
        previewText: "今天下午三点和产品一起过需求",
        streamedPreviewText: "明天上午先处理线上报警"
    )

    #expect(!decision.accept)
    #expect(decision.reason == "low_overlap")
}

@Test("stream finalization accepts when no preview text is available")
func streamFinalizationAcceptsWithoutPreviewBaseline() {
    let decision = CloudStreamingFinalizationGuard.evaluate(
        previewText: "",
        streamedPreviewText: "先把这个问题记录下来"
    )

    #expect(decision.accept)
    #expect(decision.reason == "no_preview_baseline")
}

@Test("stream finalization rejects malformed numeric protected span even with high overlap")
func streamFinalizationRejectsMalformedNumericProtectedSpan() {
    let decision = CloudStreamingFinalizationGuard.evaluate(
        previewText: "我在测试一下，2493，3512，我看一下是否还是会有逗号来间隔。",
        streamedPreviewText: "我在测试一下2,000.400.9.13.3,000.500.6.12我看一下是否还是会有逗号来间隔。"
    )

    #expect(!decision.accept)
    #expect(decision.reason == "protected_span_regression_fallback_preview_malformed_protected_span")
}

@Test("preview reuse accepts when recent preview repeats")
func previewReuseAcceptsRepeatedPreviewSnapshot() {
    let decision = CloudStreamingFinalizationGuard.evaluatePreviewReuse(
        previewText: "今天下午三点和产品一起过需求",
        recentPreviewTexts: [
            "今天下午三点和产品一起过需求",
            "今天下午三点和产品一起过需求",
            "今天下午三点和产品一起过需求"
        ]
    )

    #expect(decision.accept)
    #expect(decision.reason == "recent_preview_repeated")
}

@Test("preview reuse accepts when three previews share full prefix")
func previewReuseAcceptsSharedPrefixSnapshot() {
    let decision = CloudStreamingFinalizationGuard.evaluatePreviewReuse(
        previewText: "今天下午三点和产品一起过需求",
        recentPreviewTexts: [
            "今天下午三点和产品一起过需求，然后同步",
            "今天下午三点和产品一起过需求，先确认",
            "今天下午三点和产品一起过需求，晚点发你"
        ]
    )

    #expect(decision.accept)
    #expect(decision.reason == "recent_preview_shared_prefix")
}

@Test("preview reuse rejects unstable preview history")
func previewReuseRejectsUnstableHistory() {
    let decision = CloudStreamingFinalizationGuard.evaluatePreviewReuse(
        previewText: "今天下午三点和产品一起过需求",
        recentPreviewTexts: [
            "今天下午三点和产品一起过需求",
            "明天上午先处理线上报警",
            "晚上回去再看一下"
        ]
    )

    #expect(!decision.accept)
    #expect(decision.reason == "preview_history_not_stable")
}

@Test("protected span repair falls back to preview when candidate has malformed numeric cluster")
func protectedSpanRepairFallsBackToPreviewForMalformedNumericCluster() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "我在测试一下，2493，3512，我看一下是否还是会有逗号来间隔。",
        candidateText: "我在测试一下2,000.400.9.13.3,000.500.6.12我看一下是否还是会有逗号来间隔。"
    )

    #expect(decision.changed)
    #expect(decision.reason == "fallback_preview_malformed_protected_span")
    #expect(decision.outputText == "我在测试一下，2493，3512，我看一下是否还是会有逗号来间隔。")
}

@Test("protected span repair replaces grouped integer with stable preview digits")
func protectedSpanRepairReplacesGroupedInteger() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "我再来测试一下吧，这个笔记我写了701个词，2491个字符。",
        candidateText: "我再来测试一下吧，这个笔记我写了701个词，2,491个字符。"
    )

    #expect(decision.changed)
    #expect(decision.reason == "replace_degraded_protected_spans_numeric_format_normalized")
    #expect(decision.outputText == "我再来测试一下吧，这个笔记我写了701个词，2491个字符。")
}

@Test("protected span repair replaces malformed vivo model and project fragments")
func protectedSpanRepairReplacesMalformedMixedEntities() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "然后你再取我的Obsidian 2025年的项目里去查看关于vivo X200s和vivo X200 Ultra的开箱笔记",
        candidateText: "然后你再取我的Obsidian 2025年的项，目里去查看关于vivo x 200 S和vivo x，200 Ultra的开箱笔记"
    )

    #expect(decision.changed)
    #expect(decision.outputText == "然后你再取我的Obsidian 2025年的项目里去查看关于vivo X200s和vivo X200 Ultra的开箱笔记")
}

@Test("protected span repair replaces split brief token from preview")
func protectedSpanRepairReplacesSplitBriefToken() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "这个是vivo X300 Ultra的一些brief介绍信息，你看一下",
        candidateText: "这个是vivo X300 Ultra的一些bri，ef介绍信息，你看一下"
    )

    #expect(decision.changed)
    #expect(decision.outputText == "这个是vivo X300 Ultra的一些brief介绍信息，你看一下")
}

@Test("detect hard numeric regression when pure integer digit count changes")
func detectHardNumericRegressionWhenDigitCountChanges() {
    let reason = CloudStreamingFinalizationGuard.detectHardNumericIntegrityRegression(
        sourceText: "这里的预算是100000元。",
        candidateText: "这里的预算是1010000元。"
    )

    #expect(reason == "digit_count_changed")
}

@Test("detect hard numeric regression when integer becomes decimal")
func detectHardNumericRegressionWhenIntegerBecomesDecimal() {
    let reason = CloudStreamingFinalizationGuard.detectHardNumericIntegrityRegression(
        sourceText: "这次记录的是120。",
        candidateText: "这次记录的是120.10。"
    )

    #expect(reason == "integer_became_decimal")
}

@Test("detect hard numeric regression when han characters enter pure number")
func detectHardNumericRegressionWhenHanMixedIntoNumber() {
    let reason = CloudStreamingFinalizationGuard.detectHardNumericIntegrityRegression(
        sourceText: "这个编号是1351。",
        candidateText: "这个编号是一,351。"
    )

    #expect(reason == "mixed_han_in_numeric")
}

@Test("protected span repair replaces changed pure integer with stable preview digits")
func protectedSpanRepairReplacesChangedPureInteger() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "这个金额应该输出100000。",
        candidateText: "这个金额应该输出1010000。"
    )

    #expect(decision.changed)
    #expect(decision.reason == "replace_degraded_protected_spans_digit_count_changed")
    #expect(decision.outputText == "这个金额应该输出100000。")
}

@Test("protected span repair replaces integer that became decimal")
func protectedSpanRepairReplacesIntegerThatBecameDecimal() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "这次的数字是120。",
        candidateText: "这次的数字是120.10。"
    )

    #expect(decision.changed)
    #expect(decision.reason == "replace_degraded_protected_spans_integer_became_decimal")
    #expect(decision.outputText == "这次的数字是120。")
}

@Test("protected span repair replaces han mixed numeric token with stable preview digits")
func protectedSpanRepairReplacesHanMixedNumericToken() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "请把编号1351保留下来。",
        candidateText: "请把编号一,351保留下来。"
    )

    #expect(decision.changed)
    #expect(decision.reason == "replace_degraded_protected_spans_mixed_han_in_numeric")
    #expect(decision.outputText == "请把编号1351保留下来。")
}

@Test("protected span repair normalizes same value decimal formatting without treating it as regression")
func protectedSpanRepairNormalizesSameValueDecimalFormatting() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "折扣保持12.5%。",
        candidateText: "折扣保持12,50%。"
    )

    #expect(decision.changed)
    #expect(decision.reason == "replace_degraded_protected_spans_numeric_format_normalized")
    #expect(decision.outputText == "折扣保持12.5%。")
    #expect(
        CloudStreamingFinalizationGuard.detectHardNumericIntegrityRegression(
            sourceText: "折扣保持12.5%。",
            candidateText: "折扣保持12,50%。"
        ) == nil
    )
}

@Test("protected span repair keeps time separator stable")
func protectedSpanRepairKeepsTimeSeparatorStable() {
    let decision = CloudStreamingFinalizationGuard.repairProtectedSpans(
        previewText: "现在的时间是19:21。",
        candidateText: "现在的时间是19.21。"
    )

    #expect(decision.changed)
    #expect(decision.outputText == "现在的时间是19:21。")
}
