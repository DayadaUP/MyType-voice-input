import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PUNCT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum PunctuationStylePreference: String, CaseIterable, Sendable {
    case mixed
    case chinese
    case english
}

public struct PunctuationUserProfile: Equatable, Sendable {
    public let commaAggressiveness: Double
    public let questionBias: Double
    public let shortSentenceBias: Double
    public let stylePreference: PunctuationStylePreference
    public let learnedSamples: Int

    public init(
        commaAggressiveness: Double,
        questionBias: Double,
        shortSentenceBias: Double,
        stylePreference: PunctuationStylePreference,
        learnedSamples: Int
    ) {
        self.commaAggressiveness = commaAggressiveness
        self.questionBias = questionBias
        self.shortSentenceBias = shortSentenceBias
        self.stylePreference = stylePreference
        self.learnedSamples = learnedSamples
    }

    public static let neutral = PunctuationUserProfile(
        commaAggressiveness: 0,
        questionBias: 0,
        shortSentenceBias: 0,
        stylePreference: .mixed,
        learnedSamples: 0
    )

    public func isEffective(minSamples: Int) -> Bool {
        learnedSamples >= minSamples
    }
}

public struct PunctuationEditEvent: Equatable, Sendable {
    public let sourcePunctuation: String
    public let targetPunctuation: String
    public let contextBefore: String
    public let contextAfter: String
    public let timestamp: Date
    public let appIdentifier: String?
    public let confidence: Double

    public init(
        sourcePunctuation: String,
        targetPunctuation: String,
        contextBefore: String,
        contextAfter: String,
        timestamp: Date = Date(),
        appIdentifier: String? = nil,
        confidence: Double
    ) {
        self.sourcePunctuation = sourcePunctuation
        self.targetPunctuation = targetPunctuation
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.timestamp = timestamp
        self.appIdentifier = appIdentifier
        self.confidence = confidence
    }
}

public enum PunctuationQualityMetric: String, Sendable {
    case misbreakFixTriggered = "misbreak_fix_triggered"
    case questionBiasTriggered = "question_bias_triggered"
    case userCorrectionEventCount = "user_punctuation_correction_event_count"
}

public protocol PunctuationProfileProviding {
    func effectiveProfile(minSamples: Int) -> PunctuationUserProfile?
}

public enum PunctuationLearningStoreError: LocalizedError {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case step(String)
    case bind(String)

    public var errorDescription: String? {
        switch self {
        case .openDatabase(let detail):
            return "Failed to open punctuation learning database: \(detail)"
        case .execute(let detail):
            return "Failed to execute punctuation learning SQL: \(detail)"
        case .prepare(let detail):
            return "Failed to prepare punctuation learning SQL: \(detail)"
        case .step(let detail):
            return "Failed to run punctuation learning SQL: \(detail)"
        case .bind(let detail):
            return "Failed to bind punctuation learning SQL argument: \(detail)"
        }
    }
}

public final class PunctuationLearningStore: PunctuationProfileProviding {
    public static let defaultLearningThreshold = 6
    public static let defaultMinConfidence = 0.58

    private var db: OpaquePointer?

    public init(databasePath: String? = nil) throws {
        let path = databasePath ?? FillerBlacklistStore.defaultDatabasePath()
        try Self.ensureParentDirectory(for: path)

        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw PunctuationLearningStoreError.openDatabase(message)
        }

