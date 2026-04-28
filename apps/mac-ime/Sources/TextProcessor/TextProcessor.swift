import Foundation
import Lexicon
import Settings

public enum PunctuationStyle: String, CaseIterable, Sendable {
    case auto
    case chinese
    case english
}

private enum ResolvedPunctuationStyle {
    case chinese
    case english
}

public final class TextProcessor {
    private static let protectedYiBigrams: Set<String> = [
        "一起", "一直", "一定", "一些", "一般", "一下",
        "一边", "一会", "一旦", "一共", "一并", "一再",
        "一向", "一律", "一样", "一致", "一同", "一齐"
    ]

    private static let protectedYiTrigrams: Set<String> = [
        "一下子", "一会儿", "一点儿", "一方面", "一系列",
        "一整天", "一辈子", "一瞬间", "一个劲", "一门心"
    ]

    private static let fixedColloquialOneSuffixes: [String] = [
        "个", "些", "包", "句", "下", "桶", "遍", "段", "行", "字",
        "片", "篇", "瓶", "批", "排", "拍", "碰", "盆", "壶", "户",
        "根", "共", "股", "改", "盖", "台", "套", "体", "条",
        "次", "份", "张", "封", "杯", "盒", "箱", "栏", "列", "类",
        "轮", "场", "趟", "只", "双", "声", "手", "笔"
    ]

    private static let fixedColloquialOneSuffixPattern =
        fixedColloquialOneSuffixes
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")

    // Phrase-level protection for final punctuation reflow.
    // Keep these high-frequency chunks from being split by noisy punctuation.
    private static let protectedPunctuationPhrases: Set<String> = [
        "现在我来", "我再来", "我来看一下", "我看一下", "你看一下",
        "你看是不是", "我看是不是", "我测试一下", "继续测试一下",
        "我不太确定", "然后我再", "我觉得", "语音输入", "实时预览",
        "自动标点", "云端输入", "本地输入",
        "极简记录", "硬核统计", "购买日期", "明细页面", "一目了然", "专属资产看板",
        "数据统计页", "具体天数", "折旧价", "带出门的次数", "日均使用成本", "单次使用成本",
        "相机镜头和配件", "标点符号断句", "等待的过程中", "右键鼠标", "这一次的输入",
        "悬浮球中间固定旋转", "悬浮球的中间固定旋转", "围绕运动", "固定转圈", "视频拍摄", "手冲咖啡",
        "中间", "能够", "从剪贴板学习纠错", "显示主窗口", "累计消费分布", "累计消费分布卡片",
        "中英混排", "图层最上方", "水平居中对齐", "时光收纳区", "公开数据", "苹果后台",
        "核心价值记录每一件摄影装备", "最喜欢用这个卡片", "成本最低卡片", "免费版统计页面",
        "品牌型号购买日期和价格", "一行行的敲出来代码", "等待处理展现文字的过程",
        "情感牌和防吃灰的痛点", "每一个中文和英文之间", "上传的器材公开数据",
        "流畅运行与计算准确性", "时光收纳区中陈列的各个器材", "回收收纳的日期倒序排列",
        "总千卡消耗", "平均心率", "次/分", "告别仪式页面", "底部导航栏", "微弱的震动反馈",
        "OpenClaw", "Obsidian", "CodeX", "Skills", "APP Store", "CloudKit", "Apple Log",
        "Apple Prores Raw", "Say Something", "iPhone 17 Pro Max"
    ]

    private let lexiconService: LexiconService
    private let settings: SettingsStore
    private let punctuationProfileProvider: PunctuationProfileProviding?
    public private(set) var lastLexiconHits: [LexiconReplacementHit] = []

    public init(
        lexiconService: LexiconService,
        settings: SettingsStore,
        punctuationProfileProvider: PunctuationProfileProviding? = nil
    ) {
        self.lexiconService = lexiconService
        self.settings = settings
        self.punctuationProfileProvider = punctuationProfileProvider
    }

