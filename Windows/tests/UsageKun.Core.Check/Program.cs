using System.Globalization;
using System.Net;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using UsageKun.Core;

// Lightweight core-logic check for the Windows build, mirroring the macOS
// UsageKunCoreCheck executable: plain asserts, exit code 1 on first failure.
// Run with: dotnet run --project Windows/tests/UsageKun.Core.Check

CheckLoginStartup();
CheckStatusAndDisplay();
await CheckMockService();
CheckConfigSchema();
await CheckProviderVisibility();
CheckClaudePlanResolution();
await CheckCodexSessionRateLimits();
await CheckCodexLiveRateLimits();
await CheckCodexGeneralLimitsAndResetTimes();
await CheckClaudeDedup();
await CheckClaudeCalibration();
CheckClaudePricing();
CheckTrayEntries();
CheckFormatting();
CheckWindowLabelsAndOfficialParsers();
await CheckCodexWindowVariants();
CheckAntigravityQuota();
await CheckOfficialTransport();
await CheckOptInSources();
await CheckRefreshConfigurationRace();
await CheckRefreshFailureRecovery();
await CheckQuotaRefreshSafety();
await CheckFailedOfficialDoesNotBorrowLocalQuota();
await LocalQuotaChecks.RunAsync();
await OAuthQuotaChecks.RunAsync();

if (args.Contains("--claude-estimate"))
{
    await RunClaudeEstimate();
}

Console.WriteLine("UsageKun.Core.Check passed");
return;

static void Expect(bool condition, string message)
{
    if (!condition)
    {
        Console.Error.WriteLine($"Check failed: {message}");
        Environment.Exit(1);
    }
}

static void ExpectClose(double? value, double expected, string message, double tolerance = 0.01)
{
    Expect(value is { } actual && Math.Abs(actual - expected) <= tolerance,
        $"{message} (got {value?.ToString(CultureInfo.InvariantCulture) ?? "null"}, want {expected.ToString(CultureInfo.InvariantCulture)})");
}

static string TemporaryHome() =>
    Path.Combine(Path.GetTempPath(), $"UsageKunCoreCheck-{Guid.NewGuid()}");

static void CheckStatusAndDisplay()
{
    var mostSevere = UsageStatusInfo.MostSevere(
        [UsageStatus.Ok, UsageStatus.Critical, UsageStatus.Warning, UsageStatus.Error]);
    Expect(mostSevere == UsageStatus.Error, "error should be most severe");

    Expect(UsageStatusRules.Status(50, null) == UsageStatus.Ok, "50% left should be ok");
    Expect(UsageStatusRules.Status(35, null) == UsageStatus.Warning, "35% left should be warning");
    Expect(UsageStatusRules.Status(15, null) == UsageStatus.Critical, "15% left should be critical");
    Expect(UsageStatusRules.Status(60, 10) == UsageStatus.Critical, "constrained weekly should drive status");

    var unknown = new UsageSnapshot
    {
        Provider = UsageProvider.Claude,
        Status = UsageStatus.Unknown,
        UpdatedAt = DateTimeOffset.Now
    };

    Expect(unknown.UsedDisplay == "--", "unknown usage display should fallback");
    Expect(unknown.PercentDisplay == "--%", "unknown percent display should fallback");
}

static async Task CheckMockService()
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    var snapshots = await new MockUsageService().SnapshotsAsync(now);
    var providers = snapshots.Select(snapshot => snapshot.Provider).ToHashSet();

    Expect(providers.SetEquals([UsageProvider.Claude, UsageProvider.Codex]),
        "mock service should return Claude and Codex");
    Expect(snapshots.All(snapshot => snapshot.UpdatedAt == now),
        "mock snapshots should use provided update date");
}

static void CheckConfigSchema()
{
    var home = TemporaryHome();
    try
    {
        // Keys another platform/version wrote must be ignored, and missing
        // keys must fall back to the same defaults as the macOS decoder.
        var store = new AppConfigStore(Path.Combine(home, "config.json"));
        Directory.CreateDirectory(home);
        File.WriteAllText(store.ConfigPath, """
        {
          "localLogEnabled": false,
          "retiredRemoteFlag": true,
          "retiredSourceName": "safari",
          "refreshIntervalMinutes": 10
        }
        """);

        var legacy = store.Load();
        Expect(!legacy.LocalLogEnabled, "legacy config values should decode");
        Expect(legacy.RefreshIntervalMinutes == 10, "explicit interval should decode");
        Expect(legacy.DesktopWidgetEnabled, "desktop widget should default on for legacy config");
        Expect(legacy.LaunchAtLoginEnabled, "launch at login should default on for legacy config");
        Expect(!legacy.OnboardingCompleted, "onboarding should default incomplete for legacy config");
        Expect(!legacy.ClaudeOfficialUsageEnabled, "official Claude sync should default off");
        Expect(!legacy.CodexOfficialUsageEnabled, "official Codex sync should default off");
        Expect(legacy.ClaudePlanOverride == "auto", "Claude plan override should default to auto");
        Expect(legacy.ClaudeProviderEnabled, "Claude provider should default visible");
        Expect(legacy.CodexProviderEnabled, "Codex provider should default visible");
        Expect(!legacy.AntigravityProviderEnabled && !legacy.AntigravityUsageEnabled, "Gemini must default hidden and opt-out");
        Expect(legacy.WidgetPositionX == null, "widget position should default unset");

        var config = new AppConfig
        {
            RefreshIntervalMinutes = 15,
            ClaudePlanOverride = "max_20x",
            WidgetPositionX = 24,
            WidgetPositionY = 32
        };
        store.Save(config);

        var raw = File.ReadAllText(store.ConfigPath);
        Expect(raw.Contains("\"localLogEnabled\""),
            "saved config should use the macOS camelCase key spelling");

        var reloaded = store.Load();
        Expect(reloaded.RefreshIntervalMinutes == 15, "interval should round-trip");
        Expect(reloaded.ClaudePlanOverride == "max_20x", "plan override should round-trip");
        ExpectClose(reloaded.WidgetPositionX, 24, "widget X should round-trip");
        ExpectClose(reloaded.WidgetPositionY, 32, "widget Y should round-trip");
    }
    finally
    {
        TryDelete(home);
    }
}

