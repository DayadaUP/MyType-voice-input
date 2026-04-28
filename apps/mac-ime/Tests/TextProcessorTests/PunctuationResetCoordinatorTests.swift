import Foundation
import Testing
@testable import Settings

private final class StubResetStore: PunctuationLearningResetStore {
    private(set) var resetCallCount = 0
    var errorToThrow: Error?

    func resetLearningData(clearEvents: Bool, clearMetrics: Bool) throws {
        #expect(clearEvents)
        #expect(clearMetrics)
        resetCallCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
    }
}

private struct StubResetError: Error {}

@Test("coordinator resets store and clears punctuation counters when store is available")
func coordinatorResetsStoreAndClearsCounters() {
    let settings = InMemorySettingsStore()
    settings.set("11", forKey: SettingsKeys.punctuationMisbreakFixCount)
    settings.set("9", forKey: SettingsKeys.punctuationQuestionBiasFixCount)
    settings.set("7", forKey: SettingsKeys.punctuationUserCorrectionEventCount)

    let store = StubResetStore()
    let coordinator = PunctuationResetCoordinator(store: store, settings: settings)
    let result = coordinator.runResetForLexiconClear()

    switch result {
    case .success:
        break
    case .failure(let error):
        Issue.record("Expected success but got failure: \(error)")
    }

    #expect(store.resetCallCount == 1)
    #expect(settings.string(forKey: SettingsKeys.punctuationMisbreakFixCount, default: "") == "0")
    #expect(settings.string(forKey: SettingsKeys.punctuationQuestionBiasFixCount, default: "") == "0")
    #expect(settings.string(forKey: SettingsKeys.punctuationUserCorrectionEventCount, default: "") == "0")
}

@Test("coordinator does not crash when store is nil and still clears punctuation counters")
func coordinatorHandlesNilStoreGracefully() {
    let settings = InMemorySettingsStore()
    settings.set("6", forKey: SettingsKeys.punctuationMisbreakFixCount)
    settings.set("5", forKey: SettingsKeys.punctuationQuestionBiasFixCount)
    settings.set("4", forKey: SettingsKeys.punctuationUserCorrectionEventCount)

    let coordinator = PunctuationResetCoordinator(
        store: Optional<PunctuationLearningResetStore>.none,
        settings: settings
    )
    let result = coordinator.runResetForLexiconClear()

    switch result {
    case .success:
        break
    case .failure(let error):
        Issue.record("Expected success for nil store fallback, got failure: \(error)")
    }

    #expect(settings.string(forKey: SettingsKeys.punctuationMisbreakFixCount, default: "") == "0")
    #expect(settings.string(forKey: SettingsKeys.punctuationQuestionBiasFixCount, default: "") == "0")
    #expect(settings.string(forKey: SettingsKeys.punctuationUserCorrectionEventCount, default: "") == "0")
}

@Test("coordinator surfaces store reset errors and avoids dirty partial state")
func coordinatorSurfacesResetErrorWithoutDirtyState() {
    let settings = InMemorySettingsStore()
    settings.set("8", forKey: SettingsKeys.punctuationMisbreakFixCount)
    settings.set("3", forKey: SettingsKeys.punctuationQuestionBiasFixCount)
    settings.set("2", forKey: SettingsKeys.punctuationUserCorrectionEventCount)

    let store = StubResetStore()
    store.errorToThrow = StubResetError()

    let coordinator = PunctuationResetCoordinator(store: store, settings: settings)
    let result = coordinator.runResetForLexiconClear()

    switch result {
    case .success:
        Issue.record("Expected failure when store throws reset error.")
    case .failure:
        break
    }

    #expect(store.resetCallCount == 1)
    #expect(settings.string(forKey: SettingsKeys.punctuationMisbreakFixCount, default: "") == "8")
    #expect(settings.string(forKey: SettingsKeys.punctuationQuestionBiasFixCount, default: "") == "3")
    #expect(settings.string(forKey: SettingsKeys.punctuationUserCorrectionEventCount, default: "") == "2")
}
