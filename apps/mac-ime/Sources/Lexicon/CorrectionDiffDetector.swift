import Foundation

public struct PunctuationDiffEvent: Equatable, Sendable {
    public let sourcePunctuation: String
    public let targetPunctuation: String
    public let contextBefore: String
    public let contextAfter: String
    public let timestamp: Date
    public let appIdentifier: String?
    public let confidence: Double

    public init(
        sourcePunctuation: String,
        targetPunctuation: String,
        contextBefore: String,
        contextAfter: String,
        timestamp: Date,
        appIdentifier: String?,
        confidence: Double
    ) {
        self.sourcePunctuation = sourcePunctuation
        self.targetPunctuation = targetPunctuation
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.timestamp = timestamp
        self.appIdentifier = appIdentifier
        self.confidence = confidence
    }
}

public enum CorrectionDiffDetector {
    private static let maxPhraseLength = 40

    public static func detectPairs(from original: String, to updated: String, maxPairs: Int = 3) -> [CorrectionPair] {
        guard original != updated else { return [] }
        let oldChars = Array(original)
        let newChars = Array(updated)
        let diff = newChars.difference(from: oldChars)

        var removedChars: [(offset: Int, char: Character)] = []
        var insertedChars: [(offset: Int, char: Character)] = []

        for change in diff {
            switch change {
            case .remove(let offset, let element, _):
                removedChars.append((offset: offset, char: element))
            case .insert(let offset, let element, _):
                insertedChars.append((offset: offset, char: element))
            }
        }

        let removedSegments = collapseContiguousSegments(removedChars.sorted { $0.offset < $1.offset })
        let insertedSegments = collapseContiguousSegments(insertedChars.sorted { $0.offset < $1.offset })
        guard !removedSegments.isEmpty, !insertedSegments.isEmpty else { return [] }

        var pairs: [CorrectionPair] = []
        pairs.reserveCapacity(maxPairs)
        var seen: Set<CorrectionPair> = []

        if let phrasePair = detectPrimaryPhrasePair(from: original, to: updated) {
            appendPairIfNeeded(
                wrong: phrasePair.wrongTerm,
                corrected: phrasePair.correctedTerm,
                pairs: &pairs,
                seen: &seen,
                maxPairs: maxPairs
            )
        }

        let pairCount = min(maxPairs, min(removedSegments.count, insertedSegments.count))

        for index in 0..<pairCount {
            appendPairIfNeeded(
                wrong: removedSegments[index],
                corrected: insertedSegments[index],
                pairs: &pairs,
                seen: &seen,
                maxPairs: maxPairs
            )
            if pairs.count >= maxPairs {
                break
            }
        }

        return pairs
    }

