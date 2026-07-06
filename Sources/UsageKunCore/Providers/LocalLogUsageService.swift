import Foundation

public final class LocalLogUsageService: UsageService {
    private let home: URL
    private let calibrationStore: ClaudeCalibrationStore
    private var lastClaudeBlockWeightedUsed: Double?
    private var lastClaudeBlockComputedAt: Date?
    private var lastClaudePlanKey: String?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        calibrationStore: ClaudeCalibrationStore = ClaudeCalibrationStore()
    ) {
        self.home = home
        self.calibrationStore = calibrationStore
    }

    public func snapshots(now: Date) async -> [UsageSnapshot] {
        [
            codexSnapshot(now: now),
            claudeSnapshot(now: now)
        ]
    }

    public func recordClaudeOfficialSample(usedPercent: Double, now: Date) {
        guard let weighted = lastClaudeBlockWeightedUsed,
              let computedAt = lastClaudeBlockComputedAt,
              let planKey = lastClaudePlanKey,
              weighted > 200_000,
              usedPercent >= 10,
              now.timeIntervalSince(computedAt) < 600 else {
            return
        }

        let sample = weighted / (usedPercent / 100)
        guard sample > 500_000, sample < 500_000_000 else {
            return
        }

        let nextCalibration: ClaudeCalibration
        if var existing = calibrationStore.load(), existing.planKey == planKey {
            existing.capEstimate = existing.capEstimate * 0.7 + sample * 0.3
            existing.sampleCount += 1
            existing.updatedAt = now
            nextCalibration = existing
        } else {
            nextCalibration = ClaudeCalibration(
                capEstimate: sample,
                sampleCount: 1,
                planKey: planKey,
                updatedAt: now
            )
        }

        try? calibrationStore.save(nextCalibration)
    }

    public nonisolated static func claudeCostEstimateUSD(
        model: String?,
        input: Double,
        output: Double,
        cacheWrite: Double,
        cacheWrite5m: Double,
        cacheWrite1h: Double,
        cacheRead: Double
    ) -> Double {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_creation_input_tokens": cacheWrite,
            "cache_read_input_tokens": cacheRead
        ]

        if cacheWrite5m > 0 || cacheWrite1h > 0 {
            usage["cache_creation"] = [
                "ephemeral_5m_input_tokens": cacheWrite5m,
                "ephemeral_1h_input_tokens": cacheWrite1h
            ]
        }

        return ClaudePricing.estimateUSD(model: model, usage: ClaudeTokenUsage(usage: usage))
    }

    private func codexSnapshot(now: Date) -> UsageSnapshot {
        let localStats = codexLocalStats(now: now)

        if let rateLimit = latestCodexRateLimit(now: now) {
            let primary = rateLimit.primary
            let secondary = rateLimit.secondary
            // If the recorded 5h window already expired, Codex has reset the limit
            // but no new rate_limits event has arrived yet. Show a fresh window
            // instead of continuing to display the stale used % and a "0m" reset.
            let primaryExpired = primary.resetsAt.map { $0 <= now } ?? false
            let leftPercent = primaryExpired ? 100 : primary.leftPercent
            let resetAt = primaryExpired ? nil : primary.resetsAt
            let resetText: String
            if primaryExpired {
                resetText = "fresh"
            } else if let value = resetAt {
                resetText = Self.relativeResetText(value)
            } else {
                resetText = "--"
            }
            let weekly: UsageWindow?
            if let secondary {
                let secondaryExpired = secondary.resetsAt.map { $0 <= now } ?? false
                let secondaryLeft = secondaryExpired ? 100 : Int(secondary.leftPercent.rounded())
                weekly = UsageWindow(
                    percentLeft: Double(secondaryLeft),
                    resetAt: secondaryExpired ? nil : secondary.resetsAt
                )
            } else if let weekTokens = localStats.weekTokens {
                weekly = UsageWindow(
                    percentLeft: nil,
                    resetAt: nil,
                    detail: "\(Self.compact(weekTokens)) tok this week"
                )
            } else {
                weekly = nil
            }
            let messageSuffix = localStats.todayThreads.map { "Today: \($0) threads." } ?? ""
            let rawUsedPercent = primaryExpired ? 0 : Int(primary.usedPercent.rounded())
            var messageHead = primaryExpired
                ? "5 hour window reset. Waiting for the next Codex call to refresh the live limit."
                : "Showing 5 hour left from General usage limits. Raw used value is \(rawUsedPercent)%."
            // The logged value only updates while Codex is running, so flag stale data:
            // the real used % can only have decayed since it was recorded.
            let ageMinutes = Int(now.timeIntervalSince(rateLimit.updatedAt) / 60)
            if !primaryExpired && ageMinutes >= 30 {
                let ageText = ageMinutes >= 60 ? "\(ageMinutes / 60)h \(ageMinutes % 60)m" : "\(ageMinutes)m"
                messageHead += " Recorded \(ageText) ago; actual usage may be lower."
            }
            let message = "\(messageHead) \(messageSuffix)".trimmingCharacters(in: .whitespaces)

            return UsageSnapshot(
                provider: .codex,
                status: UsageStatusRules.status(primaryLeft: leftPercent, weeklyLeft: weekly?.percentLeft),
                used: leftPercent,
                limit: nil,
                percent: leftPercent,
                resetAt: resetAt,
                updatedAt: rateLimit.updatedAt,
                message: message,
                source: rateLimit.source,
                unit: "%",
                metricTitle: "5 hour left",
                secondaryTitle: "Reset",
                secondaryValue: resetText,
                weekly: weekly
            )
        }

        if let fallback = codexFallbackSnapshot(now: now, stats: localStats) {
            return fallback
        }

        return UsageSnapshot(
            provider: .codex,
            status: .unknown,
            used: nil,
            limit: nil,
            percent: nil,
            resetAt: nil,
            updatedAt: now,
            message: "No Codex session logs found. Start a Codex conversation to sync the 5 hour usage limit.",
            source: "local ~/.codex",
            unit: nil,
            metricTitle: "5 hour limit",
            secondaryTitle: "Reset"
        )
    }

    private func codexLocalStats(now: Date) -> CodexLocalStats {
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            return CodexLocalStats()
        }

        let fiveHoursStart = Int(now.addingTimeInterval(-5 * 60 * 60).timeIntervalSince1970)
        let dayStart = Int(Self.startOfDay(for: now).timeIntervalSince1970)
        let weekStart = Int(Self.startOfWeek(for: now).timeIntervalSince1970)
        let query = """
        select \
        coalesce(sum(case when updated_at >= \(fiveHoursStart) then tokens_used else 0 end),0), \
        coalesce(sum(case when updated_at >= \(dayStart) then tokens_used else 0 end),0), \
        coalesce(sum(case when updated_at >= \(weekStart) then tokens_used else 0 end),0), \
        coalesce(max(updated_at),0), \
        count(case when updated_at >= \(fiveHoursStart) then 1 end), \
        count(case when updated_at >= \(dayStart) then 1 end), \
        count(*) \
        from threads;
        """

        let result = runSQLite(database: database, query: query)
        guard result.exitCode == 0, let line = result.output.split(separator: "\n").first else {
            return CodexLocalStats(readFailed: true)
        }

        let values = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let fiveHourTokens = Double(values[safe: 0] ?? "0") ?? 0
        let todayTokens = Double(values[safe: 1] ?? "0") ?? 0
        let weekTokens = Double(values[safe: 2] ?? "0") ?? 0
        let updatedUnix = Double(values[safe: 3] ?? "0") ?? 0
        let fiveHourThreads = Int(values[safe: 4] ?? "0") ?? 0
        let todayThreads = Int(values[safe: 5] ?? "0") ?? 0
        let totalThreads = Int(values[safe: 6] ?? "0") ?? 0
        let updatedAt = updatedUnix > 0 ? Date(timeIntervalSince1970: updatedUnix) : now

        return CodexLocalStats(
            fiveHourTokens: fiveHourTokens,
            todayTokens: todayTokens,
            weekTokens: weekTokens,
            updatedAt: updatedAt,
            fiveHourThreads: fiveHourThreads,
            todayThreads: todayThreads,
            totalThreads: totalThreads
        )
    }

    private func codexFallbackSnapshot(now: Date, stats: CodexLocalStats) -> UsageSnapshot? {
        if stats.readFailed {
            return UsageSnapshot(
                provider: .codex,
                status: .error,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "Could not read the Codex local database. Check that sqlite3 is available.",
                source: "local",
                unit: "tok",
                metricTitle: "5 hour limit",
                secondaryTitle: "Week"
            )
        }

        guard let totalThreads = stats.totalThreads else {
            return nil
        }

        let status: UsageStatus = totalThreads > 0 ? .unknown : .unknown
        let fiveHourTokens = stats.fiveHourTokens ?? 0
        let weekTokens = stats.weekTokens ?? 0
        let todayThreads = stats.todayThreads ?? 0
        let weekly = UsageWindow(
            percentLeft: nil,
            resetAt: nil,
            detail: "\(Self.compact(weekTokens)) tok this week"
        )

        return UsageSnapshot(
            provider: .codex,
            status: status,
            used: nil,
            limit: nil,
            percent: nil,
            resetAt: nil,
            updatedAt: stats.updatedAt ?? now,
            message: "No 5 hour usage limit percent was found in session logs. Showing recent 5h \(Self.compact(fiveHourTokens)) tok and \(todayThreads) threads today as a reference.",
            source: "local ~/.codex",
            unit: "tok",
            metricTitle: "5 hour limit",
            secondaryTitle: "Week",
            secondaryValue: nil,
            weekly: weekly
        )
    }

    private func latestCodexRateLimit(now: Date) -> CodexRateLimitSnapshot? {
        var latest = latestCodexLiveRateLimit()

        let sessions = home.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            return latest
        }

        let files = jsonlFiles(under: sessions)
            .sorted { left, right in
                fileModificationDate(left) > fileModificationDate(right)
            }
            .prefix(50)

        for file in files {
            readCodexRateLimits(file) { snapshot in
                if latest == nil || snapshot.updatedAt > latest!.updatedAt {
                    latest = snapshot
                }
            }
        }

        return latest
    }

    private func latestCodexLiveRateLimit() -> CodexRateLimitSnapshot? {
        let database = home.appendingPathComponent(".codex/logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            return nil
        }

        // Two-column output with a U+001F column separator. We previously concatenated
        // `ts || char(31) || feedback_log_body` inside SQL, but sqlite3 CLI renders
        // U+001F as a printable "^_" sequence in its default mode, which made the
        // split on the wire-level byte fail and silently dropped every live row.
        let query = """
        select ts, feedback_log_body
        from logs
        where target = 'codex_api::endpoint::responses_websocket'
          and feedback_log_body like '%responses_websocket.stream_request%'
          and feedback_log_body like '%websocket event: {"type":"codex.rate_limits"%'
          and feedback_log_body not like '%response.output_item%'
          and feedback_log_body not like '%function_call%'
          and feedback_log_body not like '%ToolCall%'
        order by ts desc, ts_nanos desc
        limit 30;
        """

        let result = runSQLite(
            database: database,
            query: query,
            extraArguments: ["-separator", "\u{1F}"]
        )
        guard result.exitCode == 0 else {
            return nil
        }

        for row in result.output.split(whereSeparator: \.isNewline) {
            let parts = row.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let timestamp = Double(parts[0]),
                  let event = codexRateLimitEvent(from: String(parts[1])),
                  let rateLimits = event["rate_limits"] as? [String: Any],
                  let primaryObject = rateLimits["primary"] as? [String: Any],
                  let primary = CodexRateLimit(object: primaryObject),
                  primary.windowMinutes == 300 else {
                continue
            }

            let secondaryObject = rateLimits["secondary"] as? [String: Any]
            let secondary = secondaryObject.flatMap(CodexRateLimit.init(object:))
            return CodexRateLimitSnapshot(
                updatedAt: Date(timeIntervalSince1970: timestamp),
                primary: primary,
                secondary: secondary,
                source: "Codex live rate limits"
            )
        }

        return nil
    }

    private func codexRateLimitEvent(from text: String) -> [String: Any]? {
        guard let range = text.range(of: "{\"type\":\"codex.rate_limits\"") else {
            return nil
        }

        let fragment = String(text[range.lowerBound...])
        guard let json = firstJSONObject(in: fragment),
              let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var isEscaped = false
        var isInString = false
        var endIndex: String.Index?

        for index in text.indices {
            let character = text[index]

            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                isInString.toggle()
                continue
            }

            guard !isInString else { continue }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = text.index(after: index)
                    break
                }
            }
        }

        guard let endIndex else {
            return nil
        }

        return String(text[..<endIndex])
    }

    private func readCodexRateLimits(_ file: URL, onSnapshot: (CodexRateLimitSnapshot) -> Void) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = Data(rawLine.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let primaryObject = rateLimits["primary"] as? [String: Any],
                  let primary = CodexRateLimit(object: primaryObject),
                  primary.windowMinutes == 300 else {
                continue
            }

            let secondaryObject = rateLimits["secondary"] as? [String: Any]
            let updatedAt = Self.parseDate(object["timestamp"] as? String) ?? fileModificationDate(file)
            let secondary = secondaryObject.flatMap(CodexRateLimit.init(object:))

            onSnapshot(
                CodexRateLimitSnapshot(
                    updatedAt: updatedAt,
                    primary: primary,
                    secondary: secondary,
                    source: "Codex session rate limits"
                )
            )
        }
    }

    private func claudeSnapshot(now: Date) -> UsageSnapshot {
        let projects = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projects.path) else {
            clearLastClaudeBlock()
            return UsageSnapshot(
                provider: .claude,
                status: .unknown,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "~/.claude/projects was not found. Sign in and use Claude Code to sync local usage.",
                source: "local",
                unit: "tok",
                metricTitle: "5 hour left",
                secondaryTitle: "Reset"
            )
        }

        var stats = ClaudeLogStats()
        let dayStart = Self.startOfDay(for: now)
        let weekStart = Self.startOfWeek(for: now)
        let files = jsonlFiles(under: projects)

        for file in files {
            readClaudeJSONL(file, dayStart: dayStart, weekStart: weekStart, stats: &stats)
        }

        guard stats.usageEntries > 0 else {
            clearLastClaudeBlock()
            return UsageSnapshot(
                provider: .claude,
                status: .unknown,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "No Claude usage rows found yet. usage_kun checks Claude Code conversation logs.",
                source: "local ~/.claude",
                unit: "tok",
                metricTitle: "5 hour left",
                secondaryTitle: "Reset"
            )
        }

        let blocks = Self.buildClaudeBlocks(events: stats.events)
        let activeBlock = blocks.first { now >= $0.startTime && now < $0.endTime }
        let (planCap, planLabel, planKey) = claudePlanCap()
        let usedWeighted = activeBlock?.weighted ?? 0
        let usedTokens = activeBlock?.tokens ?? 0
        let leftPercent = max(0, min(100, 100 - usedWeighted / planCap * 100))
        let resetAt = activeBlock?.endTime
        lastClaudeBlockWeightedUsed = usedWeighted
        lastClaudeBlockComputedAt = now
        lastClaudePlanKey = planKey

        let costText = stats.todayEstimatedCost > 0
            ? " est. \(String(format: "$%.2f", stats.todayEstimatedCost))"
            : ""
        let resetText = resetAt.map(Self.relativeResetText) ?? "--"
        let weekly = UsageWindow(
            percentLeft: nil,
            resetAt: nil,
            detail: "\(Self.compact(stats.weekTokens)) tok this week"
        )

        let messageParts = [
            "\(planLabel) plan, 5h block: \(Self.compact(usedWeighted)) weighted tok of \(Self.compact(planCap)) (raw \(Self.compact(usedTokens)) tok)",
            "Today: \(stats.todaySessions.count) sessions\(costText)"
        ]

        return UsageSnapshot(
            provider: .claude,
            status: UsageStatusRules.status(primaryLeft: leftPercent, weeklyLeft: weekly.percentLeft),
            used: leftPercent,
            limit: nil,
            percent: leftPercent,
            resetAt: resetAt,
            updatedAt: stats.lastUpdated ?? now,
            message: messageParts.joined(separator: ". ") + ".",
            source: "local ~/.claude",
            unit: "%",
            metricTitle: "5 hour left",
            secondaryTitle: "Reset",
            secondaryValue: resetText,
            weekly: weekly
        )
    }

    private func clearLastClaudeBlock() {
        lastClaudeBlockWeightedUsed = nil
        lastClaudeBlockComputedAt = nil
        lastClaudePlanKey = nil
    }

    private static func buildClaudeBlocks(events: [ClaudeUsageEvent]) -> [ClaudeBlock] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var blocks: [ClaudeBlock] = []

        for event in sorted {
            if var last = blocks.last {
                let gap = event.timestamp.timeIntervalSince(last.lastActivity)
                let pastEnd = event.timestamp >= last.endTime
                if gap < claudeBlockDuration && !pastEnd {
                    last.tokens += event.tokens
                    last.weighted += event.weighted
                    last.lastActivity = event.timestamp
                    blocks[blocks.count - 1] = last
                    continue
                }
            }

            let start = roundedDownToHour(event.timestamp)
            blocks.append(
                ClaudeBlock(
                    startTime: start,
                    endTime: start.addingTimeInterval(claudeBlockDuration),
                    tokens: event.tokens,
                    weighted: event.weighted,
                    lastActivity: event.timestamp
                )
            )
        }

        return blocks
    }

    private func claudePlanCap() -> (cap: Double, label: String, key: String) {
        let path = home.appendingPathComponent(".claude.json")
        let orgType: String
        if let data = try? Data(contentsOf: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["oauthAccount"] as? [String: Any],
           let type = oauth["organizationType"] as? String {
            orgType = type.lowercased()
        } else {
            orgType = ""
        }

        let selection: ClaudePlanSelection
        switch orgType {
        case "claude_max_20x":
            selection = ClaudePlanSelection(key: "claude_max_20x", label: "Max 20x", defaultCap: ClaudePlanCaps.max20x)
        case "claude_max_5x", "claude_max5x":
            selection = ClaudePlanSelection(key: "claude_max_5x", label: "Max 5x", defaultCap: ClaudePlanCaps.max5x)
        case "claude_max":
            selection = ClaudePlanSelection(key: "claude_max", label: "Max", defaultCap: ClaudePlanCaps.max5x)
        case "claude_pro":
            selection = ClaudePlanSelection(key: "claude_pro", label: "Pro", defaultCap: ClaudePlanCaps.pro)
        default:
            selection = ClaudePlanSelection(key: "estimated", label: "estimated", defaultCap: ClaudePlanCaps.pro)
        }

        if let calibration = calibrationStore.load(), calibration.planKey == selection.key {
            return (calibration.capEstimate, "\(selection.label) (calibrated)", selection.key)
        }

        return (selection.defaultCap, selection.label, selection.key)
    }

    private static func roundedDownToHour(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components) ?? date
    }

    private static let claudeBlockDuration: TimeInterval = 5 * 60 * 60

    private func readClaudeJSONL(
        _ file: URL,
        dayStart: Date,
        weekStart: Date,
        stats: inout ClaudeLogStats
    ) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = Data(rawLine.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }

            guard let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            let timestamp = Self.parseDate(object["timestamp"] as? String)
            let eventDate = timestamp ?? Date.distantPast
            let tokenUsage = ClaudeTokenUsage(usage: usage)
            let tokens = tokenUsage.total
            guard tokens > 0 else { continue }

            let messageId = message["id"] as? String
            let requestId = object["requestId"] as? String
            if let messageId, let requestId {
                let dedupKey = "\(requestId):\(messageId)"
                guard stats.seenRequestKeys.insert(dedupKey).inserted else {
                    continue
                }
            }

            let model = message["model"] as? String
            let sessionId = object["sessionId"] as? String
            stats.usageEntries += 1
            stats.lastUpdated = max(stats.lastUpdated ?? eventDate, eventDate)

            if let timestamp {
                stats.events.append(
                    ClaudeUsageEvent(
                        timestamp: timestamp,
                        tokens: tokens,
                        weighted: tokenUsage.weighted
                    )
                )
            }

            if eventDate >= weekStart {
                stats.weekTokens += tokens
                if let sessionId {
                    stats.weekSessions.insert(sessionId)
                }
            }

            if eventDate >= dayStart {
                stats.todayTokens += tokens
                stats.todayEstimatedCost += ClaudePricing.estimateUSD(model: model, usage: tokenUsage)
                if let sessionId {
                    stats.todaySessions.insert(sessionId)
                }
            }
        }
    }

    private func jsonlFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
    }

    private func runSQLite(
        database: URL,
        query: String,
        extraArguments: [String] = []
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = extraArguments + [database.path, query]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (1, "")
        }
    }

    private static func startOfDay(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static func startOfWeek(for date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    fileprivate static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func fileModificationDate(_ file: URL) -> Date {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? Date.distantPast
    }

    private static func relativeResetText(_ date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    static func compact(_ value: Double) -> String {
        if abs(value) >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }

        if abs(value) >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }

        return String(format: "%.0f", value)
    }
}

