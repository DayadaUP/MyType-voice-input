import Foundation

public struct CloudStreamingFinalizationDecision: Equatable, Sendable {
    public let accept: Bool
    public let reason: String

    public init(accept: Bool, reason: String) {
        self.accept = accept
        self.reason = reason
    }
}

public struct ProtectedSpanRepairDecision: Equatable, Sendable {
    public let outputText: String
    public let changed: Bool
    public let reason: String

    public init(outputText: String, changed: Bool, reason: String) {
        self.outputText = outputText
        self.changed = changed
        self.reason = reason
    }
}

public enum CloudStreamingFinalizationGuard {
    private static let hanNumericCharacters = "零〇○一二两三四五六七八九十百千万亿"
    private static let hanNumericPattern = "[" + hanNumericCharacters + "]"
    private static let protectedSpanPattern =
        "(\\d{1,2}月\\d{1,2}(?:[.。．]\\d{1,2})?[日号]?)"
        + "|(\\d{1,4}[./-]\\d{1,2}[./-]\\d{1,2}(?:日|号)?)"
        + "|(\\d{1,2}[.。．:：]\\d{2})"
        + "|(\\d+(?:\\.\\d+)?小时\\d{1,2}分|\\d+(?:\\.\\d+)?小时|\\d+分钟|\\d+秒)"
        + "|(\\d+(?:[.。．,，]\\d+)?(?:%|％))"
        + "|((?=[\\d" + hanNumericCharacters + ",，.。．:：%％]*\\d)[\\d" + hanNumericCharacters + "]+(?:[,，.。．:：][\\d" + hanNumericCharacters + "]+)*(?:%|％)?)"

    public static func evaluate(
        previewText: String,
        streamedPreviewText: String
    ) -> CloudStreamingFinalizationDecision {
        let preview = normalize(previewText)
        let streamed = normalize(streamedPreviewText)

        guard !streamed.isEmpty else {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "empty_streamed_preview"
            )
        }
        guard !preview.isEmpty else {
            return CloudStreamingFinalizationDecision(
                accept: true,
                reason: "no_preview_baseline"
            )
        }
        if preview == streamed {
            return CloudStreamingFinalizationDecision(accept: true, reason: "preview_equal")
        }