static async Task CheckProviderVisibility()
{
    var now = DateTimeOffset.Now;
    var home = TemporaryHome();
    try
    {
        Directory.CreateDirectory(home);
        var configStore = new AppConfigStore(Path.Combine(home, "config.json"));
        var service = new CompositeUsageService(
            configStore,
            new LocalLogUsageService(home, new ClaudeCalibrationStore(Path.Combine(home, "claude_calibration.json"))),
            new CLIOAuthUsageService(home));

        configStore.Save(new AppConfig());
        var both = await service.SnapshotsAsync(now);
        Expect(both.Select(snapshot => snapshot.Provider).SequenceEqual([UsageProvider.Codex, UsageProvider.Claude]),
            "both providers should show by default");

        configStore.Save(new AppConfig { CodexProviderEnabled = false });
        var claudeOnly = await service.SnapshotsAsync(now);
        Expect(claudeOnly.Select(snapshot => snapshot.Provider).SequenceEqual([UsageProvider.Claude]),
            "unchecked Codex should be hidden");

        configStore.Save(new AppConfig { ClaudeProviderEnabled = false });
        var codexOnly = await service.SnapshotsAsync(now);
        Expect(codexOnly.Select(snapshot => snapshot.Provider).SequenceEqual([UsageProvider.Codex]),
            "unchecked Claude should be hidden");

        configStore.Save(new AppConfig { ClaudeProviderEnabled = false, CodexProviderEnabled = false });
        var none = await service.SnapshotsAsync(now);
        Expect(none.Count == 0, "hiding both providers should produce no snapshots");

        configStore.Save(new AppConfig { LocalLogEnabled = false, CodexProviderEnabled = false });
        var disabledClaude = await service.SnapshotsAsync(now);
        Expect(disabledClaude.Select(snapshot => snapshot.Provider).SequenceEqual([UsageProvider.Claude]),
            "disabled-sync placeholders should also respect provider visibility");
        Expect(disabledClaude[0].Source == "disabled", "placeholder should mark the disabled source");

        // Missing Windows CLI sign-in should explain the fallback without sending a request.
        configStore.Save(new AppConfig { ClaudeOfficialUsageEnabled = true });
        var officialRequested = await service.SnapshotsAsync(now);
        var claude = officialRequested.First(snapshot => snapshot.Provider == UsageProvider.Claude);
        Expect(claude.Message?.Contains("Official sync unavailable") == true,
            "missing official credentials should surface the reason in the fallback message");
    }
    finally
    {
        TryDelete(home);
    }
}

static void CheckClaudePlanResolution()
{
    var auto = LocalLogUsageService.ResolveClaudePlan(null, [], "auto");
    Expect(auto.Key == "estimated" && Math.Abs(auto.Cap - 2_000_000) < 1, "unknown account should assume the Pro cap");

    var pro = LocalLogUsageService.ResolveClaudePlan("claude_pro", [], "auto");
    Expect(pro.Key == "claude_pro" && Math.Abs(pro.Cap - 2_000_000) < 1, "pro org should resolve the Pro cap");

    var maxDefault = LocalLogUsageService.ResolveClaudePlan("claude_max", [], "auto");
    Expect(maxDefault.Key == "claude_max" && Math.Abs(maxDefault.Cap - 10_000_000) < 1,
        "max without tier should assume 5x cap");

    var max20xByTier = LocalLogUsageService.ResolveClaudePlan("claude_max", ["default_claude_max_20x"], "auto");
    Expect(max20xByTier.Key == "claude_max_20x" && Math.Abs(max20xByTier.Cap - 40_000_000) < 1,
        "20x tier string should resolve the 20x cap");

    var max5xByTier = LocalLogUsageService.ResolveClaudePlan("claude_max", ["default_claude_max_5x"], "auto");
    Expect(max5xByTier.Key == "claude_max_5x" && Math.Abs(max5xByTier.Cap - 10_000_000) < 1,
        "5x tier string should resolve the 5x cap");

    var team = LocalLogUsageService.ResolveClaudePlan("team", [], "auto");
    Expect(team.Label.Contains("Team") && Math.Abs(team.Cap - 2_000_000) < 1,
        "team org should start from the Pro cap");

    var manual = LocalLogUsageService.ResolveClaudePlan("claude_pro", [], "max_20x");
    Expect(manual.Key == "claude_max_20x" && manual.Label.Contains("manual"),
        "manual override should beat detection");
}

static async Task CheckCodexSessionRateLimits()
{
    var now = DateTimeOffset.Now;
    var home = TemporaryHome();
    try
    {
        var sessions = Path.Combine(home, ".codex", "sessions", "2026", "07", "08");
        Directory.CreateDirectory(sessions);

        var olderTimestamp = Iso(now.AddMinutes(-90));
        var newerTimestamp = Iso(now.AddMinutes(-2));
        var primaryReset = now.AddHours(1).ToUnixTimeSeconds();
        var secondaryReset = now.AddDays(4).ToUnixTimeSeconds();
        File.WriteAllLines(Path.Combine(sessions, "rollout-check.jsonl"), new[]
        {
            // Weekly-window row must never be treated as the 5h primary.
            CodexTokenCountLine(olderTimestamp, """{"used_percent":95.0,"window_minutes":10080,"resets_at":@SECONDARY_RESET@}""", null),
            CodexTokenCountLine(olderTimestamp, """{"used_percent":80.0,"window_minutes":300,"resets_at":@PRIMARY_RESET@}""", null),
            CodexTokenCountLine(newerTimestamp,
                """{"used_percent":40.0,"window_minutes":300,"resets_at":@PRIMARY_RESET@}""",
                """{"used_percent":90.0,"window_minutes":10080,"resets_at":@SECONDARY_RESET@}""")
        }.Select(line => line
            .Replace("@PRIMARY_RESET@", primaryReset.ToString(CultureInfo.InvariantCulture))
            .Replace("@SECONDARY_RESET@", secondaryReset.ToString(CultureInfo.InvariantCulture)))
        .ToArray());

        var service = new LocalLogUsageService(home, new ClaudeCalibrationStore(Path.Combine(home, "claude_calibration.json")));
        var snapshots = await service.SnapshotsAsync(now);
        var codex = snapshots.First(snapshot => snapshot.Provider == UsageProvider.Codex);

        ExpectClose(codex.Percent, 60, "Codex 5h left should come from the newest token_count row");
        ExpectClose(codex.Weekly?.PercentLeft, 10, "Codex weekly left should come from the secondary window");
        Expect(codex.Status == UsageStatus.Critical, "Codex weekly 10% left should drive status");
        Expect(codex.ResetAt != null, "Codex reset should be present");
        Expect(codex.Source == "Codex session rate limits", "Codex source should name the session logs");

        // An already-expired 5h window shows a fresh window, not a stale used %.
        var expiredHome = TemporaryHome();
        try
        {
            var expiredSessions = Path.Combine(expiredHome, ".codex", "sessions");
            Directory.CreateDirectory(expiredSessions);
            var expiredReset = now.AddMinutes(-5).ToUnixTimeSeconds();
            File.WriteAllLines(Path.Combine(expiredSessions, "rollout-expired.jsonl"), new[]
            {
                CodexTokenCountLine(olderTimestamp,
                    """{"used_percent":80.0,"window_minutes":300,"resets_at":@RESET@}""", null)
                    .Replace("@RESET@", expiredReset.ToString(CultureInfo.InvariantCulture))
            });

            var expiredService = new LocalLogUsageService(expiredHome, new ClaudeCalibrationStore(Path.Combine(expiredHome, "claude_calibration.json")));
            var expired = (await expiredService.SnapshotsAsync(now)).First(snapshot => snapshot.Provider == UsageProvider.Codex);
            Expect(expired.Percent == null && expired.Status == UsageStatus.Unknown, "expired 5h window must stay unknown until newly reported");
            Expect(expired.SecondaryValue != "fresh", "expired record must not imply a fresh quota window");
        }
        finally
        {
            TryDelete(expiredHome);
        }

        // No session logs at all -> setup guidance, not an error.
        var emptyHome = TemporaryHome();
        try
        {
            Directory.CreateDirectory(emptyHome);
            var emptyService = new LocalLogUsageService(emptyHome, new ClaudeCalibrationStore(Path.Combine(emptyHome, "claude_calibration.json")));
            var empty = (await emptyService.SnapshotsAsync(now)).First(snapshot => snapshot.Provider == UsageProvider.Codex);
            Expect(empty.Status == UsageStatus.Unknown, "missing Codex logs should read as unknown");
            Expect(empty.Percent == null, "missing Codex logs should not fake a percent");
        }
        finally
        {
            TryDelete(emptyHome);
        }
    }
    finally
    {
        TryDelete(home);
    }
}

