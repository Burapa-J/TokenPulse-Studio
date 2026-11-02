import Foundation

public struct IngestionReport: Equatable, Sendable {
    public let ingestedEventCount: Int
    public let duplicateIgnoredCount: Int
    public let skippedMalformedLineCount: Int

    public init(
        ingestedEventCount: Int,
        duplicateIgnoredCount: Int,
        skippedMalformedLineCount: Int
    ) {
        self.ingestedEventCount = ingestedEventCount
        self.duplicateIgnoredCount = duplicateIgnoredCount
        self.skippedMalformedLineCount = skippedMalformedLineCount
    }
}

public struct UsageSummary: Equatable, Sendable {
    public let totalEvents: Int
    public let todaySpentMicroUSD: Int64
    public let monthSpentMicroUSD: Int64
    public let todayTokens: Int
    public let monthTokens: Int
    public let spendByProvider: [ProviderID: Int64]
    public let spendByProject: [String: Int64]
    public let dailyAlertState: BudgetAlertState
    public let monthlyAlertState: BudgetAlertState

    public init(
        totalEvents: Int,
        todaySpentMicroUSD: Int64,
        monthSpentMicroUSD: Int64,
        todayTokens: Int,
        monthTokens: Int,
        spendByProvider: [ProviderID: Int64],
        spendByProject: [String: Int64],
        dailyAlertState: BudgetAlertState,
        monthlyAlertState: BudgetAlertState
    ) {
        self.totalEvents = totalEvents
        self.todaySpentMicroUSD = todaySpentMicroUSD
        self.monthSpentMicroUSD = monthSpentMicroUSD
        self.todayTokens = todayTokens
        self.monthTokens = monthTokens
        self.spendByProvider = spendByProvider
        self.spendByProject = spendByProject
        self.dailyAlertState = dailyAlertState
        self.monthlyAlertState = monthlyAlertState
    }
}

public enum JSONLLogIngestor {
    /// Parses newline-delimited JSON usage logs (Claude Code, OpenAI/Codex, Gemini CLI, or custom JSONL).
    /// Malformed or half-written lines are safely skipped without aborting the batch.
    public static func parseLines(
        _ jsonlContent: String,
        defaultProvider: ProviderID = .anthropic,
        defaultProject: String = "Default Workspace"
    ) -> (events: [TokenUsageEvent], skippedLines: Int) {
        var events: [TokenUsageEvent] = []
        var skippedLines = 0

        let rawLines = jsonlContent.components(separatedBy: .newlines)
        let isoFormatter = ISO8601DateFormatter()

        for (index, rawLine) in rawLines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            guard let data = trimmed.data(using: .utf8),
                  let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                skippedLines += 1
                continue
            }

            // Extract token counts from either top-level or nested `usage` object (Claude/Anthropic/OpenAI standard)
            let usageDict = (jsonObj["usage"] as? [String: Any]) ?? jsonObj
            let inputTokens = (usageDict["input_tokens"] as? Int)
                ?? (usageDict["prompt_tokens"] as? Int)
                ?? (usageDict["inputTokens"] as? Int)
            let outputTokens = (usageDict["output_tokens"] as? Int)
                ?? (usageDict["completion_tokens"] as? Int)
                ?? (usageDict["outputTokens"] as? Int)
            let cachedTokens = (usageDict["cache_read_input_tokens"] as? Int)
                ?? (usageDict["cached_tokens"] as? Int)
                ?? (usageDict["cachedInputTokens"] as? Int)
                ?? 0

            guard let validInput = inputTokens, let validOutput = outputTokens,
                  validInput >= 0, validOutput >= 0, cachedTokens >= 0 else {
                skippedLines += 1
                continue
            }

            let model = (jsonObj["model"] as? String) ?? "claude-sonnet-4"
            let providerRaw = (jsonObj["provider"] as? String)?.lowercased() ?? ""
            let provider: ProviderID = {
                if providerRaw.contains("openai") || model.lowercased().contains("gpt") || model.lowercased().contains("o3") {
                    return .openAI
                }
                if providerRaw.contains("gemini") || model.lowercased().contains("gemini") {
                    return .gemini
                }
                if providerRaw.contains("cursor") {
                    return .cursor
                }
                if providerRaw.contains("ollama") || model.lowercased().contains("llama") {
                    return .localOllama
                }
                return defaultProvider
            }()

            let timestamp: Date = {
                if let tsString = jsonObj["timestamp"] as? String,
                   let parsedDate = isoFormatter.date(from: tsString) {
                    return parsedDate
                }
                if let epoch = jsonObj["timestamp"] as? TimeInterval {
                    return Date(timeIntervalSince1970: epoch)
                }
                return Date(timeIntervalSince1970: 1_762_000_000 + TimeInterval(index))
            }()

