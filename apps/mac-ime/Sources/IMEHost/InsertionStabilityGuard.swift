import Foundation
import Darwin

public enum InsertionStabilityGuard {
    public static func canonicalText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[^\\p{Han}A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
    }

    public static func makeDedupToken(
        text: String,
        appBundleID: String?,
        appPID: pid_t?,
        sessionID: String
    ) -> String {
        let canonical = canonicalText(text)
        guard !canonical.isEmpty else { return "" }

        let appKey: String
        if let appBundleID, !appBundleID.isEmpty {
            appKey = appBundleID.lowercased()
        } else if let appPID {
            appKey = "pid:\(appPID)"
        } else {
            appKey = "unknown"
        }

        return "\(sessionID)|\(appKey)|\(canonical)"
    }

    public static func shouldSuppressDuplicateInsert(
        lastToken: String,
        lastInsertedAt: Date?,
        incomingToken: String,
        now: Date = Date(),
        windowSeconds: TimeInterval
    ) -> Bool {
        guard !incomingToken.isEmpty else { return false }
        guard !lastToken.isEmpty, lastToken == incomingToken else { return false }
        guard let lastInsertedAt else { return false }
        return now.timeIntervalSince(lastInsertedAt) <= max(0, windowSeconds)
    }

    public static func shouldSkipBecauseAlreadyPresent(
        focusedText: String,
        pendingText: String
    ) -> Bool {
        let normalizedPending = canonicalText(pendingText)
        guard !normalizedPending.isEmpty else { return true }

        let normalizedFocused = canonicalText(focusedText)
        guard !normalizedFocused.isEmpty else { return false }

        if normalizedFocused.hasSuffix(normalizedPending) {
            return true
        }

        let overlap = suffixPrefixOverlapLength(left: normalizedFocused, right: normalizedPending)
        let threshold = max(12, Int(Double(normalizedPending.count) * 0.86))
        return overlap >= threshold
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
}