static async Task CheckCodexLiveRateLimits()
{
    var now = DateTimeOffset.Parse("2026-09-17T18:00:00+09:00", CultureInfo.InvariantCulture);
    var home = TemporaryHome();
    try
    {
        var sessions = Path.Combine(home, ".codex", "sessions");
        Directory.CreateDirectory(sessions);
        var sessionPath = Path.Combine(sessions, "rollout.jsonl");
        File.WriteAllText(sessionPath, CodexTokenCountLine(Iso(now.AddMinutes(-10)),
            """{"used_percent":20,"window_minutes":300}""", null));
        var database = Path.Combine(home, ".codex", "logs_2.sqlite");
        using (var connection = OpenCodexLogFixture(database))
        {
            AddCodexLiveFixture(connection, now.AddMinutes(-1), 100, 75, 65);
            // A model-specific bucket and a tool response must not replace General limits.
            for (var index = 0; index < 205; index++)
                AddCodexLiveFixture(connection, now, 10 + index, 99, 99, "codex_other");
            AddCodexLiveFixture(connection, now, 1, 98, 98, suffix: " response.output_item function_call ToolCall");
            AddCodexLiveFixture(connection, now, 2, 97, 97, target: "unrelated_target");
            using var nullTimestamp = connection.CreateCommand();
            nullTimestamp.CommandText = "INSERT INTO logs SELECT $ts, NULL, target, feedback_log_body FROM logs LIMIT 1;";
            nullTimestamp.Parameters.AddWithValue("$ts", now.ToUnixTimeSeconds());
            nullTimestamp.ExecuteNonQuery();
            using var malformed = connection.CreateCommand();
            malformed.CommandText = "INSERT INTO logs VALUES ($ts, 3, 'codex_api::endpoint::responses_websocket', 'responses_websocket.stream_request websocket event: {\"type\":\"codex.rate_limits\",broken');";
            malformed.Parameters.AddWithValue("$ts", now.ToUnixTimeSeconds());
            malformed.ExecuteNonQuery();
        }
        var databaseBefore = File.ReadAllBytes(database);
        var service = new LocalLogUsageService(home);
        var snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 25, "newer live SQLite quota must replace stale session quota (80% -> 25% left)");
        ExpectClose(snapshot.Weekly?.PercentLeft, 35, "live SQLite weekly window must remain paired with its primary window");
        Expect(snapshot.Source == "Codex live rate limits", "live source must be identified");
        Expect(snapshot.UpdatedAt == now.AddMinutes(-1).AddTicks(1), "SQLite nanoseconds must be converted to UTC ticks");
        Expect(snapshot.ResetAt == now.AddMinutes(119).AddTicks(1), "live relative reset must use recorded time, not refresh time");
        Expect(databaseBefore.SequenceEqual(File.ReadAllBytes(database)), "reading quota must not modify the Codex database");

        // Both timestamp columns matter when two readings arrive in the same second.
        using (var connection = OpenCodexLogFixture(database))
            AddCodexLiveFixture(connection, now.AddMinutes(-1), 900_000_000, 80, 70);
        snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 20, "newest nanosecond timestamp must win within the same second");

        File.WriteAllText(sessionPath, CodexTokenCountLine(Iso(now),
            """{"used_percent":30,"window_minutes":300}""", null));
        snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 70, "newer session quota must replace older live quota");
        Expect(snapshot.Source == "Codex session rate limits", "selection must compare timestamps across both sources");

        Directory.Delete(sessions, true);
        snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 20, "SQLite-only installations must not require a sessions directory");

        // A running Codex process can keep recent committed records only in WAL.
        using (var writer = OpenCodexLogFixture(database))
        {
            using var enableWal = writer.CreateCommand();
            enableWal.CommandText = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;";
            enableWal.ExecuteNonQuery();
            AddCodexLiveFixture(writer, now, 0, 50, 60, "codex");
            Expect(File.Exists(database + "-wal"), "fixture must have an active WAL before the read");
            snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
            ExpectClose(snapshot.Percent, 50, "read-only connection must see committed live quota in an active WAL");
            using var uncommitted = writer.BeginTransaction();
            using var update = writer.CreateCommand();
            update.Transaction = uncommitted;
            update.CommandText = "UPDATE logs SET feedback_log_body = 'pending write';";
            update.ExecuteNonQuery();
            snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
            ExpectClose(snapshot.Percent, 50, "read-only connection must retain committed quota during a concurrent write");
            uncommitted.Rollback();
        }

        Directory.CreateDirectory(sessions);
        File.WriteAllText(sessionPath, CodexTokenCountLine(Iso(now),
            """{"used_percent":30,"window_minutes":300}""", null));
        File.WriteAllText(database, "not a SQLite database");
        snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 70, "unreadable live database must retain session fallback");
        File.Delete(database);
        using (var incompatible = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }.ToString()))
            incompatible.Open();
        snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 70, "unknown SQLite schema must retain session fallback");
        File.Delete(database);
        await service.SnapshotsAsync(now, true, false);
        Expect(!File.Exists(database), "missing database must never be created by a read");
    }
    finally { TryDelete(home); }
}

static SqliteConnection OpenCodexLogFixture(string database)
{
    var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }.ToString());
    connection.Open();
    using var command = connection.CreateCommand();
    command.CommandText = "CREATE TABLE IF NOT EXISTS logs (ts INTEGER, ts_nanos INTEGER, target TEXT, feedback_log_body TEXT);";
    command.ExecuteNonQuery();
    return connection;
}

