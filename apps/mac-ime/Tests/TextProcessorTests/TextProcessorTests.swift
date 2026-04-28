import Testing
@testable import TextProcessor
import Lexicon
import Settings

private struct StubPunctuationProfileProvider: PunctuationProfileProviding {
    let profile: PunctuationUserProfile?

    func effectiveProfile(minSamples: Int) -> PunctuationUserProfile? {
        guard let profile, profile.learnedSamples >= minSamples else {
            return nil
        }
        return profile
    }
}

@Test("removes default filler words when enabled")
func removesFillers() {
    let settings = InMemorySettingsStore()
    settings.set(true, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("嗯 我 呃 今天去开会")

    #expect(result == "我 今天去开会")
}

@Test("adds basic punctuation when enabled")
func addsPunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(true, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
    settings.set(PunctuationStyle.auto.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("请把周报发到群里")

    #expect(result.hasSuffix("。"))
}

@Test("sentence ending punctuation can be disabled without removing middle punctuation")
func disablesSentenceEndingPunctuationOnly() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("今天我们先过一下排期然后明天再同步细节")

    #expect(result.contains("，然后"))
    #expect(!result.hasSuffix("。"))
    #expect(!result.hasSuffix("？"))
}

@Test("existing sentence ending punctuation is preserved when auto append is disabled")
func preservesExistingSentenceEndingPunctuationWhenDisabled() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("这个问题要不要今天处理？")

    #expect(result == "这个问题要不要今天处理？")
}

@Test("trailing comma is not upgraded to sentence ending punctuation when disabled")
func doesNotPromoteTrailingCommaWhenSentenceEndingDisabled() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("今天先这样，")

    #expect(result == "今天先这样，")
}

@Test("auto punctuation uses chinese symbols when chinese is dominant")
func autoUsesChinesePunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.auto.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("今天开会,下午三点然后同步进展")

    #expect(result.contains("，"))
    #expect(result.hasSuffix("。"))
}

@Test("forced english punctuation converts chinese symbols")
func englishStyleConvertsPunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.english.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("hello，world。")

    #expect(result == "hello, world.")
}

@Test("forced chinese punctuation converts english symbols")
func chineseStyleConvertsPunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("hello, world.")

    #expect(result == "hello，world。")
}

@Test("chinese punctuation v2 inserts comma before discourse marker")
func chineseSegmentationAddsCommaBeforeMarker() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("今天我们先过一下排期然后明天再同步细节")

    #expect(result.contains("，然后"))
}

@Test("english punctuation v2 inserts comma before connector")
func englishSegmentationAddsCommaBeforeConnector() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.english.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("we finished the draft but we still need review")

    #expect(result.contains(", but"))
    #expect(result.hasSuffix("."))
}

@Test("converts spoken chinese decimal number to arabic digits")
func convertsChineseDecimal() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("这个价格是一点六元")

    #expect(result == "这个价格是1.6元")
}

@Test("converts spoken chinese integer with units to arabic digits")
func convertsChineseIntegerWithUnits() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("今天有一百二十三个人")

    #expect(result == "今天有123个人")
}

@Test("converts chinese ten-thousand magnitude variants")
func convertsChineseTenThousandMagnitudeVariants() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)

    #expect(processor.process("十三万块钱") == "130000块钱")
    #expect(processor.process("一十三万块钱") == "130000块钱")
    #expect(processor.process("一百三十万") == "1300000")
    #expect(processor.process("一千三百二十五万") == "13250000")
    #expect(processor.process("一亿一千三百二十五万") == "113250000")
    #expect(processor.process("一百三十一万") == "1310000")
}

@Test("converts colloquial abbreviated ten-thousand tails")
func convertsColloquialAbbreviatedTenThousandTails() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)

    #expect(processor.process("今天收入一万三") == "今天收入13000")
    #expect(processor.process("今天收入1万3") == "今天收入13000")
    #expect(processor.process("预算两万五") == "预算25000")
    #expect(processor.process("备用金一万零三") == "备用金10003")
    #expect(processor.process("备用金一万三百") == "备用金10300")
    #expect(processor.process("跑步消耗434千卡") == "跑步消耗434千卡")
}

@Test("does not convert lexical phrase with yi")
func doesNotConvertLexicalYi() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("我们一起去吃饭")

    #expect(result == "我们一起去吃饭")
}

