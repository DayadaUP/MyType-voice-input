import Foundation

package enum LivePreviewCommitMode: Equatable, Sendable {
    case visualOnly
    case experimentalDirectInsert
}

package enum LivePreviewCommitPolicy {
    package static func resolveMode(
        storedDirectInsertEnabled: Bool,
        experimentalOverrideEnabled: Bool
    ) -> LivePreviewCommitMode {
        if storedDirectInsertEnabled && !experimentalOverrideEnabled {
            return .visualOnly
        }
        return experimentalOverrideEnabled ? .experimentalDirectInsert : .visualOnly
    }

    package static func shouldCommitDirectly(
        mode: LivePreviewCommitMode,
        stopTransitionActive: Bool
    ) -> Bool {
        guard mode == .experimentalDirectInsert else { return false }
        return FinalInsertionGuard.shouldAllowLiveInsert(stopTransitionActive: stopTransitionActive)
    }

    package static func resolveEffectiveLiveCommitState(
        mode: LivePreviewCommitMode,
        snapshotCommittedText: String,
        snapshotHasSuccessfulInsertion: Bool,
        latestCommittedText: String,
        latestHasSuccessfulInsertion: Bool
    ) -> EffectiveLiveCommitState {
        guard mode == .experimentalDirectInsert else {
            return EffectiveLiveCommitState(committedText: "", hasSuccessfulInsertion: false)
        }

        return FinalInsertionGuard.resolveEffectiveLiveCommitState(
            snapshotCommittedText: snapshotCommittedText,
            snapshotHasSuccessfulInsertion: snapshotHasSuccessfulInsertion,
            latestCommittedText: latestCommittedText,
            latestHasSuccessfulInsertion: latestHasSuccessfulInsertion
        )
    }
}