static void AddCodexLiveFixture(SqliteConnection connection, DateTimeOffset timestamp, int nanos, double used, double weeklyUsed,
    string? limitId = null, string suffix = "", string target = "codex_api::endpoint::responses_websocket")
{
    var payload = JsonSerializer.Serialize(new
    {
        type = "codex.rate_limits", metered_limit_name = limitId,
        rate_limits = new
        {
            primary = new { used_percent = used, window_minutes = 300, reset_after_seconds = 7200 },
            secondary = new { used_percent = weeklyUsed, window_minutes = 10080, reset_after_seconds = 172800 }
        }
    });
    using var command = connection.CreateCommand();
    command.CommandText = "INSERT INTO logs VALUES ($ts, $nanos, $target, $body);";
    command.Parameters.AddWithValue("$ts", timestamp.ToUnixTimeSeconds());
    command.Parameters.AddWithValue("$nanos", nanos);
    command.Parameters.AddWithValue("$target", target);
    command.Parameters.AddWithValue("$body", "responses_websocket.stream_request websocket event: " + payload + suffix);
    command.ExecuteNonQuery();
}

static async Task CheckCodexGeneralLimitsAndResetTimes()
{
    var now = DateTimeOffset.Parse("2026-09-17T18:00:00+09:00", CultureInfo.InvariantCulture);
    var home = TemporaryHome();
    try
    {
        var sessions = Path.Combine(home, ".codex", "sessions");
        Directory.CreateDirectory(sessions);
        var path = Path.Combine(sessions, "rollout.jsonl");
        File.WriteAllLines(path, new[]
        {
            CodexTokenCountLine(Iso(now.AddMinutes(-10)), """{"used_percent":20,"window_minutes":300,"reset_after_seconds":3600}""", null)
                .Replace("\"rate_limits\":{", "\"rate_limits\":{\"limit_id\":\"codex\","),
            CodexTokenCountLine(Iso(now.AddMinutes(-1)), """{"used_percent":95,"window_minutes":300}""", null)
                .Replace("\"rate_limits\":{", "\"rate_limits\":{\"limit_id\":\"codex_other\",")
        });
        var service = new LocalLogUsageService(home);
        var snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
        ExpectClose(snapshot.Percent, 80, "model-specific session bucket must not overwrite General quota");
        Expect(snapshot.ResetAt == now.AddMinutes(50), "relative session reset must be anchored to event timestamp");
        var utcSnapshot = (await service.SnapshotsAsync(now.ToUniversalTime(), true, false)).Single();
        Expect(snapshot.Percent == utcSnapshot.Percent && snapshot.ResetAt == utcSnapshot.ResetAt,
            "timezone offset must not change quota or reset instant");
        snapshot = (await service.SnapshotsAsync(now.AddMinutes(51), true, false)).Single();
        Expect(snapshot.Percent == null && snapshot.Status == UsageStatus.Unknown, "expired relative reset must not manufacture quota on refresh");

        foreach (var reset in new[] { now.AddHours(1).ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
            now.AddHours(1).ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
            JsonSerializer.Serialize(Iso(now.AddHours(1))) })
        {
            File.WriteAllText(path, CodexTokenCountLine(Iso(now),
                "{\"used_percent\":35,\"window_minutes\":300,\"resets_at\":" + reset + "}", null));
            snapshot = (await service.SnapshotsAsync(now, true, false)).Single();
            Expect(snapshot.ResetAt == now.AddHours(1), "Unix seconds, milliseconds, and ISO offsets must resolve to the same reset instant");
            ExpectClose(snapshot.Percent, 65, "reset representation must not alter remaining percentage");
        }
    }
    finally { TryDelete(home); }
}

static async Task CheckClaudeDedup()
{
    var now = DateTimeOffset.Now;
    var home = TemporaryHome();
    try
    {
        WriteClaudeFixture(home, now);

        var service = new LocalLogUsageService(home, new ClaudeCalibrationStore(Path.Combine(home, "claude_calibration.json")));
        var snapshots = await service.SnapshotsAsync(now);
        var claude = snapshots.First(snapshot => snapshot.Provider == UsageProvider.Claude);

        Expect(claude.Percent == null && claude.Status == UsageStatus.Unknown, "deduplicated local tokens cannot establish subscription quota");
        Expect(claude.Message?.Contains("5.5K weighted tok") == true,
            "Claude message should show deduplicated weighted usage");
        Expect(claude.Message?.Contains("8.5K") != true,
            "Claude message should not show naive duplicate total");

        Expect(claude.ResetAt == null, "local activity must not invent the subscription reset time");
        Expect(claude.Weekly?.Detail?.Contains("tok this week") == true,
            "Claude weekly detail should show week tokens");
    }
    finally
    {
        TryDelete(home);
    }
}

static async Task CheckClaudeCalibration()
{
    var now = DateTimeOffset.Now;
    var home = TemporaryHome();
    try
    {
        WriteClaudeFixture(home, now, scale: 100);
        var calibrationStore = new ClaudeCalibrationStore(Path.Combine(home, "claude_calibration.json"));
        calibrationStore.Save(new ClaudeCalibration { CapEstimate = 2_200_000, SampleCount = 1,
            PlanKey = "estimated", UpdatedAt = now.AddDays(-7) });
        var before = File.ReadAllText(calibrationStore.FilePath);
        var claude = (await new LocalLogUsageService(home, calibrationStore).SnapshotsAsync(now))
            .First(snapshot => snapshot.Provider == UsageProvider.Claude);
        Expect(claude.Percent == null && claude.Weekly?.PercentLeft == null,
            "legacy learned token caps must not fabricate Claude quota");
        Expect(File.ReadAllText(calibrationStore.FilePath) == before,
            "Windows quota reads must neither overwrite nor migrate legacy calibration");
    }
    finally { TryDelete(home); }
}

static void CheckClaudePricing()
{
    var opusCost = LocalLogUsageService.ClaudeCostEstimateUsd(
        "claude-opus-4-8", 1_000_000, 1_000_000, 0, 0, 0, 0);
    ExpectClose(opusCost, 30, "opus-4-8 should cost $5 in + $25 out per 1M tokens");

    var fableCost = LocalLogUsageService.ClaudeCostEstimateUsd(
        "claude-fable-5", 1_000_000, 1_000_000, 0, 0, 0, 0);
    ExpectClose(fableCost, 60, "fable-5 should cost $10 in + $50 out per 1M tokens");

    var cacheCost = LocalLogUsageService.ClaudeCostEstimateUsd(
        "claude-opus-4-8", 0, 0, 1_000_000, 400_000, 600_000, 0);
    ExpectClose(cacheCost, 0.4 * 6.25 + 0.6 * 10, "cache write must not be double counted");
}