private struct CodexLocalStats {
    var fiveHourTokens: Double?
    var todayTokens: Double?
    var weekTokens: Double?
    var updatedAt: Date?
    var fiveHourThreads: Int?
    var todayThreads: Int?
    var totalThreads: Int?
    var readFailed = false
}

private struct CodexRateLimitSnapshot {
    let updatedAt: Date
    let primary: CodexRateLimit
    let secondary: CodexRateLimit?
    let source: String
}

private struct CodexRateLimit {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var leftPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    init?(object: [String: Any]) {
        guard let usedPercent = Self.double(object["used_percent"]) else {
            return nil
        }

        self.usedPercent = usedPercent
        windowMinutes = Int(Self.double(object["window_minutes"]) ?? 0)

        let resetUnix = Self.double(object["reset_at"]) ?? Self.double(object["resets_at"])
        if let unix = resetUnix, unix > 0 {
            resetsAt = Date(timeIntervalSince1970: unix)
        } else if let seconds = Self.double(object["reset_after_seconds"]), seconds > 0 {
            resetsAt = Date().addingTimeInterval(seconds)
        } else {
            resetsAt = nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }
}

private struct ClaudeLogStats {
    var usageEntries = 0
    var todayTokens: Double = 0
    var weekTokens: Double = 0
    var todayEstimatedCost: Double = 0
    var todaySessions = Set<String>()
    var weekSessions = Set<String>()
    var lastUpdated: Date?
    var events: [ClaudeUsageEvent] = []
    var seenRequestKeys = Set<String>()
}

private enum ClaudePlanCaps {
    // Initial estimates for deduplicated Claude Code weighted tokens.
    static let pro: Double = 2_000_000
    static let max5x: Double = 10_000_000
    static let max20x: Double = 40_000_000
}

private struct ClaudePlanSelection {
    let key: String
    let label: String
    let defaultCap: Double
}

struct ClaudeUsageEvent {
    let timestamp: Date
    let tokens: Double
    let weighted: Double
}

struct ClaudeBlock {
    var startTime: Date
    var endTime: Date
    var tokens: Double
    var weighted: Double
    var lastActivity: Date
}

private struct ClaudeTokenUsage {
    let input: Double
    let output: Double
    let cacheCreation: Double
    let cacheRead: Double
    let cacheCreation5m: Double
    let cacheCreation1h: Double

