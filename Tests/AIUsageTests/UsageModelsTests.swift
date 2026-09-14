import XCTest
@testable import AIUsage

final class UsageModelsTests: XCTestCase {
    func testInputCompositionSplitsCacheAndFreshInput() {
        let totals = UsageTotals(
            turns: 1, requests: 1, inputTokens: 1_000, outputTokens: 0,
            reasoningTokens: 0, cacheReadInputTokens: 700,
            cacheCreationInputTokens: 100, toolCalls: 0
        )

        XCTAssertEqual(totals.freshInputTokens, 200)
        XCTAssertEqual(totals.cacheReadShare, 0.7, accuracy: 0.0001)
        XCTAssertEqual(totals.cacheCreationShare, 0.1, accuracy: 0.0001)
        XCTAssertEqual(totals.freshInputShare, 0.2, accuracy: 0.0001)
    }

    func testInputCompositionHandlesZeroAndInvalidTotalsSafely() {
        let zero = UsageTotals.zero
        XCTAssertEqual(zero.freshInputTokens, 0)
        XCTAssertEqual(zero.cacheReadShare, 0)
        XCTAssertEqual(zero.cacheCreationShare, 0)
        XCTAssertEqual(zero.freshInputShare, 0)

        let overcounted = UsageTotals(
            turns: 0, requests: 0, inputTokens: 100, outputTokens: 0,
            reasoningTokens: 0, cacheReadInputTokens: 120,
            cacheCreationInputTokens: 20, toolCalls: 0
        )
        XCTAssertEqual(overcounted.freshInputTokens, 0)
        XCTAssertEqual(overcounted.cacheReadShare, 1)
        XCTAssertEqual(overcounted.cacheCreationShare, 0)
        XCTAssertEqual(overcounted.freshInputShare, 0)
    }

    func testReadableCountFormatting() {
        XCTAssertEqual(Format.count(999), "999")
        XCTAssertEqual(Format.count(12_500), "12k")
        XCTAssertEqual(Format.percent(0.826), "83%")
    }
}
