import Foundation

public struct CorrectionPair: Hashable {
    public let wrongTerm: String
    public let correctedTerm: String

    public init(wrongTerm: String, correctedTerm: String) {
        self.wrongTerm = wrongTerm
        self.correctedTerm = correctedTerm
    }
}

public enum LexiconReplacementSource: String, Sendable {
    case learnedRule
    case manualTerm
    case pronunciationRule
}

public struct LexiconReplacementHit: Equatable, Sendable {
    public let source: LexiconReplacementSource
    public let original: String
    public let replacement: String
    public let count: Int

    public init(
        source: LexiconReplacementSource,
        original: String,
        replacement: String,
        count: Int
    ) {
        self.source = source
        self.original = original
        self.replacement = replacement
        self.count = count
    }
}

public struct LexiconReplacementTrace: Equatable, Sendable {
    public let text: String
    public let hits: [LexiconReplacementHit]

    public init(text: String, hits: [LexiconReplacementHit]) {
        self.text = text
        self.hits = hits
    }
}

public final class LexiconService {
    private struct PronunciationPair: Hashable {
        let wrongPronKey: String
        let wrongLength: Int
        let correctedTerm: String
    }

    private struct PronunciationRule {
        let wrongPronKey: String
        let wrongLength: Int
        let correctedTerm: String
    }

    private var pairCounts: [CorrectionPair: Int] = [:]
    private var pronunciationPairCounts: [PronunciationPair: Int] = [:]
    private var pronunciationRulesByLength: [Int: [String: String]] = [:]
    private var lexicon: Set<String> = []
    private var manualTerms: Set<String> = []
    private var replacementRules: [String: String] = [:]
    private let threshold: Int
    private let sqliteStore: LexiconSQLiteStore?

    public init(
        threshold: Int = 10,
        enablePersistence: Bool = false,
        databasePath: String? = nil
    ) {
        self.threshold = threshold
        if enablePersistence {
            self.sqliteStore = try? LexiconSQLiteStore(databasePath: databasePath)
            if let store = self.sqliteStore, let loaded = try? store.fetchPersonalTerms() {
                self.lexicon = loaded
                self.replacementRules = (try? store.fetchPreferredReplacements()) ?? [:]
                self.manualTerms = Set((try? store.fetchManualTerms()) ?? [])
                self.pronunciationRulesByLength = Self.groupPronunciationRulesByLength(
                    rules: (try? store.fetchPreferredPronunciationMappings()) ?? []
                )
            }
        } else {
            self.sqliteStore = nil
        }
    }

    public func recordCorrection(wrong: String, corrected: String) {
        guard !wrong.isEmpty, !corrected.isEmpty, wrong != corrected else {
            return
        }

        let pair = CorrectionPair(wrongTerm: wrong, correctedTerm: corrected)
        let next: Int
        if let sqliteStore {
            next = (try? sqliteStore.incrementCorrectionPair(wrong: wrong, corrected: corrected)) ?? ((pairCounts[pair] ?? 0) + 1)
        } else {
            next = (pairCounts[pair] ?? 0) + 1
        }
        pairCounts[pair] = next

        if let pronunciationLearning = pronunciationLearningCandidate(wrong: wrong, corrected: corrected) {
            let pronunciationPair = PronunciationPair(
                wrongPronKey: pronunciationLearning.wrongPronKey,
                wrongLength: pronunciationLearning.wrongLength,
                correctedTerm: pronunciationLearning.correctedTerm
            )
            let nextPronunciationCount: Int
            if let sqliteStore {
                nextPronunciationCount =
                    (try? sqliteStore.incrementPronunciationPair(
                        wrongPronKey: pronunciationLearning.wrongPronKey,
                        wrongLength: pronunciationLearning.wrongLength,
                        corrected: pronunciationLearning.correctedTerm
                    )) ?? ((pronunciationPairCounts[pronunciationPair] ?? 0) + 1)
            } else {
                nextPronunciationCount = (pronunciationPairCounts[pronunciationPair] ?? 0) + 1
            }
            pronunciationPairCounts[pronunciationPair] = nextPronunciationCount
        }

        if next >= threshold {
            lexicon.insert(corrected)
            if let sqliteStore {
                try? sqliteStore.upsertPersonalTerm(corrected)
            }
        }
        refreshReplacementRules()
    }