@Test("does not convert spaced lexical yi phrases")
func doesNotConvertSpacedLexicalYi() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("我们一 起去吃饭，也会一 直聊方案")

    #expect(result == "我们一 起去吃饭也会一 直聊方案")
}

@Test("does not convert lexical phrase wan yi")
func doesNotConvertWanYiLexicalPhrase() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("万一失败怎么办")

    #expect(result == "万一失败怎么办")
}

@Test("converts only strong numeric contexts in conservative mode")
func convertsStrongNumericContextsInConservativeMode() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("第三次评审在三点进行，预算一百二十元，我们一起复盘")

    #expect(result == "第3次评审在3点进行预算120元我们一起复盘")
}

@Test("removes model punctuation noise when auto punctuation is disabled")
func removesModelPunctuationNoiseWhenAutoOff() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("我现在测试一下，关闭了。自动。标点。价格是1.6，预算是12,345。")

    #expect(result == "我现在测试一下关闭了自动标点价格是1.6预算是12345")
}

@Test("keeps model punctuation when preserve cloud raw punctuation is enabled")
func keepsModelPunctuationWhenPreserveEnabled() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)
    settings.set(true, forKey: SettingsKeys.preserveCloudRawPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("我现在测试一下，关闭了。自动。标点。")

    #expect(result == "我现在测试一下，关闭了。自动。标点。")
}

@Test("denoises noisy model punctuation before auto punctuation")
func denoisesNoisyModelPunctuationBeforeAutoPunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("我。再。来。测。试。1。下。")

    #expect(result == "我再来测试一下。")
}

@Test("final polish cleans formatting when auto punctuation is off")
func finalPolishWithAutoOff() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.preserveCloudRawPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("我 现在测试。 一下。 预算 一百二十 元")

    #expect(result == "我 现在测试一下预算 120 元")
}

@Test("final polish improves readability when auto punctuation is on")
func finalPolishWithAutoOn() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("现在。 来。测试。 一下。 然后看结果")

    #expect(result == "现在来测试一下，然后看结果。")
}

@Test("final polish keeps middle punctuation but skips auto sentence ending when disabled")
func finalPolishWithoutSentenceEndingPunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("现在。 来。测试。 一下。 然后看结果")

    #expect(result == "现在来测试一下，然后看结果")
}

@Test("english style skips auto period when sentence ending punctuation is disabled")
func englishStyleWithoutSentenceEndingPunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.sentenceEndingPunctuationEnabled)
    settings.set(PunctuationStyle.english.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("we finished the draft but we still need review")

    #expect(result.contains(", but"))
    #expect(!result.hasSuffix("."))
    #expect(!result.hasSuffix("?"))
}

@Test("final polish v1 reflows phrase numeric and question punctuation")
func finalPolishReflowV1RepairsPunctuationPlacement() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("现在。 我。 来。测试。 一下。 价格是1。6元。 你看。 是不是。 有问题。")

    #expect(result.contains("现在我来测试一下"))
    #expect(result.contains("1.6元"))
    #expect(result.contains("你看是不是有问题"))
    #expect(result.hasSuffix("？"))
}

@Test("final polish v1 keeps short chinese output without forced terminator")
func finalPolishReflowV1KeepsShortUtterancePlain() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("收到")

    #expect(result == "收到")
}

@Test("stores latest lexicon hit details after process")
func storesLatestLexiconHits() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let lexicon = LexiconService(threshold: 3)
    lexicon.addManualTerms(["豆包"])

    let processor = TextProcessor(lexiconService: lexicon, settings: settings)
    let result = processor.process("豆 包测试")

    #expect(result == "豆包测试")
    #expect(processor.lastLexiconHits.contains { hit in
        hit.source == .manualTerm && hit.replacement == "豆包"
    })
}

@Test("does not force sentence terminator for likely unfinished chinese sentence")
func doesNotForceTerminatorForUnfinishedSentence() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("我先说一下然后")

    #expect(!result.hasSuffix("。"))
    #expect(result.hasSuffix("然后"))
}

@Test("connector scene keeps comma instead of hard sentence break in final polish")
func connectorSceneUsesCommaInsteadOfPeriod() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("我们先看下需求。然后确认排期")

    #expect(result.contains("，然后"))
    #expect(!result.contains("。然后"))
}

