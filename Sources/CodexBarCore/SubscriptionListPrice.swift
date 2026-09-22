import Foundation

/// Public API list price for subscription usage that was recorded as tokens, not as a bill.
///
/// Cache counters are subsets of input, matching Muse and Grok turn logs. A consumed cache class
/// with no catalog rate stays unpriced. Reasoning tokens are not added; they are already inside output.
enum SubscriptionListPrice {
    static func estimateUSD(
        providerID: String,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        catalog: ModelsDevCatalog,
        customPricing: CostUsageCustomPricing = .empty) -> Double?
    {
        guard inputTokens >= 0, outputTokens >= 0, cacheReadTokens >= 0, cacheCreationTokens >= 0,
              cacheReadTokens <= inputTokens, cacheCreationTokens <= inputTokens
        else { return nil }
        let uncached = inputTokens - cacheReadTokens - cacheCreationTokens
        guard uncached >= 0 else { return nil }
        let candidates = self.modelIDs(providerID: providerID, modelID: modelID)
        guard let exact = candidates.first else { return nil }
        if let cost = self.price(
            providerID: providerID,
            modelID: exact,
            uncachedInput: uncached,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            catalog: catalog,
            customPricing: customPricing)
        {
            return cost
        }
        // An exact row that cannot price a consumed class stays unknown. Aliases apply only
        // when that exact row is absent.
        if self.hasPricingRow(
            providerID: providerID,
            modelID: exact,
            catalog: catalog,
            customPricing: customPricing)
        {
            return nil
        }
        for alias in candidates.dropFirst() {
            if let cost = self.price(
                providerID: providerID,
                modelID: alias,
                uncachedInput: uncached,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
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
        uncachedInput: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        catalog: ModelsDevCatalog,
        customPricing: CostUsageCustomPricing) -> Double?
    {
        if let rates = customPricing.rates(providerID: providerID, model: modelID) {
            return self.finite(CostUsageCustomPricing.costUSD(
                rates: rates,
                inputTokens: uncachedInput,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheCreationTokens))
        }
        return self.finite(CostUsagePricing.providerCostUSD(
            providerID: providerID,
            model: modelID,
            inputTokens: uncachedInput,
            cachedInputTokens: cacheReadTokens,
            cacheWriteInputTokens: cacheCreationTokens,
            outputTokens: outputTokens,
            pricingDate: nil,
            catalog: catalog,
            customPricing: .empty))
    }

    private static func hasPricingRow(
        providerID: String,
        modelID: String,
        catalog: ModelsDevCatalog,
        customPricing: CostUsageCustomPricing) -> Bool
    {
        if customPricing.rates(providerID: providerID, model: modelID) != nil {
            return true
        }
        return catalog.pricing(providerID: providerID, modelID: modelID, exactModelID: true) != nil
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