    init(usage: [String: Any]) {
        input = Self.double(usage["input_tokens"])
        output = Self.double(usage["output_tokens"])
        cacheCreation = Self.double(usage["cache_creation_input_tokens"])
        cacheRead = Self.double(usage["cache_read_input_tokens"])

        let cacheCreationObject = usage["cache_creation"] as? [String: Any]
        cacheCreation5m = Self.double(cacheCreationObject?["ephemeral_5m_input_tokens"])
        cacheCreation1h = Self.double(cacheCreationObject?["ephemeral_1h_input_tokens"])
    }

    var total: Double {
        // cache_creation_input_tokens already equals ephemeral_5m + ephemeral_1h,
        // so do not add the breakdown again.
        input + output + cacheCreation + cacheRead
    }

    var weighted: Double {
        // Approximates Claude Code's session usage metric.
        // Cache reads count at the same 10% rate as their pricing discount.
        input + output + cacheCreation + cacheRead * 0.1
    }

    private static func double(_ value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value) ?? 0
        }

        return 0
    }
}

private enum ClaudePricing {
    struct Rate {
        let input: Double
        let output: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
    }

    static func estimateUSD(model: String?, usage: ClaudeTokenUsage) -> Double {
        let rate = rate(for: model)
        let million = 1_000_000.0

        let write5m: Double
        let write1h: Double
        if usage.cacheCreation5m > 0 || usage.cacheCreation1h > 0 {
            write5m = usage.cacheCreation5m
            write1h = usage.cacheCreation1h
        } else {
            write5m = usage.cacheCreation
            write1h = 0
        }

        return (usage.input * rate.input
            + usage.output * rate.output
            + write5m * rate.cacheWrite5m
            + write1h * rate.cacheWrite1h
            + usage.cacheRead * rate.cacheRead) / million
    }

    private static func rate(for model: String?) -> Rate {
        let normalized = (model ?? "").lowercased()

        if normalized.contains("fable") || normalized.contains("mythos") {
            return Rate(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1.0)
        }

        if normalized.contains("opus-4-1") || normalized.contains("opus-4-0") || normalized.contains("claude-3-opus") {
            return Rate(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5)
        }

        if normalized.contains("opus") {
            return Rate(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5)
        }

        if normalized.contains("haiku") {
            return Rate(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1)
        }

        return Rate(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