    public static func detectPunctuationEvents(
        from original: String,
        to updated: String,
        contextWindow: Int = 8,
        maxEvents: Int = 8,
        appIdentifier: String? = nil,
        timestamp: Date = Date()
    ) -> [PunctuationDiffEvent] {
        guard original != updated else { return [] }
        guard maxEvents > 0 else { return [] }

        let oldChars = Array(original)
        let newChars = Array(updated)
        let diff = newChars.difference(from: oldChars)

        var removedChars: [(offset: Int, char: Character)] = []
        var insertedChars: [(offset: Int, char: Character)] = []

        for change in diff {
            switch change {
            case .remove(let offset, let element, _):
                removedChars.append((offset: offset, char: element))
            case .insert(let offset, let element, _):
                insertedChars.append((offset: offset, char: element))
            }
        }

        let removedSegments = collapseContiguousSegmentsWithOffsets(removedChars.sorted { $0.offset < $1.offset })
        let insertedSegments = collapseContiguousSegmentsWithOffsets(insertedChars.sorted { $0.offset < $1.offset })
        guard !removedSegments.isEmpty || !insertedSegments.isEmpty else { return [] }

        var events: [PunctuationDiffEvent] = []
        let pairCount = max(removedSegments.count, insertedSegments.count)
        events.reserveCapacity(min(maxEvents, pairCount))

        for index in 0..<pairCount {
            let removed = index < removedSegments.count ? removedSegments[index] : nil
            let inserted = index < insertedSegments.count ? insertedSegments[index] : nil

            let sourcePunctuation = extractPunctuationToken(from: removed?.text ?? "")
            let targetPunctuation = extractPunctuationToken(from: inserted?.text ?? "")
            guard sourcePunctuation != targetPunctuation else { continue }
            guard !sourcePunctuation.isEmpty || !targetPunctuation.isEmpty else { continue }

            let contextAnchor = inserted?.offset ?? removed?.offset ?? 0
            let context = extractContext(in: updated, around: contextAnchor, window: contextWindow)
            let confidence = punctuationEventConfidence(
                sourcePunctuation: sourcePunctuation,
                targetPunctuation: targetPunctuation,
                rawRemoved: removed?.text ?? "",
                rawInserted: inserted?.text ?? "",
                contextBefore: context.before,
                contextAfter: context.after
            )
            guard confidence >= 0.35 else { continue }

            events.append(
                PunctuationDiffEvent(
                    sourcePunctuation: sourcePunctuation,
                    targetPunctuation: targetPunctuation,
                    contextBefore: context.before,
                    contextAfter: context.after,
                    timestamp: timestamp,
                    appIdentifier: appIdentifier,
                    confidence: confidence
                )
            )
            if events.count >= maxEvents {
                break
            }
        }

        return events
    }

    private static func detectPrimaryPhrasePair(from original: String, to updated: String) -> CorrectionPair? {
        let oldChars = Array(original)
        let newChars = Array(updated)

        let minCount = min(oldChars.count, newChars.count)
        var prefix = 0
        while prefix < minCount, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var oldTail = oldChars.count - 1
        var newTail = newChars.count - 1
        while oldTail >= prefix, newTail >= prefix, oldChars[oldTail] == newChars[newTail] {
            oldTail -= 1
            newTail -= 1
        }

        guard oldTail >= prefix || newTail >= prefix else { return nil }
        guard oldTail >= prefix, newTail >= prefix else { return nil }

        let wrong = String(oldChars[prefix...oldTail])
        let corrected = String(newChars[prefix...newTail])
        return CorrectionPair(wrongTerm: wrong, correctedTerm: corrected)
    }

    private static func appendPairIfNeeded(
        wrong: String,
        corrected: String,
        pairs: inout [CorrectionPair],
        seen: inout Set<CorrectionPair>,
        maxPairs: Int
    ) {
        guard pairs.count < maxPairs else { return }

        let sanitizedWrong = sanitizeSegment(wrong)
        let sanitizedCorrected = sanitizeSegment(corrected)
        guard isMeaningfulToken(sanitizedWrong),
              isMeaningfulToken(sanitizedCorrected),
              sanitizedWrong != sanitizedCorrected else {
            return
        }
        guard sanitizedWrong.count <= maxPhraseLength,
              sanitizedCorrected.count <= maxPhraseLength else {
            return
        }
        guard !isLikelyPinyinIntermediate(wrong: sanitizedWrong, corrected: sanitizedCorrected) else {
            return
        }

        let pair = CorrectionPair(wrongTerm: sanitizedWrong, correctedTerm: sanitizedCorrected)
        guard !seen.contains(pair) else { return }
        seen.insert(pair)
        pairs.append(pair)
    }

    private static func collapseContiguousSegments(_ chars: [(offset: Int, char: Character)]) -> [String] {
        guard !chars.isEmpty else { return [] }

        var segments: [String] = []
        var current = String(chars[0].char)
        var previousOffset = chars[0].offset

        for item in chars.dropFirst() {
            if item.offset == previousOffset + 1 {
                current.append(item.char)
            } else {
                segments.append(current)
                current = String(item.char)
            }
            previousOffset = item.offset
        }
        segments.append(current)
        return segments
    }

