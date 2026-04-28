import Testing
@testable import IMEHost

@Test("stable commit guard requires three observations")
func stableCommitGuardRequiresThreeObservations() {
    let decision = CloudStreamingStableCommitGuard.evaluate(
        committedText: "",
        recentPreviewTexts: ["今天下午三点开会", "今天下午三点开会然后"]
    )

    #expect(!decision.shouldCommit)
    #expect(decision.reason == "insufficient_observations")
}

@Test("stable commit guard accepts initial stable chinese prefix")
func stableCommitGuardAcceptsInitialChinesePrefix() {
    let decision = CloudStreamingStableCommitGuard.evaluate(
        committedText: "",
        recentPreviewTexts: [
            "今天下午三点开会",
            "今天下午三点开会然后同步排期",
            "今天下午三点开会然后同步风险"
        ]
    )

    #expect(decision.shouldCommit)
    #expect(decision.nextCommittedText == "今天下午三点开会")
    #expect(decision.deltaText == "今天下午三点开会")
    #expect(decision.reason == "initial_stable_prefix")
}

@Test("stable commit guard extends from already committed prefix")
func stableCommitGuardExtendsExistingCommit() {
    let decision = CloudStreamingStableCommitGuard.evaluate(
        committedText: "今天下午三点开会",
        recentPreviewTexts: [
            "今天下午三点开会然后同步排期",
            "今天下午三点开会然后同步排期和风险",
            "今天下午三点开会然后同步排期和资源"
        ]
    )

    #expect(decision.shouldCommit)
    #expect(decision.nextCommittedText == "今天下午三点开会然后同步排期")
    #expect(decision.deltaText == "然后同步排期")
    #expect(decision.reason == "stable_prefix_extension")
}

@Test("stable commit guard rejects tiny delta")
func stableCommitGuardRejectsTinyDelta() {
    let decision = CloudStreamingStableCommitGuard.evaluate(
        committedText: "今天下午三点开会",
        recentPreviewTexts: [
            "今天下午三点开会了",
            "今天下午三点开会了吧",
            "今天下午三点开会了呀"
        ]
    )

    #expect(!decision.shouldCommit)
    #expect(decision.reason == "delta_too_short")
}

@Test("stable commit guard trims unsafe trailing latin token")
func stableCommitGuardTrimsTrailingLatinToken() {
    let decision = CloudStreamingStableCommitGuard.evaluate(
        committedText: "",
        recentPreviewTexts: [
            "open settings and per",
            "open settings and permissions",
            "open settings and permissions window"
        ]
    )

    #expect(decision.shouldCommit)
    #expect(decision.nextCommittedText == "open settings and")
    #expect(decision.deltaText == "open settings and")
}
