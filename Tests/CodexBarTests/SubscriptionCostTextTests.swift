import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct SubscriptionCostTextTests {
    @Test
    func `a known grok day stays visible when the window total is unknown`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1050,
            sessionCostUSD: 12.5,
            last30DaysTokens: 1550,
            last30DaysCostUSD: nil,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-09-21",
                    inputTokens: 500,
                    outputTokens: 0,
                    totalTokens: 500,
                    costUSD: nil,
                    modelsUsed: ["older"],
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: "2026-09-22",
                    inputTokens: 800,
                    outputTokens: 50,
                    cacheReadTokens: 200,
                    totalTokens: 1050,
                    costUSD: 12.5,
                    modelsUsed: ["grok-4.6"],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_790_121_600))
        let text = CodexBarCLI.renderCostText(provider: .grok, snapshot: snapshot, useColor: false)
        #expect(text.contains("$12.50"))
        #expect(!text.contains("dollar costs unavailable"))
        #expect(text.contains("API-equivalent estimate"))
    }
}
