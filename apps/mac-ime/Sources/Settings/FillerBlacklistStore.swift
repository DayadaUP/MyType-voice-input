import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum FillerBlacklistStoreError: LocalizedError {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case step(String)
    case bind(String)

    public var errorDescription: String? {
        switch self {
        case .openDatabase(let detail):
            return "Failed to open filler blacklist database: \(detail)"
        case .execute(let detail):
            return "Failed to execute SQL: \(detail)"
        case .prepare(let detail):
            return "Failed to prepare SQL statement: \(detail)"
        case .step(let detail):
            return "Failed to run SQL statement: \(detail)"
        case .bind(let detail):
            return "Failed to bind SQL argument: \(detail)"
        }
    }
}

public final class FillerBlacklistStore {
    private var db: OpaquePointer?

    public init(databasePath: String? = nil) throws {
        let path = databasePath ?? Self.defaultDatabasePath()
        try Self.ensureParentDirectory(for: path)
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw FillerBlacklistStoreError.openDatabase(message)
        }
        self.db = handle
        try createSchemaIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    public func seedIfNeeded(defaultPhrases: [String]) throws {
        let existing = try fetchEnabledPhrases()
        guard existing.isEmpty else { return }
        try replaceAll(with: defaultPhrases)
    }

    public func fetchEnabledPhrases() throws -> [String] {
        let sql = "SELECT phrase FROM filler_blacklist WHERE enabled = 1 ORDER BY id ASC;"
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        var phrases: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                phrases.append(String(cString: cString))
            }
        }
        return phrases
    }

    public func replaceAll(with phrases: [String]) throws {
        let normalized = Self.normalize(phrases)

        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(sql: "DELETE FROM filler_blacklist;")

            let sql = "INSERT INTO filler_blacklist(phrase, enabled, created_at) VALUES (?, 1, datetime('now'));"
            let stmt = try prepare(sql: sql)
            defer { sqlite3_finalize(stmt) }

            for phrase in normalized {
                if sqlite3_bind_text(stmt, 1, phrase, -1, SQLITE_TRANSIENT) != SQLITE_OK {
                    throw FillerBlacklistStoreError.bind(lastErrorMessage())
                }
                let stepResult = sqlite3_step(stmt)
                if stepResult != SQLITE_DONE {
                    throw FillerBlacklistStoreError.step(lastErrorMessage())
                }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }

            try execute(sql: "COMMIT;")
        } catch {
            _ = try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    public static func normalize(_ phrases: [String]) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []

        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            output.append(trimmed)
        }
        return output
    }

    public static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        let directory = appSupport
            .appendingPathComponent("MyType", isDirectory: true)
        return directory
            .appendingPathComponent("mytype.sqlite3", isDirectory: false)
            .path
    }

    private func createSchemaIfNeeded() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS filler_blacklist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            phrase TEXT NOT NULL UNIQUE,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """
        try execute(sql: sql)
    }

    private func execute(sql: String) throws {
        guard let db else {
            throw FillerBlacklistStoreError.execute("database closed")
        }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw FillerBlacklistStoreError.execute(lastErrorMessage())
        }
    }

    private func prepare(sql: String) throws -> OpaquePointer? {
        guard let db else {
            throw FillerBlacklistStoreError.prepare("database closed")
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw FillerBlacklistStoreError.prepare(lastErrorMessage())
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
