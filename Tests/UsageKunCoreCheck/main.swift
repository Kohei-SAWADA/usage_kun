import Foundation
import UsageKunCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("Check failed: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct UsageKunCoreCheck {
    static func main() async {
        expect([UsageStatus.ok, .critical, .warning, .error].max() == .error, "error should be most severe")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshots = await MockUsageService().snapshots(now: now)
        let providers = Set(snapshots.map(\.provider))

        expect(providers == [.claude, .codex], "mock service should return Claude and Codex")
        expect(snapshots.allSatisfy { $0.updatedAt == now }, "mock snapshots should use provided update date")

        let unknown = UsageSnapshot(
            provider: .claude,
            status: .unknown,
            used: nil,
            limit: nil,
            percent: nil,
            resetAt: nil,
            updatedAt: Date(),
            message: nil
        )

        expect(unknown.usedDisplay == "--", "unknown usage display should fallback")
        expect(unknown.percentDisplay == "--%", "unknown percent display should fallback")

        let legacyConfigJSON = """
        {
          "localLogEnabled": false,
          "retiredRemoteFlag": true,
          "retiredSourceName": "safari",
          "refreshIntervalMinutes": 10
        }
        """.data(using: .utf8)!
        let legacyConfig = try! JSONDecoder().decode(AppConfig.self, from: legacyConfigJSON)

        expect(legacyConfig.localLogEnabled == false, "legacy config values should decode")
        expect(legacyConfig.desktopWidgetEnabled == true, "desktop widget should default on for legacy config")
        expect(legacyConfig.launchAtLoginEnabled == true, "launch at login should default on for legacy config")
        expect(legacyConfig.menuBarShowsNumbers == false, "menu bar numbers should default off for legacy config")
        expect(legacyConfig.onboardingCompleted == false, "onboarding should default incomplete for legacy config")
        expect(legacyConfig.notificationsEnabled == false, "notifications should default off for legacy config")
        expect(legacyConfig.claudeOfficialUsageEnabled == false, "official Claude sync should default off for legacy config")
        expect(legacyConfig.codexOfficialUsageEnabled == false, "official Codex sync should default off for legacy config")

        checkOfficialUsageParsers(now: now)
        checkWeeklySnapshot(now: now)
        checkMenuBarEntries(now: now)
        checkOnboardingDetection()
        checkNotificationPlanner(now: now)
        await checkClaudeDedup(now: now)
        await checkClaudeCalibration(now: now)
        checkClaudePricing()

        if CommandLine.arguments.contains("--live") {
            await runLiveOfficialUsageCheck(now: Date())
        }

        if CommandLine.arguments.contains("--claude-estimate") {
            await runClaudeEstimate(now: Date())
        }

        if CommandLine.arguments.contains("--live-codex-composite") {
            await runLiveCodexCompositeCheck(now: Date())
        }

        print("UsageKunCoreCheck passed")
    }

    static func checkOfficialUsageParsers(now: Date) {
        let claudeJSON = """
        {
          "five_hour": {"utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00"},
          "seven_day": {"utilization": 13.5, "resets_at": "2026-04-17T00:59:59.951713+00:00"},
          "seven_day_opus": null
        }
        """.data(using: .utf8)!
        let claude = CLIOAuthUsageService.parseClaudeOAuthUsage(data: claudeJSON, now: now)

        expect(claude != nil, "Claude OAuth usage JSON should parse")
        expect(claude?.primary.usedPercent == 33.0, "Claude five_hour utilization should parse")
        expect(claude?.primary.resetsAt != nil, "Claude microsecond resets_at should parse")
        expect(claude?.secondary?.usedPercent == 13.5, "Claude seven_day utilization should parse")

        let codexNestedJSON = """
        {
          "plan_type": "plus",
          "rate_limits": {
            "primary": {"used_percent": 23.0, "window_minutes": 300, "resets_in_seconds": 5400},
            "secondary": {"used_percent": 11.0, "window_minutes": 10080, "resets_in_seconds": 320000}
          }
        }
        """.data(using: .utf8)!
        let codexNested = CLIOAuthUsageService.parseCodexWhamUsage(data: codexNestedJSON, now: now)

        expect(codexNested != nil, "Codex nested rate_limits JSON should parse")
        expect(codexNested?.primary.usedPercent == 23.0, "Codex primary used_percent should parse")
        expect(codexNested?.primary.resetsAt == now.addingTimeInterval(5400), "Codex resets_in_seconds should be relative")
        expect(codexNested?.secondary?.usedPercent == 11.0, "Codex secondary used_percent should parse")
        expect(codexNested?.planLabel == "plus", "Codex plan_type should parse")

        let codexWindowJSON = """
        {
          "rate_limit": {
            "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800, "reset_time_ms": 1800600000000},
            "primary_window": {"used_percent": 80, "limit_window_seconds": 18000, "reset_time_ms": 1800010000000}
          }
        }
        """.data(using: .utf8)!
        let codexWindows = CLIOAuthUsageService.parseCodexWhamUsage(data: codexWindowJSON, now: now)

        expect(codexWindows != nil, "Codex window-style JSON should parse")
        expect(codexWindows?.primary.usedPercent == 80, "shorter window should stay primary")
        expect(codexWindows?.primary.windowMinutes == 300, "limit_window_seconds should convert to minutes")
        expect(
            codexWindows?.primary.resetsAt == Date(timeIntervalSince1970: 1_800_010_000),
            "reset_time_ms should parse as absolute milliseconds"
        )
        expect(codexWindows?.secondary?.usedPercent == 40, "longer window should become secondary")
    }

    static func checkWeeklySnapshot(now: Date) {
        let claudeJSON = """
        {
          "five_hour": {"utilization": 40.0, "resets_at": "2026-04-11T07:00:00Z"},
          "seven_day": {"utilization": 90.0, "resets_at": "2026-04-17T00:00:00Z"}
        }
        """.data(using: .utf8)!

        guard let claudeReading = CLIOAuthUsageService.parseClaudeOAuthUsage(data: claudeJSON, now: now) else {
            expect(false, "Claude weekly fixture should parse")
            return
        }

        let claude = CLIOAuthUsageService.makeSnapshot(
            provider: .claude,
            reading: claudeReading,
            now: now,
            source: "fixture",
            detail: "fixture"
        )

        expectClose(claude.percent, 60, "Claude 5h left should be 60")
        expectClose(claude.weekly?.percentLeft, 10, "Claude weekly left should be 10")
        expect(claude.status == .critical, "Claude weekly 10% left should drive status")
        expect(claude.secondaryValue?.contains("7 day") != true, "Claude secondaryValue should not contain 7 day")

        let codexJSON = """
        {
          "rate_limits": {
            "primary": {"used_percent": 40.0, "window_minutes": 300, "resets_in_seconds": 3600},
            "secondary": {"used_percent": 90.0, "window_minutes": 10080, "resets_in_seconds": 360000}
          }
        }
        """.data(using: .utf8)!

        guard let codexReading = CLIOAuthUsageService.parseCodexWhamUsage(data: codexJSON, now: now) else {
            expect(false, "Codex weekly fixture should parse")
            return
        }

        let codex = CLIOAuthUsageService.makeSnapshot(
            provider: .codex,
            reading: codexReading,
            now: now,
            source: "fixture",
            detail: "fixture"
        )

        expectClose(codex.percent, 60, "Codex 5h left should be 60")
        expectClose(codex.weekly?.percentLeft, 10, "Codex weekly left should be 10")
        expect(codex.status == .critical, "Codex weekly 10% left should drive status")
        expect(codex.secondaryValue?.contains("7 day") != true, "Codex secondaryValue should not contain 7 day")
    }

    static func checkMenuBarEntries(now: Date) {
        let snapshots = [
            UsageSnapshot(
                provider: .claude,
                status: .ok,
                used: 62,
                limit: nil,
                percent: 62,
                resetAt: nil,
                updatedAt: now,
                message: nil,
                unit: "%",
                weekly: UsageWindow(percentLeft: 40, resetAt: nil)
            ),
            UsageSnapshot(
                provider: .codex,
                status: .ok,
                used: 41,
                limit: nil,
                percent: 41,
                resetAt: nil,
                updatedAt: now,
                message: nil,
                unit: "%"
            )
        ]

        let entries = UsageStore.menuBarEntries(snapshots: snapshots)

        expect(entries.count == 2, "menu bar entries should include Claude and Codex")
        expect(entries.map(\.mark) == ["C", "X"], "menu bar entry order should be C then X")
        expectClose(entries.first?.percentLeft, 40, "Claude menu bar percent should use the constrained weekly value")
        expectClose(entries.last?.percentLeft, 41, "Codex menu bar percent should use the primary value")
    }

    static func checkOnboardingDetection() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageKunCoreCheck-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        do {
            let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
            try "{}".write(to: codexDirectory.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        } catch {
            expect(false, "test Codex sign-in fixture should be writable: \(error)")
        }

        var detection = OnboardingDetector.detect(home: home)
        expect(detection.codexSignInFound == true, "Codex auth.json should be detected")
        expect(detection.claudeSignInFound == false, "Claude sign-in should not be detected yet")

        do {
            try "{}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        } catch {
            expect(false, "test Claude sign-in fixture should be writable: \(error)")
        }

        detection = OnboardingDetector.detect(home: home)
        expect(detection.codexSignInFound == true, "Codex detection should remain true")
        expect(detection.claudeSignInFound == true, "Claude .claude.json should be detected")
        expect(detection.anyFound == true, "detection should report anyFound")
    }

    static func checkNotificationPlanner(now: Date) {
        func snapshot(percent: Double, resetAt: Date?, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                provider: .claude,
                status: UsageStatusRules.status(primaryLeft: percent, weeklyLeft: nil),
                used: percent,
                limit: nil,
                percent: percent,
                resetAt: resetAt,
                updatedAt: updatedAt,
                message: nil,
                unit: "%"
            )
        }

        let resetAt = now.addingTimeInterval(3600)
        let previous30 = snapshot(percent: 30, resetAt: resetAt, updatedAt: now)
        let current24 = snapshot(percent: 24, resetAt: resetAt, updatedAt: now.addingTimeInterval(60))

        var plan = UsageNotificationPlanner.plan(
            previous: [previous30],
            current: [current24],
            alreadyNotified: []
        )
        expect(plan.events.count == 1, "crossing 25% should create one notification")
        expect(plan.events.first?.dedupKey == "claude.5h.threshold25", "25% notification key should be stable")
        expect(plan.notified.contains("claude.5h.threshold25"), "25% key should be marked notified")

        plan = UsageNotificationPlanner.plan(
            previous: [previous30],
            current: [current24],
            alreadyNotified: plan.notified
        )
        expect(plan.events.isEmpty, "already notified 25% crossing should not repeat")

        let current9 = snapshot(percent: 9, resetAt: resetAt, updatedAt: now.addingTimeInterval(120))
        plan = UsageNotificationPlanner.plan(
            previous: [current24],
            current: [current9],
            alreadyNotified: plan.notified
        )
        expect(plan.events.count == 1, "crossing 10% should create one notification")
        expect(plan.events.first?.dedupKey == "claude.5h.threshold10", "10% notification key should be stable")

        let resetPrevious = snapshot(
            percent: 9,
            resetAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(-20)
        )
        let resetCurrent = snapshot(
            percent: 95,
            resetAt: now.addingTimeInterval(5 * 60 * 60),
            updatedAt: now
        )
        plan = UsageNotificationPlanner.plan(
            previous: [resetPrevious],
            current: [resetCurrent],
            alreadyNotified: plan.notified
        )
        expect(plan.events.count == 1, "reset recovery should create one notification")
        expect(plan.events.first?.dedupKey.contains(".reset.") == true, "reset notification should use a reset key")
        expect(!plan.notified.contains("claude.5h.threshold25"), "reset should clear threshold25 key")
        expect(!plan.notified.contains("claude.5h.threshold10"), "reset should clear threshold10 key")
    }

    @MainActor
    static func checkClaudeDedup(now: Date) async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageKunCoreCheck-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        do {
            try writeClaudeFixture(home: home, now: now)
        } catch {
            expect(false, "test Claude fixture should be writable: \(error)")
        }

        let snapshots = await LocalLogUsageService(home: home).snapshots(now: now)
        guard let claude = snapshots.first(where: { $0.provider == .claude }) else {
            expect(false, "local log service should return Claude snapshot")
            return
        }

        let expectedPercent = 100 - 5_500.0 / 2_000_000.0 * 100
        expectClose(claude.percent, expectedPercent, "Claude dedup should use 5.5K weighted tokens")
        expect(claude.message?.contains("5.5K weighted tok") == true, "Claude message should show deduplicated weighted usage")
        expect(claude.message?.contains("8.5K") != true, "Claude message should not show naive duplicate total")
    }

    @MainActor
    static func checkClaudeCalibration(now: Date) async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageKunCoreCheck-\(UUID().uuidString)", isDirectory: true)
        let calibrationURL = home.appendingPathComponent("claude_calibration.json")
        let calibrationStore = ClaudeCalibrationStore(fileURL: calibrationURL)
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        do {
            try writeClaudeFixture(home: home, now: now, scale: 100)
        } catch {
            expect(false, "test Claude calibration fixture should be writable: \(error)")
        }

        let service = LocalLogUsageService(home: home, calibrationStore: calibrationStore)
        _ = await service.snapshots(now: now)
        service.recordClaudeOfficialSample(usedPercent: 25, now: now)

        let calibration = calibrationStore.load()
        expect(calibration != nil, "Claude calibration should be saved")
        expectClose(calibration?.capEstimate, 2_200_000, "Claude calibration cap should be learned from official used percent")
        expect(calibration?.sampleCount == 1, "Claude calibration should record sample count")

        let snapshots = await service.snapshots(now: now)
        guard let claude = snapshots.first(where: { $0.provider == .claude }) else {
            expect(false, "calibrated local log service should return Claude snapshot")
            return
        }

        expect(claude.message?.contains("(calibrated)") == true, "Claude message should mark calibrated cap")
        expectClose(claude.percent, 75, "Claude calibrated percent should use learned cap")
    }

    static func checkClaudePricing() {
        let opusCost = LocalLogUsageService.claudeCostEstimateUSD(
            model: "claude-opus-4-8",
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite: 0,
            cacheWrite5m: 0,
            cacheWrite1h: 0,
            cacheRead: 0
        )
        expectClose(opusCost, 30, "opus-4-8 should cost $5 in + $25 out per 1M tokens")

        let fableCost = LocalLogUsageService.claudeCostEstimateUSD(
            model: "claude-fable-5",
            input: 1_000_000,
            output: 1_000_000,
            cacheWrite: 0,
            cacheWrite5m: 0,
            cacheWrite1h: 0,
            cacheRead: 0
        )
        expectClose(fableCost, 60, "fable-5 should cost $10 in + $50 out per 1M tokens")

        let cacheCost = LocalLogUsageService.claudeCostEstimateUSD(
            model: "claude-opus-4-8",
            input: 0,
            output: 0,
            cacheWrite: 1_000_000,
            cacheWrite5m: 400_000,
            cacheWrite1h: 600_000,
            cacheRead: 0
        )
        expectClose(cacheCost, 0.4 * 6.25 + 0.6 * 10, "cache write must not be double counted")
    }

    static func writeClaudeFixture(home: URL, now: Date, scale: Double = 1) throws {
        let project = home.appendingPathComponent(".claude/projects/p", isDirectory: true)
        let logFile = project.appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let t1 = isoString(now.addingTimeInterval(-30 * 60))
        let t2 = isoString(now.addingTimeInterval(-20 * 60))
        let firstInput = Int(1_000 * scale)
        let firstOutput = Int(500 * scale)
        let secondInput = Int(2_000 * scale)
        let secondOutput = Int(1_000 * scale)
        let secondCacheRead = Int(10_000 * scale)
        let content = """
        {"type":"assistant","timestamp":"\(t1)","sessionId":"s1","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":\(firstInput),"output_tokens":\(firstOutput),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"\(t1)","sessionId":"s1","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":\(firstInput),"output_tokens":\(firstOutput),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"\(t1)","sessionId":"s1","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":\(firstInput),"output_tokens":\(firstOutput),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","timestamp":"\(t2)","sessionId":"s1","requestId":"req_2","message":{"id":"msg_2","model":"claude-opus-4-8","usage":{"input_tokens":\(secondInput),"output_tokens":\(secondOutput),"cache_creation_input_tokens":0,"cache_read_input_tokens":\(secondCacheRead)}}}
        """
        try content.write(to: logFile, atomically: true, encoding: .utf8)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func expectClose(_ actual: Double?, _ expected: Double, _ message: String) {
        guard let actual else {
            expect(false, message)
            return
        }

        expect(abs(actual - expected) < 0.0001, message)
    }

    @MainActor
    static func runLiveOfficialUsageCheck(now: Date) async {
        let service = CLIOAuthUsageService()

        print("-- live: Claude official usage --")
        switch await service.claudeSnapshot(now: now) {
        case .success(let snapshot):
            print("percent left: \(snapshot.percentDisplay)")
            print("reset: \(snapshot.resetAt.map { $0.description } ?? "--")")
            print("secondary: \(snapshot.secondaryValue ?? "--")")
            print("message: \(snapshot.message ?? "--")")
        case .failure(let failure):
            print("failed: \(failure.reason)")
        }

        print("-- live: Codex official usage --")
        switch await service.codexSnapshot(now: now) {
        case .success(let snapshot):
            print("percent left: \(snapshot.percentDisplay)")
            print("reset: \(snapshot.resetAt.map { $0.description } ?? "--")")
            print("secondary: \(snapshot.secondaryValue ?? "--")")
            print("message: \(snapshot.message ?? "--")")
        case .failure(let failure):
            print("failed: \(failure.reason)")
        }
    }

    @MainActor
    static func runClaudeEstimate(now: Date) async {
        let snapshots = await LocalLogUsageService().snapshots(now: now)
        let claude = snapshots.first { $0.provider == .claude }

        print("-- claude-estimate: local Claude --")
        print("percent left: \(claude?.percentDisplay ?? "--")")
        print("reset: \(claude?.resetAt.map { $0.description } ?? "--")")
        print("message: \(claude?.message ?? "--")")
    }

    @MainActor
    static func runLiveCodexCompositeCheck(now: Date) async {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-kun-live-codex-\(UUID().uuidString).json")
        let configStore = AppConfigStore(configURL: configURL)
        defer {
            try? FileManager.default.removeItem(at: configURL)
        }

        do {
            try configStore.save(AppConfig(
                localLogEnabled: true,
                claudeOfficialUsageEnabled: false,
                codexOfficialUsageEnabled: true
            ))
        } catch {
            expect(false, "live Codex config should be writable: \(error)")
        }

        let service = CompositeUsageService(
            configStore: configStore
        )
        let snapshots = await service.snapshots(now: now)
        let codex = snapshots.first { $0.provider == .codex }

        print("-- live: Composite Codex --")
        print("Codex: \(codex?.percentDisplay ?? "--") source=\(codex?.source ?? "--")")

        expect(codex != nil, "composite service should return Codex")
    }
}
