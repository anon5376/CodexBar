import CoreFoundation
import Foundation

/// One local-calendar day of Grok session-token activity.
public struct GrokLocalDailyBucket: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int
    public let sessionCount: Int
    public let models: [String]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let costUSD: Double?
    public let estimatedRequestCount: Int?
    public let unpricedRequestCount: Int?
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?

    public init(
        date: String,
        totalTokens: Int,
        sessionCount: Int,
        models: [String],
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        costUSD: Double? = nil,
        estimatedRequestCount: Int? = nil,
        unpricedRequestCount: Int? = nil,
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]? = nil)
    {
        self.date = date
        self.totalTokens = totalTokens
        self.sessionCount = sessionCount
        self.models = models
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
        self.estimatedRequestCount = estimatedRequestCount
        self.unpricedRequestCount = unpricedRequestCount
        self.modelBreakdowns = modelBreakdowns
    }
}

/// Aggregated stats from local `~/.grok/sessions/**/signals.json` files.
/// Used as a local fallback view when the JSON-RPC billing call is unavailable.
public struct GrokLocalSessionSummary: Sendable {
    public let sessionCount: Int
    public let totalTokens: Int
    public let lastSessionAt: Date?
    public let primaryModel: String?
    public let models: [String]
    public let daily: [GrokLocalDailyBucket]
    public let scannedAt: Date

    public init(
        sessionCount: Int,
        totalTokens: Int,
        lastSessionAt: Date?,
        primaryModel: String?,
        models: [String],
        daily: [GrokLocalDailyBucket] = [],
        scannedAt: Date = .init())
    {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.lastSessionAt = lastSessionAt
        self.primaryModel = primaryModel
        self.models = models
        self.daily = daily
        self.scannedAt = scannedAt
    }

    /// Turn usage is priced at public API list rates. Signal-only context size stays unpriced.
    /// SuperGrok credits remain a quota and are never converted into dollars.
    public func toCostUsageTokenSnapshot(historyDays: Int) -> CostUsageTokenSnapshot? {
        let entries = self.daily.map { bucket in
            let requests = (bucket.estimatedRequestCount ?? 0) + (bucket.unpricedRequestCount ?? 0)
            return CostUsageDailyReport.Entry(
                date: bucket.date,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                cacheCreationTokens: bucket.cacheCreationTokens,
                totalTokens: bucket.totalTokens,
                requestCount: requests > 0 ? requests : bucket.sessionCount,
                costUSD: bucket.costUSD,
                modelsUsed: bucket.models.isEmpty ? nil : bucket.models,
                modelBreakdowns: bucket.modelBreakdowns,
                unpricedRequestCount: bucket.unpricedRequestCount,
                estimatedRequestCount: bucket.estimatedRequestCount,
                pricedRequestCount: bucket.costUSD == nil && bucket.estimatedRequestCount == nil ? nil : 0)
        }
        guard !entries.isEmpty else { return nil }
        let todayKey = GrokLocalSessionScanner.dayKey(for: self.scannedAt, calendar: .current)
        let today = todayKey.flatMap { key in entries.first { $0.date == key } }
        let costs = entries.compactMap(\.costUSD)
        let priced = entries.allSatisfy { ($0.totalTokens ?? 0) == 0 || $0.costUSD != nil }
            && costs.isEmpty == false
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            last30DaysTokens: self.totalTokens,
            last30DaysCostUSD: priced ? costs.reduce(0, +) : nil,
            historyDays: historyDays,
            historyCoverageIsEstablished: true,
            costProvenance: priced ? .listPriceEstimate : .unknown,
            daily: entries,
            updatedAt: self.scannedAt)
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30

