import Foundation
import SQLite3

struct UsageRepository: Sendable {
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".zcode/cli/db/db.sqlite")

    private let databaseURL: URL

    init(databaseURL: URL = UsageRepository.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    func load() throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw UsageError.databaseMissing(databaseURL)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2("file:\(databaseURL.path)?mode=ro", &db, flags, nil) == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(db)
            throw UsageError.databaseOpen(detail)
        }
        defer { sqlite3_close(db) }

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
            throw UsageError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_int64(statement, 1, bind) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageError.query(String(cString: sqlite3_errmsg(db)))
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
        LIMIT 4
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var models: [ModelUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let model = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
            let provider = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
            models.append(ModelUsage(
                modelID: model,
                providerID: provider,
                requests: sqlite3_column_int64(statement, 2),
                outputTokens: sqlite3_column_int64(statement, 3)
            ))
        }
        return models
    }

    private func startOfTodayMilliseconds() -> Int64 {
        let date = Calendar.current.startOfDay(for: .now)
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}