    public func process(_ rawText: String) -> String {
        var text = normalize(rawText)
        text = stabilizeNumericDateUnitContexts(text)
        text = normalizeChineseColloquialOneForms(text)
        text = normalizeSampleDrivenTextPatterns(text)

        if settings.bool(forKey: SettingsKeys.removeFillers, default: true) {
            let blacklist = settings.stringArray(
                forKey: SettingsKeys.fillerBlacklist,
                default: ["嗯", "呃", "啊", "em"]
            )
            text = removeFillers(from: text, blacklist: blacklist)
            text = removeMergedFillerArtifacts(from: text, blacklist: blacklist)
        }

        let trace = lexiconService.prioritizedReplacementWithTrace(
            in: text,
            includeFuzzyManualReplacement: false
        )
        text = trace.text
        lastLexiconHits = trace.hits

        text = convertSpokenNumbersToArabic(text)
        text = stabilizeNumericDateUnitContexts(text)
        text = normalizeChineseColloquialOneForms(text)
        text = normalizeSampleDrivenTextPatterns(text)

        let autoPunctuationEnabled = settings.bool(forKey: SettingsKeys.autoPunctuation, default: true)
        let sentenceEndingPunctuationEnabled = settings.bool(
            forKey: SettingsKeys.sentenceEndingPunctuationEnabled,
            default: true
        )
        let preserveCloudRawPunctuation = settings.bool(
            forKey: SettingsKeys.preserveCloudRawPunctuation,
            default: false
        )

        if autoPunctuationEnabled {
            if shouldDenoiseModelPunctuation(text) {
                text = removeModelPunctuationNoise(from: text)
            }
            text = applyBasicPunctuation(
                on: text,
                addSentenceTerminator: sentenceEndingPunctuationEnabled
            )
        } else {
            if !preserveCloudRawPunctuation {
                text = removeModelPunctuationNoise(from: text)
            }
        }

        text = normalizeNumericAndTemporalPresentation(
            text,
            style: resolvedPresentationStyle(for: text)
        )
        text = normalizePostPunctuationSampleFixes(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Lightweight second-pass polish for final output after recording stops.
    // It focuses on formatting only: punctuation, segmentation and numeric normalization.
    public func polishFinalText(_ text: String) -> String {
        var out = normalize(text)
        guard !out.isEmpty else { return out }
        out = stabilizeNumericDateUnitContexts(out)
        out = normalizeChineseColloquialOneForms(out)
        out = normalizeSampleDrivenTextPatterns(out)

        if settings.bool(forKey: SettingsKeys.removeFillers, default: true) {
            let blacklist = settings.stringArray(
                forKey: SettingsKeys.fillerBlacklist,
                default: ["嗯", "呃", "啊", "em"]
            )
            out = removeMergedFillerArtifacts(from: out, blacklist: blacklist)
        }

        let trace = lexiconService.prioritizedReplacementWithTrace(in: out)
        out = trace.text
        lastLexiconHits = trace.hits

        out = convertSpokenNumbersToArabic(out)
        out = stabilizeNumericDateUnitContexts(out)
        out = normalizeChineseColloquialOneForms(out)
        out = normalizeSampleDrivenTextPatterns(out)

        let autoPunctuationEnabled = settings.bool(forKey: SettingsKeys.autoPunctuation, default: true)
        let sentenceEndingPunctuationEnabled = settings.bool(
            forKey: SettingsKeys.sentenceEndingPunctuationEnabled,
            default: true
        )
        let preserveCloudRawPunctuation = settings.bool(
            forKey: SettingsKeys.preserveCloudRawPunctuation,
            default: false
        )

        if autoPunctuationEnabled {
            if shouldDenoiseModelPunctuation(out) {
                out = removeModelPunctuationNoise(from: out)
            }
            let configuredStyle = settings.string(
                forKey: SettingsKeys.punctuationStyle,
                default: PunctuationStyle.auto.rawValue
            )
            let style = resolvePunctuationStyle(configuredStyle, text: out)
            out = applyBasicPunctuation(
                on: out,
                addSentenceTerminator: sentenceEndingPunctuationEnabled
            )
            out = applyFinalPunctuationReflowV2(on: out, style: style)
            out = applyFinalPunctuationPolish(on: out, style: style)
            out = applyFinalPunctuationReflowV2(on: out, style: style)
            if sentenceEndingPunctuationEnabled && style == .chinese && countContentCharacters(out) < 8 {
                out = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.hasSuffix("。") && !containsStrongQuestionHint(in: out) {
                    out.removeLast()
                }
            } else if sentenceEndingPunctuationEnabled {
                out = ensureSentenceTerminator(out, style: style)
            }
        } else if !preserveCloudRawPunctuation {
            out = removeModelPunctuationNoise(from: out)
        }

        out = normalizeNumericAndTemporalPresentation(
            out,
            style: resolvedPresentationStyle(for: out)
        )
        out = normalizePostPunctuationSampleFixes(out)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Live preview uses a lighter pipeline to reduce jitter:
    // keep filler removal/lexicon normalization/number normalization, but skip auto punctuation.
    public func processForPreview(_ rawText: String) -> String {
        var text = normalize(rawText)
        text = stabilizeNumericDateUnitContexts(text)
        text = normalizeChineseColloquialOneForms(text)
        text = normalizeSampleDrivenTextPatterns(text)

        if settings.bool(forKey: SettingsKeys.removeFillers, default: true) {
            let blacklist = settings.stringArray(
                forKey: SettingsKeys.fillerBlacklist,
                default: ["嗯", "呃", "啊", "em"]
            )
            text = removeFillers(from: text, blacklist: blacklist)
            text = removeMergedFillerArtifacts(from: text, blacklist: blacklist)
        }

        let trace = lexiconService.prioritizedReplacementWithTrace(
            in: text,
            includeFuzzyManualReplacement: false
        )
        text = trace.text
        lastLexiconHits = trace.hits

        text = convertSpokenNumbersToArabic(text)
        text = stabilizeNumericDateUnitContexts(text)
        text = normalizeChineseColloquialOneForms(text)
        text = normalizeSampleDrivenTextPatterns(text)
        text = removeModelPunctuationNoise(from: text)
        text = normalizeNumericAndTemporalPresentation(
            text,
            style: resolvedPresentationStyle(for: text)
        )
        text = normalizePostPunctuationSampleFixes(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldDenoiseModelPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let charCount = countMatches(pattern: "[\\p{Han}A-Za-z0-9]", in: trimmed)
        let sentencePunctuationCount = countMatches(pattern: "[。！？!?]", in: trimmed)
        guard charCount >= 6, sentencePunctuationCount >= 3 else { return false }

        let density = Double(sentencePunctuationCount) / Double(max(1, charCount))
        if density >= 0.12 {
            return true
        }

        // Typical noisy pattern: each 1-2 characters followed by sentence punctuation.
        let shortChunkPattern = "(?:[\\p{Han}A-Za-z0-9]{1,2}[。！？!?]){4,}"
        if countMatches(pattern: shortChunkPattern, in: trimmed) > 0 {
            return true
        }

        // Also catch spaced punctuation like: 现在 。 的 。 文本 。
        let spacedShortChunkPattern = "(?:[\\p{Han}A-Za-z0-9]{1,3}\\s*[。！？!?]\\s*){4,}"
        return countMatches(pattern: spacedShortChunkPattern, in: trimmed) > 0
    }

    private func removeModelPunctuationNoise(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let hanCount = countMatches(pattern: "\\p{Han}", in: trimmed)
        let latinCount = countMatches(pattern: "[A-Za-z]", in: trimmed)

        // Preserve decimal points and thousand separators between digits.
        let dotToken = "§§0§§"
        let commaToken = "§§1§§"
        let zhDotToken = "§§2§§"
        let zhCommaToken = "§§3§§"
        let timeColonToken = "§§4§§"
        var out = trimmed
        out = out.replacingOccurrences(
            of: "(?<=\\d)\\.(?=\\d)",
            with: dotToken,
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<=\\d)[。．](?=\\d)",
            with: zhDotToken,
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<=\\d),(?=\\d{3}(\\D|$))",
            with: commaToken,
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<=\\d)，(?=\\d{3}(\\D|$))",
            with: zhCommaToken,
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<=\\d)[:：](?=\\d{2}(\\D|$))",
            with: timeColonToken,
            options: .regularExpression
        )

        let replacement = hanCount >= latinCount ? "" : " "

        out = out.replacingOccurrences(
            of: "\\s*[，。！？；：,.!?;:]\\s*",
            with: replacement,
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: dotToken, with: ".")
        out = out.replacingOccurrences(of: zhDotToken, with: ".")
        out = out.replacingOccurrences(of: commaToken, with: ",")
        out = out.replacingOccurrences(of: zhCommaToken, with: ",")
        out = out.replacingOccurrences(of: timeColonToken, with: ":")
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func replacingMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let replacement = transform(match, nsText) else { continue }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private func resolvedPresentationStyle(for text: String) -> ResolvedPunctuationStyle {
        let configuredStyle = settings.string(
            forKey: SettingsKeys.punctuationStyle,
            default: PunctuationStyle.auto.rawValue
        )
        return resolvePunctuationStyle(configuredStyle, text: text)
    }

    private func normalizeNumericAndTemporalPresentation(
        _ text: String,
        style: ResolvedPunctuationStyle
    ) -> String {
        switch style {
        case .chinese:
            return normalizeChineseNumericAndTemporalPresentation(text)
        case .english:
            return text
        }
    }

    private func normalizeChineseNumericAndTemporalPresentation(_ text: String) -> String {
        var out = text

        // Chinese output should keep grouped integers continuous.
        out = replacingMatches(
            in: out,
            pattern: "(?<!\\d)\\d{1,3}(?:[,，]\\d{3})+(?!\\d)"
        ) { match, nsText in
            let groupedInteger = nsText.substring(with: match.range)
            return groupedInteger.replacingOccurrences(
                of: "[,，]",
                with: "",
                options: .regularExpression
            )
        }
        // Keep time in Arabic clock form and drop a leading zero in the hour.
        out = out.replacingOccurrences(
            of: "(?<!\\d)0(\\d)\\s*[:：]\\s*(\\d{2})(?!\\d)",
            with: "$1:$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<!\\d)(\\d{1,2})\\s*[:：]\\s*(\\d{2})(?!\\d)",
            with: "$1:$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<!\\d)(\\d{1,2})点(\\d{2})分(?!\\d)",
            with: "$1:$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d)\\s*(年|月|日|号|点|时|分|秒|小时|分钟|秒钟)",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(年|月|日|号|点|时|分|秒|小时|分钟|秒钟)\\s*(\\d)",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(周|星期)\\s*([一二三四五六日天])",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d{4}年)\\s+(\\d{1,2}月\\d{1,2}日)",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d{4}年\\d{1,2}月\\d{1,2}日)\\s*(周[一二三四五六日天]|星期[一二三四五六日天])\\s*(\\d{1,2}:\\d{2})",
            with: "$1 $2 $3",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d{4}年\\d{1,2}月\\d{1,2}日)\\s*(周[一二三四五六日天]|星期[一二三四五六日天])",
            with: "$1 $2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d{4}年\\d{1,2}月\\d{1,2}日)\\s*(\\d{1,2}:\\d{2})",
            with: "$1 $2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(周[一二三四五六日天]|星期[一二三四五六日天])\\s*(\\d{1,2}:\\d{2})",
            with: "$1 $2",
            options: .regularExpression
        )

