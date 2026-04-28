import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LexiconSQLiteStoreError: LocalizedError {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .openDatabase(let detail):
            return "Failed to open lexicon database: \(detail)"
        case .execute(let detail):
            return "Failed to execute SQL: \(detail)"
        case .prepare(let detail):
            return "Failed to prepare SQL statement: \(detail)"
        case .bind(let detail):
            return "Failed to bind SQL argument: \(detail)"
        case .step(let detail):
            return "Failed to step SQL statement: \(detail)"
        }
    }
}

final class LexiconSQLiteStore {
    struct PronunciationMapping: Equatable {
        let wrongPronKey: String
        let wrongLength: Int
        let correctedTerm: String
        let count: Int
    }

    private var db: OpaquePointer?

    init(databasePath: String? = nil) throws {
        let path = databasePath ?? Self.defaultDatabasePath()
        try Self.ensureParentDirectory(for: path)

        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw LexiconSQLiteStoreError.openDatabase(message)
        }
        self.db = handle
        try createSchemaIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    func incrementCorrectionPair(wrong: String, corrected: String) throws -> Int {
        let upsertSQL = """
        INSERT INTO correction_pairs(wrong_term, corrected_term, count, last_seen_at)
        VALUES (?, ?, 1, datetime('now'))
        ON CONFLICT(wrong_term, corrected_term)
        DO UPDATE SET count = count + 1, last_seen_at = datetime('now');
        """
        let upsertStmt = try prepare(sql: upsertSQL)
        defer { sqlite3_finalize(upsertStmt) }

        guard sqlite3_bind_text(upsertStmt, 1, wrong, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_text(upsertStmt, 2, corrected, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }

        guard sqlite3_step(upsertStmt) == SQLITE_DONE else {
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }

        return try correctionCount(wrong: wrong, corrected: corrected)
    }

    func correctionCount(wrong: String, corrected: String) throws -> Int {
        let sql = "SELECT count FROM correction_pairs WHERE wrong_term = ? AND corrected_term = ? LIMIT 1;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, wrong, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 2, corrected, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }

        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        if stepResult == SQLITE_DONE {
            return 0
        }
        throw LexiconSQLiteStoreError.step(lastErrorMessage())
    }

    func upsertPersonalTerm(_ term: String, source: String = "auto", boostWeight: Double = 1.0) throws {
        let sql = """
        INSERT INTO personal_lexicon(term, source, boost_weight, created_at, updated_at)
        VALUES (?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(term)
        DO UPDATE SET updated_at = datetime('now');
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_double(stmt, 3, boostWeight) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
    }

    func containsPersonalTerm(_ term: String) throws -> Bool {
        let sql = "SELECT 1 FROM personal_lexicon WHERE term = ? LIMIT 1;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }

        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW { return true }
        if stepResult == SQLITE_DONE { return false }
        throw LexiconSQLiteStoreError.step(lastErrorMessage())
    }

    func deletePersonalTerm(_ term: String) throws {
        let sql = "DELETE FROM personal_lexicon WHERE term = ?;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
    }

    func fetchPersonalTerms() throws -> Set<String> {
        let sql = "SELECT term FROM personal_lexicon;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        var terms: Set<String> = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    terms.insert(String(cString: cString))
                }
                continue
            }
            if stepResult == SQLITE_DONE {
                break
            }
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
        return terms
    }

    func upsertManualTerm(_ term: String) throws {
        let sql = """
        INSERT INTO manual_lexicon(term, created_at, updated_at)
        VALUES (?, datetime('now'), datetime('now'))
        ON CONFLICT(term)
        DO UPDATE SET updated_at = datetime('now');
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
    }

    func fetchManualTerms() throws -> [String] {
        let sql = "SELECT term FROM manual_lexicon ORDER BY updated_at DESC, term ASC;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        var terms: [String] = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                guard let cString = sqlite3_column_text(stmt, 0) else { continue }
                terms.append(String(cString: cString))
                continue
            }
            if stepResult == SQLITE_DONE {
                break
            }
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
        return terms
    }

    func deleteManualTerm(_ term: String) throws {
        let sql = "DELETE FROM manual_lexicon WHERE term = ?;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
    }

