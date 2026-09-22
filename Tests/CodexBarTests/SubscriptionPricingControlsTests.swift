import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SubscriptionPricingControlsTests {
    @Test
    func `grok token snapshot honors disabled pricing refresh and the injected client`() async throws {
        let root = try Self.writeGrokTurn(model: "grok-unlisted-test")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = CostUsageScanner.Options()
        options.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)

        let blocked = SubscriptionPricingRequestCounter()
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .grok,
            environment: ["GROK_HOME": root.path],
            now: Self.when,
            historyDays: 7,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: SubscriptionPricingCountingTransport(counter: blocked)))
        #expect(snapshot.last30DaysTokens == 1050)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(await blocked.requestCount == 0)

        let allowed = SubscriptionPricingRequestCounter()
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .grok,
            environment: ["GROK_HOME": root.path],
            now: Self.when,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: SubscriptionPricingCountingTransport(counter: allowed)))
        #expect(await allowed.requestCount > 0)
    }

    private static let when = Date(timeIntervalSince1970: 1_787_079_600)

    private static func writeGrokTurn(model: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-pricing-controls-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let usage = """
        {"timestamp":1787079600,"method":"_x.ai/session/update",\
        "params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,\
        "outputTokens":50,"totalTokens":1050,"cachedReadTokens":200,"cacheCreationTokens":0,\
        "modelUsage":{"\(model)":{"inputTokens":1000,"outputTokens":50,"totalTokens":1050,\
        "cachedReadTokens":200,"cacheCreationTokens":0}}}}}}
        """
        let updates = session.appendingPathComponent("updates.jsonl")
        try usage.write(to: updates, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: self.when], ofItemAtPath: updates.path)
        return root
    }
}

private actor SubscriptionPricingRequestCounter {
    private(set) var requestCount = 0

    func recordRequest() {
        self.requestCount += 1
    }
}

private struct SubscriptionPricingCountingTransport: ModelsDevHTTPTransport {
    let counter: SubscriptionPricingRequestCounter

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await self.counter.recordRequest()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(#"{"openai":{"id":"openai","models":{}}}"#.utf8), response)
    }
}
