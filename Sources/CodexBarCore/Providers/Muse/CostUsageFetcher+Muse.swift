import Foundation

extension CostUsageFetcher {
    private struct MuseScan {
        let context: MuseLocalUsageReader.Context
        let calendar: Calendar
        let sinceKey: String
        let untilKey: String
        let cacheRoot: URL
        let customPricing: CostUsageCustomPricing
    }

    static func loadMuseLocalSnapshot(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        options: CostUsageScanner.Options,
        pricing: SubscriptionPricingControls = .init()) async throws -> CostUsageTokenSnapshot
    {
        let context = MuseLocalUsageReader.Context(environment: environment)
        let calendar = options.calendar
        let since = calendar.date(
            byAdding: .day, value: -(historyDays - 1), to: calendar.startOfDay(for: now)) ?? now
        let cacheRoot = options.cacheRoot ?? context.defaultCacheRoot
        let scan = MuseScan(
            context: context,
            calendar: calendar,
            sinceKey: CostUsageLocalDay.key(from: since, calendar: calendar),
            untilKey: CostUsageLocalDay.key(from: now, calendar: calendar),
            cacheRoot: cacheRoot,
            customPricing: CostUsageCustomPricing.load(environment: environment))
        var pricing = pricing
        if pricing.cacheRoot == nil {
            pricing.cacheRoot = cacheRoot
        }
        let result = try await self.museReport(
            scan,
            forceRescan: options.forceRescan,
            pricing: pricing,
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
            // Empty or wholly unpriced history stays dollar-free instead of reading as $0.
            monetaryValuesAreAvailable: priced,
            costProvenance: priced ? .listPriceEstimate : .unknown)
    }

    private static func museReport(
        _ scan: MuseScan,
        forceRescan: Bool,
        pricing: SubscriptionPricingControls,
        now: Date) async throws -> MuseLocalUsageReader.DailyReportResult
    {
        let catalog = await pricing.catalog(now: now)
        let report = try await self.scanMuse(scan, forceRescan: forceRescan, catalog: catalog)
        guard let refreshed = await pricing.catalog(
            pricing: self.unpricedMuseModels(in: report),
            providerID: "meta",
            now: now)
        else { return report }
        return try await self.scanMuse(scan, forceRescan: true, catalog: refreshed)
    }

    private static func scanMuse(
        _ scan: MuseScan,
        forceRescan: Bool,
        catalog: ModelsDevCatalog?) async throws -> MuseLocalUsageReader.DailyReportResult
    {
        try await CostUsageScanExecutor.run { cancellation in
            try MuseLocalUsageReader.makeDailyReportWithStatus(
                context: scan.context,
                calendar: scan.calendar,
                sinceDayKey: scan.sinceKey,
                untilDayKey: scan.untilKey,
                cacheRoot: scan.cacheRoot,
                forceRescan: forceRescan,
                estimateCost: true,
                pricingCatalog: catalog,
                customPricing: scan.customPricing,
                checkCancellation: cancellation)
        }
    }

    private static func unpricedMuseModels(in report: MuseLocalUsageReader.DailyReportResult) -> Set<String> {
        var ids = Set<String>()
        for day in report.report.data {
            for breakdown in day.modelBreakdowns ?? [] {
                guard breakdown.costUSD == nil, (breakdown.totalTokens ?? 0) > 0 else { continue }
                let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != "unknown" else { continue }
                ids.insert(name)
            }
        }
        return ids
    }
}