    private static func collapseContiguousSegmentsWithOffsets(
        _ chars: [(offset: Int, char: Character)]
    ) -> [(offset: Int, text: String)] {
        guard !chars.isEmpty else { return [] }

        var segments: [(offset: Int, text: String)] = []
        var segmentStart = chars[0].offset
        var current = String(chars[0].char)
        var previousOffset = chars[0].offset

        for item in chars.dropFirst() {
            if item.offset == previousOffset + 1 {
                current.append(item.char)
            } else {
                segments.append((offset: segmentStart, text: current))
                segmentStart = item.offset
                current = String(item.char)
            }
            previousOffset = item.offset
        }
        segments.append((offset: segmentStart, text: current))
        return segments
    }

    private static func sanitizeSegment(_ segment: String) -> String {
        segment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func isMeaningfulToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.range(of: "\\p{Han}|[A-Za-z0-9]", options: .regularExpression) != nil
    }

    private static func extractPunctuationToken(from text: String) -> String {
        let filtered = text.filter { isPunctuationCharacter($0) }
        return String(filtered.prefix(2))
    }

    private static func punctuationEventConfidence(
        sourcePunctuation: String,
        targetPunctuation: String,
        rawRemoved: String,
        rawInserted: String,
        contextBefore: String,
        contextAfter: String
    ) -> Double {
        var score = sourcePunctuation.isEmpty || targetPunctuation.isEmpty ? 0.64 : 0.74
        let rawCombined = rawRemoved + rawInserted
        if rawCombined.range(of: "\\p{Han}|[A-Za-z]", options: .regularExpression) != nil {
            score -= 0.22
        }
        if (sourcePunctuation.contains(".") || sourcePunctuation.contains(",")
            || targetPunctuation.contains(".") || targetPunctuation.contains(","))
            && isLikelyNumericPunctuationContext(contextBefore: contextBefore, contextAfter: contextAfter) {
            score -= 0.30
        }
        if contentCharacterCount(contextBefore + contextAfter) <= 1 {
            score -= 0.18
        }
        return min(1, max(0, score))
    }

    private static func isLikelyNumericPunctuationContext(contextBefore: String, contextAfter: String) -> Bool {
        guard let before = contextBefore.last else { return false }
        guard before.isNumber else { return false }
        guard let after = contextAfter.first else { return false }
        if after.isNumber {
            return true
        }
        if isPunctuationCharacter(after),
           let second = contextAfter.dropFirst().first {
            return second.isNumber
        }
        return false
    }

    private static func contentCharacterCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "\\p{Han}|[A-Za-z0-9]") else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func extractContext(
        in text: String,
        around anchor: Int,
        window: Int
    ) -> (before: String, after: String) {
        let chars = Array(text)
        guard !chars.isEmpty else { return ("", "") }

        let safeAnchor = min(max(anchor, 0), chars.count)
        let width = max(1, window)
        let beforeStart = max(0, safeAnchor - width)
        let afterEnd = min(chars.count, safeAnchor + width)
        let before = String(chars[beforeStart..<safeAnchor])
        let after = String(chars[safeAnchor..<afterEnd])
        return (before, after)
    }

    private static func isPunctuationCharacter(_ char: Character) -> Bool {
        char.isPunctuation || "，。！？；：、,.!?;:".contains(char)
    }

    private static func isLikelyPinyinIntermediate(wrong: String, corrected: String) -> Bool {
        let wrongHasHan = containsHan(wrong)
        let correctedHasHan = containsHan(corrected)
        guard wrongHasHan != correctedHasHan else {
            return false
        }

        // Skip transitions between Han text and short pure-latin syllables
        // generated by IME composition (e.g. "似莫格 -> si", "wei -> 唯卓仕").
        if isPureLatinWord(wrong) || isPureLatinWord(corrected) {
            return true
        }
        return false
    }

    private static func containsHan(_ token: String) -> Bool {
        token.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    private static func isPureLatinWord(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z]{1,12}$", options: .regularExpression) != nil
    }
}