static void CheckTrayEntries()
{
    var now = DateTimeOffset.Now;
    IReadOnlyList<UsageSnapshot> snapshots =
    [
        new UsageSnapshot
        {
            Provider = UsageProvider.Claude,
            Status = UsageStatus.Ok,
            Used = 62,
            Percent = 62,
            UpdatedAt = now,
            Unit = "%",
            Weekly = new UsageWindow(40, null)
        },
        new UsageSnapshot
        {
            Provider = UsageProvider.Codex,
            Status = UsageStatus.Ok,
            Used = 41,
            Percent = 41,
            UpdatedAt = now,
            Unit = "%"
        }
    ];

    var entries = UsageStore.TrayEntriesFor(snapshots);

    Expect(entries.Count == 2, "tray entries should include Claude and Codex");
    Expect(entries.Select(entry => entry.Mark).SequenceEqual(["C", "X"]), "tray entry order should be C then X");
    ExpectClose(entries[0].PercentLeft, 40, "Claude tray percent should use the constrained weekly value");
    ExpectClose(entries[1].PercentLeft, 41, "Codex tray percent should use the primary value");
}

static void CheckFormatting()
{
    Expect(Format.Compact(5_500) == "5.5K", "5500 should compact to 5.5K");
    Expect(Format.Compact(2_000_000) == "2.0M", "2M should compact to 2.0M");
    Expect(Format.Compact(950) == "950", "950 should stay plain");

    var now = DateTimeOffset.Now;
    Expect(Format.RelativeReset(now.AddMinutes(185), now) == "3h 5m", "reset text should be h/m");
    Expect(Format.RelativeReset(now.AddMinutes(-5), now) == "0m", "past reset should clamp to 0m");
    Expect(Format.WidgetReset(now.AddDays(2).AddHours(4), now) == "2d 4h", "widget reset should show days");
}

// Raw-string interpolation cannot express JSON lines ending in }}}} (CS9007),
// so fixtures use @TOKEN@ placeholders instead.
static string CodexTokenCountLine(string timestamp, string primaryJson, string? secondaryJson)
{
    var secondaryPart = secondaryJson == null ? "" : $$""","secondary":{{secondaryJson}}""";
    return """{"timestamp":"@TS@","payload":{"type":"token_count","rate_limits":{"primary":@PRIMARY@@SECONDARY@}}}"""
        .Replace("@TS@", timestamp)
        .Replace("@PRIMARY@", primaryJson)
        .Replace("@SECONDARY@", secondaryPart);
}

static string ClaudeUsageLine(
    string timestamp, string requestId, string messageId,
    long input, long output, long cacheRead)
{
    return """{"type":"assistant","timestamp":"@TS@","sessionId":"s1","requestId":"@REQ@","message":{"id":"@MSG@","model":"claude-opus-4-8","usage":{"input_tokens":@IN@,"output_tokens":@OUT@,"cache_creation_input_tokens":0,"cache_read_input_tokens":@CACHE@}}}"""
        .Replace("@TS@", timestamp)
        .Replace("@REQ@", requestId)
        .Replace("@MSG@", messageId)
        .Replace("@IN@", input.ToString(CultureInfo.InvariantCulture))
        .Replace("@OUT@", output.ToString(CultureInfo.InvariantCulture))
        .Replace("@CACHE@", cacheRead.ToString(CultureInfo.InvariantCulture));
}

static void WriteClaudeFixture(string home, DateTimeOffset now, double scale = 1)
{
    var project = Path.Combine(home, ".claude", "projects", "p");
    Directory.CreateDirectory(project);

    var t1 = Iso(now.AddMinutes(-30));
    var t2 = Iso(now.AddMinutes(-20));
    var duplicated = ClaudeUsageLine(t1, "req_1", "msg_1", (long)(1_000 * scale), (long)(500 * scale), 0);

    File.WriteAllLines(Path.Combine(project, "session.jsonl"), new[]
    {
        duplicated,
        duplicated,
        duplicated,
        ClaudeUsageLine(t2, "req_2", "msg_2", (long)(2_000 * scale), (long)(1_000 * scale), (long)(10_000 * scale))
    });
}

static async Task RunClaudeEstimate()
{
    var service = new LocalLogUsageService();
    var snapshots = await service.SnapshotsAsync(DateTimeOffset.Now);
    var claude = snapshots.FirstOrDefault(snapshot => snapshot.Provider == UsageProvider.Claude);

    Console.WriteLine("--claude-estimate (compare with Claude Code /usage):");
    Console.WriteLine($"  percent left : {claude?.PercentDisplay ?? "--"}");
    Console.WriteLine($"  reset        : {claude?.SecondaryValue ?? "--"}");
    Console.WriteLine($"  message      : {claude?.Message ?? "--"}");
}

static string Iso(DateTimeOffset date) =>
    date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

static void TryDelete(string directory)
{
    try
    {
        Directory.Delete(directory, recursive: true);
    }
    catch
    {
        // Best-effort cleanup of temp fixtures.
    }
}

static void CheckWindowLabelsAndOfficialParsers()
{
    var now = DateTimeOffset.Parse("2026-09-10T01:00:00Z", CultureInfo.InvariantCulture);
    UsageSnapshot Snapshot(int? minutes) => new()
    {
        Provider = UsageProvider.Codex, Status = UsageStatus.Ok, UpdatedAt = now, PrimaryWindowMinutes = minutes
    };
    Expect(Snapshot(null).PrimaryWindowLabel == "LIMIT", "unknown Codex window must never imply 5h");
    Expect(Snapshot(300).PrimaryWindowLabel == "5H" && Snapshot(300).PrimaryWindowTitle == "5-HOUR", "5h metadata should label 5H");
    Expect(Snapshot(10080).PrimaryWindowLabel == "1W" && Snapshot(10080).PrimaryWindowTitle == "1-WEEK", "weekly metadata should label 1W");
    Expect(Snapshot(1440).PrimaryWindowLabel == "1D" && Snapshot(90).PrimaryWindowLabel == "90M", "variable durations should remain exact");
    Expect((Snapshot(null) with { Provider = UsageProvider.Claude }).PrimaryWindowLabel == "5H", "Claude default remains 5h");

    var weekly = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limit":{"primary_window":{"used_percent":29,"limit_window_seconds":604800,"reset_after_seconds":3600}},"plan_type":"free"}""", now);
    Expect(weekly?.Primary.WindowMinutes == 10080 && weekly.Secondary == null, "weekly-only official primary must be retained");
    ExpectClose(weekly?.Primary.LeftPercent, 71, "weekly-only official percent");
    Expect(weekly?.Primary.ResetsAt == now.AddHours(1), "relative resets use the reading time");
    var promoted = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limits":{"primary":null,"secondary":{"percent_left":43,"window_minutes":10080}}}""", now);
    Expect(promoted?.Primary.WindowMinutes == 10080 && promoted.Secondary == null, "secondary-only weekly official window must be promoted");
    var reversed = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limits":{"primary":{"used_percent":90,"window_minutes":10080},"secondary":{"used_percent":20,"window_minutes":300}}}""", now);
    Expect(reversed?.Primary.WindowMinutes == 300 && reversed.Secondary?.WindowMinutes == 10080, "shorter official duration must be primary");
    var unknown = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limit":{"primary_window":{"used_percent":20}}}""", now);
    Expect(unknown?.Primary.WindowMinutes == null, "unknown official duration must stay unknown");
    Expect(CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":"NaN","window_minutes":300}}""", now) == null, "nonfinite percentages are invalid");
    Expect(CLIOAuthUsageService.ParseCodexWhamUsage("[]", now) == null, "invalid official shape must not throw");
    var claude = CLIOAuthUsageService.ParseClaudeOAuthUsage("""{"five_hour":{"utilization":20,"resets_at":"2026-09-10T06:00:00.123456+00:00"},"seven_day":{"utilization":90}}""", now);
    Expect(claude?.Primary.WindowMinutes == 300 && claude.Secondary?.WindowMinutes == 10080, "Claude official known durations");
    Expect(claude?.Primary.ResetsAt != null, "microsecond official timestamp should parse");
    Expect(CLIOAuthUsageService.MakeSnapshot(UsageProvider.Claude, claude!, now, "test", "test").Status == UsageStatus.Critical,
        "official weekly limit should constrain status");
}

