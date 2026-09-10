import Foundation
import Combine
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
        expect(legacyConfig.claudePlanOverride == "auto", "Claude plan override should default to auto for legacy config")
        expect(legacyConfig.claudeProviderEnabled == true, "Claude provider should default visible for legacy config")
        expect(legacyConfig.codexProviderEnabled == true, "Codex provider should default visible for legacy config")

        await checkProviderVisibility(now: now)
        checkClaudePlanResolution()
        checkOfficialUsageParsers(now: now)
        checkWeeklySnapshot(now: now)
        await checkDynamicCodexWindows(now: now)
        checkMenuBarEntries(now: now)
        checkAntigravityConfiguration()
        checkAntigravityQuotas(now: now)
        await checkAntigravityProviderVisibility(now: now)
        await checkProviderToggleDuringRefresh(now: now)
        checkAntigravityMenuIsolation(now: now)
        checkAntigravityNotifications(now: now)
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

        if CommandLine.arguments.contains("--live-antigravity") {
            await runLiveAntigravityCheck(now: Date())
        }

        print("UsageKunCoreCheck passed")
    }

    @MainActor
    static func checkDynamicCodexWindows(now: Date) async {
        let week = "{\"used_percent\":29,\"limit_window_seconds\":604800}"
        let short = "{\"used_percent\":10,\"limit_window_seconds\":18000}"
        for (body, label, weekly) in [
            ("\"primary_window\":\(week)", "1W", false),
            ("\"primary_window\":null,\"secondary_window\":\(week)", "1W", false),
            ("\"primary_window\":\(short),\"secondary_window\":\(week)", "5H", true),
            ("\"primary_window\":\(week),\"secondary_window\":\(short)", "5H", true),
            ("\"primary_window\":{\"used_percent\":29}", "LIMIT", false)
        ] {
            let data = Data("{\"rate_limit\":{\(body)}}".utf8)
            guard let reading = CLIOAuthUsageService.parseCodexWhamUsage(data: data, now: now) else {
                expect(false, "Codex window fixture must parse"); continue
            }
            let snapshot = CLIOAuthUsageService.makeSnapshot(provider: .codex, reading: reading,
                now: now, source: "fixture", detail: "fixture")
            expect(snapshot.primaryWindowLabel == label, "Codex label must match duration: \(label)")
            expect((snapshot.weekly != nil) == weekly, "weekly-only must not duplicate its bar")
            expectClose(snapshot.percent, label == "5H" ? 90 : 71, "selected window quota must match label")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for slot in ["primary", "secondary"] {
            let log = "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"\(slot)\":{\"used_percent\":29,\"window_minutes\":10080,\"resets_at\":1900000000}}}}"
            try! log.write(to: sessions.appendingPathComponent("fixture.jsonl"), atomically: true, encoding: .utf8)
            let result = await LocalLogUsageService(home: home).snapshots(now: now)
            let codex = result.first { $0.provider == .codex }
            expect(codex?.primaryWindowLabel == "1W", "local weekly-only \(slot) must show 1W")
            expectClose(codex?.percent, 71, "local weekly-only quota must be preserved")
        }
    }

    @MainActor
    static func checkProviderVisibility(now: Date) async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageKunCoreCheck-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let configStore = AppConfigStore(configURL: home.appendingPathComponent("config.json"))
        let service = await CompositeUsageService(
            configStore: configStore,
            localLogService: LocalLogUsageService(home: home)
        )

        try? configStore.save(AppConfig())
        let both = await service.snapshots(now: now)
        expect(both.map(\.provider) == [.codex, .claude], "both providers should show by default")

        try? configStore.save(AppConfig(codexProviderEnabled: false))
        let claudeOnly = await service.snapshots(now: now)
        expect(claudeOnly.map(\.provider) == [.claude], "unchecked Codex should be hidden")

        try? configStore.save(AppConfig(claudeProviderEnabled: false))
        let codexOnly = await service.snapshots(now: now)
        expect(codexOnly.map(\.provider) == [.codex], "unchecked Claude should be hidden")

        try? configStore.save(AppConfig(claudeProviderEnabled: false, codexProviderEnabled: false))
        let none = await service.snapshots(now: now)
        expect(none.isEmpty, "hiding both providers should produce no snapshots")

        try? configStore.save(AppConfig(localLogEnabled: false, codexProviderEnabled: false))
        let disabledClaude = await service.snapshots(now: now)
        expect(
            disabledClaude.map(\.provider) == [.claude],
            "disabled-sync placeholders should also respect provider visibility"
        )
    }

    static func checkClaudePlanResolution() {
        func resolve(
            _ organizationType: String?,
            tiers: [String] = [],
            override: String = "auto"
        ) -> ClaudePlanResolution {
            LocalLogUsageService.resolveClaudePlan(
                organizationType: organizationType,
                rateLimitTiers: tiers,
                override: override
            )
        }

        expect(resolve("claude_pro").key == "claude_pro", "claude_pro org type should resolve to Pro")
        expect(resolve("claude_pro").cap == 2_000_000, "Pro cap should be 2M weighted tokens")

        // Real accounts report organizationType "claude_max" for both Max
        // tiers; 5x vs 20x only shows up in the rate-limit tier strings.
        expect(
            resolve("claude_max", tiers: ["default_claude_max_20x"]).key == "claude_max_20x",
            "Max with 20x rate-limit tier should resolve to Max 20x"
        )
        expect(
            resolve("claude_max", tiers: ["default_claude_max_20x"]).cap == 40_000_000,
            "Max 20x cap should be 40M weighted tokens"
        )
        expect(
            resolve("claude_max", tiers: ["default_claude_max_5x"]).key == "claude_max_5x",
            "Max with 5x rate-limit tier should resolve to Max 5x"
        )
        expect(
            resolve("claude_max", tiers: [String]()).key == "claude_max",
            "Max without tier info should stay generic Max"
        )
        expect(
            resolve("claude_max", tiers: [String]()).cap == 10_000_000,
            "generic Max should default to the 5x cap"
        )
        expect(
            resolve("claude_max_20x").key == "claude_max_20x",
            "legacy claude_max_20x org type should still resolve"
        )
        expect(
            resolve(nil, tiers: ["default_claude_max_20x"]).key == "claude_max_20x",
            "rate-limit tier alone should resolve Max 20x"
        )

        expect(resolve("claude_team").cap == 2_000_000, "Team should start from the Pro cap")
        expect(resolve(nil).key == "estimated", "missing org type should resolve to estimated")
        expect(resolve("").key == "estimated", "empty org type should resolve to estimated")

        expect(
            resolve("claude_pro", override: "max_20x").cap == 40_000_000,
            "manual Max 20x override should win over detection"
        )
        expect(
            resolve("claude_max", tiers: ["default_claude_max_20x"], override: "pro").key == "claude_pro",
            "manual Pro override should win over detection"
        )
        expect(
            resolve("claude_pro", override: "bogus").key == "claude_pro",
            "unknown override value should fall back to auto detection"
        )
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

extension UsageKunCoreCheck {
    static func checkAntigravityConfiguration() {
        expect(!AppConfig().antigravityProviderEnabled, "Antigravity should be opt-in")
        let oldConfig = try! JSONDecoder().decode(AppConfig.self, from: Data("""
        {"claudeProviderEnabled":false,"codexProviderEnabled":true,"codexOfficialUsageEnabled":true,
         "refreshIntervalMinutes":10,"onboardingCompleted":true}
        """.utf8))
        expect(!oldConfig.antigravityProviderEnabled, "old config must not silently enable Antigravity")
        expect(!oldConfig.claudeProviderEnabled && oldConfig.codexProviderEnabled,
               "adding Antigravity must preserve the existing Codex-only selection")
        expect(oldConfig.codexOfficialUsageEnabled && oldConfig.refreshIntervalMinutes == 10,
               "old sync and refresh preferences must survive migration")
        expect(oldConfig.onboardingCompleted, "adding a provider must preserve completed onboarding")
        for enabled in [false, true] {
            var config = oldConfig
            config.antigravityProviderEnabled = enabled
            let decoded = try! JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            expect(decoded == config, "Antigravity selection and all existing config should round-trip")
        }
    }

    static func antigravitySummary(_ buckets: String, now: Date) -> UsageSnapshot? {
        AntigravityUsageService.parseSummary(data: Data("""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[\(buckets)]}]}}
        """.utf8), now: now)
    }

    static func checkAntigravityQuotas(now: Date) {
        let snapshot = antigravitySummary("""
        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-09-09T13:00:00Z"},
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.375,"resetTime":"2026-09-09T12:00:00.125Z"}
        """, now: now)!
        expect(snapshot.provider == .antigravity && snapshot.updatedAt == now,
               "Antigravity summary should identify its provider and supplied refresh time")
        expectClose(snapshot.percent, 37.5, "remaining fraction should convert to primary percent left")
        expectClose(snapshot.weekly?.percentLeft, 100, "explicit full weekly quota should remain 100%")
        expect(snapshot.status == .ok, "both available windows above warning should be ready")
        let expectedReset = ISO8601DateFormatter().date(from: "2026-09-09T12:00:00Z")!.addingTimeInterval(0.125)
        expect(snapshot.resetAt != nil, "fractional ISO reset timestamps should parse")
        expect(abs(snapshot.resetAt!.timeIntervalSince(expectedReset)) < 0.001,
               "fractional ISO reset timestamps must preserve their time")
        expect(snapshot.weekly?.resetAt == ISO8601DateFormatter().date(from: "2026-09-09T13:00:00Z"),
               "whole-second ISO reset timestamps should parse")

        let observedShape = antigravitySummary("""
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0},
        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.64844364}
        """, now: now)!
        expectClose(observedShape.percent, 0, "an explicit zero is a known exhausted quota")
        expectClose(observedShape.weekly?.percentLeft, 64.844364, "fractional weekly quota must retain precision")
        expect(observedShape.status == .critical, "an explicit exhausted quota should be critical")
        let full = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":1,"disabled":false},
        {"bucketId":"gemini-weekly","remainingFraction":1}
        """, now: now)!
        expectClose(full.percent, 100, "a full primary quota must remain 100%")
        expect(full.status == .ok, "full windows should be ready when optional window labels are absent")
        let disabled = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.5,"disabled":true},
        {"bucketId":"gemini-weekly","remainingFraction":1}
        """, now: now)!
        expect(disabled.percent == nil && disabled.status == .unknown,
               "disabled bucket must stay unknown like Antigravity's quota component")

        let invalidFields = [
            "", // Missing is distinct from an explicit zero.
            ",\"remainingFraction\":null", ",\"remainingFraction\":-0.01",
            ",\"remainingFraction\":1.01", ",\"remainingFraction\":true",
            ",\"remainingFraction\":false", ",\"remainingFraction\":\"0.5\"",
            ",\"remainingFraction\":[]", ",\"remainingFraction\":{}",
            ",\"remainingAmount\":50", ",\"remainingFraction\":0.5,\"remainingAmount\":50",
            ",\"remainingFraction\":0.5,\"disabled\":\"false\"",
            ",\"remainingFraction\":0.5,\"disabled\":0",
            ",\"remainingFraction\":0.5,\"window\":\"weekly\""
        ]
        for fields in invalidFields {
            let unknown = antigravitySummary("""
            {"bucketId":"gemini-5h"\(fields)},
            {"bucketId":"gemini-weekly","remainingFraction":1}
            """, now: now)!
            expect(unknown.percent == nil && unknown.used == nil && unknown.status == .unknown,
                   "missing or invalid primary quota must stay unknown: \(fields)")
            expectClose(unknown.weekly?.percentLeft, 100, "invalid primary quota must not discard known weekly quota")
        }
        let noPrimary = antigravitySummary("{\"bucketId\":\"gemini-weekly\",\"remainingFraction\":0.5}", now: now)!
        expect(noPrimary.percent == nil && noPrimary.status == .unknown,
               "a missing primary window should leave the overall state unknown")
        expectClose(noPrimary.weekly?.percentLeft, 50, "known weekly quota should survive missing primary quota")
        let noWeekly = antigravitySummary("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":0.5}", now: now)!
        expectClose(noWeekly.percent, 50, "known primary quota should survive missing weekly quota")
        expect(noWeekly.weekly?.percentLeft == nil && noWeekly.status == .unknown,
               "missing weekly quota must not imply full weekly availability")
        let partialExhausted = antigravitySummary("{\"bucketId\":\"gemini-weekly\",\"remainingFraction\":0}", now: now)!
        expect(partialExhausted.percent == nil && partialExhausted.status == .critical,
               "a known exhausted weekly window should remain critical when primary is unknown")
        let duplicate = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.2},
        {"bucketId":"gemini-5h","remainingFraction":0.8},
        {"bucketId":"gemini-weekly","remainingFraction":1}
        """, now: now)!
        expect(duplicate.percent == nil && duplicate.status == .unknown,
               "conflicting duplicate buckets must not arbitrarily select a quota")
        let invalidReset = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.2,"resetTime":"not-a-date"},
        {"bucketId":"gemini-weekly","remainingFraction":1}
        """, now: now)!
        expect(invalidReset.resetAt == nil, "invalid reset dates must not be fabricated")
        expectClose(invalidReset.percent, 20, "an invalid reset must not discard a valid quota")
        for malformed in ["", "{", "[]", "null", "{}", "{\"response\":{\"groups\":{}}}",
                          "{\"userStatus\":{\"cascadeModelConfigData\":{\"clientModelConfigs\":[]}}}"] {
            expect(AntigravityUsageService.parseSummary(data: Data(malformed.utf8), now: now) == nil,
                   "malformed or obsolete model data should fail safely")
        }
        let nonGeminiJSON = """
        {"response":{"groups":[{"displayName":"Claude Models","buckets":[
          {"bucketId":"gemini-5h","remainingFraction":1},{"bucketId":"gemini-weekly","remainingFraction":1}
        ]}]}}
        """
        expect(AntigravityUsageService.parseSummary(data: Data(nonGeminiJSON.utf8), now: now) == nil,
               "non-Gemini groups must not substitute another provider's quota")
        let empty = antigravitySummary("", now: now)!
        expect(empty.percent == nil && empty.weekly?.percentLeft == nil && empty.status == .unknown,
               "empty bucket lists must produce unknown usage")
    }

    @MainActor
    static func checkAntigravityProviderVisibility(now: Date) async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("UsageKunCoreCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let configStore = AppConfigStore(configURL: home.appendingPathComponent("config.json"))
        let fixture = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.4},{"bucketId":"gemini-weekly","remainingFraction":0.8}
        """, now: now)!
        var fetchCount = 0
        let service = CompositeUsageService(configStore: configStore,
                                            localLogService: LocalLogUsageService(home: home),
                                            antigravitySnapshot: { date in
            expect(date == now, "composite should forward the refresh time to Antigravity")
            fetchCount += 1
            return fixture
        })
        var config = AppConfig(localLogEnabled: false, claudeProviderEnabled: false, codexProviderEnabled: false)
        try! configStore.save(config)
        let disabled = await service.snapshots(now: now)
        expect(disabled.isEmpty && fetchCount == 0, "disabled Antigravity must neither fetch nor display")
        config.antigravityProviderEnabled = true
        try! configStore.save(config)
        let enabled = await service.snapshots(now: now)
        expect(enabled == [fixture] && fetchCount == 1,
               "Antigravity should work with all existing providers and sync sources disabled")
        config.codexProviderEnabled = true
        try! configStore.save(config)
        let codexAndGemini = await service.snapshots(now: now)
        expect(codexAndGemini.map(\.provider) == [.codex, .antigravity] && fetchCount == 2,
               "Antigravity should coexist with a disabled-sync Codex placeholder")
        config.antigravityProviderEnabled = false
        try! configStore.save(config)
        let codexOnly = await service.snapshots(now: now)
        expect(codexOnly.map(\.provider) == [.codex] && fetchCount == 2,
               "disabling Antigravity must stop fetching and preserve Codex selection")
    }

    @MainActor
    static func checkProviderToggleDuringRefresh(now: Date) async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("UsageKunCoreCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let configStore = AppConfigStore(configURL: home.appendingPathComponent("config.json"))
        var config = AppConfig(localLogEnabled: false, claudeProviderEnabled: false,
                               codexProviderEnabled: true, antigravityProviderEnabled: true)
        try! configStore.save(config)
        let service = ControlledUsageService()
        let store = UsageStore(service: service, configStore: configStore)
        var publishedProviders: [[UsageProvider]] = []
        let observer = store.$snapshots.sink { publishedProviders.append($0.map(\.provider)) }
        defer { observer.cancel() }

        await withCheckedContinuation { firstRequested in
            service.onRequest = { count in
                if count == 1 { firstRequested.resume() }
            }
            store.refresh()
        }
        config.antigravityProviderEnabled = false
        store.updateConfig(config)
        expect(service.callCount == 1, "a toggle should queue a refresh while the current request is pending")
        let stale = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.5},{"bucketId":"gemini-weekly","remainingFraction":0.8}
        """, now: now)!
        await withCheckedContinuation { secondRequested in
            service.onRequest = { count in
                if count == 2 { secondRequested.resume() }
            }
            service.pending.removeFirst().resume(returning: [stale])
        }
        expect(service.callCount == 2, "a provider toggle must trigger a second refresh without waiting for the timer")
        expect(!publishedProviders.contains(where: { $0.contains(.antigravity) }),
               "the result from before the toggle must never publish the disabled provider")
        let codex = UsageSnapshot(provider: .codex, status: .ok, used: 70, limit: nil,
                                  percent: 70, resetAt: nil, updatedAt: now, message: nil)
        var finishedObserver: AnyCancellable?
        await withCheckedContinuation { finished in
            finishedObserver = store.$isRefreshing.sink { refreshing in
                if !refreshing { finished.resume() }
            }
            service.pending.removeFirst().resume(returning: [codex])
        }
        finishedObserver?.cancel()
        expect(store.snapshots == [codex] && !store.isRefreshing,
               "the queued refresh should publish only the newly selected providers")
        expect(service.callCount == 2, "one in-flight toggle should not create extra refreshes")
    }

    static func checkAntigravityMenuIsolation(now: Date) {
        let codex = UsageSnapshot(provider: .codex, status: .ok, used: 65, limit: nil,
                                  percent: 65, resetAt: nil, updatedAt: now, message: nil,
                                  weekly: UsageWindow(percentLeft: 45, resetAt: nil))
        let claude = UsageSnapshot(provider: .claude, status: .warning, used: 30, limit: nil,
                                   percent: 30, resetAt: nil, updatedAt: now, message: nil)
        let gemini = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.7},{"bucketId":"gemini-weekly","remainingFraction":0.1}
        """, now: now)!
        let before = UsageStore.menuBarEntries(snapshots: [codex, claude])
        let after = UsageStore.menuBarEntries(snapshots: [gemini, codex, claude])
        expect(Array(after.prefix(2)) == before, "adding Gemini must not change Claude or Codex menu entries")
        expect(after.map(\.mark) == ["C", "X", "G"], "Gemini should have its own stable G menu entry")
        expectClose(after.last?.percentLeft, 10, "Gemini menu should use its constrained weekly quota")
        expect(after.last?.status == .critical, "Gemini menu entry should retain its quota status")
        expect(UsageStore.menuBarEntries(snapshots: [codex]).map(\.mark) == ["X"],
               "Codex-only snapshots must keep a Codex-only menu")
        for buckets in ["", "{\"bucketId\":\"gemini-5h\",\"remainingFraction\":0.5}",
                        "{\"bucketId\":\"gemini-weekly\",\"remainingFraction\":0.5}"] {
            let entries = UsageStore.menuBarEntries(snapshots: [antigravitySummary(buckets, now: now)!, codex])
            expect(entries.last?.percentLeft == nil && entries.last?.status == .unknown,
                   "an incomplete Gemini quota must remain unknown in the menu")
            expectClose(entries.first?.percentLeft, 45, "unknown Gemini quota must not affect Codex's weekly value")
        }
    }

    static func checkAntigravityNotifications(now: Date) {
        let previous = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.5},{"bucketId":"gemini-weekly","remainingFraction":0.8}
        """, now: now)!
        let current = antigravitySummary("""
        {"bucketId":"gemini-5h","remainingFraction":0.5},{"bucketId":"gemini-weekly","remainingFraction":0.2}
        """, now: now.addingTimeInterval(60))!
        let plan = UsageNotificationPlanner.plan(previous: [previous], current: [current], alreadyNotified: [])
        expect(plan.events.count == 1, "a weekly Gemini threshold crossing should notify once")
        expect(plan.events.first?.dedupKey == "antigravity.weekly.threshold25",
               "Gemini weekly notifications must be isolated from other providers and primary quota")
        expect(plan.events.first?.title.contains("7 day") == true,
               "a weekly Gemini warning should name its actual quota window")
    }

    @MainActor
    static func runLiveAntigravityCheck(now: Date) async {
        let snapshot = await AntigravityUsageService().snapshot(now: now)
        print("-- live: Antigravity Gemini quota --")
        print("status: \(snapshot.status.rawValue)")
        print("5 hour left: \(snapshot.percentDisplay)")
        print("5 hour reset: \(snapshot.resetAt.map { $0.description } ?? "--")")
        print("weekly left: \(snapshot.weekly?.percentLeft.map { String(format: "%.2f%%", $0) } ?? "--")")
        print("weekly reset: \(snapshot.weekly?.resetAt.map { $0.description } ?? "--")")
        print("source: \(snapshot.source)")
        expect(snapshot.provider == .antigravity, "live snapshot should identify Antigravity")
        expect(snapshot.percent != nil && snapshot.weekly?.percentLeft != nil,
               "live Antigravity check requires actual primary and weekly quota values")
    }
}

@MainActor
private final class ControlledUsageService: UsageService {
    var callCount = 0
    var pending: [CheckedContinuation<[UsageSnapshot], Never>] = []
    var onRequest: ((Int) -> Void)?

    func snapshots(now: Date) async -> [UsageSnapshot] {
        callCount += 1
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            onRequest?(callCount)
        }
    }
}
