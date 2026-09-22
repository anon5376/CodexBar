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

        for model in self.modelIDs(providerID: providerID, modelID: modelID) {
            if let cost = CostUsagePricing.providerCostUSD(
                providerID: providerID,
                model: model,
                inputTokens: uncached,
                cachedInputTokens: cacheReadTokens,
                cacheWriteInputTokens: cacheCreationTokens,
                outputTokens: outputTokens,
                pricingDate: nil,
                catalog: catalog,
                customPricing: customPricing),
                cost.isFinite, cost >= 0
            {
                return cost
            }
        }
        return nil
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
