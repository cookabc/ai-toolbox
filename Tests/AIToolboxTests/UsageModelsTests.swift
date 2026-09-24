import XCTest
@testable import AIToolbox

final class UsageModelsTests: XCTestCase {
    func testInputCompositionSplitsCacheAndFreshInput() {
        let totals = UsageTotals(inputTokens: 1_000, cacheReadTokens: 700, cacheWriteTokens: 100)
        XCTAssertEqual(totals.freshInputTokens, 200)
        XCTAssertEqual(totals.cacheReadShare, 0.7, accuracy: 0.0001)
        XCTAssertEqual(totals.cacheWriteShare, 0.1, accuracy: 0.0001)
        XCTAssertEqual(totals.freshInputShare, 0.2, accuracy: 0.0001)
    }

    func testInputCompositionHandlesZeroAndInconsistentTotals() {
        let zero = UsageTotals.zero
        XCTAssertEqual(zero.freshInputTokens, 0)
        XCTAssertEqual(zero.cacheReadShare, 0)
        XCTAssertEqual(zero.cacheWriteShare, 0)
        XCTAssertEqual(zero.freshInputShare, 0)

        let overcounted = UsageTotals(inputTokens: 100, cacheReadTokens: 120, cacheWriteTokens: 20)
        XCTAssertEqual(overcounted.freshInputTokens, 0)
        XCTAssertEqual(overcounted.cacheReadShare, 1)
        XCTAssertEqual(overcounted.cacheWriteShare, 0)
        XCTAssertEqual(overcounted.freshInputShare, 0)
    }

    func testReadableFormatting() {
        XCTAssertEqual(Format.token(999), "999")
        XCTAssertEqual(Format.token(1_260), "1.3k")
        XCTAssertEqual(Format.token(27_400), "27k")
        XCTAssertEqual(Format.token(3_700_000), "3.7M")
        XCTAssertEqual(Format.token(38_600_000), "39M")
        XCTAssertEqual(Format.token(2_500_000_000), "2.50B")
        XCTAssertEqual(Format.count(999), "999")
        XCTAssertEqual(Format.count(12_600), "13k")
        XCTAssertEqual(Format.percent(0.826), "83%")
    }

    func testDaysAreLookedUpByLocalDateAndGapsAreFilled() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let snapshot = UsageSnapshot(
            refreshedAt: Date(),
            totals: UsageTotals(outputTokens: 30),
            daily: [
                DailyUsage(date: twoDaysAgo, totals: UsageTotals(outputTokens: 10)),
                DailyUsage(date: today, totals: UsageTotals(outputTokens: 20)),
            ],
            models: []
        )
        XCTAssertEqual(snapshot.totals(on: today.addingTimeInterval(3_600)).outputTokens, 20)
        XCTAssertEqual(snapshot.totals(on: calendar.date(byAdding: .day, value: -1, to: today)!), .zero)
        let week = snapshot.recentDays(7, endingAt: Date())
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.date, today)
        XCTAssertEqual(week.map(\.totals.outputTokens), [0, 0, 0, 0, 10, 0, 20])
        XCTAssertEqual(snapshot.firstActiveDay, twoDaysAgo)
    }
}