@Test("short complete chinese sentences keep hard break after conservative merge")
func shortCompleteSentencesKeepHardBreak() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("今天下雨。我们改线上。")

    #expect(result.contains("今天下雨。我们改线上。"))
    #expect(!result.contains("今天下雨，我们改线上。"))
}

@Test("numeric unit and percentage contexts are protected from wrong segmentation")
func protectsNumericContextsInFinalPolish() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("这款镜头重1。6公斤，折扣是12。5％，预算12,345元")

    #expect(result.contains("1.6公斤"))
    #expect(result.contains("12.5％"))
    #expect(result.contains("12345元"))
}

@Test("pre punctuation numeric guard keeps date time and duration stable")
func keepsDateTimeAndDurationStableBeforePunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)
    settings.set(false, forKey: SettingsKeys.preserveCloudRawPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("会议在2026。03。03 下午 09：30 开始 时长1。5小时")

    #expect(result.contains("2026.03.03"))
    #expect(result.contains("9:30"))
    #expect(result.contains("1.5小时"))
}

@Test("preview normalizes chinese grouped integers and time presentation")
func previewNormalizesChineseGroupedIntegersAndTimePresentation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.processForPreview("现在的时间是09：30，预算12,345元，这个文档有2,491个字符")

    #expect(result.contains("9:30"))
    #expect(result.contains("12345元"))
    #expect(result.contains("2491个字符"))
}

@Test("contextual pronoun repair does not rewrite human sentence")
func contextualPronounRepairKeepsHumanSubject() {
    let settings = InMemorySettingsStore()
    settings.set(true, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("他躲哪去了一直躲着的吗一下午。")

    #expect(result.contains("他躲哪去"))
    #expect(!result.contains("它躲哪去"))
}

@Test("pre punctuation numeric guard keeps metric units stable")
func keepsMetricUnitsStableBeforePunctuation() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("包裹重3。5kg 长12。0cm 距离1。2km")

    #expect(result.contains("3.5kg"))
    #expect(result.contains("12.0cm"))
    #expect(result.contains("1.2km"))
}

@Test("sample driven numeric series keeps standalone decimal untouched")
func sampleDrivenNumericSeriesKeepsStandaloneDecimal() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("我现在说数字120.10，看看这个小数会不会被拆开")

    #expect(result.contains("数字120.10"))
    #expect(!result.contains("数字120，10"))
}

@Test("sample driven numeric series keeps isolated pure integer untouched")
func sampleDrivenNumericSeriesKeepsIsolatedPureInteger() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("我现在说数字100000，看看这一串会不会被乱拆")

    #expect(result.contains("数字100000"))
    #expect(!result.contains("数字100，000"))
    #expect(!result.contains("数字1000，00"))
}

@Test("sample driven polish fixes colloquial one forms")
func sampleDrivenPolishFixesColloquialOneForms() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("我还是希望能够在等待的过程中右键鼠标来取消这1次的输入")

    #expect(result.contains("等待的过程中"))
    #expect(result.contains("这一次的输入"))
    #expect(!result.contains("这1次"))
}

@Test("sample driven polish repairs split phrase and keeps center term")
func sampleDrivenPolishRepairsSplitPhraseAndCenterTerm() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("等待过程中的这个转圈图标没有在悬浮球的中，间固定旋转")

    #expect(result.contains("悬浮球的中间固定旋转"))
    #expect(!result.contains("中，间"))
}

@Test("sample driven polish normalizes chinese english spacing around product names")
func sampleDrivenPolishNormalizesChineseEnglishSpacing() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("那么 CodeX 中的分支又是什么意思呢")

    #expect(result.contains("那么CodeX中的分支"))
}

@Test("sample driven process normalizes one-dot-colloquial pattern")
func sampleDrivenProcessNormalizesOneDotColloquialPattern() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("这个等待过程还是有1点点长")

    #expect(result.contains("有一点点长"))
    #expect(!result.contains("1点点"))
}

