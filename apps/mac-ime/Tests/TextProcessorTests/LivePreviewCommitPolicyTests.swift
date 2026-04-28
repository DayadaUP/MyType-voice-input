import Testing
@testable import IMEHost

@Test("legacy stored direct-insert flag stays visual-only by default")
func legacyStoredDirectInsertFlagStaysVisualOnlyByDefault() {
    let mode = LivePreviewCommitPolicy.resolveMode(
        storedDirectInsertEnabled: true,
        experimentalOverrideEnabled: false
    )

    #expect(mode == .visualOnly)
    #expect(
        !LivePreviewCommitPolicy.shouldCommitDirectly(
            mode: mode,
            stopTransitionActive: false
        )
    )
}

@Test("experimental override is required for direct live insert")
func experimentalOverrideIsRequiredForDirectLiveInsert() {
    let mode = LivePreviewCommitPolicy.resolveMode(
        storedDirectInsertEnabled: false,
        experimentalOverrideEnabled: true
    )

    #expect(mode == .experimentalDirectInsert)
    #expect(
        LivePreviewCommitPolicy.shouldCommitDirectly(
            mode: mode,
            stopTransitionActive: false
        )
    )
    #expect(
        !LivePreviewCommitPolicy.shouldCommitDirectly(
            mode: mode,
            stopTransitionActive: true
        )
    )
}

@Test("visual-only mode drops stale live commit state")
func visualOnlyModeDropsStaleLiveCommitState() {
    let effective = LivePreviewCommitPolicy.resolveEffectiveLiveCommitState(
        mode: .visualOnly,
        snapshotCommittedText: "今天下午三点开会",
        snapshotHasSuccessfulInsertion: true,
        latestCommittedText: "今天下午三点开会然后同步排期",
        latestHasSuccessfulInsertion: true
    )

    #expect(!effective.hasSuccessfulInsertion)
    #expect(effective.committedText.isEmpty)
}
