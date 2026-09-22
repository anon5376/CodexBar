import Foundation

/// Public API list price for subscription usage that was recorded as tokens, not as a bill.
///
/// Cache counters are subsets of input, matching Muse and Grok turn logs. A consumed cache class
/// with no catalog rate stays unpriced. Reasoning tokens are not added; they are already inside output.
enum SubscriptionListPrice {
    struct Usage: Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int

        var uncachedInputTokens: Int? {
            guard self.inputTokens >= 0, self.outputTokens >= 0,
                  self.cacheReadTokens >= 0, self.cacheCreationTokens >= 0,
                  self.cacheReadTokens <= self.inputTokens, self.cacheCreationTokens <= self.inputTokens
            else { return nil }
            let uncached = self.inputTokens - self.cacheReadTokens - self.cacheCreationTokens
            return uncached >= 0 ? uncached : nil
        }
    }

    /// Custom rates apply without a catalog, so a fresh or offline install still prices configured models.
    static func estimateUSD(
        providerID: String,
        modelID: String,
        usage: Usage,
        catalog: ModelsDevCatalog?,
        customPricing: CostUsageCustomPricing = .empty) -> Double?
    {
        guard usage.uncachedInputTokens != nil else { return nil }
        let candidates = self.modelIDs(providerID: providerID, modelID: modelID)
        guard let exact = candidates.first else { return nil }
        if let cost = self.price(
            providerID: providerID,
            modelID: exact,
            usage: usage,
            catalog: catalog,
            customPricing: customPricing)
        {
            return cost
        }
        // An exact row that exists stays unknown when it cannot price the usage, even with no cost at all.
        // Aliases apply only when that exact row is absent.
        if customPricing.rates(providerID: providerID, model: exact) != nil
            || self.listsModel(providerID: providerID, modelID: exact, catalog: catalog)
        {
            return nil
        }
        for alias in candidates.dropFirst() {
            if let cost = self.price(
                providerID: providerID,
                modelID: alias,
                usage: usage,
                catalog: catalog,
                customPricing: customPricing)
            {
                return cost
            }
        }
        return nil
    }

    /// Custom overrides price independent token classes. Catalog lookup keeps the inclusive-input
    /// convention inside `providerCostUSD`, so this passes the non-cached remainder only.
    private static func price(
        providerID: String,
        modelID: String,
        usage: Usage,
        catalog: ModelsDevCatalog?,
        customPricing: CostUsageCustomPricing) -> Double?
    {
        guard let uncached = usage.uncachedInputTokens else { return nil }
        if let rates = customPricing.rates(providerID: providerID, model: modelID) {
            return self.finite(CostUsageCustomPricing.costUSD(
                rates: rates,
                inputTokens: uncached,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheCreationTokens))
        }
        guard let catalog else { return nil }
        return self.finite(CostUsagePricing.providerCostUSD(
            providerID: providerID,
            model: modelID,
            inputTokens: uncached,
            cachedInputTokens: usage.cacheReadTokens,
            cacheWriteInputTokens: usage.cacheCreationTokens,
            outputTokens: usage.outputTokens,
            pricingDate: nil,
            catalog: catalog,
            customPricing: .empty))
    }

    /// Model identity only: a listed row with missing input or output prices still counts as present.
    private static func listsModel(providerID: String, modelID: String, catalog: ModelsDevCatalog?) -> Bool {
        guard let provider = catalog?.providers[ModelsDevProvider.normalizeProviderID(providerID)] else {
            return false
        }
        let normalized = ModelsDevModelIDNormalizer.normalize(modelID)
        return provider.models[normalized] != nil
            || provider.models.values.contains { $0.normalizedID == normalized }
    }

    private static func finite(_ cost: Double?) -> Double? {
        guard let cost, cost.isFinite, cost >= 0 else { return nil }
        return cost
    }

    /// `grok-4.6-build` is the Grok Build recording of the public `grok-4.6` model.
    /// The exact id wins when the catalog has its own row.
    private static func modelIDs(providerID: String, modelID: String) -> [String] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var ids = [trimmed]
        if providerID == "xai", trimmed.hasSuffix("-build") {
            let stem = String(trimmed.dropLast("-build".count))
            if !stem.isEmpty, stem != trimmed {
                ids.append(stem)
            }
        }
        return ids
    }
}

/// Pricing-refresh controls that `CostUsageFetcher.loadTokenSnapshot` forwards to local subscription readers.
struct SubscriptionPricingControls: Sendable {
    var allowRefresh = true
    var refreshInBackground = true
    var retryUnknown = true
    var cacheRoot: URL?
    var client = ModelsDevClient()

    /// Refreshes a stale catalog when allowed, waiting only when nothing is cached yet.
    func catalog(now: Date) async -> ModelsDevCatalog? {
        if self.allowRefresh, self.retryUnknown {
            let cacheRoot = self.cacheRoot
            let client = self.client
            if !self.refreshInBackground || CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: cacheRoot) == nil {
                await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
            } else {
                Task.detached(priority: .utility) {
                    await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
                }
            }
        }
        return CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: self.cacheRoot)
    }

    /// A refreshed catalog when unpriced models gained prices; nil when a rescan would not change anything.
    func catalog(pricing modelIDs: Set<String>, providerID: String, now: Date) async -> ModelsDevCatalog? {
        guard self.allowRefresh, self.retryUnknown, !modelIDs.isEmpty else { return nil }
        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: providerID,
            modelIDs: modelIDs,
            now: now,
            cacheRoot: self.cacheRoot,
            client: self.client)
        guard outcome == .pricingAvailable else { return nil }
        return CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: self.cacheRoot)
    }
}
