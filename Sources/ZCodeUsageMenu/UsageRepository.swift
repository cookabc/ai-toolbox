import Foundation
import SQLite3

struct UsageRepository: Sendable {
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".zcode/cli/db/db.sqlite")

    private let databaseURL: URL
    private let readCopy = DatabaseReadCopy()

    init(databaseURL: URL = UsageRepository.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    func load() throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw UsageError.databaseMissing(databaseURL)
        }

        do {
            return try loadDatabase(at: databaseURL)
        } catch UsageError.sqliteRead(let code, _) where code == SQLITE_CANTOPEN {
            return try readCopy.read(source: databaseURL) { copy in
                try loadDatabase(at: copy, readOnly: false)
            }
        }
    }

    private func loadDatabase(at url: URL, readOnly: Bool = true) throws -> UsageSnapshot {

        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            let code = db.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN
            sqlite3_close(db)
            throw UsageError.sqliteRead(code, detail)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        // Keep all three aggregates on the same database snapshot while ZCode writes.
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw UsageError.sqliteRead(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        return UsageSnapshot(
            refreshedAt: .now,
            totals: try queryTotals(db: db, condition: nil),
            today: try queryTotals(db: db, condition: "started_at >= ?", bind: startOfTodayMilliseconds()),
            models: try queryModels(db: db)
        )
    }

    private func queryTotals(db: OpaquePointer, condition: String?, bind: Int64? = nil) throws -> UsageTotals {
        let whereClause = condition.map { " WHERE \($0)" } ?? ""
        let sql = """
        SELECT COUNT(*),
               COALESCE(SUM(model_request_count), 0),
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(output_tokens), 0),
               COALESCE(SUM(reasoning_tokens), 0),
               COALESCE(SUM(cache_read_input_tokens), 0),
               COALESCE(SUM(cache_creation_input_tokens), 0),
               COALESCE(SUM(tool_call_count), 0)
        FROM turn_usage\(whereClause)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageError.sqliteRead(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_int64(statement, 1, bind) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageError.sqliteRead(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
        }
        return UsageTotals(
            turns: sqlite3_column_int64(statement, 0),
            requests: sqlite3_column_int64(statement, 1),
            inputTokens: sqlite3_column_int64(statement, 2),
            outputTokens: sqlite3_column_int64(statement, 3),
            reasoningTokens: sqlite3_column_int64(statement, 4),
            cacheReadInputTokens: sqlite3_column_int64(statement, 5),
            cacheCreationInputTokens: sqlite3_column_int64(statement, 6),
            toolCalls: sqlite3_column_int64(statement, 7)
        )
    }

    private func queryModels(db: OpaquePointer) throws -> [ModelUsage] {
        // 刻意不 JOIN turn_usage：一个 turn 有多个 model 请求，会把回合的 token 成倍放大。
        let sql = """
        SELECT m.model_id,
               m.provider_id,
               COUNT(*) AS requests,
               COALESCE(SUM(CAST(json_extract(p.data, '$.tokens.output') AS INTEGER)), 0) AS output_tokens
        FROM model_usage AS m
        JOIN part AS p ON p.message_id = m.assistant_message_id
                       AND json_extract(p.data, '$.type') = 'step-finish'
        GROUP BY m.model_id, m.provider_id
        ORDER BY output_tokens DESC, requests DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageError.sqliteRead(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var models: [ModelUsage] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let model = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
            let provider = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
            models.append(ModelUsage(
                modelID: model,
                providerID: provider,
                requests: sqlite3_column_int64(statement, 2),
                outputTokens: sqlite3_column_int64(statement, 3)
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw UsageError.sqliteRead(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db))) }
        return models
    }

    private func startOfTodayMilliseconds() -> Int64 {
        let date = Calendar.current.startOfDay(for: .now)
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}