@Test("sample driven process normalizes fixed colloquial one phrases")
func sampleDrivenProcessNormalizesFixedColloquialOnePhrases() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process(
        "我先改1下文案再补1条说明顺手发1包图片和1些备注然后再看1遍最后排1排"
            + "再过1次流程补1份摘要贴1张截图发1封邮件倒1杯水装1盒样品搬1箱物料"
            + "看1栏数据对1列字段分1类问题跑1轮回归开1场会议走1趟流程"
            + "抓1只样本配1双手套听1声提示留1手方案记1笔备注"
    )

    #expect(result.contains("改一下"))
    #expect(result.contains("一条说明"))
    #expect(result.contains("一包图片"))
    #expect(result.contains("一些备注"))
    #expect(result.contains("看一遍"))
    #expect(result.contains("排一排"))
    #expect(result.contains("过一次流程"))
    #expect(result.contains("一份摘要"))
    #expect(result.contains("一张截图"))
    #expect(result.contains("一封邮件"))
    #expect(result.contains("一杯水"))
    #expect(result.contains("一盒样品"))
    #expect(result.contains("一箱物料"))
    #expect(result.contains("一栏数据"))
    #expect(result.contains("一列字段"))
    #expect(result.contains("一类问题"))
    #expect(result.contains("一轮回归"))
    #expect(result.contains("一场会议"))
    #expect(result.contains("一趟流程"))
    #expect(result.contains("一只样本"))
    #expect(result.contains("一双手套"))
    #expect(result.contains("一声提示"))
    #expect(result.contains("一手方案"))
    #expect(result.contains("一笔备注"))
    #expect(!result.contains("1下"))
    #expect(!result.contains("1条"))
    #expect(!result.contains("1包"))
    #expect(!result.contains("1些"))
    #expect(!result.contains("1遍"))
    #expect(!result.contains("1排"))
    #expect(!result.contains("1次"))
    #expect(!result.contains("1份"))
    #expect(!result.contains("1张"))
    #expect(!result.contains("1封"))
    #expect(!result.contains("1杯"))
    #expect(!result.contains("1盒"))
    #expect(!result.contains("1箱"))
    #expect(!result.contains("1栏"))
    #expect(!result.contains("1列"))
    #expect(!result.contains("1类"))
    #expect(!result.contains("1轮"))
    #expect(!result.contains("1场"))
    #expect(!result.contains("1趟"))
    #expect(!result.contains("1只"))
    #expect(!result.contains("1双"))
    #expect(!result.contains("1声"))
    #expect(!result.contains("1手"))
    #expect(!result.contains("1笔"))
}

@Test("sample driven final polish splits enumerated list markers into separate clauses")
func sampleDrivenFinalPolishSplitsEnumeratedListMarkers() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText(
        "我希望你能对它进行优化。1是将显示主窗口改为设置，二是将从剪贴板学习纠错这个选项删除，三是给软件加上图标"
    )

    #expect(result.contains("。1 将显示主窗口改为设置。2 将从剪贴板学习纠错这个选项删除。3 给软件加上图标。"))
}

@Test("sample driven process normalizes workout metrics")
func sampleDrivenProcessNormalizesWorkoutMetrics() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("今天一共训练了一小时06分，总牵卡消耗4341000卡，平均心率是118分钟每次")

    #expect(result.contains("1小时6分"))
    #expect(result.contains("总千卡消耗434千卡"))
    #expect(result.contains("平均心率是118次/分"))
}

@Test("sample driven final polish inserts inline question break before pronoun continuation")
func sampleDrivenFinalPolishInsertsInlineQuestionBreak() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("你能看到当前Pro版统计页面顶部的累计消费分布卡片吗它好像变窄了")

    #expect(result.contains("累计消费分布卡片吗？它好像变窄了"))
}

@Test("sample driven process normalizes common tool names")
func sampleDrivenProcessNormalizesCommonToolNames() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("open claw已经装好了，但是我还不太会在obsidian里用skills")

    #expect(result.contains("OpenClaw已经装好了"))
    #expect(result.contains("Obsidian里用Skills"))
}

@Test("sample driven process normalizes fragmented tool names and cloud terms")
func sampleDrivenProcessNormalizesFragmentedToolNamesAndCloudTerms() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(false, forKey: SettingsKeys.autoPunctuation)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.process("open c，law已经装好了，现在去obsidian里看saysomething和cloudkit")

    #expect(result.contains("OpenClaw已经装好了"))
    #expect(result.contains("Obsidian里看Say Something和CloudKit"))
}

@Test("sample driven final polish splits adjacent questions and keeps final sentence terminator")
func sampleDrivenFinalPolishSplitsAdjacentQuestions() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("你点外卖吃了吗晚上要1起吃饭吗我现在准备健身")

    #expect(result == "你点外卖吃了吗？晚上要一起吃饭吗？我现在准备健身。")
}

