import Foundation
import SQLite3
import XCTest
@testable import ZCodeUsageMenu

final class UsageRepositoryTests: XCTestCase {
    private var databaseURL: URL!
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "zcode-usage-test-\(UUID().uuidString).sqlite")
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        try execute("""
        CREATE TABLE turn_usage (
          session_id, turn_id, trace_id, user_message_id, status,
          started_at, first_model_start_at, first_token_at, completed_at, duration_ms,
          time_to_first_token_ms, model_request_count, model_retry_count, tool_call_count,
          tool_error_count, input_tokens, output_tokens, reasoning_tokens,
          cache_creation_input_tokens, cache_read_input_tokens
        );
        CREATE TABLE model_usage (
          id, logical_request_id, attempt_index, session_id, turn_id, trace_id, span_id,
          assistant_message_id, parent_user_message_id, query_source, provider_id, model_id,
          variant, agent, mode, task_type, status, started_at, first_token_at, completed_at
        );
        CREATE TABLE part (id, message_id, session_id, time_created, time_updated, data, sequence);
        """)

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let old = now - 40 * 86_400_000
        // 今日回合：input=5000（cache-read=4000）、output=1000。
        try execute("""
        INSERT INTO turn_usage VALUES ('sess_a','t1',NULL,NULL,'completed',\(now),NULL,NULL,\(now),0,0,10,0,3,0,5000,1000,200,100,4000);
        INSERT INTO turn_usage VALUES ('sess_a','t2',NULL,NULL,'completed',\(old),NULL,NULL,\(old),0,0,2,0,1,0,2000,500,50,0,1500);
        INSERT INTO turn_usage VALUES ('sess_subagent_x','t3',NULL,NULL,'completed',\(now),NULL,NULL,\(now),0,0,1,0,0,0,100,10,0,0,90);
        """)

        // 一个 turn 两个模型请求；model output 必须使用 step-finish，而非把 t1.output=1000 重复两次。
        try execute("""
        INSERT INTO model_usage VALUES ('m1',NULL,0,'sess_a','t1',NULL,NULL,'msg1',NULL,NULL,'prov','GLM-5.3',NULL,NULL,NULL,NULL,'completed',\(now),NULL,NULL);
        INSERT INTO model_usage VALUES ('m2',NULL,0,'sess_a','t1',NULL,NULL,'msg2',NULL,NULL,'prov','GLM-5.3',NULL,NULL,NULL,NULL,'completed',\(now),NULL,NULL);
        INSERT INTO model_usage VALUES ('m3',NULL,0,'sess_a','t1',NULL,NULL,'missing',NULL,NULL,'prov','k3',NULL,NULL,NULL,NULL,'completed',\(now),NULL,NULL);
        INSERT INTO part VALUES ('p1','msg1','sess_a',\(now),\(now),'{"type":"step-finish","tokens":{"input":800,"output":100}}',0);
        INSERT INTO part VALUES ('p2','msg2','sess_a',\(now),\(now),'{"type":"step-finish","tokens":{"input":900,"output":200}}',0);
        """)
    }

    override func tearDownWithError() throws {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func testAggregatesTotalsTodayAndModelOutputWithoutTurnMultiplication() throws {
        let snapshot = try UsageRepository(databaseURL: databaseURL).load()

        XCTAssertEqual(snapshot.totals.turns, 3)
        XCTAssertEqual(snapshot.totals.outputTokens, 1_510)
        XCTAssertEqual(snapshot.totals.inputTokens, 7_100)
        XCTAssertEqual(snapshot.totals.cacheReadInputTokens, 5_590)
        XCTAssertEqual(snapshot.totals.toolCalls, 4)

        XCTAssertEqual(snapshot.today.turns, 2)
        XCTAssertEqual(snapshot.today.outputTokens, 1_010)
        XCTAssertEqual(snapshot.today.cacheReadInputTokens, 4_090)

        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertEqual(snapshot.models.first?.modelID, "GLM-5.3")
        XCTAssertEqual(snapshot.models.first?.requests, 2)
        XCTAssertEqual(snapshot.models.first?.outputTokens, 300)
    }

    func testMissingDatabaseHasClearError() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try UsageRepository(databaseURL: missing).load()) { error in
            guard case UsageError.databaseMissing(let url) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(url, missing)
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite setup failed"
            sqlite3_free(error)
            throw NSError(domain: "UsageRepositoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
