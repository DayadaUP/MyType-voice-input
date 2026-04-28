import Foundation

public struct EffectiveLiveCommitState: Equatable, Sendable {
    public let committedText: String
    public let hasSuccessfulInsertion: Bool

    public init(committedText: String, hasSuccessfulInsertion: Bool) {
        self.committedText = committedText
        self.hasSuccessfulInsertion = hasSuccessfulInsertion
    }
}

public enum FinalInsertionGuard {
    public static func shouldAllowLiveInsert(stopTransitionActive: Bool) -> Bool {
        !stopTransitionActive
    }

    public static func resolveEffectiveLiveCommitState(
        snapshotCommittedText: String,
        snapshotHasSuccessfulInsertion: Bool,
        latestCommittedText: String,
        latestHasSuccessfulInsertion: Bool
    ) -> EffectiveLiveCommitState {
        let snapshot = snapshotCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = latestCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)

        let snapshotHasInsert = snapshotHasSuccessfulInsertion && !snapshot.isEmpty
        let latestHasInsert = latestHasSuccessfulInsertion && !latest.isEmpty

        guard snapshotHasInsert || latestHasInsert else {
            return EffectiveLiveCommitState(committedText: "", hasSuccessfulInsertion: false)
        }
        if snapshotHasInsert && !latestHasInsert {
            return EffectiveLiveCommitState(committedText: snapshot, hasSuccessfulInsertion: true)
        }
        if latestHasInsert && !snapshotHasInsert {
            return EffectiveLiveCommitState(committedText: latest, hasSuccessfulInsertion: true)
        }

        let resolved = coveragePreferredCommittedText(snapshot, latest)
        guard !resolved.isEmpty else {
            return EffectiveLiveCommitState(committedText: "", hasSuccessfulInsertion: false)
        }
        return EffectiveLiveCommitState(committedText: resolved, hasSuccessfulInsertion: true)
    }

    public static func pendingFinalInsertionText(
        finalText: String,
        liveCommittedText: String,
        liveHasSuccessfulInsertion: Bool
    ) -> String {
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return "" }
        guard liveHasSuccessfulInsertion else { return final }

        let live = liveCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty else { return final }

        if shouldSkipFinalInsertForNearEquivalentTexts(
            liveCommittedText: live,
            finalText: final
        ) {
            return ""
        }

        if final.hasPrefix(live) {
            let start = final.index(final.startIndex, offsetBy: live.count)
            return String(final[start...])
        }
        if live.hasPrefix(final) {
            return ""
        }

        let overlap = suffixPrefixOverlapLength(left: live, right: final)
        guard overlap > 0 else {
            return final
        }

        let start = final.index(final.startIndex, offsetBy: overlap)
        return String(final[start...])
    }

    public static func shouldSkipFinalInsertForNearEquivalentTexts(
        liveCommittedText: String,
        finalText: String,
        coverageThreshold: Double = 0.82
    ) -> Bool {
        let liveCanonical = normalizedForComparison(liveCommittedText)
        let finalCanonical = normalizedForComparison(finalText)
        guard !liveCanonical.isEmpty, !finalCanonical.isEmpty else { return false }

        if liveCanonical == finalCanonical {
            return true
        }

        let maxLen = max(liveCanonical.count, finalCanonical.count)
        let minLen = min(liveCanonical.count, finalCanonical.count)
        guard maxLen >= 8 else { return false }

        let lengthDelta = maxLen - minLen
        if lengthDelta > max(6, Int(Double(maxLen) * 0.30)) {
            return false
        }

        if (liveCanonical.contains(finalCanonical) || finalCanonical.contains(liveCanonical)),
           lengthDelta <= 4 {
            return true
        }

        let prefixLen = commonPrefix(liveCanonical, finalCanonical).count
        let suffixLen = commonSuffixLength(liveCanonical, finalCanonical)
        let covered = min(minLen, prefixLen + suffixLen)
        let coverage = Double(covered) / Double(maxLen)
        return coverage >= coverageThreshold
    }

    private static func coveragePreferredCommittedText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        let lhsCanonical = normalizedForComparison(lhs)
        let rhsCanonical = normalizedForComparison(rhs)

        guard !lhsCanonical.isEmpty else { return rhs }
        guard !rhsCanonical.isEmpty else { return lhs }

        if lhsCanonical == rhsCanonical {
            return lhs.count >= rhs.count ? lhs : rhs
        }
        if lhsCanonical.contains(rhsCanonical) {
            return lhs
        }
        if rhsCanonical.contains(lhsCanonical) {
            return rhs
        }
        if lhsCanonical.count == rhsCanonical.count {
            return rhs
        }
        return lhsCanonical.count > rhsCanonical.count ? lhs : rhs
    }

    private static func normalizedForComparison(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[^\\p{Han}A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
    }

    private static func suffixPrefixOverlapLength(left: String, right: String) -> Int {
        let maxOverlap = min(left.count, right.count)
        guard maxOverlap > 0 else { return 0 }

        for length in stride(from: maxOverlap, through: 1, by: -1) {
            let leftStart = left.index(left.endIndex, offsetBy: -length)
            let rightEnd = right.index(right.startIndex, offsetBy: length)
            if left[leftStart...] == right[..<rightEnd] {
                return length
            }
        }
        return 0
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        let chars = zip(lhs, rhs).prefix { $0 == $1 }.map(\.0)
        return String(chars)
    }

    private static func commonSuffixLength(_ lhs: String, _ rhs: String) -> Int {
        let reversedPairs = zip(lhs.reversed(), rhs.reversed())
        var length = 0
        for (l, r) in reversedPairs {
            if l == r {
                length += 1
            } else {
                break
            }
        }
        return length
    }
}
