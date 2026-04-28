import Foundation
import Testing
@testable import Lexicon

@Test("persists correction count and auto-enrolls at threshold 3 across service restart")
func persistsCorrectionCountAndEnrollsAtThresholdThree() throws {
    let baseDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-lexicon-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let dbPath = baseDir.appendingPathComponent("lexicon.sqlite3").path

    do {
        let service = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        #expect(service.correctionCount(wrong: "思莫格", corrected: "斯莫格") == 2)
        #expect(service.containsInPersonalLexicon("斯莫格") == false)
    }

    do {
        let reopened = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        #expect(reopened.correctionCount(wrong: "思莫格", corrected: "斯莫格") == 2)
        reopened.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        #expect(reopened.correctionCount(wrong: "思莫格", corrected: "斯莫格") == 3)
        #expect(reopened.containsInPersonalLexicon("斯莫格") == true)
        let replaced = reopened.prioritizedReplacement(in: "今天思莫格这个词又错了")
        #expect(replaced == "今天斯莫格这个词又错了")
    }
}

@Test("clears personal lexicon and correction counts in persistence mode")
func clearsPersistedLearningData() throws {
    let baseDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-lexicon-clear-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let dbPath = baseDir.appendingPathComponent("lexicon.sqlite3").path

    do {
        let service = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        #expect(service.containsInPersonalLexicon("斯莫格") == true)
        #expect(service.correctionCount(wrong: "思莫格", corrected: "斯莫格") == 3)

        service.clearPersonalLexiconData(resetCorrectionCounts: true)
        #expect(service.containsInPersonalLexicon("斯莫格") == false)
        #expect(service.correctionCount(wrong: "思莫格", corrected: "斯莫格") == 0)
    }

    do {
        let reopened = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        #expect(reopened.containsInPersonalLexicon("斯莫格") == false)
        #expect(reopened.correctionCount(wrong: "思莫格", corrected: "斯莫格") == 0)
    }
}

@Test("persists manual lexicon terms across service restart")
func persistsManualLexiconTermsAcrossRestart() throws {
    let baseDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-lexicon-manual-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let dbPath = baseDir.appendingPathComponent("lexicon.sqlite3").path

    do {
        let service = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        service.addManualTerms(["豆包", "火山引擎"])
        let listed = service.listManualTerms()
        #expect(listed.contains("豆包"))
        #expect(listed.contains("火山引擎"))
    }

    do {
        let reopened = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        let listed = reopened.listManualTerms()
        #expect(listed.contains("豆包"))
        #expect(listed.contains("火山引擎"))
        let replaced = reopened.prioritizedReplacement(in: "我在测试豆 包语音输入")
        #expect(replaced == "我在测试豆包语音输入")
    }
}

@Test("persists pronunciation mapping across service restart")
func persistsPronunciationMappingAcrossRestart() throws {
    let baseDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-lexicon-pron-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let dbPath = baseDir.appendingPathComponent("lexicon.sqlite3").path

    do {
        let service = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        service.recordCorrection(wrong: "思莫格", corrected: "斯莫格")
        let direct = service.prioritizedReplacement(in: "思莫格")
        #expect(direct == "斯莫格")
    }

    do {
        let reopened = LexiconService(threshold: 3, enablePersistence: true, databasePath: dbPath)
        let variant = reopened.prioritizedReplacement(in: "私莫格")
        #expect(variant == "斯莫格")
    }
}