static async Task CheckCodexWindowVariants()
{
    var now = DateTimeOffset.Now;
    var cases = new[]
    {
        (Primary: "{\"used_percent\":29,\"window_minutes\":10080}", Secondary: (string?)null, Label: "1W", Left: 71.0, Weekly: (double?)null),
        (Primary: "null", Secondary: "{\"used_percent\":29,\"window_minutes\":10080}", Label: "1W", Left: 71.0, Weekly: (double?)null),
        (Primary: "{\"used_percent\":90,\"window_minutes\":10080}", Secondary: "{\"used_percent\":20,\"window_minutes\":300}", Label: "5H", Left: 80.0, Weekly: (double?)10),
        (Primary: "{\"used_percent\":33}", Secondary: (string?)null, Label: "LIMIT", Left: 67.0, Weekly: (double?)null)
    };
    foreach (var item in cases)
    {
        var home = TemporaryHome();
        try
        {
            var sessions = Path.Combine(home, ".codex", "sessions");
            Directory.CreateDirectory(sessions);
            File.WriteAllText(Path.Combine(sessions, "rollout.jsonl"), CodexTokenCountLine(Iso(now), item.Primary, item.Secondary));
            var snapshot = (await new LocalLogUsageService(home).SnapshotsAsync(now)).First(s => s.Provider == UsageProvider.Codex);
            Expect(snapshot.PrimaryWindowLabel == item.Label, "local Codex label must follow its actual duration");
            ExpectClose(snapshot.Percent, item.Left, "local Codex variant percent");
            if (item.Weekly == null) Expect(snapshot.Weekly == null, "sole limit must not duplicate a weekly bar");
            else ExpectClose(snapshot.Weekly?.PercentLeft, item.Weekly.Value, "reversed local weekly percent");
        }
        finally { TryDelete(home); }
    }
}

