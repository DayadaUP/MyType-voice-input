import Testing
@testable import IMEHost

@Test("live insert gate blocks preview writes during stop transition")
func liveInsertGateBlocksDuringStopTransition() {
    #expect(!FinalInsertionGuard.shouldAllowLiveInsert(stopTransitionActive: true))
    #expect(FinalInsertionGuard.shouldAllowLiveInsert(stopTransitionActive: false))
}

@Test("effective live commit prefers higher-coverage latest commit")
func effectiveLiveCommitPrefersHigherCoverageLatestCommit() {
    let resolved = FinalInsertionGuard.resolveEffectiveLiveCommitState(
        snapshotCommittedText: "今天下午三点开会",
        snapshotHasSuccessfulInsertion: true,
        latestCommittedText: "今天下午三点开会然后同步排期",
        latestHasSuccessfulInsertion: true
    )

    #expect(resolved.hasSuccessfulInsertion)
    #expect(resolved.committedText == "今天下午三点开会然后同步排期")

    let pending = FinalInsertionGuard.pendingFinalInsertionText(
        finalText: "今天下午三点开会然后同步排期",
        liveCommittedText: resolved.committedText,
        liveHasSuccessfulInsertion: resolved.hasSuccessfulInsertion
    )
    #expect(pending.isEmpty)
}

@Test("near-equivalent live/final text skips stop-stage insertion")
func nearEquivalentLiveFinalSkipsStopStageInsertion() {
    let live = "今天下午三点开会然后同步排期"
    let final = "今天下午三点开会，然后同步排期。"

    #expect(
        FinalInsertionGuard.shouldSkipFinalInsertForNearEquivalentTexts(
            liveCommittedText: live,
            finalText: final
        )
    )

    let pending = FinalInsertionGuard.pendingFinalInsertionText(
        finalText: final,
        liveCommittedText: live,
        liveHasSuccessfulInsertion: true
    )
    #expect(pending.isEmpty)
}

@Test("visual-only mode ignores divergent live preview draft")
func visualOnlyModeIgnoresDivergentLivePreviewDraft() {
    let effective = LivePreviewCommitPolicy.resolveEffectiveLiveCommitState(
        mode: .visualOnly,
        snapshotCommittedText: "我们是否可以优化1",
        snapshotHasSuccessfulInsertion: true,
        latestCommittedText: "我们是否可以优化1",
        latestHasSuccessfulInsertion: true
    )

    #expect(!effective.hasSuccessfulInsertion)
    #expect(effective.committedText.isEmpty)

    let final = "我们是否可以优化一下用户上传的物品照片尺寸"
    let pending = FinalInsertionGuard.pendingFinalInsertionText(
        finalText: final,
        liveCommittedText: effective.committedText,
        liveHasSuccessfulInsertion: effective.hasSuccessfulInsertion
    )
    #expect(pending == final)
}

@Test("visual-only mode ignores case revised preview draft")
func visualOnlyModeIgnoresCaseRevisedPreviewDraft() {
    let effective = LivePreviewCommitPolicy.resolveEffectiveLiveCommitState(
        mode: .visualOnly,
        snapshotCommittedText: "App",
        snapshotHasSuccessfulInsertion: true,
        latestCommittedText: "App",
        latestHasSuccessfulInsertion: true
    )

    #expect(!effective.hasSuccessfulInsertion)

    let final = "APP现在还没有上架呢"
    let pending = FinalInsertionGuard.pendingFinalInsertionText(
        finalText: final,
        liveCommittedText: effective.committedText,
        liveHasSuccessfulInsertion: effective.hasSuccessfulInsertion
    )
    #expect(pending == final)
}