    public func correctionCount(wrong: String, corrected: String) -> Int {
        if let sqliteStore,
           let count = try? sqliteStore.correctionCount(wrong: wrong, corrected: corrected) {
            return count
        }
        return pairCounts[CorrectionPair(wrongTerm: wrong, correctedTerm: corrected)] ?? 0
    }

    public func containsInPersonalLexicon(_ term: String) -> Bool {
        if lexicon.contains(term) {
            return true
        }
        if let sqliteStore,
           let contains = try? sqliteStore.containsPersonalTerm(term),
           contains {
            lexicon.insert(term)
            refreshReplacementRules()
            return true
        }
        return false
    }

    public func prioritizedReplacement(
        in text: String,
        includeFuzzyManualReplacement: Bool = true
    ) -> String {
        prioritizedReplacementWithTrace(
            in: text,
            includeFuzzyManualReplacement: includeFuzzyManualReplacement
        ).text
    }

    public func prioritizedReplacementWithTrace(
        in text: String,
        includeFuzzyManualReplacement: Bool = true
    ) -> LexiconReplacementTrace {
        var output = text
        var hits: [LexiconReplacementHit] = []

        let terms = sortedManualTerms()
        let manualFirstPass = applyManualTermNormalization(
            in: output,
            terms: terms,
            includeFuzzy: includeFuzzyManualReplacement
        )
        output = manualFirstPass.text
        hits.append(contentsOf: manualFirstPass.hits)

        if !replacementRules.isEmpty {
            let protected = maskProtectedManualTerms(in: output, terms: terms)
            output = protected.text
            let keys = replacementRules.keys.sorted { $0.count > $1.count }
            for wrong in keys {
                guard let corrected = replacementRules[wrong],
                      !wrong.isEmpty, wrong != corrected else {
                    continue
                }
                let replaced = applyReplacement(wrong: wrong, corrected: corrected, in: output)
                output = replaced.text
                if replaced.count > 0 {
                    hits.append(
                        LexiconReplacementHit(
                            source: .learnedRule,
                            original: wrong,
                            replacement: corrected,
                            count: replaced.count
                        )
                    )
                }
            }
            let pronunciationPass = applyPronunciationRuleReplacement(in: output)
            output = pronunciationPass.text
            hits.append(contentsOf: pronunciationPass.hits)
            output = unmaskProtectedManualTerms(in: output, tokenToTerm: protected.tokenToTerm)
        }

        let manualSecondPass = applyManualTermNormalization(
            in: output,
            terms: terms,
            includeFuzzy: includeFuzzyManualReplacement
        )
        output = manualSecondPass.text
        hits.append(contentsOf: manualSecondPass.hits)
        return LexiconReplacementTrace(text: output, hits: hits)
    }

    public func addManualTerms(_ terms: [String]) {
        let normalized = normalizeManualTerms(terms)
        guard !normalized.isEmpty else { return }
        for term in normalized {
            manualTerms.insert(term)
            if let sqliteStore {
                try? sqliteStore.upsertManualTerm(term)
            }
        }
    }

    public func listManualTerms() -> [String] {
        if let sqliteStore,
           let persisted = try? sqliteStore.fetchManualTerms() {
            manualTerms = Set(persisted)
            return persisted
        }
        return manualTerms.sorted()
    }

