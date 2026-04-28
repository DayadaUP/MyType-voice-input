import Foundation

public protocol PunctuationLearningResetStore {
    func resetLearningData(clearEvents: Bool, clearMetrics: Bool) throws
}

extension PunctuationLearningStore: PunctuationLearningResetStore {}

public enum PunctuationResetCoordinatorResult {
    case success
    case failure(Error)
}

public struct PunctuationResetCoordinator {
    private let store: PunctuationLearningResetStore?
    private let settings: SettingsStore

    public init(store: PunctuationLearningStore?, settings: SettingsStore) {
        self.init(store: store as PunctuationLearningResetStore?, settings: settings)
    }

    init(store: PunctuationLearningResetStore?, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    public func runResetForLexiconClear() -> PunctuationResetCoordinatorResult {
        do {
            try store?.resetLearningData(clearEvents: true, clearMetrics: true)
            resetPunctuationCounters()
            return .success
        } catch {
            return .failure(error)
        }
    }

    private func resetPunctuationCounters() {
        settings.set("0", forKey: SettingsKeys.punctuationMisbreakFixCount)
        settings.set("0", forKey: SettingsKeys.punctuationQuestionBiasFixCount)
        settings.set("0", forKey: SettingsKeys.punctuationUserCorrectionEventCount)
    }
}