        self.db = handle
        try createSchemaIfNeeded()
        try ensureProfileRow()
    }

    deinit {
        sqlite3_close(db)
    }

    public func currentProfile() -> PunctuationUserProfile {
        (try? loadProfile()) ?? .neutral
    }

    public func effectiveProfile(minSamples: Int = PunctuationLearningStore.defaultLearningThreshold) -> PunctuationUserProfile? {
        let profile = currentProfile()
        guard profile.isEffective(minSamples: minSamples) else { return nil }
        return profile
    }

    @discardableResult
    public func record(
        event: PunctuationEditEvent,
        learningEnabled: Bool,
        minConfidence: Double = PunctuationLearningStore.defaultMinConfidence
    ) -> PunctuationUserProfile {
        guard let normalized = normalize(event: event) else {
            return currentProfile()
        }
        try? insert(event: normalized)
        guard learningEnabled, normalized.confidence >= minConfidence else {
            return currentProfile()
        }
        return (try? applyLearning(for: normalized)) ?? currentProfile()
    }

    @discardableResult
    public func incrementQualityMetric(_ metric: PunctuationQualityMetric, delta: Int = 1) -> Int {
        guard delta > 0 else { return qualityMetricCount(metric) }
        let sql = """
        INSERT INTO punctuation_quality_metrics(metric, count, updated_at)
        VALUES (?, ?, datetime('now'))
        ON CONFLICT(metric)
        DO UPDATE SET count = count + excluded.count, updated_at = datetime('now');
        """
        do {
            let stmt = try prepare(sql: sql)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_text(stmt, 1, metric.rawValue, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
                  sqlite3_bind_int(stmt, 2, Int32(delta)) == SQLITE_OK else {
                throw PunctuationLearningStoreError.bind(lastErrorMessage())
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw PunctuationLearningStoreError.step(lastErrorMessage())
            }
        } catch {
            return qualityMetricCount(metric)
        }
        return qualityMetricCount(metric)
    }

    public func qualityMetricCount(_ metric: PunctuationQualityMetric) -> Int {
        let sql = "SELECT count FROM punctuation_quality_metrics WHERE metric = ? LIMIT 1;"
        guard let stmt = try? prepare(sql: sql) else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, metric.rawValue, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK else {
            return 0
        }

        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    public func resetLearningData(
        clearEvents: Bool = true,
        clearMetrics: Bool = true
    ) throws {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let resetProfileSQL = """
            UPDATE punctuation_profile
            SET
                comma_aggressiveness = 0,
                question_bias = 0,
                short_sentence_bias = 0,
                style_preference = 'mixed',
                learned_samples = 0,
                updated_at = datetime('now')
            WHERE id = 1;
            """
            try execute(sql: resetProfileSQL)
            if clearEvents {
                try execute(sql: "DELETE FROM punctuation_events;")
            }
            if clearMetrics {
                try execute(sql: "DELETE FROM punctuation_quality_metrics;")
            }
            try execute(sql: "COMMIT;")
        } catch {
            _ = try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    private func loadProfile() throws -> PunctuationUserProfile {
        let sql = """
        SELECT
            comma_aggressiveness,
            question_bias,
            short_sentence_bias,
            style_preference,
            learned_samples
        FROM punctuation_profile
        WHERE id = 1
        LIMIT 1;
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_ROW {
            let comma = sqlite3_column_double(stmt, 0)
            let question = sqlite3_column_double(stmt, 1)
            let shortSentence = sqlite3_column_double(stmt, 2)
            let styleRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? PunctuationStylePreference.mixed.rawValue
            let style = PunctuationStylePreference(rawValue: styleRaw) ?? .mixed
            let samples = Int(sqlite3_column_int(stmt, 4))
            return PunctuationUserProfile(
                commaAggressiveness: comma,
                questionBias: question,
                shortSentenceBias: shortSentence,
                stylePreference: style,
                learnedSamples: samples
            )
        }
        if stepResult == SQLITE_DONE {
            return .neutral
        }
        throw PunctuationLearningStoreError.step(lastErrorMessage())
    }

    private func applyLearning(for event: PunctuationEditEvent) throws -> PunctuationUserProfile {
        let profile = try loadProfile()
        let source = event.sourcePunctuation
        let target = event.targetPunctuation
        let context = event.contextBefore + event.contextAfter

        var comma = profile.commaAggressiveness
        var question = profile.questionBias
        var shortSentence = profile.shortSentenceBias
        let samples = profile.learnedSamples + 1

        var zhVotes = 0
        var enVotes = 0
        if isChinesePunctuation(target) {
            zhVotes += 1
        } else if isEnglishPunctuation(target) {
            enVotes += 1
        }

        if isCommaLike(target), isSentenceTerminator(source) {
            comma += 0.22
        } else if isCommaLike(source), isSentenceTerminator(target) {
            comma -= 0.20
        }

        if isQuestionPunctuation(target), !isQuestionPunctuation(source) {
            question += 0.24
        } else if isQuestionPunctuation(source), !isQuestionPunctuation(target) {
            question -= 0.22
        }

        if countContentCharacters(context) <= 8 {
            if isSentenceTerminator(target) {
                shortSentence += 0.18
            } else if isSentenceTerminator(source), !isSentenceTerminator(target) {
                shortSentence -= 0.20
            }
        }

        comma = clampSigned01(comma)
        question = clampSigned01(question)
        shortSentence = clampSigned01(shortSentence)

        var stylePreference = profile.stylePreference
        if zhVotes > enVotes {
            stylePreference = .chinese
        } else if enVotes > zhVotes {
            stylePreference = .english
        }

        let sql = """
        UPDATE punctuation_profile
        SET
            comma_aggressiveness = ?,
            question_bias = ?,
            short_sentence_bias = ?,
            style_preference = ?,
            learned_samples = ?,
            updated_at = datetime('now')
        WHERE id = 1;
        """
        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_double(stmt, 1, comma) == SQLITE_OK,
              sqlite3_bind_double(stmt, 2, question) == SQLITE_OK,
              sqlite3_bind_double(stmt, 3, shortSentence) == SQLITE_OK,
              sqlite3_bind_text(stmt, 4, stylePreference.rawValue, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_int(stmt, 5, Int32(samples)) == SQLITE_OK else {
            throw PunctuationLearningStoreError.bind(lastErrorMessage())
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PunctuationLearningStoreError.step(lastErrorMessage())
        }

        return PunctuationUserProfile(
            commaAggressiveness: comma,
            questionBias: question,
            shortSentenceBias: shortSentence,
            stylePreference: stylePreference,
            learnedSamples: samples
        )
    }

    private func insert(event: PunctuationEditEvent) throws {
        let sql = """
        INSERT INTO punctuation_events(
            source_punctuation,
            target_punctuation,
            context_before,
            context_after,
            context_window,
            confidence,
            app_identifier,
            created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let contextWindow = event.contextBefore + "|" + event.contextAfter
        let timestamp = ISO8601DateFormatter.string(
            from: event.timestamp,
            timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )

        let stmt = try prepare(sql: sql)
        defer { sqlite3_finalize(stmt) }

        let app = event.appIdentifier ?? ""
        guard sqlite3_bind_text(stmt, 1, event.sourcePunctuation, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 2, event.targetPunctuation, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 3, event.contextBefore, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 4, event.contextAfter, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 5, contextWindow, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_double(stmt, 6, event.confidence) == SQLITE_OK,
              sqlite3_bind_text(stmt, 7, app, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK,
              sqlite3_bind_text(stmt, 8, timestamp, -1, SQLITE_TRANSIENT_PUNCT) == SQLITE_OK else {
            throw PunctuationLearningStoreError.bind(lastErrorMessage())
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PunctuationLearningStoreError.step(lastErrorMessage())
        }
    }

    private func normalize(event: PunctuationEditEvent) -> PunctuationEditEvent? {
        let source = punctuationToken(from: event.sourcePunctuation)
        let target = punctuationToken(from: event.targetPunctuation)
        guard source != target else { return nil }

        let contextBefore = event.contextBefore
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .suffix(18)
        let contextAfter = event.contextAfter
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(18)

        return PunctuationEditEvent(
            sourcePunctuation: source,
            targetPunctuation: target,
            contextBefore: String(contextBefore),
            contextAfter: String(contextAfter),
            timestamp: event.timestamp,
            appIdentifier: event.appIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: min(1, max(0, event.confidence))
        )
    }

    private func punctuationToken(from raw: String) -> String {
        let token = raw.filter { ch in
            ch.isPunctuation || "，。！？；：、,.;:?!".contains(ch)
        }
        return String(token.prefix(2))
    }

    private func isCommaLike(_ punctuation: String) -> Bool {
        punctuation.contains(",") || punctuation.contains("，") || punctuation.contains("、")
    }

    private func isSentenceTerminator(_ punctuation: String) -> Bool {
        punctuation.contains(".")
            || punctuation.contains("。")
            || punctuation.contains("!")
            || punctuation.contains("！")
            || punctuation.contains("?")
            || punctuation.contains("？")
    }

    private func isQuestionPunctuation(_ punctuation: String) -> Bool {
        punctuation.contains("?") || punctuation.contains("？")
    }

    private func isChinesePunctuation(_ punctuation: String) -> Bool {
        punctuation.contains("，")
            || punctuation.contains("。")
            || punctuation.contains("？")
            || punctuation.contains("！")
            || punctuation.contains("；")
            || punctuation.contains("：")
            || punctuation.contains("、")
    }

    private func isEnglishPunctuation(_ punctuation: String) -> Bool {
        punctuation.contains(",")
            || punctuation.contains(".")
            || punctuation.contains("?")
            || punctuation.contains("!")
            || punctuation.contains(";")
            || punctuation.contains(":")
    }

    private func countContentCharacters(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{Han}A-Za-z0-9]") else {
            return 0
        }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func clampSigned01(_ value: Double) -> Double {
        min(1, max(-1, value))
    }

    private func createSchemaIfNeeded() throws {
        let profileSQL = """
        CREATE TABLE IF NOT EXISTS punctuation_profile (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            comma_aggressiveness REAL NOT NULL DEFAULT 0,
            question_bias REAL NOT NULL DEFAULT 0,
            short_sentence_bias REAL NOT NULL DEFAULT 0,
            style_preference TEXT NOT NULL DEFAULT 'mixed',
            learned_samples INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """
        let eventsSQL = """
        CREATE TABLE IF NOT EXISTS punctuation_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_punctuation TEXT NOT NULL,
            target_punctuation TEXT NOT NULL,
            context_before TEXT NOT NULL,
            context_after TEXT NOT NULL,
            context_window TEXT NOT NULL,
            confidence REAL NOT NULL,
            app_identifier TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL
        );
        """
        let eventsIndexSQL = """
        CREATE INDEX IF NOT EXISTS idx_punctuation_events_created_at
        ON punctuation_events(created_at DESC);
        """
        let qualitySQL = """
        CREATE TABLE IF NOT EXISTS punctuation_quality_metrics (
            metric TEXT PRIMARY KEY,
            count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """
        try execute(sql: profileSQL)
        try execute(sql: eventsSQL)
        try execute(sql: eventsIndexSQL)
        try execute(sql: qualitySQL)
    }

    private func ensureProfileRow() throws {
        let sql = """
        INSERT INTO punctuation_profile(
            id,
            comma_aggressiveness,
            question_bias,
            short_sentence_bias,
            style_preference,
            learned_samples,
            updated_at
        ) VALUES (1, 0, 0, 0, 'mixed', 0, datetime('now'))
        ON CONFLICT(id) DO NOTHING;
        """
        try execute(sql: sql)
    }

    private func execute(sql: String) throws {
        guard let db else {
            throw PunctuationLearningStoreError.execute("database closed")
        }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw PunctuationLearningStoreError.execute(lastErrorMessage())
        }
    }

    private func prepare(sql: String) throws -> OpaquePointer? {
        guard let db else {
            throw PunctuationLearningStoreError.prepare("database closed")
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw PunctuationLearningStoreError.prepare(lastErrorMessage())
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