    public func listPersonalTermsForDisplay() -> [String] {
        if let sqliteStore,
           let persistedPersonal = try? sqliteStore.fetchPersonalTerms(),
           let persistedManual = try? sqliteStore.fetchManualTerms() {
            lexicon = persistedPersonal
            manualTerms = Set(persistedManual)
            return sortTermsForDisplay(Array(persistedPersonal.union(manualTerms)))
        }
        return sortTermsForDisplay(Array(lexicon.union(manualTerms)))
    }

    public func listLearnedTermsForDisplay() -> [String] {
        if let sqliteStore,
           let persistedPersonal = try? sqliteStore.fetchPersonalTerms(),
           let persistedManual = try? sqliteStore.fetchManualTerms() {
            lexicon = persistedPersonal
            manualTerms = Set(persistedManual)
            return sortTermsForDisplay(Array(persistedPersonal.subtracting(manualTerms)))
        }
        return sortTermsForDisplay(Array(lexicon.subtracting(manualTerms)))
    }

    public func removeManualTerm(_ term: String) {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        manualTerms.remove(normalized)
        if let sqliteStore {
            try? sqliteStore.deleteManualTerm(normalized)
        }
    }

    public func removePersonalTerm(_ term: String) {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        manualTerms.remove(normalized)
        lexicon.remove(normalized)
        if let sqliteStore {
            try? sqliteStore.deleteManualTerm(normalized)
            try? sqliteStore.deletePersonalTerm(normalized)
        }
        refreshReplacementRules()
    }

    public func clearPersonalLexiconData(resetCorrectionCounts: Bool = true) {
        lexicon.removeAll()
        manualTerms.removeAll()
        replacementRules.removeAll()
        if resetCorrectionCounts {
            pairCounts.removeAll()
            pronunciationPairCounts.removeAll()
        }

        guard let sqliteStore else { return }
        if resetCorrectionCounts {
            try? sqliteStore.clearCorrectionPairs()
            try? sqliteStore.clearPronunciationPairs()
        }
        try? sqliteStore.clearPersonalLexicon()
        try? sqliteStore.clearManualLexicon()
        refreshReplacementRules()
    }

    private func refreshReplacementRules() {
        if let sqliteStore,
           let rules = try? sqliteStore.fetchPreferredReplacements() {
            replacementRules = rules
            pronunciationRulesByLength = Self.groupPronunciationRulesByLength(
                rules: (try? sqliteStore.fetchPreferredPronunciationMappings()) ?? []
            )
            return
        }
        replacementRules = buildInMemoryReplacementRules()
        pronunciationRulesByLength = buildInMemoryPronunciationRulesByLength()
    }

    private func buildInMemoryReplacementRules() -> [String: String] {
        var best: [String: (corrected: String, count: Int)] = [:]
        for (pair, count) in pairCounts where lexicon.contains(pair.correctedTerm) {
            if let existing = best[pair.wrongTerm], existing.count >= count {
                continue
            }
            best[pair.wrongTerm] = (pair.correctedTerm, count)
        }

        var rules: [String: String] = [:]
        for (wrong, entry) in best {
            rules[wrong] = entry.corrected
        }
        return rules
    }

    private func buildInMemoryPronunciationRulesByLength() -> [Int: [String: String]] {
        var best: [String: (corrected: String, count: Int)] = [:]

        for (pair, count) in pronunciationPairCounts {
            let key = "\(pair.wrongLength)|\(pair.wrongPronKey)"
            if let existing = best[key], existing.count >= count {
                continue
            }
            guard lexicon.contains(pair.correctedTerm) || manualTerms.contains(pair.correctedTerm) else {
                continue
            }
            best[key] = (pair.correctedTerm, count)
        }

        var grouped: [Int: [String: String]] = [:]
        for (compositeKey, entry) in best {
            let parts = compositeKey.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let length = Int(parts[0]), length >= 2 else { continue }
            var mapping = grouped[length] ?? [:]
            mapping[parts[1]] = entry.corrected
            grouped[length] = mapping
        }
        return grouped
    }