        let protectedSpanDecision = repairProtectedSpans(
            previewText: preview,
            candidateText: streamed
        )
        if protectedSpanDecision.changed, protectedSpanDecision.outputText == preview {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "protected_span_regression_" + protectedSpanDecision.reason
            )
        }

        let previewCanonical = canonicalComparable(preview)
        let streamedCanonical = canonicalComparable(streamed)
        guard !previewCanonical.isEmpty, !streamedCanonical.isEmpty else {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "non_comparable_divergence"
            )
        }

        if previewCanonical == streamedCanonical {
            return CloudStreamingFinalizationDecision(accept: true, reason: "canonical_equal")
        }

        let maxLen = max(previewCanonical.count, streamedCanonical.count)
        let lengthDelta = abs(previewCanonical.count - streamedCanonical.count)

        if streamedCanonical.contains(previewCanonical) {
            return CloudStreamingFinalizationDecision(accept: true, reason: "stream_superset")
        }

        if previewCanonical.contains(streamedCanonical) {
            let coverage = Double(streamedCanonical.count) / Double(max(1, previewCanonical.count))
            if coverage >= 0.85 || lengthDelta <= 3 {
                return CloudStreamingFinalizationDecision(
                    accept: true,
                    reason: "preview_contains_stream_near_complete"
                )
            }
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "preview_contains_stream_truncated"
            )
        }

        guard maxLen >= 8 else {
            return CloudStreamingFinalizationDecision(accept: false, reason: "short_divergent")
        }

        let prefixLen = commonPrefixLength(previewCanonical, streamedCanonical)
        let suffixLen = commonSuffixLength(previewCanonical, streamedCanonical)
        let covered = min(
            min(previewCanonical.count, streamedCanonical.count),
            prefixLen + suffixLen
        )
        let coverage = Double(covered) / Double(maxLen)
        let allowedDelta = max(4, Int(Double(maxLen) * 0.2))
        if coverage >= 0.82, lengthDelta <= allowedDelta {
            return CloudStreamingFinalizationDecision(
                accept: true,
                reason: "prefix_suffix_overlap"
            )
        }

        return CloudStreamingFinalizationDecision(accept: false, reason: "low_overlap")
    }

    public static func evaluatePreviewReuse(
        previewText: String,
        recentPreviewTexts: [String]
    ) -> CloudStreamingFinalizationDecision {
        let preview = normalize(previewText)
        guard !preview.isEmpty else {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "empty_preview_snapshot"
            )
        }

        let previewCanonical = canonicalComparable(preview)
        guard previewCanonical.count >= 6 else {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "preview_snapshot_too_short"
            )
        }

        let recent = recentPreviewTexts
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !recent.isEmpty else {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "missing_recent_preview_history"
            )
        }

        let canonicalRecent = recent.map(canonicalComparable).filter { !$0.isEmpty }
        guard !canonicalRecent.isEmpty else {
            return CloudStreamingFinalizationDecision(
                accept: false,
                reason: "non_comparable_preview_history"
            )
        }

        let trailing = Array(canonicalRecent.suffix(3))
        let exactMatchCount = trailing.filter { $0 == previewCanonical }.count
        if exactMatchCount >= 2 {
            return CloudStreamingFinalizationDecision(
                accept: true,
                reason: "recent_preview_repeated"
            )
        }

        if trailing.count >= 3 {
            let sharedPrefix = trailing.dropFirst().reduce(trailing[0]) { candidate, next in
                String(zip(candidate, next).prefix { $0 == $1 }.map(\.0))
            }
            if sharedPrefix == previewCanonical {
                return CloudStreamingFinalizationDecision(
                    accept: true,
                    reason: "recent_preview_shared_prefix"
                )
            }
        }

        return CloudStreamingFinalizationDecision(
            accept: false,
            reason: "preview_history_not_stable"
        )
    }

    public static func detectHardNumericIntegrityRegression(
        sourceText: String,
        candidateText: String
    ) -> String? {
        let source = normalize(sourceText)
        let candidate = normalize(candidateText)
        guard !source.isEmpty, !candidate.isEmpty, source != candidate else { return nil }
        return hardNumericIntegrityRegressionReason(
            previewText: source,
            candidateText: candidate
        )
    }

    public static func repairProtectedSpans(
        previewText: String,
        candidateText: String
    ) -> ProtectedSpanRepairDecision {
        let preview = normalize(previewText)
        let candidate = normalize(candidateText)
        guard !preview.isEmpty, !candidate.isEmpty else {
            return ProtectedSpanRepairDecision(
                outputText: candidate,
                changed: false,
                reason: "missing_preview_or_candidate"
            )
        }
        guard preview != candidate else {
            return ProtectedSpanRepairDecision(
                outputText: candidate,
                changed: false,
                reason: "unchanged"
            )
        }

        let entityRepair = repairProtectedEntityFragments(
            previewText: preview,
            candidateText: candidate
        )
        let candidateAfterEntityRepair = entityRepair.outputText

        let previewSpans = protectedSpans(in: preview)
        let candidateSpans = protectedSpans(in: candidateAfterEntityRepair)
        guard !previewSpans.isEmpty, !candidateSpans.isEmpty else {
            if let hardReason = hardNumericIntegrityRegressionReason(
                previewText: preview,
                candidateText: candidateAfterEntityRepair
            ),
                skeletonsComparable(preview, candidateAfterEntityRepair) {
                return ProtectedSpanRepairDecision(
                    outputText: preview,
                    changed: true,
                    reason: "fallback_preview_" + hardReason
                )
            }
            if entityRepair.changed {
                return ProtectedSpanRepairDecision(
                    outputText: candidateAfterEntityRepair,
                    changed: true,
                    reason: "replace_degraded_protected_entities"
                )
            }
            return ProtectedSpanRepairDecision(
                outputText: candidateAfterEntityRepair,
                changed: false,
                reason: "no_protected_spans"
            )
        }

        let hardNumericRegressionReason = hardNumericIntegrityRegressionReason(
            previewText: preview,
            candidateText: candidateAfterEntityRepair
        )
        if hasGlobalMalformedNumericCluster(in: candidateAfterEntityRepair)
            || (previewSpans.count != candidateSpans.count
                && hasSevereMalformedProtectedSpan(in: candidateSpans)),
           hasStableProtectedSpan(in: previewSpans),
           skeletonsComparable(preview, candidateAfterEntityRepair) {
            return ProtectedSpanRepairDecision(
                outputText: preview,
                changed: true,
                reason: "fallback_preview_malformed_protected_span"
            )
        }

        guard previewSpans.count == candidateSpans.count,
              skeletonsComparable(preview, candidateAfterEntityRepair) else {
            if let hardNumericRegressionReason,
               hasStableProtectedSpan(in: previewSpans),
               skeletonsComparable(preview, candidateAfterEntityRepair) {
                return ProtectedSpanRepairDecision(
                    outputText: preview,
                    changed: true,
                    reason: "fallback_preview_" + hardNumericRegressionReason
                )
            }
            if entityRepair.changed {
                return ProtectedSpanRepairDecision(
                    outputText: candidateAfterEntityRepair,
                    changed: true,
                    reason: "replace_degraded_protected_entities"
                )
            }
            return ProtectedSpanRepairDecision(
                outputText: candidateAfterEntityRepair,
                changed: false,
                reason: "span_alignment_unavailable"
            )
        }

        let mutable = NSMutableString(string: candidateAfterEntityRepair)
        var changed = false
        var spanReplacementReason: String?
        for index in stride(from: candidateSpans.count - 1, through: 0, by: -1) {
            let previewSpan = previewSpans[index]
            let candidateSpan = candidateSpans[index]
            guard let replacementReason = replacementReason(
                preview: previewSpan,
                candidate: candidateSpan
            ) else {
                continue
            }
            mutable.replaceCharacters(in: candidateSpan.range, with: previewSpan.text)
            changed = true
            spanReplacementReason = preferredReplacementReason(
                existing: spanReplacementReason,
                candidate: replacementReason
            )
        }

        guard changed else {
            if entityRepair.changed {
                return ProtectedSpanRepairDecision(
                    outputText: candidateAfterEntityRepair,
                    changed: true,
                    reason: "replace_degraded_protected_entities"
                )
            }
            return ProtectedSpanRepairDecision(
                outputText: candidateAfterEntityRepair,
                changed: false,
                reason: "no_degraded_protected_span"
            )
        }

        let repairedOutput = normalize(mutable as String)
        let numericSuffix = spanReplacementReason.map { "_" + $0 } ?? ""
        return ProtectedSpanRepairDecision(
            outputText: repairedOutput,
            changed: true,
            reason: entityRepair.changed
                ? "replace_degraded_protected_entities_and_spans" + numericSuffix
                : "replace_degraded_protected_spans" + numericSuffix
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ProtectedSpan {
        let range: NSRange
        let text: String
        let kind: ProtectedSpanKind
        let numericFingerprint: NumericFingerprint?
    }

    private struct ProtectedEntityFragment {
        let range: NSRange
        let text: String
    }

    private enum ProtectedSpanKind {
        case date
        case time
        case duration
        case integer
        case decimal
        case percentage
        case number

        var isNumericLike: Bool {
            switch self {
            case .integer, .decimal, .percentage, .number:
                return true
            case .date, .time, .duration:
                return false
            }
        }
    }

    private enum NumericFingerprintKind {
        case integer
        case decimal
        case percentage
        case mixed
        case unknown
    }

    private struct NumericFingerprint {
        let rawText: String
        let kind: NumericFingerprintKind
        let digitsOnly: String
        let normalizedValue: String?
        let digitCount: Int
        let containsHanNumeric: Bool
        let containsColonSeparator: Bool
        let containsGroupingSeparator: Bool
        let containsMixedSeparators: Bool
    }

    private static let protectedEntityPatterns: [String] = [
        "(?i)vivo\\s*X\\s*\\d{3}\\s*Ultra",
        "(?i)vivo\\s*X\\s*\\d{3}\\s*[sS]",
        "(?i)X\\s*\\d{3}\\s*Ultra",
        "(?i)X\\s*\\d{3}\\s*[sS]",
        "(?i)Obsidian",
        "(?i)brief",
        "(?i)4K\\s*120帧",
        "(?i)4K\\s*60帧",
        "项目",
        "输出结果"
    ]

    private static func protectedSpans(in text: String) -> [ProtectedSpan] {
        guard let regex = try? NSRegularExpression(pattern: protectedSpanPattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            let token = nsText.substring(with: match.range)
            let fingerprint = numericFingerprint(for: token)
            return ProtectedSpan(
                range: match.range,
                text: token,
                kind: classifyProtectedSpan(token, fingerprint: fingerprint),
                numericFingerprint: fingerprint
            )
        }
    }

    private static func protectedEntityFragments(in text: String) -> [ProtectedEntityFragment] {
        let nsText = text as NSString
        var fragments: [ProtectedEntityFragment] = []

        for pattern in protectedEntityPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.range.location != NSNotFound {
                let candidateRange = match.range
                if fragments.contains(where: { NSIntersectionRange($0.range, candidateRange).length > 0 }) {
                    continue
                }
                fragments.append(
                    ProtectedEntityFragment(
                        range: candidateRange,
                        text: nsText.substring(with: candidateRange)
                    )
                )
            }
        }

        return fragments.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length > rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
    }

    private static func repairProtectedEntityFragments(
        previewText: String,
        candidateText: String
    ) -> ProtectedSpanRepairDecision {
        let previewFragments = protectedEntityFragments(in: previewText)
        guard !previewFragments.isEmpty else {
            return ProtectedSpanRepairDecision(
                outputText: candidateText,
                changed: false,
                reason: "no_protected_entities"
            )
        }

        var output = candidateText
        var changed = false

        for fragment in previewFragments.sorted(by: { $0.range.location > $1.range.location }) {
            let relaxedPattern = relaxedProtectedEntityPattern(for: fragment.text)
            let options: NSRegularExpression.Options = fragment.text.contains(where: \.isLetter)
                ? [.caseInsensitive]
                : []
            guard let regex = try? NSRegularExpression(pattern: relaxedPattern, options: options) else {
                continue
            }

            let nsOutput = output as NSString
            let searchRange = NSRange(location: 0, length: nsOutput.length)
            guard let match = regex.firstMatch(in: output, range: searchRange) else { continue }
            let matchedText = nsOutput.substring(with: match.range)
            guard matchedText != fragment.text else { continue }

            let mutable = NSMutableString(string: output)
            mutable.replaceCharacters(in: match.range, with: fragment.text)
            output = mutable as String
            changed = true
        }

        return ProtectedSpanRepairDecision(
            outputText: normalize(output),
            changed: changed,
            reason: changed ? "replace_degraded_protected_entities" : "no_protected_entity_regression"
        )
    }

    private static func relaxedProtectedEntityPattern(for fragment: String) -> String {
        let separator = "[\\s,，.。．:：-]*"
        let units = fragment
            .filter { !$0.isWhitespace }
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        return units.joined(separator: separator)
    }

    private static func classifyProtectedSpan(
        _ text: String,
        fingerprint: NumericFingerprint? = nil
    ) -> ProtectedSpanKind {
        if isDateLike(text) {
            return .date
        }
        if isTimeLike(text) {
            return .time
        }
        if isDurationLike(text) {
            return .duration
        }
        switch (fingerprint ?? numericFingerprint(for: text))?.kind {
        case .integer:
            return .integer
        case .decimal:
            return .decimal
        case .percentage:
            return .percentage
        case .mixed, .unknown, .none:
            return .number
        }
    }

    private static func hasStableProtectedSpan(in spans: [ProtectedSpan]) -> Bool {
        spans.contains { isStableProtectedSpan($0) }
    }

    private static func hasMalformedProtectedSpan(in spans: [ProtectedSpan]) -> Bool {
        spans.contains { isMalformedProtectedSpan($0) }
    }

    private static func hasSevereMalformedProtectedSpan(in spans: [ProtectedSpan]) -> Bool {
        spans.contains { isSeverelyMalformedProtectedSpan($0) }
    }

    private static func replacementReason(
        preview: ProtectedSpan,
        candidate: ProtectedSpan
    ) -> String? {
        guard preview.text != candidate.text else { return nil }
        guard isStableProtectedSpan(preview) else { return nil }

        if preview.kind.isNumericLike, candidate.kind.isNumericLike {
            if let reason = hardNumericRegressionReason(preview: preview, candidate: candidate) {
                return reason
            }
            if sameNormalizedNumericValue(preview: preview, candidate: candidate) {
                return "numeric_format_normalized"
            }
            if isMalformedNumber(candidate.text) {
                return "malformed_numeric_text"
            }
            return nil
        }

        guard preview.kind == candidate.kind else { return nil }
        switch candidate.kind {
        case .date:
            return isMalformedDate(candidate.text) ? "malformed_date" : nil
        case .time:
            return isMalformedTime(candidate.text) ? "malformed_time" : nil
        case .duration:
            return isMalformedDuration(candidate.text) ? "malformed_duration" : nil
        case .integer, .decimal, .percentage, .number:
            return nil
        }
    }

    private static func isStableProtectedSpan(_ span: ProtectedSpan) -> Bool {
        switch span.kind {
        case .date:
            return !isMalformedDate(span.text)
        case .time:
            return !isMalformedTime(span.text)
        case .duration:
            return !isMalformedDuration(span.text)
        case .integer, .decimal, .percentage, .number:
            return !isMalformedNumber(span.text)
        }
    }

    private static func isMalformedProtectedSpan(_ span: ProtectedSpan) -> Bool {
        switch span.kind {
        case .date:
            return isMalformedDate(span.text)
        case .time:
            return isMalformedTime(span.text)
        case .duration:
            return isMalformedDuration(span.text)
        case .integer, .decimal, .percentage, .number:
            return isMalformedNumber(span.text)
        }
    }

    private static func isSeverelyMalformedProtectedSpan(_ span: ProtectedSpan) -> Bool {
        switch span.kind {
        case .date, .time, .duration:
            return isMalformedProtectedSpan(span)
        case .integer, .decimal, .percentage, .number:
            return isSeverelyMalformedNumber(span.text)
        }
    }

    private static func isDateLike(_ text: String) -> Bool {
        text.range(
            of: "^\\d{1,2}月\\d{1,2}(?:[.。．]\\d{1,2})?[日号]?$|^\\d{1,4}[./-]\\d{1,2}[./-]\\d{1,2}(?:日|号)?$",
            options: .regularExpression
        ) != nil
    }

    private static func isTimeLike(_ text: String) -> Bool {
        text.range(
            of: "^\\d{1,2}[.。．:：]\\d{2}$",
            options: .regularExpression
        ) != nil
    }

    private static func isDurationLike(_ text: String) -> Bool {
        text.range(
            of: "^\\d+(?:\\.\\d+)?小时\\d{1,2}分$|^\\d+(?:\\.\\d+)?小时$|^\\d+分钟$|^\\d+秒$",
            options: .regularExpression
        ) != nil
    }

    private static func isMalformedDate(_ text: String) -> Bool {
        if text.range(of: "^\\d{1,2}月\\d{1,2}[日号]?$", options: .regularExpression) != nil {
            return false
        }
        if text.range(of: "^\\d{1,4}[./-]\\d{1,2}[./-]\\d{1,2}(?:日|号)?$", options: .regularExpression) != nil {
            return false
        }
        return isDateLike(text)
    }

    private static func isMalformedTime(_ text: String) -> Bool {
        guard isTimeLike(text) else { return false }
        return text.range(of: "^\\d{1,2}:\\d{2}$", options: .regularExpression) == nil
    }

    private static func isMalformedDuration(_ text: String) -> Bool {
        !isDurationLike(text)
    }

    private static func isMalformedNumber(_ text: String) -> Bool {
        guard let fingerprint = numericFingerprint(for: text) else { return false }
        if fingerprint.containsHanNumeric {
            return true
        }
        if fingerprint.kind == .integer, fingerprint.containsGroupingSeparator {
            return true
        }
        if fingerprint.kind == .mixed || fingerprint.kind == .unknown {
            return true
        }
        if fingerprint.containsMixedSeparators {
            return true
        }
        return false
    }

    private static func isSeverelyMalformedNumber(_ text: String) -> Bool {
        guard let fingerprint = numericFingerprint(for: text) else { return false }
        if fingerprint.containsHanNumeric || fingerprint.kind == .mixed || fingerprint.kind == .unknown {
            return true
        }
        if fingerprint.containsMixedSeparators {
            return true
        }
        let separatorCount = countMatches(pattern: "[,，.。．:：]", in: text)
        return separatorCount >= 2
    }

    private static func hasGlobalMalformedNumericCluster(in text: String) -> Bool {
        if text.range(
            of: "\\d[\\d,，.。．:：]*[,，.。．:：][\\d,，.。．:：]*[,，.。．:：][\\d,，.。．:：]*\\d",
            options: .regularExpression
        ) != nil {
            return true
        }
        return text.range(
            of: "\\d[\\d,，.。．:：]*[,，][\\d,，.。．:：]*[.。．:：][\\d,，.。．:：]*\\d|\\d[\\d,，.。．:：]*[.。．:：][\\d,，.。．:：]*[,，][\\d,，.。．:：]*\\d",
            options: .regularExpression
        ) != nil
    }

    private static func isGroupedInteger(_ text: String) -> Bool {
        text.range(of: "^\\d{1,3}(?:[,，]\\d{3})+$", options: .regularExpression) != nil
    }

    private static func isPlainInteger(_ text: String) -> Bool {
        text.range(of: "^\\d+$", options: .regularExpression) != nil
    }

    private static func skeletonsComparable(_ preview: String, _ candidate: String) -> Bool {
        let previewSkeleton = structuralSkeleton(preview)
        let candidateSkeleton = structuralSkeleton(candidate)
        guard !previewSkeleton.isEmpty, !candidateSkeleton.isEmpty else { return false }
        if previewSkeleton == candidateSkeleton {
            return true
        }
        let maxLen = max(previewSkeleton.count, candidateSkeleton.count)
        let minLen = min(previewSkeleton.count, candidateSkeleton.count)
        let prefixLen = commonPrefixLength(previewSkeleton, candidateSkeleton)
        let suffixLen = commonSuffixLength(previewSkeleton, candidateSkeleton)
        let covered = min(minLen, prefixLen + suffixLen)
        let coverage = Double(covered) / Double(max(1, maxLen))
        return coverage >= 0.82
    }

    private static func structuralSkeleton(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: protectedSpanPattern) else {
            return canonicalComparable(text)
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "#")
        }
        let collapsed = (mutable as String).replacingOccurrences(
            of: "#+",
            with: "#",
            options: .regularExpression
        )
        let stripped = collapsed.replacingOccurrences(
            of: "[^\\p{Han}A-Za-z#]",
            with: "",
            options: .regularExpression
        )
        return stripped.replacingOccurrences(
            of: "#+",
            with: "#",
            options: .regularExpression
        )
    }

    private static func hardNumericIntegrityRegressionReason(
        previewText: String,
        candidateText: String
    ) -> String? {
        let previewSpans = protectedSpans(in: previewText).filter { $0.kind.isNumericLike }
        let candidateSpans = protectedSpans(in: candidateText).filter { $0.kind.isNumericLike }
        guard !previewSpans.isEmpty, !candidateSpans.isEmpty else { return nil }
        guard previewSpans.count == candidateSpans.count,
              skeletonsComparable(previewText, candidateText) else {
            if previewSpans.contains(where: { isStableProtectedSpan($0) }),
               candidateSpans.contains(where: { isSeverelyMalformedProtectedSpan($0) }) {
                return "numeric_alignment_unavailable"
            }
            return nil
        }

        for index in previewSpans.indices {
            if let reason = hardNumericRegressionReason(
                preview: previewSpans[index],
                candidate: candidateSpans[index]
            ) {
                return reason
            }
        }
        return nil
    }

    private static func hardNumericRegressionReason(
        preview: ProtectedSpan,
        candidate: ProtectedSpan
    ) -> String? {
        guard preview.kind.isNumericLike, candidate.kind.isNumericLike else { return nil }
        guard let previewFingerprint = preview.numericFingerprint,
              let candidateFingerprint = candidate.numericFingerprint else {
            return nil
        }
        guard previewFingerprint.kind != .mixed,
              previewFingerprint.kind != .unknown else {
            return nil
        }

        if candidateFingerprint.containsHanNumeric {
            return "mixed_han_in_numeric"
        }

        switch previewFingerprint.kind {
        case .integer:
            if candidateFingerprint.kind == .decimal {
                return "integer_became_decimal"
            }
            if candidateFingerprint.kind != .integer {
                return "numeric_shape_changed"
            }
            guard previewFingerprint.normalizedValue != candidateFingerprint.normalizedValue else {
                return nil
            }
            if previewFingerprint.digitCount != candidateFingerprint.digitCount {
                return "digit_count_changed"
            }
            return "numeric_value_changed"
        case .decimal:
            if candidateFingerprint.kind != .decimal {
                return "decimal_shape_changed"
            }
            return previewFingerprint.normalizedValue == candidateFingerprint.normalizedValue
                ? nil
                : "numeric_value_changed"
        case .percentage:
            if candidateFingerprint.kind != .percentage {
                return "percentage_shape_changed"
            }
            return previewFingerprint.normalizedValue == candidateFingerprint.normalizedValue
                ? nil
                : "numeric_value_changed"
        case .mixed, .unknown:
            return nil
        }
    }

    private static func sameNormalizedNumericValue(
        preview: ProtectedSpan,
        candidate: ProtectedSpan
    ) -> Bool {
        guard preview.kind.isNumericLike, candidate.kind.isNumericLike else { return false }
        guard let previewFingerprint = preview.numericFingerprint,
              let candidateFingerprint = candidate.numericFingerprint else {
            return false
        }
        guard let previewValue = previewFingerprint.normalizedValue,
              let candidateValue = candidateFingerprint.normalizedValue else {
            return false
        }
        if previewFingerprint.kind != candidateFingerprint.kind {
            return previewFingerprint.kind == .integer
                && candidateFingerprint.kind == .integer
                && previewValue == candidateValue
        }
        return previewValue == candidateValue
    }

    private static func preferredReplacementReason(
        existing: String?,
        candidate: String
    ) -> String {
        guard let existing else { return candidate }
        if isHardNumericReason(candidate) && !isHardNumericReason(existing) {
            return candidate
        }
        return existing
    }

    private static func isHardNumericReason(_ reason: String) -> Bool {
        reason == "numeric_value_changed"
            || reason == "integer_became_decimal"
            || reason == "digit_count_changed"
            || reason == "mixed_han_in_numeric"
            || reason == "numeric_shape_changed"
            || reason == "decimal_shape_changed"
            || reason == "percentage_shape_changed"
    }

    private static func numericFingerprint(for text: String) -> NumericFingerprint? {
        let trimmed = normalize(text)
        guard trimmed.range(of: "\\d", options: .regularExpression) != nil else {
            return nil
        }

        let containsHanNumeric = trimmed.range(
            of: hanNumericPattern,
            options: .regularExpression
        ) != nil
        let digitsOnly = asciiDigitsOnly(trimmed)
        let containsColonSeparator = trimmed.range(of: "[:：]") != nil
        let containsGroupingSeparator = trimmed.range(of: "[,，]", options: .regularExpression) != nil
        let containsMixedSeparators = trimmed.range(
            of: "[,，].*[.。．:：]|[.。．:：].*[,，]|[:：].*[.。．]|[.。．].*[:：]",
            options: .regularExpression
        ) != nil

        let kind: NumericFingerprintKind
        let normalizedValue: String?
        if containsHanNumeric {
            kind = .mixed
            normalizedValue = nil
        } else if trimmed.range(
            of: "^\\d+(?:[.。．,，]\\d+)?(?:%|％)$",
            options: .regularExpression
        ) != nil {
            kind = .percentage
            normalizedValue = normalizedPercentageValue(trimmed)
        } else if trimmed.range(of: "^\\d{1,3}(?:[,，]\\d{3})+$", options: .regularExpression) != nil
            || trimmed.range(of: "^\\d+$", options: .regularExpression) != nil {
            kind = .integer
            normalizedValue = normalizedIntegerValue(from: digitsOnly)
        } else if trimmed.range(of: "^\\d+[.。．,，]\\d+$", options: .regularExpression) != nil {
            kind = .decimal
            normalizedValue = normalizedDecimalValue(trimmed)
        } else {
            kind = .unknown
            normalizedValue = nil
        }

        return NumericFingerprint(
            rawText: trimmed,
            kind: kind,
            digitsOnly: digitsOnly,
            normalizedValue: normalizedValue,
            digitCount: digitsOnly.count,
            containsHanNumeric: containsHanNumeric,
            containsColonSeparator: containsColonSeparator,
            containsGroupingSeparator: containsGroupingSeparator,
            containsMixedSeparators: containsMixedSeparators
        )
    }

    private static func asciiDigitsOnly(_ text: String) -> String {
        let digits = text.compactMap { character -> Character? in
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  scalar.value >= 48,
                  scalar.value <= 57 else {
                return nil
            }
            return character
        }
        return String(digits)
    }

    private static func normalizedIntegerValue(from digits: String) -> String {
        let trimmed = digits.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func normalizedDecimalValue(_ text: String) -> String? {
        let canonical = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "．", with: ".")
        let parts = canonical.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let integerPart = normalizedIntegerValue(from: String(parts[0]))
        let fractionPart = String(parts[1]).replacingOccurrences(
            of: "0+$",
            with: "",
            options: .regularExpression
        )
        if fractionPart.isEmpty {
            return integerPart
        }
        return integerPart + "." + fractionPart
    }

    private static func normalizedPercentageValue(_ text: String) -> String? {
        let stripped = text.replacingOccurrences(
            of: "(?:%|％)$",
            with: "",
            options: .regularExpression
        )
        if stripped.range(of: "^\\d+$", options: .regularExpression) != nil {
            return normalizedIntegerValue(from: stripped) + "%"
        }
        guard let normalizedDecimal = normalizedDecimalValue(stripped) else { return nil }
        return normalizedDecimal + "%"
    }

    private static func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func canonicalComparable(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[^\\p{Han}A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    private static func commonSuffixLength(_ lhs: String, _ rhs: String) -> Int {
        let reversedPairs = zip(lhs.reversed(), rhs.reversed())
        var length = 0
        for (left, right) in reversedPairs {
            if left == right {
                length += 1
            } else {
                break
            }
        }
        return length
    }
}
