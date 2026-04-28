import Foundation
import Testing
@testable import IMEHost

@Test("dedup token includes app and session scopes")
func dedupTokenIncludesScopes() {
    let tokenA = InsertionStabilityGuard.makeDedupToken(
        text: "你好，世界！",
        appBundleID: "com.google.chrome",
        appPID: 100,
        sessionID: "s1"
    )
    let tokenB = InsertionStabilityGuard.makeDedupToken(
        text: "你好世界",
        appBundleID: "com.google.chrome",
        appPID: 100,
        sessionID: "s1"
    )
    let tokenC = InsertionStabilityGuard.makeDedupToken(
        text: "你好世界",
        appBundleID: "com.google.chrome",
        appPID: 100,
        sessionID: "s2"
    )

    #expect(!tokenA.isEmpty)
    #expect(tokenA == tokenB)
    #expect(tokenA != tokenC)
}

@Test("duplicate suppression is bounded by time window")
func duplicateSuppressionIsTimeBounded() {
    let now = Date()
    let token = "session|app|hello"

    #expect(
        InsertionStabilityGuard.shouldSuppressDuplicateInsert(
            lastToken: token,
            lastInsertedAt: now.addingTimeInterval(-0.8),
            incomingToken: token,
            now: now,
            windowSeconds: 1.2
        )
    )

    #expect(
        !InsertionStabilityGuard.shouldSuppressDuplicateInsert(
            lastToken: token,
            lastInsertedAt: now.addingTimeInterval(-2.0),
            incomingToken: token,
            now: now,
            windowSeconds: 1.2
        )
    )
}

@Test("duplicate suppression canonicalizes stop stage retry text")
func duplicateSuppressionCanonicalizesStopStageRetryText() {
    let first = InsertionStabilityGuard.makeDedupToken(
        text: "APP现在还没有上架呢。",
        appBundleID: "com.google.chrome",
        appPID: 100,
        sessionID: "session"
    )
    let retried = InsertionStabilityGuard.makeDedupToken(
        text: "APP现在还没有上架呢",
        appBundleID: "com.google.chrome",
        appPID: 100,
        sessionID: "session"
    )

    #expect(first == retried)
}

@Test("already present detection avoids duplicate tail append")
func alreadyPresentDetectionAvoidsDuplicateTailAppend() {
    #expect(
        InsertionStabilityGuard.shouldSkipBecauseAlreadyPresent(
            focusedText: "今天我们先看需求然后确认排期",
            pendingText: "然后确认排期"
        )
    )

    #expect(
        !InsertionStabilityGuard.shouldSkipBecauseAlreadyPresent(
            focusedText: "今天我们先看需求",
            pendingText: "然后确认排期"
        )
    )
}