    private static func groupPronunciationRulesByLength(
        rules: [LexiconSQLiteStore.PronunciationMapping]
    ) -> [Int: [String: String]] {
        var grouped: [Int: [String: String]] = [:]
        for rule in rules where rule.wrongLength >= 2 {
            var mapping = grouped[rule.wrongLength] ?? [:]
            if mapping[rule.wrongPronKey] == nil {
                mapping[rule.wrongPronKey] = rule.correctedTerm
                grouped[rule.wrongLength] = mapping
            }
        }
        return grouped
    }

    private func pronunciationLearningCandidate(
        wrong: String,
        corrected: String
    ) -> (wrongPronKey: String, wrongLength: Int, correctedTerm: String)? {
        let normalizedWrong = normalizePronunciationLearningTerm(wrong)
        let normalizedCorrected = normalizePronunciationLearningTerm(corrected)
        guard normalizedWrong.count >= 2, normalizedWrong.count <= 12 else { return nil }
        guard normalizedCorrected.count >= 2, normalizedCorrected.count <= 12 else { return nil }

        let wrongKey = pronunciationKey(for: normalizedWrong)
        let correctedKey = pronunciationKey(for: normalizedCorrected)
        guard !wrongKey.isEmpty, wrongKey == correctedKey else { return nil }
        return (wrongKey, normalizedWrong.count, normalizedCorrected)
    }

    private func applyPronunciationRuleReplacement(
        in text: String
    ) -> (text: String, hits: [LexiconReplacementHit]) {
        guard !pronunciationRulesByLength.isEmpty else { return (text, []) }

        var chars = Array(text)
        let lengths = pronunciationRulesByLength.keys.sorted(by: >)
        guard !lengths.isEmpty else { return (text, []) }

        var index = 0
        var hitCounts: [String: (original: String, replacement: String, count: Int)] = [:]
        while index < chars.count {
            var matched = false
            for length in lengths {
                guard length >= 2, index + length <= chars.count else { continue }
                let slice = chars[index..<(index + length)]
                guard isPronunciationCandidate(Array(slice)) else { continue }

                let candidate = String(slice)
                let candidateKey = pronunciationKey(for: candidate)
                guard !candidateKey.isEmpty,
                      let corrected = pronunciationRulesByLength[length]?[candidateKey],
                      corrected != candidate else {
                    continue
                }

                let replacementChars = Array(corrected)
                chars.replaceSubrange(index..<(index + length), with: replacementChars)
                let hitKey = "\(candidate)->\(corrected)"
                let existing = hitCounts[hitKey] ?? (candidate, corrected, 0)
                hitCounts[hitKey] = (existing.original, existing.replacement, existing.count + 1)
                index += replacementChars.count
                matched = true
                break
            }

            if !matched {
                index += 1
            }
        }

        guard !hitCounts.isEmpty else { return (text, []) }
        let sortedKeys = hitCounts.keys.sorted()
        var hits: [LexiconReplacementHit] = []
        for key in sortedKeys {
            guard let hit = hitCounts[key] else { continue }
            hits.append(
                LexiconReplacementHit(
                    source: .pronunciationRule,
                    original: hit.original,
                    replacement: hit.replacement,
                    count: hit.count
                )
            )
        }
        return (String(chars), hits)
    }

    private func applyReplacement(wrong: String, corrected: String, in text: String) -> (text: String, count: Int) {
        let escaped = NSRegularExpression.escapedPattern(for: wrong)
        let pattern: String
        if wrong.range(of: "[A-Za-z0-9_]", options: .regularExpression) != nil {
            pattern = "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
        } else {
            pattern = escaped
        }
        return applyRegexReplacement(pattern: pattern, replacement: corrected, in: text)
    }

    private func sortedManualTerms() -> [String] {
        guard !manualTerms.isEmpty else { return [] }
        return sortTermsForDisplay(Array(manualTerms))
    }

