import Foundation
import Testing
@testable import Settings

@Test("normalizes custom filler blacklist by trimming and deduplicating")
func normalizesBlacklistInput() {
    let result = FillerBlacklistStore.normalize([" 嗯 ", "呃", "呃", "", "  ", "em"])
    #expect(result == ["嗯", "呃", "em"])
}

@Test("persists filler blacklist in sqlite")
func persistsBlacklistInSQLite() throws {
    let baseDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mytype-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let dbPath = baseDir.appendingPathComponent("filler.sqlite3").path

    let store = try FillerBlacklistStore(databasePath: dbPath)
    try store.seedIfNeeded(defaultPhrases: ["嗯", "呃"])
    #expect(try store.fetchEnabledPhrases() == ["嗯", "呃"])

    try store.replaceAll(with: ["啊", "啊", " em "])
    #expect(try store.fetchEnabledPhrases() == ["啊", "em"])

    let reopened = try FillerBlacklistStore(databasePath: dbPath)
    #expect(try reopened.fetchEnabledPhrases() == ["啊", "em"])
}

