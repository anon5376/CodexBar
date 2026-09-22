import Foundation

extension CostUsageFetcher {
    static func loadMuseLocalSnapshot(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        options: CostUsageScanner.Options,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        retryUnknownPricing: Bool = true,
        modelsDevClient: ModelsDevClient = ModelsDevClient()) async throws -> CostUsageTokenSnapshot
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
            now: now,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            retryUnknownPricing: retryUnknownPricing,
            modelsDevClient: modelsDevClient)
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
        now: Date,
        allowPricingRefresh: Bool,
        refreshPricingInBackground: Bool,
        retryUnknownPricing: Bool,
        modelsDevClient: ModelsDevClient) async throws -> MuseLocalUsageReader.DailyReportResult
    {
        if allowPricingRefresh, retryUnknownPricing {
            if CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: cacheRoot) == nil
                || !refreshPricingInBackground
            {
                await ModelsDevPricingPipeline.refreshIfNeeded(
                    now: now, cacheRoot: cacheRoot, client: modelsDevClient)
            } else {
                Task.detached(priority: .utility) {
                    await ModelsDevPricingPipeline.refreshIfNeeded(
                        now: now, cacheRoot: cacheRoot, client: modelsDevClient)
                }
            }
        }
        var catalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: cacheRoot)
        var report = try await self.scanMuse(
            context: context,
            calendar: calendar,
            sinceKey: sinceKey,
            untilKey: untilKey,
            cacheRoot: cacheRoot,
            forceRescan: forceRescan,
            catalog: catalog,
            customPricing: customPricing)
        guard allowPricingRefresh, retryUnknownPricing else { return report }
        let unknown = self.unpricedMuseModels(in: report)
        guard !unknown.isEmpty else { return report }
        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "meta",
            modelIDs: unknown,
            now: now,
            cacheRoot: cacheRoot,
            client: modelsDevClient)
        guard outcome == .pricingAvailable else { return report }
        catalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: cacheRoot)
        report = try await self.scanMuse(
            context: context,
            calendar: calendar,
            sinceKey: sinceKey,
            untilKey: untilKey,
            cacheRoot: cacheRoot,
            forceRescan: true,
            catalog: catalog,
            customPricing: customPricing)
        return report
    }

    private static func scanMuse(
        context: MuseLocalUsageReader.Context,
        calendar: Calendar,
        sinceKey: String,
        untilKey: String,
        cacheRoot: URL,
        forceRescan: Bool,
        catalog: ModelsDevCatalog?,
        customPricing: CostUsageCustomPricing) async throws -> MuseLocalUsageReader.DailyReportResult
    {
        try await CostUsageScanExecutor.run { cancellation in
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