    private func sortTermsForDisplay(_ terms: [String]) -> [String] {
        terms.sorted { lhs, rhs in
            if lhs.count == rhs.count { return lhs < rhs }
            return lhs.count > rhs.count
        }
    }

    private func applyManualTermNormalization(
        in text: String,
        terms: [String],
        includeFuzzy: Bool
    ) -> (text: String, hits: [LexiconReplacementHit]) {
        guard !terms.isEmpty else { return (text, []) }

        var output = text
        var hits: [LexiconReplacementHit] = []

        for term in terms {
            guard term.count >= 2, !term.contains(where: \.isNewline) else { continue }
            let replaced = applySpacedTermReplacement(term: term, in: output)
            output = replaced.text
            if replaced.count > 0 {
                hits.append(
                    LexiconReplacementHit(
                        source: .manualTerm,
                        original: term + "（空格变体）",
                        replacement: term,
                        count: replaced.count
                    )
                )
            }

            if includeFuzzy {
                let fuzzy = applyFuzzyTermReplacement(term: term, in: output)
                output = fuzzy.text
                if fuzzy.count > 0 {
                    hits.append(
                        LexiconReplacementHit(
                            source: .manualTerm,
                            original: term + "（近似纠偏）",
                            replacement: term,
                            count: fuzzy.count
                        )
                    )
                }
            }
        }
        return (output, hits)
    }

    private func applySpacedTermReplacement(term: String, in text: String) -> (text: String, count: Int) {
        let compactTerm = term.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactTerm.isEmpty else { return (text, 0) }
        guard !compactTerm.contains(" ") else { return (text, 0) }

        let escapedChars = compactTerm.map { NSRegularExpression.escapedPattern(for: String($0)) }
        let core = escapedChars.joined(separator: "\\s*")
        guard !core.isEmpty else { return (text, 0) }

        let hasLatinOrDigit = compactTerm.range(of: "[A-Za-z0-9_]", options: .regularExpression) != nil
        let pattern: String
        if hasLatinOrDigit {
            pattern = "(?i)(?<![A-Za-z0-9_])" + core + "(?![A-Za-z0-9_])"
        } else {
            pattern = core
        }

        return applyRegexReplacement(pattern: pattern, replacement: compactTerm, in: text)
    }