static void CheckAntigravityQuota()
{
    var now = DateTimeOffset.Now;
    string Summary(string buckets, string displayName = "Gemini Models") =>
        "{\"response\":{\"groups\":[{\"displayName\":\"" + displayName + "\",\"buckets\":[" + buckets + "]}]}}";
    const string week = "{\"bucketId\":\"gemini-weekly\",\"window\":\"weekly\",\"remainingFraction\":0.6}";
    var complete = AntigravityUsageService.ParseSummary(Summary("{\"bucketId\":\"gemini-5h\",\"window\":\"5h\",\"remainingFraction\":0.7}," + week), now);
    ExpectClose(complete?.Percent, 70, "Gemini 5h must come from the explicit Gemini bucket");
    ExpectClose(complete?.Weekly?.PercentLeft, 60, "Gemini weekly must come from the explicit weekly bucket");
    Expect(complete?.Status == UsageStatus.Ok && complete.Provider == UsageProvider.Antigravity, "Gemini complete quota status");
    var zero = AntigravityUsageService.ParseSummary(Summary("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":0,\"resetTime\":\"2020-01-01T00:00:00Z\"}," + week), now);
    ExpectClose(zero?.Percent, 0, "explicit Gemini zero means exhausted even after a past reset");
    Expect(zero?.Status == UsageStatus.Critical && zero.ResetAt < now, "past Gemini reset must be preserved");
    foreach (var value in new[] { "true", "\"0.7\"", "1.2", "-0.1", "null" })
    {
        var malformed = AntigravityUsageService.ParseSummary(Summary("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":" + value + "}," + week), now);
        Expect(malformed?.Percent == null && malformed?.Status == UsageStatus.Unknown, "invalid Gemini fraction must remain unknown");
    }
    foreach (var extra in new[] { ",\"disabled\":true", ",\"disabled\":\"false\"", ",\"remainingAmount\":12", ",\"window\":\"weekly\"" })
    {
        var unusable = AntigravityUsageService.ParseSummary(Summary("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":0.7" + extra + "}," + week), now);
        Expect(unusable?.Percent == null, "disabled, contradictory, or mismatched Gemini bucket must remain unknown");
    }
    var partial = AntigravityUsageService.ParseSummary(Summary("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":0.7}"), now);
    Expect(partial?.Weekly?.PercentLeft == null && partial?.Status == UsageStatus.Unknown, "missing Gemini weekly must not imply ready");
    Expect(UsageStore.TrayEntriesFor([partial!])[0].PercentLeft == null, "tray must preserve unknown Gemini quota");
    Expect(AntigravityUsageService.ParseSummary(Summary(week, "Claude Models"), now) == null, "other providers must never appear as Gemini");
    var duplicate = AntigravityUsageService.ParseSummary(Summary(week + "," + week), now);
    Expect(duplicate?.Weekly?.PercentLeft == null, "duplicate Gemini bucket must remain unknown");
}

static async Task CheckOfficialTransport()
{
    var home = TemporaryHome();
    try
    {
        Directory.CreateDirectory(Path.Combine(home, ".codex"));
        var authPath = Path.Combine(home, ".codex", "auth.json");
        const string auth = "{\"tokens\":{\"access_token\":\"fixture-only-token\",\"account_id\":\"fixture-account\"}}";
        File.WriteAllText(authPath, auth);
        var handler = new FixtureHttpHandler(request =>
        {
            Expect(request.RequestUri?.AbsoluteUri == "https://chatgpt.com/backend-api/wham/usage", "Codex credentials must target its official endpoint");
            Expect(request.Headers.Authorization?.Parameter == "fixture-only-token", "request uses the existing fixture sign-in");
            return new(HttpStatusCode.OK) { Content = new StringContent("{\"rate_limit\":{\"primary_window\":{\"used_percent\":29,\"limit_window_seconds\":604800}}}") };
        });
        using var client = new HttpClient(handler);
        var service = new CLIOAuthUsageService(home, client);
        var result = await service.SnapshotAsync(UsageProvider.Codex, DateTimeOffset.Now);
        Expect(result.Snapshot?.PrimaryWindowLabel == "1W" && result.FailureReason == null, "official transport should feed duration metadata");
        Expect(File.ReadAllText(authPath) == auth, "official sync must never modify CLI credentials");
        handler.Responder = _ => new(HttpStatusCode.Unauthorized) { Content = new StringContent("sensitive response must not leak") };
        result = await service.SnapshotAsync(UsageProvider.Codex, DateTimeOffset.Now);
        Expect(result.Snapshot == null && result.FailureReason?.Contains("HTTP 401") == true && !result.FailureReason.Contains("sensitive"), "HTTP errors must use sanitized guidance");
        var count = handler.Count;
        result = await service.SnapshotAsync(UsageProvider.Claude, DateTimeOffset.Now);
        Expect(result.FailureReason?.Contains("not found") == true && handler.Count == count, "missing sign-in must not make network calls");
        Directory.CreateDirectory(Path.Combine(home, ".claude"));
        File.WriteAllText(Path.Combine(home, ".claude", ".credentials.json"), "{\"claudeAiOauth\":{\"accessToken\":\"fixture-only-token\",\"expiresAt\":1}}");
        result = await service.SnapshotAsync(UsageProvider.Claude, DateTimeOffset.Now);
        Expect(result.FailureReason?.Contains("expired") == true && handler.Count == count, "expired Claude tokens must not be sent or refreshed");
    }
    finally { TryDelete(home); }
}

static async Task CheckOptInSources()
{
    var home = TemporaryHome();
    try
    {
        Directory.CreateDirectory(home);
        var configStore = new AppConfigStore(Path.Combine(home, "config.json"));
        var official = new FixtureOfficialService();
        var gemini = new FixtureAntigravityService();
        var service = new CompositeUsageService(configStore, new LocalLogUsageService(home), official, gemini);
        var config = new AppConfig { LocalLogEnabled = false, AntigravityProviderEnabled = true };
        configStore.Save(config);
        var snapshots = await service.SnapshotsAsync(DateTimeOffset.Now);
        Expect(official.Count == 0 && gemini.Count == 0, "visible providers must not imply credential opt-in");
        Expect(snapshots.Count == 3, "visible Gemini should have setup guidance before opt-in");
        config.ClaudeOfficialUsageEnabled = true;
        config.CodexOfficialUsageEnabled = true;
        config.AntigravityUsageEnabled = true;
        configStore.Save(config);
        snapshots = await service.SnapshotsAsync(DateTimeOffset.Now);
        Expect(official.Count == 2 && gemini.Count == 1, "explicitly enabled sources should be called");
        Expect(snapshots.Select(s => s.Provider).SequenceEqual([UsageProvider.Codex, UsageProvider.Claude, UsageProvider.Antigravity]), "provider identity/order must remain stable");
        config.ClaudeProviderEnabled = false;
        config.CodexProviderEnabled = false;
        config.AntigravityProviderEnabled = false;
        configStore.Save(config);
        Expect((await service.SnapshotsAsync(DateTimeOffset.Now)).Count == 0 && official.Count == 2 && gemini.Count == 1,
            "hidden providers must not be fetched even if their sync flags remain enabled");
    }
    finally { TryDelete(home); }
}

static async Task CheckRefreshConfigurationRace()
{
    var home = TemporaryHome();
    try
    {
        Directory.CreateDirectory(home);
        var configStore = new AppConfigStore(Path.Combine(home, "config.json"));
        configStore.Save(new AppConfig());
        var service = new DelayedFixtureService();
        var store = new UsageStore(service, configStore);
        var refresh = store.RefreshAsync();
        await service.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        store.UpdateConfig(new AppConfig { CodexProviderEnabled = false });
        service.Release.TrySetResult();
        await refresh.WaitAsync(TimeSpan.FromSeconds(5));
        Expect(service.Count == 2, "config change during a fetch must queue an immediate second refresh");
        Expect(store.Snapshots.All(snapshot => snapshot.Provider != UsageProvider.Codex), "in-flight old provider result must never reappear");
        Expect(!store.IsRefreshing, "refresh state should settle after queued refresh");
    }
    finally { TryDelete(home); }
}

static async Task CheckRefreshFailureRecovery()
{
    var home = TemporaryHome();
    try
    {
        Directory.CreateDirectory(home);
        var configStore = new AppConfigStore(Path.Combine(home, "config.json"));
        configStore.Save(new AppConfig());
        var store = new UsageStore(new RecoveringFixtureService(), configStore);
        await store.RefreshAsync();
        Expect(store.LastErrorMessage?.Contains("Usage refresh failed") == true && !store.IsRefreshing,
            "refresh exception must show safe guidance and release the refresh state");
        Expect(store.LastErrorMessage?.Contains("fixture-private-diagnostic") != true, "provider diagnostics must not reach the UI");
        await store.RefreshAsync();
        Expect(store.LastErrorMessage == null && store.Snapshots.Count == 1 && !store.IsRefreshing,
            "a successful retry must clear the previous refresh error");
    }
    finally { TryDelete(home); }
}

static async Task CheckQuotaRefreshSafety()
{
    var now = DateTimeOffset.Now;
    var known = new UsageSnapshot { Provider = UsageProvider.Codex, Status = UsageStatus.Ok,
        UpdatedAt = now, Percent = 95, Used = 95, Unit = "%", PrimaryWindowMinutes = 300,
        ResetAt = now.AddHours(1), Weekly = new UsageWindow(84, now.AddDays(1)) };
    var expired = UsageStore.ValidateForDisplay(known with { ResetAt = now.AddSeconds(-1) }, now);
    Expect(expired.Percent == null && expired.Weekly?.PercentLeft == 84 && expired.Status == UsageStatus.Unknown,
        "expired primary must not erase the still-valid weekly reading or invent100");
    var expiredWeekly = UsageStore.ValidateForDisplay(known with { Weekly = new UsageWindow(84, now.AddSeconds(-1)) }, now);
    Expect(expiredWeekly.Percent == 95 && expiredWeekly.Weekly?.PercentLeft == null &&
        UsageStore.TrayEntriesFor([expiredWeekly]).Single().PercentLeft == null,
        "unknown weekly must not be treated as100 in the aggregate");
    foreach (var timestamp in new[] { now.AddMinutes(-30), now.AddMinutes(6) })
    {
        var stale = UsageStore.ValidateForDisplay(known with { UpdatedAt = timestamp }, now);
        Expect(stale.Percent == null && stale.Weekly?.PercentLeft == null, "stale/future snapshot is unknown");
    }
    foreach (var invalid in new[] { double.NaN, double.PositiveInfinity, -1, 101 })
        Expect(UsageStore.ValidateForDisplay(known with { Percent = invalid }, now).Percent == null,
            "invalid provider output is unknown before display");
    var home = TemporaryHome();
    try
    {
        Directory.CreateDirectory(home);
        var configStore = new AppConfigStore(Path.Combine(home, "config.json"));
        configStore.Save(new AppConfig { ClaudeProviderEnabled = false });
        var service = new QuotaFailureFixtureService();
        var store = new UsageStore(service, configStore);
        await store.RefreshAsync();
        Expect(store.Snapshots.Single().Percent == 100, "explicit fresh100 is supported");
        await store.RefreshAsync();
        Expect(store.Snapshots.Single().Percent == null && store.MostConstrainedPercent == null &&
            store.Snapshots.Single().PercentDisplay == "--%", "failed refresh cannot retain apparent current100");
        Expect(store.LastErrorMessage?.Contains("fixture-private") != true, "refresh errors remain sanitized");
        await store.RefreshAsync();
        Expect(store.Snapshots.Single().Percent == 95 && store.LastErrorMessage == null,
            "successful recovery restores the exact quota");
    }
    finally { TryDelete(home); }
}

static async Task CheckFailedOfficialDoesNotBorrowLocalQuota()
{
    var now = DateTimeOffset.Now;
    var home = TemporaryHome();
    try
    {
        var sessions = Path.Combine(home, ".codex", "sessions");
        Directory.CreateDirectory(sessions);
        File.WriteAllText(Path.Combine(sessions, "previous-account.jsonl"), CodexTokenCountLine(Iso(now),
            "{\"used_percent\":0,\"window_minutes\":300}", "{\"used_percent\":0,\"window_minutes\":10080}"));
        var configStore = new AppConfigStore(Path.Combine(home, "config.json"));
        configStore.Save(new AppConfig { ClaudeProviderEnabled = false, CodexOfficialUsageEnabled = true });
        var service = new CompositeUsageService(configStore, new LocalLogUsageService(home), new FailedOfficialFixtureService());
        var snapshot = (await service.SnapshotsAsync(now)).Single();
        Expect(snapshot.Percent == null && snapshot.Weekly?.PercentLeft == null && snapshot.Status == UsageStatus.Unknown,
            "failed authenticated sync must not borrow100 from unverified previous-account local logs");
        Expect(snapshot.Message?.Contains("Current quota is unknown") == true,
            "unavailable current account quota should explain the unknown reading");
    }
    finally { TryDelete(home); }
}

sealed class FailedOfficialFixtureService : IOfficialUsageService
{
    public Task<OfficialUsageResult> SnapshotAsync(UsageProvider provider, DateTimeOffset now) =>
        Task.FromResult(new OfficialUsageResult(null, "Synthetic authentication failure."));
}

sealed class QuotaFailureFixtureService : IUsageService
{
    private int _count;
    public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now)
    {
        _count++;
        if (_count == 2) throw new IOException("fixture-private-detail");
        return Task.FromResult<IReadOnlyList<UsageSnapshot>>([new UsageSnapshot
        { Provider = UsageProvider.Codex, Status = UsageStatus.Ok, UpdatedAt = now,
            Percent = _count == 1 ? 100 : 95, PrimaryWindowMinutes = 300, ResetAt = now.AddHours(1) }]);
    }
}

sealed class FixtureHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
{
    public Func<HttpRequestMessage, HttpResponseMessage> Responder { get; set; } = responder;
    public int Count { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Count++;
        return Task.FromResult(Responder(request));
    }
}

sealed class FixtureOfficialService : IOfficialUsageService
{
    public int Count { get; private set; }
    public Task<OfficialUsageResult> SnapshotAsync(UsageProvider provider, DateTimeOffset now)
    {
        Count++;
        return Task.FromResult(new OfficialUsageResult(new UsageSnapshot
        {
            Provider = provider, Status = UsageStatus.Ok, UpdatedAt = now, Percent = 70, Source = "fixture"
        }, null));
    }
}

sealed class FixtureAntigravityService : IAntigravityUsageService
{
    public int Count { get; private set; }
    public Task<UsageSnapshot> SnapshotAsync(DateTimeOffset now)
    {
        Count++;
        return Task.FromResult(new UsageSnapshot
        {
            Provider = UsageProvider.Antigravity, Status = UsageStatus.Ok, UpdatedAt = now,
            Percent = 70, Weekly = new UsageWindow(60, null), Source = "fixture"
        });
    }
}

sealed class DelayedFixtureService : IUsageService
{
    public int Count;
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now)
    {
        if (Interlocked.Increment(ref Count) == 1)
        {
            Started.TrySetResult();
            await Release.Task;
        }
        return new[] { UsageProvider.Claude, UsageProvider.Codex }.Select(provider => new UsageSnapshot
        {
            Provider = provider, Status = UsageStatus.Ok, UpdatedAt = now, Percent = 70
        }).ToArray();
    }
}

sealed class RecoveringFixtureService : IUsageService
{
    private int _count;
    public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now)
    {
        if (++_count == 1) throw new IOException("fixture-private-diagnostic");
        return Task.FromResult<IReadOnlyList<UsageSnapshot>>([new UsageSnapshot
        {
            Provider = UsageProvider.Codex, Status = UsageStatus.Ok, UpdatedAt = now, Percent = 70
        }]);
    }
}

