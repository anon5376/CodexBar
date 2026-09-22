import Foundation

extension CostUsageFetcher {
    static func loadMuseLocalSnapshot(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        let context = MuseLocalUsageReader.Context(environment: environment)
        let calendar = options.calendar
        let since = calendar.date(
            byAdding: .day, value: -(historyDays - 1), to: calendar.startOfDay(for: now)) ?? now
        let sinceKey = CostUsageLocalDay.key(from: since, calendar: calendar)
        let untilKey = CostUsageLocalDay.key(from: now, calendar: calendar)
        let cacheRoot = options.cacheRoot ?? context.defaultCacheRoot
        let customPricing = CostUsageCustomPricing.load(environment: environment)
        let result = try await self.museReport(
            context: context,
            calendar: calendar,
            sinceKey: sinceKey,
            untilKey: untilKey,
            cacheRoot: cacheRoot,
            forceRescan: options.forceRescan,
            customPricing: customPricing,
            now: now)
        let days = result.report.data
        let priced = days.contains { $0.costUSD != nil }
            && days.allSatisfy { ($0.totalTokens ?? 0) == 0 || $0.costUSD != nil }
        return Self.tokenSnapshot(
            from: result.report,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            historyCoverageIsEstablished: result.isComplete && result.isAvailable,
            monetaryValuesAreAvailable: true,
            costProvenance: priced ? .listPriceEstimate : .unknown)
    }

    private static func museReport(
        context: MuseLocalUsageReader.Context,
        calendar: Calendar,
        sinceKey: String,
        untilKey: String,
        cacheRoot: URL,
        forceRescan: Bool,
        customPricing: CostUsageCustomPricing,
        now: Date) async throws -> MuseLocalUsageReader.DailyReportResult
    {
        let catalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: cacheRoot)
        return try await CostUsageScanExecutor.run { cancellation in
            try MuseLocalUsageReader.makeDailyReportWithStatus(
                context: context,
                calendar: calendar,
                sinceDayKey: sinceKey,
                untilDayKey: untilKey,
                cacheRoot: cacheRoot,
                forceRescan: forceRescan,
                estimateCost: true,
                pricingCatalog: catalog,
                customPricing: customPricing,
                checkCancellation: cancellation)
        }
    }
}
