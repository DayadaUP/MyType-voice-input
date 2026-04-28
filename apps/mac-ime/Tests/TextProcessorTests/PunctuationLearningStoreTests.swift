import Foundation
import SQLite3
import Testing
@testable import Settings

@Test("resetLearningData clears events and metrics when both flags are true")
func resetLearningDataClearsEventsAndMetrics() throws {
    try runResetCase(clearEvents: true, clearMetrics: true)
}

@Test("resetLearningData clears events but keeps metrics when only clearEvents is true")
func resetLearningDataClearsEventsKeepsMetrics() throws {
    try runResetCase(clearEvents: true, clearMetrics: false)
}

@Test("resetLearningData keeps events but clears metrics when only clearMetrics is true")
func resetLearningDataKeepsEventsClearsMetrics() throws {
    try runResetCase(clearEvents: false, clearMetrics: true)
}

@Test("resetLearningData keeps events and metrics when both flags are false")
func resetLearningDataKeepsEventsAndMetrics() throws {
    try runResetCase(clearEvents: false, clearMetrics: false)
}

private func runResetCase(clearEvents: Bool, clearMetrics: Bool) throws {
    let dbPath = try makeIsolatedSQLitePath()
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try PunctuationLearningStore(databasePath: dbPath)
    seedLearningData(into: store)

    let seededEvents = try rowCount(databasePath: dbPath, table: "punctuation_events")
    let seededMisbreak = store.qualityMetricCount(.misbreakFixTriggered)
    let seededUserCorrections = store.qualityMetricCount(.userCorrectionEventCount)
    #expect(seededEvents > 0)
    #expect(seededMisbreak > 0)
    #expect(seededUserCorrections > 0)
    #expect(store.currentProfile() != .neutral)

    try store.resetLearningData(clearEvents: clearEvents, clearMetrics: clearMetrics)

    let resetProfile = store.currentProfile()
    #expect(resetProfile.commaAggressiveness == 0)
    #expect(resetProfile.questionBias == 0)
    #expect(resetProfile.shortSentenceBias == 0)
    #expect(resetProfile.stylePreference == .mixed)
    #expect(resetProfile.learnedSamples == 0)

    let eventsAfterReset = try rowCount(databasePath: dbPath, table: "punctuation_events")
    if clearEvents {
        #expect(eventsAfterReset == 0)
    } else {
        #expect(eventsAfterReset == seededEvents)
    }

    let misbreakAfterReset = store.qualityMetricCount(.misbreakFixTriggered)
    let userCorrectionsAfterReset = store.qualityMetricCount(.userCorrectionEventCount)
    if clearMetrics {
        #expect(misbreakAfterReset == 0)
        #expect(userCorrectionsAfterReset == 0)
    } else {
        #expect(misbreakAfterReset == seededMisbreak)
        #expect(userCorrectionsAfterReset == seededUserCorrections)
    }
}

private func seedLearningData(into store: PunctuationLearningStore) {
    let commaEvent = PunctuationEditEvent(
        sourcePunctuation: "。",
        targetPunctuation: "，",
        contextBefore: "今天先",
        contextAfter: "然后继续",
        confidence: 0.95
    )
    let questionEvent = PunctuationEditEvent(
        sourcePunctuation: "。",
        targetPunctuation: "？",
        contextBefore: "你看",
        contextAfter: "可以吗",
        confidence: 0.95
    )
    _ = store.record(event: commaEvent, learningEnabled: true)
    _ = store.record(event: questionEvent, learningEnabled: true)
    _ = store.incrementQualityMetric(.misbreakFixTriggered, delta: 2)
    _ = store.incrementQualityMetric(.userCorrectionEventCount, delta: 3)
}

private func makeIsolatedSQLitePath() throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-punctuation-store-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("mytype.sqlite3", isDirectory: false).path
}

private func rowCount(databasePath: String, table: String) throws -> Int {
    var db: OpaquePointer?
    if sqlite3_open(databasePath, &db) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(db)
        throw NSError(domain: "PunctuationLearningStoreTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to open sqlite database: \(message)"
        ])
    }
    defer { sqlite3_close(db) }

    let sql = "SELECT COUNT(1) FROM \(table);"
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_finalize(stmt)
        throw NSError(domain: "PunctuationLearningStoreTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Failed to prepare query: \(message)"
        ])
    }
    defer { sqlite3_finalize(stmt) }

    if sqlite3_step(stmt) == SQLITE_ROW {
        return Int(sqlite3_column_int(stmt, 0))
    }
    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    throw NSError(domain: "PunctuationLearningStoreTests", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Failed to execute query: \(message)"
    ])
}