    /// Walk `~/.grok/sessions/<encoded_cwd>/<session_id>/` and aggregate stats.
    /// `updates.jsonl` turn usage replaces the context-size signal for that session.
    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) -> GrokLocalSessionSummary
    {
        self.summarize(
            env: env,
            fileManager: fileManager,
            lookbackDays: lookbackDays,
            now: now,
            catalog: nil,
            customPricing: .empty)
    }

    // swiftlint:disable:next function_parameter_count
    static func summarize(
        env: [String: String],
        fileManager: FileManager,
        lookbackDays: Int,
        now: Date,
        catalog: ModelsDevCatalog?,
        customPricing: CostUsageCustomPricing) -> GrokLocalSessionSummary
    {
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let rootEnum = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else {
            return self.emptySummary(now: now)
        }

        let calendar = Calendar.current
        let lookbackCutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        var sessions: [String: SessionScan] = [:]

        while let url = rootEnum.nextObject() as? URL {
            let name = url.lastPathComponent
            guard name == "signals.json" || name == "updates.jsonl" else { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            guard mtime >= lookbackCutoff else { continue }
            let key = url.deletingLastPathComponent().path
            var session = sessions[key] ?? SessionScan()
            if name == "signals.json" {
                self.readSignals(url: url, mtime: mtime, calendar: calendar, into: &session)
            } else if (attrs?.fileSize ?? 0) <= self.maxTurnLogBytes {
                self.readTurns(url: url, mtime: mtime, into: &session)
            }
            sessions[key] = session
        }

        var sessionCount = 0
        var totalTokens = 0
        var lastSessionAt: Date?
        var modelCounts: [String: Int] = [:]
        var days: [String: DayAccum] = [:]

        for session in sessions.values {
            let contribution = self.contribution(
                session,
                lookbackCutoff: lookbackCutoff,
                catalog: catalog,
                customPricing: customPricing)
            guard !contribution.pieces.isEmpty else { continue }
            sessionCount += 1
            if let at = contribution.lastAt, at > (lastSessionAt ?? Date.distantPast) {
                lastSessionAt = at
            }
            var countedDays = Set<String>()
            for piece in contribution.pieces {
                guard let added = self.checkedAdd(totalTokens, piece.totalTokens) else { continue }
                totalTokens = added
                modelCounts[piece.model, default: 0] += 1
                var day = days[piece.day] ?? DayAccum()
                if countedDays.insert(piece.day).inserted {
                    day.sessions += 1
                }
                day.add(piece)
                days[piece.day] = day
            }
        }

        let sortedModels = modelCounts.sorted { $0.value > $1.value }.map(\.key)
        let daily = days.keys.sorted().map { key in
            let day = days[key] ?? DayAccum()
            return day.bucket(date: key)
        }
        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            lastSessionAt: lastSessionAt,
            primaryModel: sortedModels.first,
            models: sortedModels,
            daily: daily,
            scannedAt: now)
    }

    public static func summarizeOffMainThread(
        env: [String: String],
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) async throws -> GrokLocalSessionSummary
    {
        try await self.summarizeOffMainThread(env: env, lookbackDays: lookbackDays, now: now, pricing: .init())
    }

    static func summarizeOffMainThread(
        env: [String: String],
        lookbackDays: Int,
        now: Date,
        pricing: SubscriptionPricingControls) async throws -> GrokLocalSessionSummary
    {
        let customPricing = CostUsageCustomPricing.load(environment: env)
        let catalog = await pricing.catalog(now: now)
        let summary = try await self.scanSummary(
            env: env,
            lookbackDays: lookbackDays,
            now: now,
            catalog: catalog,
            customPricing: customPricing)
        guard let refreshed = await pricing.catalog(
            pricing: self.unpricedModelIDs(in: summary),
            // Provider-specific by design: Grok Build models are listed under xAI in the price catalog.
            providerID: "xai",
            now: now)
        else { return summary }
        return try await self.scanSummary(
            env: env,
            lookbackDays: lookbackDays,
            now: now,
            catalog: refreshed,
            customPricing: customPricing)
    }

    private static func scanSummary(
        env: [String: String],
        lookbackDays: Int,
        now: Date,
        catalog: ModelsDevCatalog?,
        customPricing: CostUsageCustomPricing) async throws -> GrokLocalSessionSummary
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try checkCancellation()
            let summary = Self.summarize(
                env: env,
                fileManager: .default,
                lookbackDays: lookbackDays,
                now: now,
                catalog: catalog,
                customPricing: customPricing)
            try checkCancellation()
            return summary
        }
    }

    private static func unpricedModelIDs(in summary: GrokLocalSessionSummary) -> Set<String> {
        var ids = Set<String>()
        for day in summary.daily {
            for breakdown in day.modelBreakdowns ?? [] {
                guard breakdown.costUSD == nil, (breakdown.totalTokens ?? 0) > 0 else { continue }
                let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != "unknown" else { continue }
                ids.insert(name)
                if name.hasSuffix("-build") {
                    let stem = String(name.dropLast("-build".count))
                    if !stem.isEmpty { ids.insert(stem) }
                }
            }
        }
        return ids
    }

    private static let maxTurnLogBytes = 32 * 1024 * 1024

    private struct SessionScan {
        var signalTokens: Int?
        var signalDay: String?
        var signalAt: Date?
        var signalModel = "unknown"
        var turns: [Turn] = []
        var turnParseFailed = false
    }

    private struct Turn: Equatable {
        let at: Date
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
    }

    private struct Piece {
        let day: String
        let at: Date
        let model: String
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let totalTokens: Int
        let costUSD: Double?
        let requests: Int
    }

    private struct Contribution {
        var pieces: [Piece] = []
        var lastAt: Date?
    }

    private struct ModelAccum {
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var total = 0
        var requests = 0
        var cost = 0.0
        var priced = true
    }

    private struct DayAccum {
        var tokens = 0
        var sessions = 0
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var cost = 0.0
        var costComplete = true
        var sawCost = false
        var estimated = 0
        var unpriced = 0
        var models: [String: ModelAccum] = [:]

        mutating func add(_ piece: Piece) {
            self.tokens += piece.totalTokens
            if piece.costUSD == nil {
                self.costComplete = false
                self.unpriced += piece.requests
            } else if let cost = piece.costUSD {
                self.cost += cost
                self.sawCost = true
                self.estimated += piece.requests
            }
            if let input = piece.input, let output = piece.output {
                self.input = (self.input ?? 0) + input
                self.output = (self.output ?? 0) + output
                self.cacheRead = (self.cacheRead ?? 0) + (piece.cacheRead ?? 0)
                self.cacheWrite = (self.cacheWrite ?? 0) + (piece.cacheWrite ?? 0)
            }
            var model = self.models[piece.model] ?? ModelAccum()
            model.total += piece.totalTokens
            model.requests += piece.requests
            if let input = piece.input { model.input = (model.input ?? 0) + input }
            if let output = piece.output { model.output = (model.output ?? 0) + output }
            if let cacheRead = piece.cacheRead { model.cacheRead = (model.cacheRead ?? 0) + cacheRead }
            if let cacheWrite = piece.cacheWrite { model.cacheWrite = (model.cacheWrite ?? 0) + cacheWrite }
            if let cost = piece.costUSD, model.priced {
                model.cost += cost
            } else if piece.costUSD == nil {
                model.priced = false
            }
            self.models[piece.model] = model
        }

        func bucket(date: String) -> GrokLocalDailyBucket {
            let names = self.models.keys.sorted()
            let breakdowns = names.map { name in
                let model = self.models[name] ?? ModelAccum()
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: name,
                    costUSD: model.priced && model.requests > 0 ? model.cost : nil,
                    totalTokens: model.total,
                    requestCount: model.requests,
                    inputTokens: model.input,
                    outputTokens: model.output,
                    cacheReadTokens: model.cacheRead,
                    cacheCreationTokens: model.cacheWrite)
            }
            return GrokLocalDailyBucket(
                date: date,
                totalTokens: self.tokens,
                sessionCount: self.sessions,
                models: names,
                inputTokens: self.input,
                outputTokens: self.output,
                cacheReadTokens: self.cacheRead,
                cacheCreationTokens: self.cacheWrite,
                costUSD: self.costComplete && self.sawCost ? self.cost : nil,
                estimatedRequestCount: self.estimated,
                unpricedRequestCount: self.unpriced,
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns)
        }
    }

    private static func emptySummary(now: Date) -> GrokLocalSessionSummary {
        GrokLocalSessionSummary(
            sessionCount: 0,
            totalTokens: 0,
            lastSessionAt: nil,
            primaryModel: nil,
            models: [],
            scannedAt: now)
    }

    private static func readSignals(
        url: URL,
        mtime: Date,
        calendar: Calendar,
        into session: inout SessionScan)
    {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let beforeCompaction = self.intValue(json["totalTokensBeforeCompaction"]) ?? 0
        let contextUsed = self.intValue(json["contextTokensUsed"]) ?? 0
        guard let tokens = self.checkedAdd(beforeCompaction, contextUsed), tokens >= 0 else { return }
        session.signalTokens = tokens
        session.signalDay = self.dayKey(for: mtime, calendar: calendar)
        session.signalAt = mtime
        if let primary = (json["primaryModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primary.isEmpty
        {
            session.signalModel = primary
        }
    }

    private static func readTurns(url: URL, mtime: Date, into session: inout SessionScan) {
        guard let data = try? Data(contentsOf: url) else { return }
        // A log that is not UTF-8 falls back to the context signal instead of counting repaired text.
        guard let text = String(bytes: data, encoding: .utf8) else {
            session.turnParseFailed = true
            return
        }
        var seen: [String: Turn] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.contains("\"sessionUpdate\":\"turn_completed\"")
                || raw.contains("\"sessionUpdate\": \"turn_completed\"")
            else { continue }
            guard let identified = self.turn(from: raw, fallbackDate: mtime) else {
                session.turnParseFailed = true
                continue
            }
            if let prompt = identified.promptID {
                if let previous = seen[prompt], previous != identified.turn {
                    session.turnParseFailed = true
                }
                seen[prompt] = identified.turn
                continue
            }
            session.turns.append(identified.turn)
        }
        if session.turnParseFailed {
            session.turns = []
            return
        }
        session.turns.append(contentsOf: seen.values)
    }

    private struct IdentifiedTurn {
        let promptID: String?
        let turn: Turn
    }

    private static func turn(from line: String, fallbackDate: Date) -> IdentifiedTurn? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = json["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any]
        else { return nil }
        let at = self.intValue(json["timestamp"]).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? fallbackDate
        let prompt = update["prompt_id"] as? String
        if let models = usage["modelUsage"] as? [String: Any], !models.isEmpty {
            guard models.count == 1, let (name, raw) = models.first,
                  let body = raw as? [String: Any],
                  let turn = self.turn(model: name, usage: body, at: at)
            else { return nil }
            return IdentifiedTurn(promptID: prompt, turn: turn)
        }
        guard let turn = self.turn(model: "unknown", usage: usage, at: at) else { return nil }
        return IdentifiedTurn(promptID: prompt, turn: turn)
    }

    private static func turn(model: String, usage: [String: Any], at: Date) -> Turn? {
        guard let input = self.intValue(usage["inputTokens"]),
              let output = self.intValue(usage["outputTokens"]),
              input >= 0, output >= 0,
              let total = self.checkedAdd(input, output)
        else { return nil }
        let cacheRead = self.intValue(usage["cachedReadTokens"]) ?? 0
        let cacheWrite = self.intValue(usage["cacheCreationTokens"]) ?? 0
        guard cacheRead >= 0, cacheWrite >= 0, cacheRead <= input, cacheWrite <= input else { return nil }
        if let recorded = self.intValue(usage["totalTokens"]), recorded != total { return nil }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return Turn(
            at: at,
            model: name.isEmpty ? "unknown" : name,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            total: total)
    }

    private static func contribution(
        _ session: SessionScan,
        lookbackCutoff: Date,
        catalog: ModelsDevCatalog?,
        customPricing: CostUsageCustomPricing) -> Contribution
    {
        let calendar = Calendar.current
        if !session.turns.isEmpty, !session.turnParseFailed {
            var pieces: [Piece] = []
            var last: Date?
            for turn in session.turns where turn.at >= lookbackCutoff {
                guard let day = self.dayKey(for: turn.at, calendar: calendar) else { continue }
                let cost = SubscriptionListPrice.estimateUSD(
                    // Provider-specific by design: Grok Build models are listed under xAI in the price catalog.
                    providerID: "xai",
                    modelID: turn.model,
                    usage: .init(
                        inputTokens: turn.input,
                        outputTokens: turn.output,
                        cacheReadTokens: turn.cacheRead,
                        cacheCreationTokens: turn.cacheWrite),
                    catalog: catalog,
                    customPricing: customPricing)
                pieces.append(Piece(
                    day: day,
                    at: turn.at,
                    model: turn.model,
                    input: turn.input,
                    output: turn.output,
                    cacheRead: turn.cacheRead,
                    cacheWrite: turn.cacheWrite,
                    totalTokens: turn.total,
                    costUSD: cost,
                    requests: 1))
                if let previous = last {
                    if turn.at > previous { last = turn.at }
                } else {
                    last = turn.at
                }
            }
            return Contribution(pieces: pieces, lastAt: last)
        }
        guard let tokens = session.signalTokens, let day = session.signalDay, tokens > 0 || session.signalAt != nil
        else { return Contribution() }
        return Contribution(
            pieces: [Piece(
                day: day,
                at: session.signalAt ?? .distantPast,
                model: session.signalModel,
                input: nil,
                output: nil,
                cacheRead: nil,
                cacheWrite: nil,
                totalTokens: tokens,
                costUSD: nil,
                requests: 1)],
            lastAt: session.signalAt)
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