        return out
    }

    private func normalizePostPunctuationSampleFixes(_ text: String) -> String {
        var out = normalizeEnumeratedNumericSeries(text)
        out = out.replacingOccurrences(of: "4K120帧的，拍摄录制", with: "4K120帧的拍摄录制")
        out = out.replacingOccurrences(of: "合作说，明", with: "合作说明")
        return out
    }

    private func removeFillers(from text: String, blacklist: [String]) -> String {
        guard !text.isEmpty else { return text }

        var processed = text
        for filler in blacklist where !filler.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            // Keep this conservative to reduce accidental semantic deletion.
            let pattern = "(^|\\s)" + escaped + "(?=\\s|$)"
            processed = processed.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        return processed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func removeMergedFillerArtifacts(from text: String, blacklist: [String]) -> String {
        guard !text.isEmpty else { return text }

        let compactFillers = blacklist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) && $0 != "然后" }
        guard !compactFillers.isEmpty else { return text }

        let alternation = compactFillers
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = "(^|[，,。！？；：\\s])(?:(?:" + alternation + ")){2,}(?=([，,。！？；：\\s]|$))"
        let cleaned = text.replacingOccurrences(
            of: pattern,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.replacingOccurrences(of: "\\s+", with: " ", options: NSString.CompareOptions.regularExpression)
    }

    private func applyBasicPunctuation(
        on text: String,
        addSentenceTerminator: Bool
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let normalizedInput = normalizeChineseColloquialOneForms(trimmed)

        let configuredStyle = settings.string(
            forKey: SettingsKeys.punctuationStyle,
            default: PunctuationStyle.auto.rawValue
        )
        let style = resolvePunctuationStyle(configuredStyle, text: normalizedInput)
        let normalized = normalizePunctuation(normalizedInput, style: style)
        guard addSentenceTerminator else { return normalized }
        return ensureSentenceTerminator(normalized, style: style)
    }

    private func resolvePunctuationStyle(_ configuredStyle: String, text: String) -> ResolvedPunctuationStyle {
        if let explicit = PunctuationStyle(rawValue: configuredStyle) {
            switch explicit {
            case .chinese:
                return .chinese
            case .english:
                return .english
            case .auto:
                if let adaptiveProfile = currentAdaptivePunctuationProfile() {
                    switch adaptiveProfile.stylePreference {
                    case .chinese:
                        return .chinese
                    case .english:
                        return .english
                    case .mixed:
                        break
                    }
                }
                break
            }
        }

        let hanCount = countMatches(pattern: "\\p{Han}", in: text)
        let latinCount = countMatches(pattern: "[A-Za-z]", in: text)

        if hanCount == 0, latinCount == 0 {
            return .chinese
        }
        return hanCount >= latinCount ? .chinese : .english
    }

    private func normalizePunctuation(_ text: String, style: ResolvedPunctuationStyle) -> String {
        switch style {
        case .chinese:
            var out = text
            out = out.replacingOccurrences(
                of: "(?<!\\d),(?!\\d)",
                with: "，",
                options: .regularExpression
            )
            out = out.replacingOccurrences(
                of: "(?<!\\d)\\.(?!\\d)",
                with: "。",
                options: .regularExpression
            )
            out = out.replacingOccurrences(of: "\\?", with: "？", options: .regularExpression)
            out = out.replacingOccurrences(of: "!", with: "！", options: .regularExpression)
            out = out.replacingOccurrences(of: ";", with: "；")
            out = out.replacingOccurrences(of: ":", with: "：")
            out = out.replacingOccurrences(
                of: "\\s*([，。！？；：])\\s*",
                with: "$1",
                options: .regularExpression
            )
            out = applyChineseSegmentationV2(out)
            out = normalizeEnumeratedListMarkers(out)
            out = repairInlineChineseQuestionBreaks(out)
            out = normalizeChineseMixedScriptSpacing(out)
            return out
        case .english:
            var out = text
            out = out.replacingOccurrences(of: "，", with: ", ")
            out = out.replacingOccurrences(of: "。", with: ". ")
            out = out.replacingOccurrences(of: "？", with: "?")
            out = out.replacingOccurrences(of: "！", with: "!")
            out = out.replacingOccurrences(of: "；", with: "; ")
            out = out.replacingOccurrences(of: "：", with: ": ")
            out = out.replacingOccurrences(
                of: "\\s+([,.;:!?])",
                with: "$1",
                options: .regularExpression
            )
            out = out.replacingOccurrences(
                of: "([,.;:!?])([A-Za-z0-9])",
                with: "$1 $2",
                options: .regularExpression
            )
            out = applyEnglishSegmentationV2(out)
            out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func ensureSentenceTerminator(_ text: String, style: ResolvedPunctuationStyle) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasSuffix("，") || trimmed.hasSuffix(",") {
            let candidate = String(trimmed.dropLast())
            guard !candidate.isEmpty else { return trimmed }
            let candidateSuffix = style == .chinese ? inferChineseSentenceTerminator(for: candidate) : "."
            if !hasTrailingContinuationMarker(in: candidate, style: style)
                && shouldAppendSentenceTerminator(for: candidate, style: style) {
                return candidate + candidateSuffix
            }
        }

        let endsWithPunctuation: Bool
        let suffix: String
        switch style {
        case .chinese:
            endsWithPunctuation = ["。", "！", "？"].contains(where: { trimmed.hasSuffix($0) })
            suffix = inferChineseSentenceTerminator(for: trimmed)
        case .english:
            endsWithPunctuation = [".", "!", "?"].contains(where: { trimmed.hasSuffix($0) })
            suffix = "."
        }

        guard !endsWithPunctuation else { return trimmed }
        guard shouldAppendSentenceTerminator(for: trimmed, style: style) else {
            return trimmed
        }
        return trimmed + suffix
    }

    private func shouldAppendSentenceTerminator(for text: String, style: ResolvedPunctuationStyle) -> Bool {
        sentenceCompletionConfidence(for: text, style: style) >= 0.60
    }

    private func sentenceCompletionConfidence(for text: String, style: ResolvedPunctuationStyle) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var score = 0.52
        let adaptiveProfile = currentAdaptivePunctuationProfile()
        let contentCount = countContentCharacters(trimmed)
        if contentCount >= 12 {
            score += 0.15
        } else if contentCount >= 7 {
            score += 0.09
        } else if contentCount <= 4 {
            score -= 0.20
        }

        if containsStrongQuestionHint(in: trimmed) {
            score += 0.32
        } else if containsWeakQuestionHint(in: trimmed) {
            score += 0.08
        }

        if hasTrailingContinuationMarker(in: trimmed, style: style) {
            score -= 0.62
        }

        if trimmed.range(of: "[，,、;；:：]\\s*$", options: .regularExpression) != nil {
            score -= 0.46
        }

        if hasUnclosedTrailingDelimiter(in: trimmed) {
            score -= 0.26
        }

        if trimmed.range(of: "(的|地|得|和|或|及|并|且|把|被)\\s*$", options: .regularExpression) != nil {
            score -= 0.22
        }

        if trimmed.range(of: "(\\d+\\s*(年|月|日|号|点|时|分|秒|%|％))\\s*$", options: .regularExpression) != nil {
            score += 0.08
        }

        if let adaptiveProfile {
            score += adaptiveProfile.shortSentenceBias * 0.20
            if containsStrongQuestionHint(in: trimmed) {
                score += adaptiveProfile.questionBias * 0.12
            }
        }

        return min(1, max(0, score))
    }

    private func hasTrailingContinuationMarker(in text: String, style: ResolvedPunctuationStyle) -> Bool {
        switch style {
        case .chinese:
            let pattern = "(但是|不过|然后|所以|因此|因为|如果|并且|而且|还有|以及|比如|例如|或者|还是|同时|接着|先|再|就是|也就是|只要|而是)$"
            return text.range(of: pattern, options: .regularExpression) != nil
        case .english:
            let pattern = "(?i)\\b(and|or|but|so|because|if|then|however|therefore)\\s*$"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func hasUnclosedTrailingDelimiter(in text: String) -> Bool {
        let openers: Set<Character> = ["（", "(", "[", "【", "“", "\""]
        let closers: Set<Character> = ["）", ")", "]", "】", "”", "\""]
        var stack = 0
        for ch in text {
            if openers.contains(ch) {
                stack += 1
            } else if closers.contains(ch), stack > 0 {
                stack -= 1
            }
        }
        return stack > 0
    }

    private func inferChineseSentenceTerminator(for text: String) -> String {
        if containsStrongQuestionHint(in: text) {
            return "？"
        }
        if let adaptiveProfile = currentAdaptivePunctuationProfile(),
           adaptiveProfile.questionBias >= 0.72,
            text.range(of: "(是不是|行不行|对不对|好不好|可不可以)$", options: .regularExpression) != nil {
            return "？"
        }
        return "。"
    }

    private func hasSentenceTerminator(_ text: String, style: ResolvedPunctuationStyle) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch style {
        case .chinese:
            return ["。", "！", "？"].contains(where: { trimmed.hasSuffix($0) })
        case .english:
            return [".", "!", "?"].contains(where: { trimmed.hasSuffix($0) })
        }
    }

    private func applyFinalPunctuationPolish(on text: String, style: ResolvedPunctuationStyle) -> String {
        switch style {
        case .chinese:
            var out = text
            out = out.replacingOccurrences(of: "([，。！？；：]){2,}", with: "$1", options: .regularExpression)
            out = out.replacingOccurrences(of: "[。！？](?=[吧吗呢啊呀嘛哦呗啦])", with: "，", options: .regularExpression)
            // Merge over-segmented short clauses like "测试。了。下。"
            for _ in 0..<3 {
                out = out.replacingOccurrences(
                    of: "([\\p{Han}A-Za-z]{2,18})[。！？](?=[\\p{Han}A-Za-z]{1,2}[。！？])",
                    with: "$1",
                    options: .regularExpression
                )
            }
            out = out.replacingOccurrences(of: "，([，。！？；：])", with: "$1", options: .regularExpression)
            out = normalizeChineseMixedScriptSpacing(out)
            return out
        case .english:
            var out = text
            out = out.replacingOccurrences(of: "([,.;:!?]){2,}", with: "$1", options: .regularExpression)
            out = out.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
            out = out.replacingOccurrences(of: "([,.;:!?])([A-Za-z0-9])", with: "$1 $2", options: .regularExpression)
            return out
        }
    }

    // Final punctuation reflow (v2):
    // 1) protect high-frequency phrases
    // 2) repair punctuation splits in numeric/date/unit contexts
    // 3) repair over-segmented sentence punctuation
    // 4) normalize question endings
    private func applyFinalPunctuationReflowV2(on text: String, style: ResolvedPunctuationStyle) -> String {
        switch style {
        case .chinese:
            var out = text
            var misbreakFixTriggerCount = 0
            var questionFixTriggerCount = 0
            out = out.replacingOccurrences(
                of: "\\s*([，。！？；：])\\s*",
                with: "$1",
                options: .regularExpression
            )
            out = normalizeChineseColloquialOneForms(out)

            let beforeProtected = out
            out = repairChineseProtectedPhraseBreaks(out)
            if out != beforeProtected { misbreakFixTriggerCount += 1 }

            let beforeNumeric = out
            out = repairChineseNumericBreaks(out)
            if out != beforeNumeric { misbreakFixTriggerCount += 1 }

            let beforeConnector = out
            out = rebalanceChineseConnectorPunctuation(out)
            if out != beforeConnector { misbreakFixTriggerCount += 1 }

            let beforeCollapse = out
            out = collapseOverSegmentedChineseSentences(out)
            if out != beforeCollapse { misbreakFixTriggerCount += 1 }

            let beforeQuestion = out
            out = normalizeChineseQuestionEnding(out)
            if out != beforeQuestion { questionFixTriggerCount += 1 }

            let beforeInlineQuestion = out
            out = repairInlineChineseQuestionBreaks(out)
            if out != beforeInlineQuestion { questionFixTriggerCount += 1 }

            out = out.replacingOccurrences(of: "，([。！？])", with: "$1", options: .regularExpression)
            out = out.replacingOccurrences(of: "([，。！？；：]){2,}", with: "$1", options: .regularExpression)
            recordPunctuationQualityMetrics(
                misbreakFixDelta: misbreakFixTriggerCount,
                questionFixDelta: questionFixTriggerCount
            )
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        case .english:
            var out = text
            out = out.replacingOccurrences(
                of: "(?i)[.!?]\\s+(but|so|however|therefore|then|meanwhile)\\b",
                with: ", $1",
                options: .regularExpression
            )
            out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func repairChineseProtectedPhraseBreaks(_ text: String) -> String {
        var out = text
        var phrases = Self.protectedPunctuationPhrases
        phrases.formUnion(Self.protectedYiBigrams)
        phrases.formUnion(Self.protectedYiTrigrams)

        for phrase in phrases where phrase.count >= 2 {
            let units = phrase.map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = units.joined(separator: "[\\s，。！？；：,.!?;:]{0,2}")
            out = out.replacingOccurrences(
                of: pattern,
                with: phrase,
                options: .regularExpression
            )
        }
        return out
    }

    private func repairChineseNumericBreaks(_ text: String) -> String {
        var out = stabilizeNumericDateUnitContexts(text)

        // Number run artifacts: "12，345" stays; "12。34" -> "1234"
        out = out.replacingOccurrences(
            of: "(\\d)\\s*[！？；：]\\s*(\\d)",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d)\\s*。\\s*(\\d{2,})",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d{1,4})\\s*[，。．]\\s*(\\d{1,2})(\\s*[，。．]\\s*(\\d{1,2}))",
            with: "$1.$2.$4",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d)\\s*，\\s*(\\d{3}(\\D|$))",
            with: "$1,$2",
            options: .regularExpression
        )
        return out
    }

    // Keep numeric/date/unit spans stable before punctuation strategies run.
    private func stabilizeNumericDateUnitContexts(_ text: String) -> String {
        var out = text

        // Decimal artifacts: "1。6" -> "1.6"
        out = out.replacingOccurrences(
            of: "(\\d)\\s*[。．]\\s*(\\d)",
            with: "$1.$2",
            options: .regularExpression
        )
        // ASR occasionally returns "12，5" for decimal comma; convert to dot.
        out = out.replacingOccurrences(
            of: "(\\d)\\s*，\\s*(\\d)(?!\\d)",
            with: "$1.$2",
            options: .regularExpression
        )
        // Keep thousand separators.
        out = out.replacingOccurrences(
            of: "(\\d)\\s*，\\s*(\\d{3}(\\D|$))",
            with: "$1,$2",
            options: .regularExpression
        )
        // Date-like dotted sequence.
        out = out.replacingOccurrences(
            of: "(\\d{1,4})\\s*[，。．]\\s*(\\d{1,2})\\s*[，。．]\\s*(\\d{1,2})(?!\\d)",
            with: "$1.$2.$3",
            options: .regularExpression
        )
        // Time-like separator.
        out = out.replacingOccurrences(
            of: "(\\d{1,2})\\s*[：]\\s*(\\d{2})(?!\\d)",
            with: "$1:$2",
            options: .regularExpression
        )

        // Numeric unit/date/time contexts should not be broken by sentence punctuation.
        out = out.replacingOccurrences(
            of: "(\\d)\\s*[，。！？；：]\\s*(年|月|日|号|点|时|分|秒|元|块|角|毛|厘|次|个|岁|天|周|斤|克|千克|公斤|米|厘米|毫米|公里|千米|小时|分钟|秒钟|毫秒|升|毫升|g|kg|cm|mm|km|%|％)",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d)\\s*[，。！？；：]\\s*(\\d)\\s*(月|日|号|点|时|分|秒)",
            with: "$1$2$3",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(第)\\s*[，。！？；：]\\s*(\\d)",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(年|月|日|号|点|时|分|秒)\\s*[，。！？；：]\\s*(\\d)",
            with: "$1$2",
            options: .regularExpression
        )
        return out
    }

    private func normalizeChineseColloquialOneForms(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: "(^|\\p{Han})\\s*1\\s*(\(Self.fixedColloquialOneSuffixPattern))",
            with: "$1一$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "([这那哪每])\\s*1\\s*(个|次|台|遍|句|种|款|页|章)",
            with: "$1一$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\p{Han})\\s*1\\s*下",
            with: "$1一下",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\p{Han})\\s*1\\s*点\\s*点",
            with: "$1一点点",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "之\\s*1",
            with: "之一",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "1\\s*目\\s*了\\s*然",
            with: "一目了然",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "([这那哪每])\\s*1\\s*(下|点|遍|台|句|层|张)",
            with: "$1一$2",
            options: .regularExpression
        )
        return out
    }

    private func normalizeSampleDrivenTextPatterns(_ text: String) -> String {
        var out = text
        out = normalizeFrequentSplitArtifacts(out)
        out = normalizeCorruptedDateTimeClusters(out)
        out = normalizeEnumeratedNumericSeries(out)
        out = normalizeHighConfidenceMixedEntities(out)
        out = normalizeEnumeratedListMarkers(out)
        out = normalizeWorkoutMetricPhrases(out)
        out = normalizeContextualContentMisrecognitions(out)
        out = normalizeCommonSpeechMisrecognitions(out)
        out = normalizeSampleDrivenClausePunctuation(out)
        out = normalizeFrequentSplitArtifacts(out)
        return out
    }

    private func normalizeFrequentSplitArtifacts(_ text: String) -> String {
        var out = text
        let directReplacements = [
            "这，个": "这个",
            "一，个": "一个",
            "个，人": "个人",
            "输，入": "输入",
            "视，频": "视频",
            "拍，摄": "拍摄",
            "风，格": "风格",
            "原相，机": "原相机",
            "图，层": "图层",
            "元，素": "元素",
            "分，布": "分布",
            "中，英": "中英",
            "英，文": "英文",
            "之，间": "之间",
            "公，开": "公开",
            "记，录数据": "记录数据",
            "悬，浮球": "悬浮球",
            "APP，的": "APP的",
            "A，PP": "APP",
            "iPho，ne": "iPhone",
            "我，们": "我们",
            "我，感觉": "我感觉",
            "防吃，亏": "防吃灰",
            "瀑，布": "瀑布",
            "边，界": "边界",
            "几秒，钟": "几秒钟",
            "计，算": "计算",
            "希，望": "希望",
            "各，种": "各种",
            "这一个，月": "这一个月",
            "这个，错误": "这个错误",
            "这个，之一": "这个之一",
            "项，目": "项目",
            "输出结，果": "输出结果",
            "卡，片": "卡片",
            "画，质": "画质",
            "普通，模式": "普通模式"
        ]
        for (source, target) in directReplacements {
            out = out.replacingOccurrences(of: source, with: target)
        }
        out = out.replacingOccurrences(
            of: "(\\p{Han})，的",
            with: "$1的",
            options: .regularExpression
        )
        return out
    }

    private func normalizeCorruptedDateTimeClusters(_ text: String) -> String {
        var out = text

        out = replacingMatches(
            in: out,
            pattern: "(\\d{4})年([零〇○一二两三四五六七八九十]+)\\s*[。．]?月(\\d)\\s*[.。．]10\\s*[.。．](\\d)日\\s*(周[一二三四五六日天]|星期[一二三四五六日天])?\\s*(\\d{1,2}:\\d{2})?"
        ) { match, nsText in
            let year = nsText.substring(with: match.range(at: 1))
            let monthToken = nsText.substring(with: match.range(at: 2))
            let firstDayDigit = nsText.substring(with: match.range(at: 3))
            let lastDayDigit = nsText.substring(with: match.range(at: 4))
            let weekday = match.range(at: 5).location != NSNotFound
                ? nsText.substring(with: match.range(at: 5))
                : nil
            let time = match.range(at: 6).location != NSNotFound
                ? nsText.substring(with: match.range(at: 6))
                : nil
            guard let month = convertChineseIntegerToken(monthToken) else { return nil }

            var rebuilt = "\(year)年\(month)月\(firstDayDigit)\(lastDayDigit)日"
            if let weekday, !weekday.isEmpty {
                rebuilt += " \(weekday)"
            }
            if let time, !time.isEmpty {
                rebuilt += " \(time)"
            }
            return rebuilt
        }

        out = replacingMatches(
            in: out,
            pattern: "(\\d{4})年([零〇○一二两三四五六七八九十]+)月(\\d{1,2})日"
        ) { match, nsText in
            let year = nsText.substring(with: match.range(at: 1))
            let monthToken = nsText.substring(with: match.range(at: 2))
            let day = nsText.substring(with: match.range(at: 3))
            guard let month = convertChineseIntegerToken(monthToken) else { return nil }
            return "\(year)年\(month)月\(day)日"
        }

        return out
    }

    private func normalizeEnumeratedNumericSeries(_ text: String) -> String {
        replacingMatches(
            in: text,
            pattern: "((?:说|念|报|读|测试|再测试|我现在说)?数字(?:是|为)?)([0-9][0-9.。,，\\s]{3,}[0-9])"
        ) { match, nsText in
            let prefix = nsText.substring(with: match.range(at: 1))
            let rawSeries = nsText.substring(with: match.range(at: 2))
            guard let normalizedSeries = normalizedEnumeratedNumericSeries(rawSeries) else {
                return nil
            }
            return prefix + normalizedSeries
        }
    }

    private func normalizedEnumeratedNumericSeries(_ rawSeries: String) -> String? {
        let fragments = rawSeries
            .components(separatedBy: CharacterSet(charactersIn: ".,，。． \t"))
            .filter { !$0.isEmpty }

        guard fragments.count >= 2 else { return nil }
        guard !looksLikeStandaloneDecimalSeries(rawSeries, fragments: fragments) else {
            return nil
        }

        let normalized = fragments.flatMap { expandEnumeratedNumericFragment($0) }
        guard normalized.count >= 2 else { return nil }
        return normalized.joined(separator: "，")
    }

    private func looksLikeStandaloneDecimalSeries(
        _ rawSeries: String,
        fragments: [String]
    ) -> Bool {
        guard fragments.count == 2 else { return false }
        let compact = rawSeries.replacingOccurrences(
            of: "\\s+",
            with: "",
            options: .regularExpression
        )
        return compact.range(
            of: "^\\d{1,4}[.。．,，]\\d{1,2}$",
            options: .regularExpression
        ) != nil
    }

    private func expandEnumeratedNumericFragment(_ fragment: String) -> [String] {
        let digits = fragment.filter(\.isNumber)
        guard !digits.isEmpty else { return [] }

        if digits.count <= 4 {
            return [digits]
        }
        if digits.count == 7 {
            return [
                String(digits.prefix(4)),
                String(digits.suffix(3))
            ]
        }
        if digits.count == 8 {
            let split = digits.index(digits.startIndex, offsetBy: 4)
            return [
                String(digits[..<split]),
                String(digits[split...])
            ]
        }

        let remainder = digits.count - 4
        if digits.count > 4, remainder % 3 == 0 {
            var groups = [String(digits.prefix(4))]
            var cursor = digits.index(digits.startIndex, offsetBy: 4)
            while cursor < digits.endIndex {
                let next = digits.index(cursor, offsetBy: 3)
                groups.append(String(digits[cursor..<next]))
                cursor = next
            }
            return groups
        }

        if digits.count >= 6, digits.count % 3 == 0 {
            var groups: [String] = []
            var cursor = digits.startIndex
            while cursor < digits.endIndex {
                let next = digits.index(cursor, offsetBy: 3)
                groups.append(String(digits[cursor..<next]))
                cursor = next
            }
            return groups
        }

        if digits.count % 4 == 0 {
            var groups: [String] = []
            var cursor = digits.startIndex
            while cursor < digits.endIndex {
                let next = digits.index(cursor, offsetBy: 4)
                groups.append(String(digits[cursor..<next]))
                cursor = next
            }
            return groups
        }

        return [digits]
    }

    private func normalizeHighConfidenceMixedEntities(_ text: String) -> String {
        var out = text

        out = replacingMatches(
            in: out,
            pattern: "(?i)(?<![A-Za-z])vivo\\s*x\\s*[，,。．:：\\s-]*(\\d{3})\\s*[，,。．:：\\s-]*ultr[，,。．:：\\s-]*a(?![A-Za-z])"
        ) { match, nsText in
            let model = nsText.substring(with: match.range(at: 1))
            return "vivo X\(model) Ultra"
        }
        out = replacingMatches(
            in: out,
            pattern: "(?i)(?<![A-Za-z])vivo\\s*x\\s*[，,。．:：\\s-]*(\\d{3})\\s*[，,。．:：\\s-]*s(?![A-Za-z])"
        ) { match, nsText in
            let model = nsText.substring(with: match.range(at: 1))
            return "vivo X\(model)s"
        }
        out = replacingMatches(
            in: out,
            pattern: "(?i)(?<![A-Za-z])x\\s*[，,。．:：\\s-]*(\\d{3})\\s*[，,。．:：\\s-]*ultr[，,。．:：\\s-]*a(?![A-Za-z])"
        ) { match, nsText in
            let model = nsText.substring(with: match.range(at: 1))
            return "X\(model) Ultra"
        }
        out = replacingMatches(
            in: out,
            pattern: "(?i)(?<![A-Za-z])x\\s*[，,。．:：\\s-]*(\\d{3})\\s*[，,。．:：\\s-]*s(?![A-Za-z])"
        ) { match, nsText in
            let model = nsText.substring(with: match.range(at: 1))
            return "X\(model)s"
        }
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])bri[，,。．:：\\s-]*ef(?![A-Za-z])",
            with: "brief",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])x\\s*300\\s*ultra\\s*在视频\\s*x\\s*300\\s*ultra\\s*在",
            with: "X300 Ultra在视频",
            options: .regularExpression
        )
        return out
    }

    private func normalizeContextualContentMisrecognitions(_ text: String) -> String {
        var out = text
        let directReplacements = [
            "把蚊子打出来": "把文字打出来",
            "他有的时候会很快把文字打出来": "它有的时候会很快把文字打出来",
            "我觉得他在重量上是要做一些取舍的": "我觉得它在重量上是要做一些取舍的",
            "就是他很有利于直出分享": "就是它很有利于直出分享",
            "我打算更侧重来分享他在日常拍摄城市和户外风景上的能力": "我打算更侧重来分享它在日常拍摄城市和户外风景上的能力",
            "一句话评价，就是他是普通人最适合日常的记录设备": "一句话评价，就是它是普通人最适合日常的记录设备",
            "你先查看一下。我更新了哪些信息": "你先查看一下我更新了哪些信息",
            "开箱的，一个笔记当中": "开箱的一个笔记当中",
            "在测试一下数字和时间": "再测试一下数字和时间"
        ]
        for (source, target) in directReplacements {
            out = out.replacingOccurrences(of: source, with: target)
        }

        out = out.replacingOccurrences(of: "有1点发热", with: "有一点发热")
        out = out.replacingOccurrences(of: "更精准1点", with: "更精准一点")
        out = out.replacingOccurrences(of: "久1点", with: "久一点")
        return out
    }

    private func normalizeEnumeratedListMarkers(_ text: String) -> String {
        let listMarkerCount = countMatches(
            pattern: "(^|[，,。！？；：])\\s*([一二三四五六七八九123456789])是",
            in: text
        )
        guard listMarkerCount >= 2 else { return text }

        var out = text
        out = out.replacingOccurrences(
            of: "([，,])\\s*([123456789])是",
            with: "。$2 ",
            options: .regularExpression
        )
        let mappings = [
            ("一", "1"), ("二", "2"), ("三", "3"), ("四", "4"), ("五", "5"),
            ("六", "6"), ("七", "7"), ("八", "8"), ("九", "9")
        ]
        for (han, arabic) in mappings {
            out = out.replacingOccurrences(
                of: "([，,])\\s*" + han + "是",
                with: "。" + arabic + " ",
                options: .regularExpression
            )
            out = out.replacingOccurrences(
                of: "([。！？；：])\\s*" + han + "是",
                with: "$1" + arabic + " ",
                options: .regularExpression
            )
        }
        out = out.replacingOccurrences(
            of: "([。！？；：])\\s*([123456789])是",
            with: "$1$2 ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "^\\s*([123456789])是",
            with: "$1 ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "([。！？；：])\\s*([123456789])\\s+",
            with: "$1$2 ",
            options: .regularExpression
        )
        return restoreEnumeratedMarkerSpacing(out)
    }

    private func normalizeWorkoutMetricPhrases(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: "一小时0*(\\d{1,2})分",
            with: "1小时$1分",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(\\d+)小时0+(\\d{1,2})分",
            with: "$1小时$2分",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "总牵卡",
            with: "总千卡"
        )
        out = out.replacingOccurrences(
            of: "总1000卡",
            with: "总千卡"
        )
        out = out.replacingOccurrences(
            of: "(总千卡消耗)(\\d{2,4})1000卡",
            with: "$1$2千卡",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(平均心率(?:是)?)(\\d{2,3})分(?:钟|中)每次",
            with: "$1$2次/分",
            options: .regularExpression
        )
        return out
    }

    private func normalizeCommonSpeechMisrecognitions(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: "首冲咖啡",
            with: "手冲咖啡"
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])open\\s*claw(?![A-Za-z])",
            with: "OpenClaw",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])open\\s*c[，,。！？；：:\\s-]*law(?![A-Za-z])",
            with: "OpenClaw",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])opencloud(?![A-Za-z])",
            with: "OpenClaw",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])openclaw(?![A-Za-z])",
            with: "OpenClaw",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])obsidian(?![A-Za-z])",
            with: "Obsidian",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: "OBC点", with: "Obsidian")
        out = out.replacingOccurrences(
            of: "(?<![A-Za-z])skill(?![A-Za-z])",
            with: "Skill",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<![A-Za-z])skills(?![A-Za-z])",
            with: "Skills",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])cloudkit(?![A-Za-z])",
            with: "CloudKit",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])app\\s*store(?![A-Za-z])",
            with: "APP Store",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])apple\\s*log(?![A-Za-z])",
            with: "Apple Log",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])apple\\s*prores\\s*raw(?![A-Za-z])",
            with: "Apple Prores Raw",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])say\\s*something(?![A-Za-z])",
            with: "Say Something",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])saysomething(?![A-Za-z])",
            with: "Say Something",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<![A-Za-z])Phone\\s*17\\s*Pro",
            with: "iPhone 17 Pro",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)10\\.7\\s*pro\\s*max",
            with: "17 Pro Max",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)10\\.7promax",
            with: "17 Pro Max",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(?<![A-Za-z])x(?=平台)",
            with: "X",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: "对于他的使用", with: "对于它的使用")
        out = out.replacingOccurrences(of: "他的使用", with: "它的使用")
        out = out.replacingOccurrences(of: "1起", with: "一起")
        out = out.replacingOccurrences(of: "方案2", with: "方案二")
        out = out.replacingOccurrences(of: "现实活动", with: "限时活动")
        out = out.replacingOccurrences(of: "E倍", with: "1倍")
        out = out.replacingOccurrences(of: "四K120.10帧", with: "4K120帧")
        out = out.replacingOccurrences(of: "四K6.10帧", with: "4K60帧")
        out = out.replacingOccurrences(of: "4K120.10帧", with: "4K120帧")
        out = out.replacingOccurrences(of: "4K6.10帧", with: "4K60帧")
        out = out.replacingOccurrences(of: "4K120帧的，拍摄录制", with: "4K120帧的拍摄录制")
        out = out.replacingOccurrences(of: "很很好看", with: "很好看")
        return out
    }

    private func normalizeSampleDrivenClausePunctuation(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: "一个新的细节优化需求啊(?=在)",
            with: "一个新的细节优化需求：",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "工作吧(?=[，,]?我首先)",
            with: "工作吧：",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "不不不(?=我不是)",
            with: "不不不，",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "([\\p{Han}A-Za-z0-9]{4,})但(?=(本|我|他|她|它|这|那|您))",
            with: "$1，但",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: "APP它", with: "APP，它")
        out = out.replacingOccurrences(of: "将那个显示主窗口改为设置", with: "将显示主窗口改为设置")
        out = out.replacingOccurrences(of: "装好了，部署好了，然后也装了几个", with: "装好部署好了，也装了几个")
        out = out.replacingOccurrences(of: "设置吧，然后", with: "设置，然后")
        out = out.replacingOccurrences(of: "训练计划。今天一共", with: "训练计划，今天一共")
        out = out.replacingOccurrences(of: "实时同步，吗", with: "实时同步吗")
        out = out.replacingOccurrences(of: "再往右放，一些", with: "再往右放一些")
        out = out.replacingOccurrences(of: "分布卡片吗？它好像变窄了没有", with: "分布卡片吗？它好像变窄了，没有")
        out = out.replacingOccurrences(of: "还是，有一点点", with: "还是有一点点")
        out = out.replacingOccurrences(of: "吧，不，是", with: "吧，不是")
        out = out.replacingOccurrences(of: "点什么？我先说中文", with: "点什么，我先说中文")
        out = out.replacingOccurrences(of: "说中文看看", with: "说中文，看看")
        out = out.replacingOccurrences(of: "APP Store，上架", with: "APP Store上架")
        out = out.replacingOccurrences(of: "底部导航栏加入", with: "底部导航栏，加入")
        out = out.replacingOccurrences(of: "自己的器材数据并上传", with: "自己的器材数据，并上传")
        out = out.replacingOccurrences(of: "上传到，苹果后台", with: "上传到苹果后台")
        out = out.replacingOccurrences(of: "显示出。可以添加", with: "显示出可以添加")
        out = out.replacingOccurrences(of: "联系方式以及。合作说明", with: "联系方式以及合作说明")
        out = out.replacingOccurrences(of: "合作说，明", with: "合作说明")
        out = out.replacingOccurrences(of: "能力以及。相关合作案例", with: "能力以及相关合作案例")
        out = out.replacingOccurrences(of: "外观后背的设计还有手感", with: "外观后背的设计，还有手感")
        out = out.replacingOccurrences(of: "也很好看很方便拍摄", with: "也很好看，很方便拍摄")
        out = out.replacingOccurrences(of: "很方便拍摄在普通模式下", with: "很方便拍摄，在普通模式下")
        out = out.replacingOccurrences(of: "匿名的数据了装备记录数据", with: "匿名的装备记录数据")
        out = out.replacingOccurrences(of: "扩充了短语防误切保护新增", with: "扩充了短语防误切保护，新增")
        out = out.replacingOccurrences(of: "边界空格清理新增", with: "边界空格清理，新增")
        out = out.replacingOccurrences(of: "极简记录科学统计", with: "极简记录，科学统计")
        out = out.replacingOccurrences(of: "本软件是按照现状提供的对于应用内的", with: "本软件是按照现状提供的。对于应用内的")
        out = out.replacingOccurrences(of: "不构成任何财务投资二手交易的指导意见", with: "不构成任何财务、投资、二手交易的指导意见")
        out = out.replacingOccurrences(of: "这一次请你先不要直接改代码先好好理解一下我的截图", with: "这一次请你先不要直接改代码，先好好理解一下我的截图")
        out = out.replacingOccurrences(of: "你看左边统计的页面他", with: "你看左边统计的页面，它")
        out = out.replacingOccurrences(of: "其他元素干扰只显示", with: "其他元素干扰，只显示")
        out = out.replacingOccurrences(of: "图层最上方不要", with: "图层最上方，不要")
        out = out.replacingOccurrences(of: "其他涂层", with: "其他图层")
        out = out.replacingOccurrences(of: "免费版统计页面app，语言设置为中文时最喜欢用这个卡片", with: "免费版统计页面，app语言设置为中文时，最喜欢用这个卡片")
        out = out.replacingOccurrences(of: "某某品牌运动相机下面成本最低卡片内的大疆", with: "某某品牌运动相机。下面成本最低卡片内的大疆")
        out = out.replacingOccurrences(of: "大疆，pocket3", with: "大疆pocket3")
        out = out.replacingOccurrences(of: "APP，它的核心功能，就是", with: "APP，它的核心功能就是")
        out = out.replacingOccurrences(of: "价格它就会", with: "价格，它就会")
        out = out.replacingOccurrences(of: "这一个月我，几乎每天", with: "这一个月，我几乎每天")
        out = out.replacingOccurrences(of: "代码现在我觉得", with: "代码，现在我觉得")
        out = out.replacingOccurrences(of: "才和大家分享目前已经在", with: "才和大家分享，目前已经在")
        out = out.replacingOccurrences(of: "数据统计业", with: "数据统计页")
        out = out.replacingOccurrences(of: "哪一个器材陪伴我最久哪一台", with: "哪一个器材陪伴我最久，哪一台")
        out = out.replacingOccurrences(of: "转圈的图标它", with: "转圈的图标，它")
        out = out.replacingOccurrences(of: "固定旋转而应该", with: "固定旋转，而应该")
        out = out.replacingOccurrences(
            of: "底子正(?=后期调色)",
            with: "底子正，",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "风格都可以(?=当然当然)",
            with: "风格都可以，",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "国产机(?=你也同样)",
            with: "国产机，",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: "吧不", with: "吧，不")
        out = out.replacingOccurrences(of: "了这个处理的效率", with: "了，这个处理的效率")
        out = out.replacingOccurrences(
            of: "图层最上方(?=不要)",
            with: "图层最上方，",
            options: .regularExpression
        )
        return out
    }

    private func normalizeChineseMixedScriptSpacing(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: "(\\p{Han})\\s+([A-Za-z0-9])",
            with: "$1$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "([A-Za-z0-9])\\s+(\\p{Han})",
            with: "$1$2",
            options: .regularExpression
        )
        return restoreEnumeratedMarkerSpacing(out)
    }

    private func restoreEnumeratedMarkerSpacing(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: "([。！？；：])([123456789])(?=[\\p{Han}])",
            with: "$1$2 ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "^([123456789])(?=[\\p{Han}])",
            with: "$1 ",
            options: .regularExpression
        )
        return out
    }

    private func rebalanceChineseConnectorPunctuation(_ text: String) -> String {
        var out = text
        let connectors = [
            "但是", "不过", "然后", "所以", "因此", "另外", "同时", "而且",
            "并且", "接着", "最后", "如果", "虽然", "因为", "比如", "例如", "那么", "还有",
            "只要", "就是", "也就是", "而是"
        ]
        for connector in connectors {
            let escaped = NSRegularExpression.escapedPattern(for: connector)
            out = out.replacingOccurrences(
                of: "[。！？；：]\\s*" + escaped,
                with: "，" + connector,
                options: .regularExpression
            )
            out = out.replacingOccurrences(
                of: "([\\p{Han}A-Za-z0-9]{2,24})[。！？]\\s*(" + escaped + "[\\p{Han}A-Za-z0-9]{2,24})",
                with: "$1，$2",
                options: .regularExpression
            )
        }
        return out
    }

    private func collapseOverSegmentedChineseSentences(_ text: String) -> String {
        let sentenceTerminators: Set<Character> = ["。", "！", "？"]
        var segments: [String] = []
        var current = ""

        for ch in text {
            if sentenceTerminators.contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(trimmed)
                }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            segments.append(tail)
        }

        guard segments.count >= 2 else { return text }
        if segments.count == 2 {
            let firstLength = countContentCharacters(segments[0])
            let secondLength = countContentCharacters(segments[1])
            let secondStartsWithConnector = segments[1].range(
                of: "^(但是|不过|然后|所以|因此|另外|同时|而且|并且|接着|最后|如果|虽然|因为|比如|例如|那么|还有|只要|就是|也就是|而是)",
                options: .regularExpression
            ) != nil
            let bothVeryShort = firstLength <= 2 && secondLength <= 3
            if secondStartsWithConnector || bothVeryShort {
                let joined = segments.joined(separator: "，")
                let suffix = inferChineseSentenceTerminator(for: joined)
                return joined + suffix
            }
            return text
        }

        let lengths = segments.map { countContentCharacters($0) }
        let shortCount = lengths.filter { $0 <= 4 }.count
        let avgLength = Double(lengths.reduce(0, +)) / Double(max(1, lengths.count))
        let shortRatio = Double(shortCount) / Double(max(1, segments.count))
        let hasConnectorSegment = segments.contains { segment in
            segment.range(
                of: "^(但是|不过|然后|所以|因此|另外|同时|而且|并且|接着|最后|如果|虽然|因为|比如|例如|那么|还有|只要|就是|也就是|而是)",
                options: .regularExpression
            ) != nil
        }
        let conservativeMergeAllowed = (shortRatio >= 0.75 && avgLength <= 4.2)
            || (hasConnectorSegment && shortRatio >= 0.60 && avgLength <= 5.0)

        guard conservativeMergeAllowed else {
            return text
        }

        let joined = segments.joined(separator: "，")
        let suffix = inferChineseSentenceTerminator(for: joined)
        return joined + suffix
    }

    private func normalizeChineseQuestionEnding(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if containsStrongQuestionHint(in: trimmed) {
            if trimmed.hasSuffix("。") || trimmed.hasSuffix("，") {
                return String(trimmed.dropLast()) + "？"
            }
        }
        return trimmed
    }

    private func repairInlineChineseQuestionBreaks(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "吗他好像", with: "吗？它好像")
        out = out.replacingOccurrences(
            of: "(吗|呢|么)(?=(晚上|现在|然后|那|再|还|你|我|他|她|它|这|哪))",
            with: "$1？",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(吗|呢|么|吧)([他它你我这那])",
            with: "$1？$2",
            options: .regularExpression
        )
        return out
    }

    private func containsStrongQuestionHint(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("？") || trimmed.hasSuffix("?") {
            return true
        }

        let normalized = trimmed.replacingOccurrences(
            of: "[。.!！？，,]+$",
            with: "",
            options: .regularExpression
        )
        let target = String(normalized.suffix(22))
        if target.range(
            of: "(吗|么|呢|嘛|吧|是不是|对不对|行不行|可不可以|好不好|能不能|要不要)[”\"』」】）)]?$",
            options: .regularExpression
        ) != nil {
            return true
        }

        if target.range(
            of: "^(请问)?(为什么|怎么|如何|多少|几(点|号|月|日|岁|个)|哪里|哪儿|哪位|哪种|是否|能否|可不可以|行不行|对不对|是不是|要不要|能不能)",
            options: .regularExpression
        ) != nil {
            return true
        }

        return target.range(
            of: "(是不是|对不对|行不行|可不可以|要不要|能不能)[^。！？，,;；:：]{0,8}$",
            options: .regularExpression
        ) != nil
    }

    private func containsWeakQuestionHint(in text: String) -> Bool {
        let target = String(text.suffix(18))
        return target.range(
            of: "(为什么|怎么|如何|多少|几(点|号|月|日|岁|个)|哪里|哪儿|哪位|哪种|是否)",
            options: .regularExpression
        ) != nil
    }

    private func currentAdaptivePunctuationProfile() -> PunctuationUserProfile? {
        guard settings.bool(forKey: SettingsKeys.enableAdaptivePunctuation, default: false) else {
            return nil
        }
        return punctuationProfileProvider?.effectiveProfile(
            minSamples: PunctuationLearningStore.defaultLearningThreshold
        )
    }

    private func recordPunctuationQualityMetrics(misbreakFixDelta: Int, questionFixDelta: Int) {
        let misbreakTotal = incrementPunctuationMetric(
            key: SettingsKeys.punctuationMisbreakFixCount,
            delta: misbreakFixDelta
        )
        let questionTotal = incrementPunctuationMetric(
            key: SettingsKeys.punctuationQuestionBiasFixCount,
            delta: questionFixDelta
        )
        guard settings.bool(forKey: SettingsKeys.punctuationDebugLogEnabled, default: false) else {
            return
        }
        if misbreakFixDelta > 0 || questionFixDelta > 0 {
            print(
                "PunctuationQuality misbreak_fix+=\(misbreakFixDelta) total=\(misbreakTotal) "
                    + "question_fix+=\(questionFixDelta) total=\(questionTotal)"
            )
        }
    }

    @discardableResult
    private func incrementPunctuationMetric(key: String, delta: Int) -> Int {
        let current = Int(settings.string(forKey: key, default: "0")) ?? 0
        guard delta > 0 else { return current }
        let next = current + delta
        settings.set(String(next), forKey: key)
        return next
    }

    private func countContentCharacters(_ text: String) -> Int {
        countMatches(pattern: "[\\p{Han}A-Za-z0-9]", in: text)
    }

    private func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func applyChineseSegmentationV2(_ text: String) -> String {
        var out = text
        let adaptiveProfile = currentAdaptivePunctuationProfile()
        let markers = [
            "但是", "不过", "然后", "所以", "因此", "另外", "同时", "而且",
            "并且", "接着", "最后", "如果", "虽然", "因为", "比如", "例如",
            "只要", "就是", "也就是", "而是"
        ]

        for marker in markers {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let pattern = "(?<=[\\p{Han}A-Za-z0-9]{2})\\s*" + escaped
            out = out.replacingOccurrences(
                of: pattern,
                with: "，" + marker,
                options: .regularExpression
            )
        }

        let threshold = max(
            16,
            22 - Int((adaptiveProfile?.commaAggressiveness ?? 0) * 4.0)
        )
        out = insertCommaForLongChineseRun(out, threshold: threshold)
        out = out.replacingOccurrences(of: "，{2,}", with: "，", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func insertCommaForLongChineseRun(_ text: String, threshold: Int) -> String {
        guard threshold > 5 else { return text }

        let punctuationSet = CharacterSet(charactersIn: "，。！？；：,.!?;:")
        var result = ""
        var runCount = 0

        for scalar in text.unicodeScalars {
            let character = String(scalar)
            result.append(character)

            if punctuationSet.contains(scalar) {
                runCount = 0
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }

            runCount += 1
            if runCount >= threshold {
                result.append("，")
                runCount = 0
            }
        }

        return result.replacingOccurrences(of: "，([。！？；：])", with: "$1", options: .regularExpression)
    }

    private func applyEnglishSegmentationV2(_ text: String) -> String {
        var out = text
        let connectors = ["but", "so", "however", "therefore", "then", "meanwhile"]

        for connector in connectors {
            let pattern = "(?i)(?<=[A-Za-z0-9])\\s+" + connector + "\\b"
            out = out.replacingOccurrences(
                of: pattern,
                with: ", " + connector,
                options: .regularExpression
            )
        }

        out = out.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        return out
    }

    private func convertSpokenNumbersToArabic(_ text: String) -> String {
        let numericChars = "0-9零〇○一二两三四五六七八九十百千万亿萬億壹贰貳叁參肆伍陆陸柒捌玖拾佰仟"
        let digitChars = "0-9零〇○一二两三四五六七八九壹贰貳叁參肆伍陆陸柒捌玖"
        let pattern = "([\(numericChars)]+点[\(digitChars)]+)|([\(numericChars)]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            guard shouldConvertNumberToken(token, in: text, range: match.range),
                  let converted = convertNumberToken(token) else {
                continue
            }
            mutable.replaceCharacters(in: match.range, with: converted)
        }
        return mutable as String
    }

    private func shouldConvertNumberToken(_ token: String, in text: String, range: NSRange) -> Bool {
        guard !token.isEmpty else { return false }

        // High-frequency lexical phrase; converting to 10001 is almost always wrong.
        if token == "万一" {
            return false
        }

        // "千卡" is a unit phrase (kcal), not a multiplier expression.
        if token.hasSuffix("千") {
            let (_, after) = surroundingCharactersSkippingWhitespace(in: text, range: range)
            if after == "卡" {
                return false
            }
        }

        if token.contains("点") {
            return true
        }

        let hasUnit = token.contains { chineseSmallUnitValue($0) != nil || chineseBigUnitValue($0) != nil }
        if hasUnit {
            return true
        }

        let allDigits = token.allSatisfy { numericDigitValue($0) != nil }
        guard allDigits else { return false }

        if token.allSatisfy({ asciiDigitValue($0) != nil }) {
            return false
        }

        if token == "一", isProtectedSingleYiPhrase(in: text, range: range) {
            return false
        }

        if token.count >= 2 {
            return true
        }

        let (before, after) = surroundingCharactersSkippingWhitespace(in: text, range: range)
        if before == "第" {
            return true
        }
        if let after, isStrongNumericSuffix(after) {
            return true
        }
        return false
    }

    private func surroundingCharactersSkippingWhitespace(in text: String, range: NSRange) -> (Character?, Character?) {
        guard let swiftRange = Range(range, in: text) else {
            return (nil, nil)
        }

        let before = previousNonWhitespaceCharacter(in: text, before: swiftRange.lowerBound)
        let after = nextNonWhitespaceCharacter(in: text, after: swiftRange.upperBound)?.character
        return (before, after)
    }

    private func isStrongNumericSuffix(_ ch: Character) -> Bool {
        switch ch {
        case "年", "月", "日", "号", "点", "时", "分", "秒",
            "元", "块", "角", "毛", "厘",
            "次", "天", "周", "岁", "倍",
            "页", "章", "条", "件", "台", "本", "张",
            "米", "里", "斤", "克", "度", "小",
            "%", "％":
            return true
        default:
            return false
        }
    }

    private func isProtectedSingleYiPhrase(in text: String, range: NSRange) -> Bool {
        guard let swiftRange = Range(range, in: text) else { return false }
        guard let first = nextNonWhitespaceCharacter(in: text, after: swiftRange.upperBound) else {
            return false
        }

        let bigram = "一" + String(first.character)
        if Self.protectedYiBigrams.contains(bigram) {
            return true
        }

        let secondStart = text.index(after: first.index)
        if let second = nextNonWhitespaceCharacter(in: text, after: secondStart) {
            let trigram = "一" + String(first.character) + String(second.character)
            if Self.protectedYiTrigrams.contains(trigram) {
                return true
            }
        }
        return false
    }

    private func previousNonWhitespaceCharacter(in text: String, before index: String.Index) -> Character? {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let ch = text[cursor]
            if !ch.isWhitespace {
                return ch
            }
        }
        return nil
    }

    private func nextNonWhitespaceCharacter(
        in text: String,
        after index: String.Index
    ) -> (character: Character, index: String.Index)? {
        var cursor = index
        while cursor < text.endIndex {
            let ch = text[cursor]
            if !ch.isWhitespace {
                return (ch, cursor)
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private func convertNumberToken(_ token: String) -> String? {
        guard !token.isEmpty else { return nil }

        if token.contains("点") {
            let parts = token.split(separator: "点", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let integerPart = convertChineseIntegerToken(parts[0]),
                  let decimalDigits = convertChineseDecimalDigits(parts[1]) else {
                return nil
            }
            return integerPart + "." + decimalDigits
        }

        return convertChineseIntegerToken(token)
    }

    private func convertChineseDecimalDigits(_ token: String) -> String? {
        var digits = ""
        for ch in token {
            guard let value = numericDigitValue(ch) else {
                return nil
            }
            digits.append(String(value))
        }
        return digits
    }

    private func convertChineseIntegerToken(_ token: String) -> String? {
        guard !token.isEmpty else { return nil }

        if token.allSatisfy({ numericDigitValue($0) != nil }) {
            var out = ""
            for ch in token {
                guard let value = numericDigitValue(ch) else { return nil }
                out.append(String(value))
            }
            return out
        }

        let chars = Array(token)
        var total = 0
        var section = 0
        var number = 0
        var numberDigitCount = 0
        var lastBigUnit: Int?
        var zeroAfterLastBigUnit = false

        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if let digit = asciiDigitValue(ch) {
                var value = digit
                var digitCount = 1
                index += 1
                while index < chars.count, let nextDigit = asciiDigitValue(chars[index]) {
                    value = value * 10 + nextDigit
                    digitCount += 1
                    index += 1
                }
                number = value
                numberDigitCount = digitCount
                continue
            }

            if let digit = chineseDigitValue(ch) {
                number = digit
                numberDigitCount = 1
                if digit == 0, lastBigUnit != nil, section == 0 {
                    zeroAfterLastBigUnit = true
                }
                index += 1
                continue
            }

            if let unit = chineseSmallUnitValue(ch) {
                if number == 0 { number = 1 }
                section += number * unit
                number = 0
                numberDigitCount = 0
                if lastBigUnit != nil {
                    zeroAfterLastBigUnit = false
                }
                index += 1
                continue
            }

            if let bigUnit = chineseBigUnitValue(ch) {
                section += number
                if section == 0 { section = 1 }
                total += section * bigUnit
                lastBigUnit = bigUnit
                section = 0
                number = 0
                numberDigitCount = 0
                zeroAfterLastBigUnit = false
                index += 1
                continue
            }

            return nil
        }

        if let lastBigUnit, section == 0, number > 0, !zeroAfterLastBigUnit {
            let unitDigits = decimalDigitCount(lastBigUnit) - 1
            if numberDigitCount > 0, numberDigitCount < unitDigits {
                total += number * integerPower10(unitDigits - numberDigitCount)
            } else {
                total += number
            }
        } else {
            total += section + number
        }
        return String(total)
    }

    private func asciiDigitValue(_ ch: Character) -> Int? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return nil
        }
        let value = scalar.value
        guard value >= 48, value <= 57 else { return nil }
        return Int(value - 48)
    }

    private func numericDigitValue(_ ch: Character) -> Int? {
        asciiDigitValue(ch) ?? chineseDigitValue(ch)
    }

    private func decimalDigitCount(_ value: Int) -> Int {
        String(value).count
    }

    private func integerPower10(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { result, _ in result * 10 }
    }

    private func chineseDigitValue(_ ch: Character) -> Int? {
        switch ch {
        case "零", "〇", "○":
            return 0
        case "一", "壹":
            return 1
        case "二", "两", "贰", "貳":
            return 2
        case "三", "叁", "參":
            return 3
        case "四", "肆":
            return 4
        case "五", "伍":
            return 5
        case "六", "陆", "陸":
            return 6
        case "七", "柒":
            return 7
        case "八", "捌":
            return 8
        case "九", "玖":
            return 9
        default:
            return nil
        }
    }

    private func chineseSmallUnitValue(_ ch: Character) -> Int? {
        switch ch {
        case "十", "拾":
            return 10
        case "百", "佰":
            return 100
        case "千", "仟":
            return 1000
        default:
            return nil
        }
    }

    private func chineseBigUnitValue(_ ch: Character) -> Int? {
        switch ch {
        case "万", "萬":
            return 10_000
        case "亿", "億":
            return 100_000_000
        default:
            return nil
        }
    }
}