    private func applyRegexReplacement(
        pattern: String,
        replacement: String,
        in text: String
    ) -> (text: String, count: Int) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, 0)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let count = regex.numberOfMatches(in: text, options: [], range: range)
        guard count > 0 else { return (text, 0) }
        let replaced = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        return (replaced, count)
    }

    private func applyFuzzyTermReplacement(term: String, in text: String) -> (text: String, count: Int) {
        let normalized = term
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else { return (text, 0) }
        guard !normalized.contains(where: { $0.isASCII }) else { return (text, 0) }
        guard normalized.contains(where: isCJKCharacter) else { return (text, 0) }

        let target = Array(normalized)
        let targetLength = target.count
        let maxDistance = targetLength >= 5 ? 2 : 1
        let windowLength = targetLength

        var chars = Array(text)
        guard chars.count >= windowLength else { return (text, 0) }

        var index = 0
        var replacedCount = 0
        while index + windowLength <= chars.count {
            let end = index + windowLength
            let candidate = Array(chars[index..<end])
            if candidate == target || shouldSkipFuzzyCandidate(candidate) {
                index += 1
                continue
            }

            guard let distance = boundedLevenshteinDistance(candidate, target, maxDistance: maxDistance),
                  distance > 0 else {
                index += 1
                continue
            }

            let normalizedDistance = Double(distance) / Double(targetLength)
            guard normalizedDistance <= 0.34 else {
                index += 1
                continue
            }

            let range = index..<end
            chars.replaceSubrange(range, with: target)
            replacedCount += 1
            index += targetLength
        }

        guard replacedCount > 0 else { return (text, 0) }
        return (String(chars), replacedCount)
    }

    private func maskProtectedManualTerms(
        in text: String,
        terms: [String]
    ) -> (text: String, tokenToTerm: [String: String]) {
        guard !terms.isEmpty else { return (text, [:]) }

        var output = text
        var tokenToTerm: [String: String] = [:]
        var tokenIndex = 0

        for term in terms {
            guard term.count >= 2 else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern: String
            if term.range(of: "[A-Za-z0-9_]", options: .regularExpression) != nil {
                pattern = "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
            } else {
                pattern = escaped
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let searchRange = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = regex.matches(in: output, options: [], range: searchRange)
            guard !matches.isEmpty else { continue }

            for match in matches.reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let token = "\u{F8FF}M\(tokenIndex)\u{F8FE}"
                output.replaceSubrange(range, with: token)
                tokenToTerm[token] = term
                tokenIndex += 1
            }
        }

        return (output, tokenToTerm)
    }

    private func unmaskProtectedManualTerms(
        in text: String,
        tokenToTerm: [String: String]
    ) -> String {
        guard !tokenToTerm.isEmpty else { return text }
        var output = text
        for (token, term) in tokenToTerm {
            output = output.replacingOccurrences(of: token, with: term)
        }
        return output
    }

    private func shouldSkipFuzzyCandidate(_ chars: [Character]) -> Bool {
        if chars.isEmpty { return true }
        if chars.contains(where: \.isWhitespace) { return true }
        if chars.contains(where: \.isNewline) { return true }
        if chars.allSatisfy(\.isASCII) { return true }
        if !chars.contains(where: isCJKCharacter) { return true }

        for char in chars {
            if String(char).rangeOfCharacter(from: .punctuationCharacters) != nil {
                return true
            }
        }
        return false
    }

    private func isPronunciationCandidate(_ chars: [Character]) -> Bool {
        guard chars.count >= 2 else { return false }
        guard !chars.contains(where: \.isWhitespace) else { return false }
        guard !chars.contains(where: \.isNewline) else { return false }
        guard chars.allSatisfy(isCJKCharacter) else { return false }
        for char in chars {
            if String(char).rangeOfCharacter(from: .punctuationCharacters) != nil {
                return false
            }
        }
        return true
    }

    private func boundedLevenshteinDistance(
        _ source: [Character],
        _ target: [Character],
        maxDistance: Int
    ) -> Int? {
        if abs(source.count - target.count) > maxDistance {
            return nil
        }

        var previous = Array(0...target.count)
        var current = Array(repeating: 0, count: target.count + 1)

        for i in 1...source.count {
            current[0] = i
            var rowMin = current[0]

            for j in 1...target.count {
                let cost = source[i - 1] == target[j - 1] ? 0 : 1
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                let substitution = previous[j - 1] + cost
                let best = min(deletion, insertion, substitution)
                current[j] = best
                if best < rowMin {
                    rowMin = best
                }
            }

            if rowMin > maxDistance {
                return nil
            }
            swap(&previous, &current)
        }

        let distance = previous[target.count]
        return distance <= maxDistance ? distance : nil
    }

    private func isCJKCharacter(_ char: Character) -> Bool {
        for scalar in char.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    private func normalizeManualTerms(_ terms: [String]) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []

        for raw in terms {
            let normalized = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }

    private func normalizePronunciationLearningTerm(_ term: String) -> String {
        let compact = term
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "" }
        guard compact.allSatisfy(isCJKCharacter) else { return "" }
        return compact
    }

    private func pronunciationKey(for text: String) -> String {
        guard !text.isEmpty else { return "" }
        let mutable = NSMutableString(string: text)
        let transformed = CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        guard transformed else { return "" }
        let folded = (mutable as String).folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        return folded.replacingOccurrences(
            of: "[^a-z0-9]",
            with: "",
            options: .regularExpression
        )
    }
}
