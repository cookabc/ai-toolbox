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

    /// English groups large numbers by thousands (K / M / B / T); below 10,000 the
    /// count is shown in full.
    func testReadableFormatting() {
        XCTAssertEqual(Format.token(999), "999")
        XCTAssertEqual(Format.token(1_260), "1,260")
        XCTAssertEqual(Format.token(9_999), "9,999")
        XCTAssertEqual(Format.token(10_000), "10.0K")
        XCTAssertEqual(Format.token(27_400), "27.4K")
        XCTAssertEqual(Format.token(127_000), "127K")
        XCTAssertEqual(Format.token(3_700_000), "3.70M")
        XCTAssertEqual(Format.token(38_600_000), "38.6M")
        XCTAssertEqual(Format.token(2_500_000_000), "2.50B")
        XCTAssertEqual(Format.token(-27_400), "-27.4K")
        XCTAssertEqual(Format.count(999), "999")
        XCTAssertEqual(Format.count(9_999), "9,999")
        XCTAssertEqual(Format.count(12_600), "12.6K")
        XCTAssertEqual(Format.exact(1_234_567), "1,234,567")
        XCTAssertEqual(Format.percent(0.826), "83%")
    }

    /// Rounding can carry a value past a precision or unit boundary; the shown
    /// number must still have three significant digits in the right unit. Both
    /// sides of a boundary have to be asserted, or a carry that stops carrying
    /// would still pass: 99,994,999 and 99,995,000 both render 100M now that the
    /// tiers are thousands, so the pairs below straddle a real edge instead.
    func testCompactNumbersCarryAcrossBoundaries() {
        XCTAssertEqual(Format.token(99_949), "99.9K")
        XCTAssertEqual(Format.token(99_995), "100K")
        XCTAssertEqual(Format.token(999_499), "999K")
        XCTAssertEqual(Format.token(999_500), "1.00M")
        XCTAssertEqual(Format.token(999_500_000), "1.00B")
        // Nothing sits above T, so the top tier keeps its digits and does not carry.
        // That wart predates the K/M/B/T tiers; it is asserted here so changing it
        // has to be deliberate rather than accidental.
        XCTAssertEqual(Format.token(1_000_000_000_000_000), "1000T")
    }

    /// An English time carries a narrow no-break space before "AM"/"PM", and the
    /// pixel font draws a plain space but neither no-break variant. `Format.time` and
    /// `Format.day` are pixel type on screen, so neither may keep one — a stray
    /// no-break space would drop that single character to the system font and change
    /// the word spacing mid-line.
    func testPixelRenderedDatesUsePlainSpaces() {
        let reference = Date(timeIntervalSince1970: 1_000_000_000)
        let rendered = [
            Format.time(reference, withDate: true), Format.time(reference, withDate: false),
            Format.day(reference),
        ]
        for text in rendered {
            XCTAssertFalse(
                text.unicodeScalars.contains { $0 == "\u{202F}" || $0 == "\u{00A0}" },
                "\"\(text)\" still carries a no-break space")
        }
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
