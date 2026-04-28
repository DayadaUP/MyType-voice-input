import Foundation

public struct CloudStreamingStableCommitDecision: Equatable, Sendable {
    public let shouldCommit: Bool
    public let nextCommittedText: String
    public let deltaText: String
    public let reason: String

    public init(
        shouldCommit: Bool,
        nextCommittedText: String,
        deltaText: String,
        reason: String
    ) {
        self.shouldCommit = shouldCommit
        self.nextCommittedText = nextCommittedText
        self.deltaText = deltaText
        self.reason = reason
    }
}

public enum CloudStreamingStableCommitGuard {
    private static let requiredObservationCount = 3
    private static let minimumInitialComparableLength = 6
    private static let minimumDeltaComparableLength = 3

    public static func evaluate(
        committedText: String,
        recentPreviewTexts: [String]
    ) -> CloudStreamingStableCommitDecision {
        let previews = recentPreviewTexts
            .map(normalize)
            .filter { !$0.isEmpty }
        guard previews.count >= requiredObservationCount else {
            return CloudStreamingStableCommitDecision(
                shouldCommit: false,
                nextCommittedText: normalize(committedText),
                deltaText: "",
                reason: "insufficient_observations"
            )
        }

        let window = Array(previews.suffix(requiredObservationCount))
        let committed = normalize(committedText)
        let stablePrefix = sanitizeCommitCandidate(
            window.dropFirst().reduce(window[0]) { commonPrefix($0, $1) }
        )
        guard !stablePrefix.isEmpty else {
            return CloudStreamingStableCommitDecision(
                shouldCommit: false,
                nextCommittedText: committed,
                deltaText: "",
                reason: "empty_stable_prefix"
            )
        }
        guard committed.isEmpty || stablePrefix.hasPrefix(committed) else {
            return CloudStreamingStableCommitDecision(
                shouldCommit: false,
                nextCommittedText: committed,
                deltaText: "",
                reason: "stable_prefix_diverged"
            )
        }
        guard stablePrefix.count > committed.count else {
            return CloudStreamingStableCommitDecision(
                shouldCommit: false,
                nextCommittedText: committed,
                deltaText: "",
                reason: "no_new_stable_prefix"
            )
        }

        let deltaStart = stablePrefix.index(stablePrefix.startIndex, offsetBy: committed.count)
        let delta = String(stablePrefix[deltaStart...])
        let stableComparable = canonicalComparable(stablePrefix)
        let deltaComparable = canonicalComparable(delta)
        if committed.isEmpty, stableComparable.count < minimumInitialComparableLength {
            return CloudStreamingStableCommitDecision(
                shouldCommit: false,
                nextCommittedText: committed,
                deltaText: "",
                reason: "initial_prefix_too_short"
            )
        }
        guard deltaComparable.count >= minimumDeltaComparableLength else {
            return CloudStreamingStableCommitDecision(
                shouldCommit: false,
                nextCommittedText: committed,
                deltaText: "",
                reason: "delta_too_short"
            )
        }

        return CloudStreamingStableCommitDecision(
            shouldCommit: true,
            nextCommittedText: stablePrefix,
            deltaText: delta,
            reason: committed.isEmpty ? "initial_stable_prefix" : "stable_prefix_extension"
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalComparable(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[^\\p{Han}A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        String(zip(lhs, rhs).prefix { $0 == $1 }.map(\.0))
    }

    private static func sanitizeCommitCandidate(_ text: String) -> String {
        let normalized = normalize(text)
        guard normalized.contains(" ") else { return normalized }
        guard let trailingToken = normalized.range(
            of: "[A-Za-z0-9]+$",
            options: .regularExpression
        ) else {
            return normalized
        }
        return String(normalized[..<trailingToken.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