@Test("sample driven final polish repairs split artifacts around card question")
func sampleDrivenFinalPolishRepairsSplitArtifactsAroundCardQuestion() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("你能看到当前Pro版统计页面顶部的累计消费分，布卡片吗他好像变窄了")

    #expect(result.contains("累计消费分布卡片吗？它好像变窄了"))
}

@Test("sample driven final polish normalizes detail request lead-in")
func sampleDrivenFinalPolishNormalizesDetailRequestLeadIn() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("一个新的细节优化需求啊在免费版统计页面app语言设置为中文时")

    #expect(result.contains("一个新的细节优化需求：在免费版统计页面app语言设置为中文时"))
}

@Test("sample driven final polish repairs screenshot explanation clauses")
func sampleDrivenFinalPolishRepairsScreenshotExplanationClauses() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText(
        "这一次请你先不要直接改代码先好好理解一下我的截图你看左边统计的页面他被1个我用红线标出来的纯色块儿给盖住了我希望统计页面不要被其他元素干扰只显示原本的画面"
    )

    #expect(result.contains("这一次请你先不要直接改代码，先好好理解一下我的截图"))
    #expect(result.contains("你看左边统计的页面，它"))
    #expect(result.contains("被一个我用红线标出来的纯色块儿给盖住了"))
    #expect(result.contains("其他元素干扰，只显示原本的画面"))
    #expect(!result.contains("被1个"))
}

@Test("sample driven final polish repairs strategy summary narration")
func sampleDrivenFinalPolishRepairsStrategySummaryNarration() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("扩充了短语防误切保护新增中文语境下中，英混排边界空格清理新增连接词语断句逗号的策略")

    #expect(result.contains("扩充了短语防误切保护，新增"))
    #expect(result.contains("中英混排边界空格清理，新增"))
}

@Test("question ending uses question mark after final polish")
func questionEndingUsesQuestionMark() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("你现在方便看一下吗。")

    #expect(result.hasSuffix("？"))
}

@Test("weak interrogative wording does not force question mark")
func weakInterrogativeWordingKeepsPeriod() {
    let settings = InMemorySettingsStore()
    settings.set(false, forKey: SettingsKeys.removeFillers)
    settings.set(true, forKey: SettingsKeys.autoPunctuation)
    settings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)

    let processor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: settings)
    let result = processor.polishFinalText("我怎么感觉今天有点冷。")

    #expect(result.hasSuffix("。"))
    #expect(!result.hasSuffix("？"))
}

@Test("adaptive punctuation profile changes output when enabled")
func adaptivePunctuationProfileAffectsOutput() {
    let baselineSettings = InMemorySettingsStore()
    baselineSettings.set(false, forKey: SettingsKeys.removeFillers)
    baselineSettings.set(true, forKey: SettingsKeys.autoPunctuation)
    baselineSettings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)
    baselineSettings.set(false, forKey: SettingsKeys.enableAdaptivePunctuation)

    let adaptiveSettings = InMemorySettingsStore()
    adaptiveSettings.set(false, forKey: SettingsKeys.removeFillers)
    adaptiveSettings.set(true, forKey: SettingsKeys.autoPunctuation)
    adaptiveSettings.set(PunctuationStyle.chinese.rawValue, forKey: SettingsKeys.punctuationStyle)
    adaptiveSettings.set(true, forKey: SettingsKeys.enableAdaptivePunctuation)

    let profile = PunctuationUserProfile(
        commaAggressiveness: 0.2,
        questionBias: 0.1,
        shortSentenceBias: -1.0,
        stylePreference: .mixed,
        learnedSamples: 8
    )
    let provider = StubPunctuationProfileProvider(profile: profile)

    let baselineProcessor = TextProcessor(lexiconService: LexiconService(threshold: 3), settings: baselineSettings)
    let adaptiveProcessor = TextProcessor(
        lexiconService: LexiconService(threshold: 3),
        settings: adaptiveSettings,
        punctuationProfileProvider: provider
    )

    let baseline = baselineProcessor.process("今天同步这个排期")
    let adaptive = adaptiveProcessor.process("今天同步这个排期")

    #expect(baseline.hasSuffix("。"))
    #expect(!adaptive.hasSuffix("。"))
}