static void CheckLoginStartup()
{
    Expect(LoginStartupPolicy.Decide(false, false, true, false, false, false) == LoginStartupAction.Register, "first install registration");
    Expect(LoginStartupPolicy.Decide(true, true, true, true, false, false) == LoginStartupAction.None, "no repeated registration");
    Expect(LoginStartupPolicy.Decide(true, true, true, false, false, false) == LoginStartupAction.None, "OS deletion respected");
    Expect(LoginStartupPolicy.Decide(false, true, false, false, false, false) == LoginStartupAction.None, "legacy off respected");
    Expect(LoginStartupPolicy.Decide(false, true, true, false, false, false) == LoginStartupAction.None, "legacy OS off respected");
    Expect(LoginStartupPolicy.Decide(true, true, true, true, true, true) == LoginStartupAction.None, "StartupApproved off respected");
    Expect(LoginStartupPolicy.Decide(true, true, true, true, false, true) == LoginStartupAction.Relocate, "moved enabled entry repaired");
    Expect(LoginStartupPolicy.Decide(true, true, false, true, false, false, true) == LoginStartupAction.Remove, "explicit off removes entry");
    Expect(LoginStartupPolicy.Decide(true, true, true, false, true, false, true) == LoginStartupAction.Register, "explicit on requests entry but does not bypass OS block");
    var path = Path.Combine(Path.GetTempPath(), $"usage-kun-startup-{Guid.NewGuid()}.json");
    try {
        var store = new AppConfigStore(path);
        store.Save(new AppConfig { LaunchAtLoginEnabled = false, LaunchAtLoginInitialized = true });
        var reloaded = new AppConfigStore(path).Load();
        Expect(!reloaded.LaunchAtLoginEnabled && reloaded.LaunchAtLoginInitialized, "explicit off and initialization persist across store reconstruction");
    } finally { File.Delete(path); }
}