            let sessionID = (jsonObj["session_id"] as? String)
                ?? (jsonObj["id"] as? String)
                ?? (jsonObj["request_id"] as? String)
                ?? "line-\(index)"

            let projectName = (jsonObj["project"] as? String)
                ?? (jsonObj["cwd"] as? String)?.components(separatedBy: "/").last
                ?? defaultProject

            let deterministicID = "\(provider.rawValue):\(sessionID):\(Int(timestamp.timeIntervalSince1970))"

            let event = TokenUsageEvent(
                id: deterministicID,
                provider: provider,
                model: model,
                inputTokens: validInput,
                outputTokens: validOutput,
                cachedInputTokens: cachedTokens,
                timestamp: timestamp,
                projectName: projectName
            )
            events.append(event)
        }

        return (events, skippedLines)
    }
}

public actor UsageLedger {
    private var eventsByID: [String: TokenUsageEvent] = [:]
    private var policy: BudgetPolicy
    private let storageURL: URL?

    public init(
        policy: BudgetPolicy = BudgetPolicy(),
        storageURL: URL? = nil,
        initialEvents: [TokenUsageEvent] = []
    ) {
        self.policy = policy
        self.storageURL = storageURL
        for event in initialEvents {
            self.eventsByID[event.id] = event
        }
    }

    public func record(_ newEvents: [TokenUsageEvent]) -> IngestionReport {
        var added = 0
        var duplicates = 0
        for event in newEvents {
            if eventsByID[event.id] != nil {
                duplicates += 1
            } else {
                eventsByID[event.id] = event
                added += 1
            }
        }
        return IngestionReport(
            ingestedEventCount: added,
            duplicateIgnoredCount: duplicates,
            skippedMalformedLineCount: 0
        )
    }

    public func ingestJSONL(
        _ content: String,
        defaultProvider: ProviderID = .anthropic,
        defaultProject: String = "Default Workspace"
    ) -> IngestionReport {
        let parsed = JSONLLogIngestor.parseLines(
            content,
            defaultProvider: defaultProvider,
            defaultProject: defaultProject
        )
        let baseReport = record(parsed.events)
        return IngestionReport(
            ingestedEventCount: baseReport.ingestedEventCount,
            duplicateIgnoredCount: baseReport.duplicateIgnoredCount,
            skippedMalformedLineCount: parsed.skippedLines
        )
    }

    public func updatePolicy(_ newPolicy: BudgetPolicy) {
        self.policy = newPolicy
    }

    public func currentPolicy() -> BudgetPolicy {
        policy
    }

    public func allEventsSorted() -> [TokenUsageEvent] {
        eventsByID.values.sorted { $0.timestamp > $1.timestamp }
    }

    public func summary(referenceDate: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        var todaySpent: Int64 = 0
        var monthSpent: Int64 = 0
        var todayTokens = 0
        var monthTokens = 0
        var byProvider: [ProviderID: Int64] = [:]
        var byProject: [String: Int64] = [:]

        let refComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)

        for event in eventsByID.values {
            let evComponents = calendar.dateComponents([.year, .month, .day], from: event.timestamp)
            let isSameMonth = (evComponents.year == refComponents.year && evComponents.month == refComponents.month)
            let isSameDay = isSameMonth && (evComponents.day == refComponents.day)

            if isSameMonth {
                monthSpent += event.costMicroUSD
                monthTokens += event.totalTokens
                byProvider[event.provider, default: 0] += event.costMicroUSD
                byProject[event.projectName, default: 0] += event.costMicroUSD
            }
            if isSameDay {
                todaySpent += event.costMicroUSD
                todayTokens += event.totalTokens
            }
        }

        return UsageSummary(
            totalEvents: eventsByID.count,
            todaySpentMicroUSD: todaySpent,
            monthSpentMicroUSD: monthSpent,
            todayTokens: todayTokens,
            monthTokens: monthTokens,
            spendByProvider: byProvider,
            spendByProject: byProject,
            dailyAlertState: policy.evaluate(spentMicroUSD: todaySpent, isDaily: true),
            monthlyAlertState: policy.evaluate(spentMicroUSD: monthSpent, isDaily: false)
        )
    }

    public func saveAtomically() throws {
        guard let url = storageURL else { return }
        let snapshot = LedgerSnapshotV1(
            savedAt: Date(),
            policy: policy,
            events: allEventsSorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func loadFromDisk() throws {
        guard let url = storageURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LedgerSnapshotV1.self, from: data)
        self.policy = snapshot.policy
        self.eventsByID.removeAll(keepingCapacity: true)
        for event in snapshot.events {
            self.eventsByID[event.id] = event
        }
    }
}