    func fetchPreferredReplacements() throws -> [String: String] {
        let sql = """
        SELECT cp.wrong_term, cp.corrected_term, cp.count
        FROM correction_pairs cp
        INNER JOIN personal_lexicon pl ON pl.term = cp.corrected_term
        INNER JOIN (
            SELECT wrong_term, MAX(count) AS max_count
            FROM correction_pairs
            GROUP BY wrong_term
        ) mx ON mx.wrong_term = cp.wrong_term AND mx.max_count = cp.count
        ORDER BY LENGTH(cp.wrong_term) DESC, cp.count DESC, cp.corrected_term ASC;
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        var result: [String: String] = [:]
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                guard let wrongCString = sqlite3_column_text(stmt, 0),
                      let correctedCString = sqlite3_column_text(stmt, 1) else {
                    continue
                }
                let wrong = String(cString: wrongCString)
                let corrected = String(cString: correctedCString)
                if result[wrong] == nil {
                    result[wrong] = corrected
                }
                continue
            }
            if stepResult == SQLITE_DONE {
                break
            }
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
        return result
    }

    func incrementPronunciationPair(
        wrongPronKey: String,
        wrongLength: Int,
        corrected: String
    ) throws -> Int {
        let upsertSQL = """
        INSERT INTO pronunciation_pairs(wrong_pron_key, wrong_length, corrected_term, count, last_seen_at)
        VALUES (?, ?, ?, 1, datetime('now'))
        ON CONFLICT(wrong_pron_key, wrong_length, corrected_term)
        DO UPDATE SET count = count + 1, last_seen_at = datetime('now');
        """
        let upsertStmt = try prepare(sql: upsertSQL)
        defer { sqlite3_finalize(upsertStmt) }

        guard sqlite3_bind_text(upsertStmt, 1, wrongPronKey, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_int(upsertStmt, 2, Int32(wrongLength)) == SQLITE_OK,
              sqlite3_bind_text(upsertStmt, 3, corrected, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }

        guard sqlite3_step(upsertStmt) == SQLITE_DONE else {
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }

        return try pronunciationPairCount(
            wrongPronKey: wrongPronKey,
            wrongLength: wrongLength,
            corrected: corrected
        )
    }

    func pronunciationPairCount(
        wrongPronKey: String,
        wrongLength: Int,
        corrected: String
    ) throws -> Int {
        let sql = """
        SELECT count FROM pronunciation_pairs
        WHERE wrong_pron_key = ? AND wrong_length = ? AND corrected_term = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_text(stmt, 1, wrongPronKey, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_int(stmt, 2, Int32(wrongLength)) == SQLITE_OK,
              sqlite3_bind_text(stmt, 3, corrected, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw LexiconSQLiteStoreError.bind(lastErrorMessage())
        }

        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        if stepResult == SQLITE_DONE {
            return 0
        }
        throw LexiconSQLiteStoreError.step(lastErrorMessage())
    }

    func fetchPreferredPronunciationMappings() throws -> [PronunciationMapping] {
        let sql = """
        SELECT pp.wrong_pron_key, pp.wrong_length, pp.corrected_term, pp.count
        FROM pronunciation_pairs pp
        INNER JOIN (
            SELECT wrong_pron_key, wrong_length, MAX(count) AS max_count
            FROM pronunciation_pairs
            GROUP BY wrong_pron_key, wrong_length
        ) mx
            ON mx.wrong_pron_key = pp.wrong_pron_key
           AND mx.wrong_length = pp.wrong_length
           AND mx.max_count = pp.count
        WHERE EXISTS (
            SELECT 1 FROM personal_lexicon pl WHERE pl.term = pp.corrected_term
        ) OR EXISTS (
            SELECT 1 FROM manual_lexicon ml WHERE ml.term = pp.corrected_term
        )
        ORDER BY pp.wrong_length DESC, pp.count DESC, pp.corrected_term ASC;
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        var result: [PronunciationMapping] = []
        var seen: Set<String> = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                guard let keyCString = sqlite3_column_text(stmt, 0),
                      let correctedCString = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                let wrongPronKey = String(cString: keyCString)
                let wrongLength = Int(sqlite3_column_int(stmt, 1))
                let correctedTerm = String(cString: correctedCString)
                let count = Int(sqlite3_column_int(stmt, 3))
                let composite = "\(wrongLength)|\(wrongPronKey)"
                guard !seen.contains(composite) else { continue }
                seen.insert(composite)
                result.append(
                    PronunciationMapping(
                        wrongPronKey: wrongPronKey,
                        wrongLength: wrongLength,
                        correctedTerm: correctedTerm,
                        count: count
                    )
                )
                continue
            }
            if stepResult == SQLITE_DONE {
                break
            }
            throw LexiconSQLiteStoreError.step(lastErrorMessage())
        }
        return result
    }

    func clearPersonalLexicon() throws {
        try execute(sql: "DELETE FROM personal_lexicon;")
    }

    func clearManualLexicon() throws {
        try execute(sql: "DELETE FROM manual_lexicon;")
    }

    func clearCorrectionPairs() throws {
        try execute(sql: "DELETE FROM correction_pairs;")
    }

    func clearPronunciationPairs() throws {
        try execute(sql: "DELETE FROM pronunciation_pairs;")
    }

    static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        let directory = appSupport.appendingPathComponent("MyType", isDirectory: true)
        return directory.appendingPathComponent("mytype.sqlite3", isDirectory: false).path
    }

    private func createSchemaIfNeeded() throws {
        let correctionPairsSQL = """
        CREATE TABLE IF NOT EXISTS correction_pairs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            wrong_term TEXT NOT NULL,
            corrected_term TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(wrong_term, corrected_term)
        );
        """

        let personalLexiconSQL = """
        CREATE TABLE IF NOT EXISTS personal_lexicon (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL UNIQUE,
            source TEXT NOT NULL DEFAULT 'auto',
            boost_weight REAL NOT NULL DEFAULT 1.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """

        let manualLexiconSQL = """
        CREATE TABLE IF NOT EXISTS manual_lexicon (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """

        let pronunciationPairsSQL = """
        CREATE TABLE IF NOT EXISTS pronunciation_pairs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            wrong_pron_key TEXT NOT NULL,
            wrong_length INTEGER NOT NULL,
            corrected_term TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(wrong_pron_key, wrong_length, corrected_term)
        );
        """

        try execute(sql: correctionPairsSQL)
        try execute(sql: personalLexiconSQL)
        try execute(sql: manualLexiconSQL)
        try execute(sql: pronunciationPairsSQL)
    }

    private func execute(sql: String) throws {
        guard let db else {
            throw LexiconSQLiteStoreError.execute("database closed")
        }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw LexiconSQLiteStoreError.execute(lastErrorMessage())
        }
    }

    private func prepare(sql: String) throws -> OpaquePointer? {
        guard let db else {
            throw LexiconSQLiteStoreError.prepare("database closed")
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw LexiconSQLiteStoreError.prepare(lastErrorMessage())
        }
        return stmt
    }

    private func lastErrorMessage() -> String {
        guard let db else { return "database closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func ensureParentDirectory(for path: String) throws {
        let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}
