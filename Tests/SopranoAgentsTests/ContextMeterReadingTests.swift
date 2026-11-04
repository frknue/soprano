import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct ContextMeterReadingTests {
    @Test func usageWithoutAWindowIsUnknown() {
        #expect(ContextMeterReading(nil) == nil)
        #expect(ContextMeterReading(TokenUsage(usedTokens: 1200, contextWindow: nil)) == nil)
        #expect(ContextMeterReading(TokenUsage(usedTokens: 1200, contextWindow: 0)) == nil)
    }

    @Test func tokenCountsReadAsThousandsAndMillionsWithOneDecimalAtMost() {
        #expect(ContextMeterReading.tokens(950) == "950")
        #expect(ContextMeterReading.tokens(62_400) == "62.4k")
        #expect(ContextMeterReading.tokens(200_000) == "200k")
        #expect(ContextMeterReading.tokens(1_000_000) == "1M")
        #expect(ContextMeterReading.tokens(1_500_000) == "1.5M")
    }

    @Test func tooltipAndCardSummaryNameUsedTokensWindowAndRoundedPercent() throws {
        let reading = try #require(ContextMeterReading(TokenUsage(usedTokens: 62_400, contextWindow: 200_000)))
        #expect(reading.toolTip == "Context: 62.4k / 200k tokens (31%)")
        #expect(reading.summary == "62.4k of 200k tokens used · 31%")
    }

    @Test func theRingWarnsFromSeventyPercentAndAlarmsFromNinety() throws {
        func level(_ used: Int) throws -> ContextMeterReading.Level {
            try #require(ContextMeterReading(TokenUsage(usedTokens: used, contextWindow: 1000))).level
        }
        #expect(try level(699) == .normal)
        #expect(try level(700) == .warning)
        #expect(try level(899) == .warning)
        #expect(try level(900) == .critical)
        #expect(try level(1200) == .critical)
    }
}
