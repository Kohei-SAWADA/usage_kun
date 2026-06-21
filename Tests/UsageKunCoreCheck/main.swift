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
          "openAIAdminEnabled": true,
          "anthropicAdminEnabled": false,
          "cookieOAuthEnabled": false,
          "browserSource": "safari",
          "refreshIntervalMinutes": 10
        }
        """.data(using: .utf8)!
        let legacyConfig = try! JSONDecoder().decode(AppConfig.self, from: legacyConfigJSON)

        expect(legacyConfig.localLogEnabled == false, "legacy config values should decode")
        expect(legacyConfig.browserSource == .safari, "legacy browser source should decode")
        expect(legacyConfig.desktopWidgetEnabled == true, "desktop widget should default on for legacy config")
        expect(legacyConfig.launchAtLoginEnabled == true, "launch at login should default on for legacy config")
        expect(legacyConfig.claudeOfficialUsageEnabled == false, "official Claude sync should default off for legacy config")
        expect(legacyConfig.codexOfficialUsageEnabled == false, "official Codex sync should default off for legacy config")

        checkOfficialUsageParsers(now: now)

        if CommandLine.arguments.contains("--live") {
            await runLiveOfficialUsageCheck(now: Date())
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
}
