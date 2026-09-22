import Foundation
import Testing
@testable import CodexBarCore

struct MuseListPriceTests {
    @Test
    func `recorded muse turns price at the meta list and leave unknown models unpriced`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-price-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("2026/08/31/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let line = """
        {"schema_version":1,"id":"turn-1","record_type":"event","payload_type":"runtime.session","payload_schema_version":1,"recorded_at":1788177600000000,"payload":{"event":{"kind":"model_completed","model":"muse-spark-1.3-contributor","usage":{"input_tokens":1000,"output_tokens":100,"cached_tokens":400,"reasoning_tokens":0}}}}
        """
        try (line + "\n").write(
            to: session.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let report = try MuseLocalUsageReader.makeDailyReportWithStatus(
            context: MuseLocalUsageReader.Context(sessionsRoot: root),
            calendar: calendar,
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            estimateCost: true,
            pricingCatalog: self.catalog())
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 1100)
        let cost = try #require(report.report.summary?.totalCostUSD)
        // 600 uncached * $0.10 + 400 cached * $0.002 + 100 output * $0.20, per million tokens.
        #expect(abs(cost - 0.0000808) < 0.0000000001)
        #expect(report.report.data.first?.estimatedRequestCount == 1)
        #expect(report.report.data.first?.unpricedRequestCount == 0)
    }

    @Test
    func `custom rates charge the uncached remainder once`() throws {
        let pricing = CostUsageCustomPricing.parse(Data("""
        {"meta/muse-spark-1.3-contributor":{"input":0.1,"output":0.2,"cache_read":0.002}}
        """.utf8))
        let catalog = try self.catalogWithoutCache()
        let cost = try #require(SubscriptionListPrice.estimateUSD(
            providerID: "meta",
            modelID: "muse-spark-1.3-contributor",
            inputTokens: 1000,
            outputTokens: 100,
            cacheReadTokens: 400,
            cacheCreationTokens: 0,
            catalog: catalog,
            customPricing: pricing))
        #expect(abs(cost - 0.0000808) < 0.0000000001)
    }

    @Test
    func `an unpriceable exact grok build row does not borrow the base price`() throws {
        let json = """
        {"xai":{"id":"xai","models":{
          "grok-4.6-build":{"id":"grok-4.6-build","cost":{"input":2,"output":6}},
          "grok-4.6":{"id":"grok-4.6","cost":{"input":2,"output":6,"cache_read":0.5}}
        }}}
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        let cost = SubscriptionListPrice.estimateUSD(
            providerID: "xai",
            modelID: "grok-4.6-build",
            inputTokens: 1000,
            outputTokens: 50,
            cacheReadTokens: 200,
            cacheCreationTokens: 0,
            catalog: catalog)
        #expect(cost == nil)
    }

    @Test
    func `missing cache rate does not invent a muse dollar total`() throws {
        let priced = try SubscriptionListPrice.estimateUSD(
            providerID: "meta",
            modelID: "muse-spark-1.3-contributor",
            inputTokens: 1000,
            outputTokens: 10,
            cacheReadTokens: 100,
            cacheCreationTokens: 0,
            catalog: self.catalogWithoutCache())
        #expect(priced == nil)
    }

    private func catalog() throws -> ModelsDevCatalog {
        let json = """
        {"meta":{"id":"meta","models":{"muse-spark-1.3-contributor":{"id":"muse-spark-1.3-contributor","cost":{"input":0.1,"output":0.2,"cache_read":0.002}}}}}
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private func catalogWithoutCache() throws -> ModelsDevCatalog {
        let json = """
        {"meta":{"id":"meta","models":{"muse-spark-1.3-contributor":{"id":"muse-spark-1.3-contributor","cost":{"input":0.1,"output":0.2}}}}}
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}
