using System.Globalization;
using System.Text.Json;
using UsageKun.Core;
using Microsoft.Data.Sqlite;

// All inputs here are synthetic, written to isolated temporary profiles.
// These checks never inspect the machine's real CLI logs or credentials.
internal static class LocalQuotaChecks
{
    internal static async Task RunAsync()
    {
        await CheckExactPercentages();
        await CheckExpiredAndStaleWindows();
        await CheckLiveDatabaseWindows();
        await CheckMissingAndInvalidValues();
        await CheckProviderAndWindowIdentity();
        await CheckClaudeTokenLogsDoNotEstablishQuota();
    }

    private static readonly DateTimeOffset Now = DateTimeOffset.Parse(
        "2026-10-09T12:00:00Z", CultureInfo.InvariantCulture);

    private static async Task CheckExactPercentages()
    {
        foreach (var left in new[] { 95.0, 94.9, 95.1, 99, 99.5, 100, 0 })
        {
            foreach (var remaining in new[] { false, true })
            {
                var snapshot = await WithCodex(
                    Window(left, 300, Now.AddHours(1), remaining),
                    Window(left, 10080, Now.AddDays(1), remaining));
                Equal(snapshot.Percent, left, "local primary keeps the exact percentage");
                Equal(snapshot.Weekly?.PercentLeft, left, "local weekly keeps the exact percentage");
                Require(snapshot.ResetAt == Now.AddHours(1), "explicit future reset is retained");
                Require(snapshot.Provider == UsageProvider.Codex, "Codex fixture stays Codex");
            }
        }
    }

    private static async Task CheckExpiredAndStaleWindows()
    {
        // Regression: a real 95%-left reading must never become 100% merely
        // because its recorded reset passed. Passing reset is not a new sample.
        foreach (var reset in new[] { Now.AddSeconds(-1), Now })
        {
            var expired = await WithCodex(Window(95, 300, reset), Window(94.9, 10080, Now.AddDays(1)));
            Unknown(expired, "expired primary is unknown, never fabricated full quota");
            Equal(expired.Weekly?.PercentLeft, 94.9, "valid weekly survives expired primary");
            Require(expired.ResetAt == null && expired.SecondaryValue == "expired", "expired primary must request a new reading");
        }

        var expiredWeekly = await WithCodex(Window(95, 300, Now.AddHours(1)), Window(99.5, 10080, Now));
        Equal(expiredWeekly.Percent, 95, "valid primary survives expired weekly");
        Require(expiredWeekly.Weekly?.PercentLeft == null && expiredWeekly.Status == UsageStatus.Unknown,
            "expired constraining weekly quota is unknown");

        foreach (var recorded in new[] { Now.AddMinutes(-30), Now.AddDays(-1), Now.AddMinutes(5).AddTicks(1) })
        {
            var stale = await WithCodex(Window(95, 300, Now.AddHours(1)), Window(99.5, 10080, Now.AddDays(1)), recorded);
            Unknown(stale, "stale or implausibly future quota is unknown");
            Require(stale.Weekly?.PercentLeft == null && stale.ResetAt == null, "stale reading cannot carry a current quota/reset");
        }
        var justFresh = await WithCodex(Window(95, 300, Now.AddHours(1)), recorded: Now.AddMinutes(-30).AddTicks(1));
        Equal(justFresh.Percent, 95, "freshness boundary preserves a recent recorded value");
    }

    private static async Task CheckLiveDatabaseWindows()
    {
        foreach (var reset in new[] { Now.AddHours(1), Now.AddSeconds(-1) })
        {
            var home = TemporaryHome();
            try
            {
                var codex = Path.Combine(home, ".codex");
                Directory.CreateDirectory(codex);
                var database = Path.Combine(codex, "logs_2.sqlite");
                using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                { DataSource = database, Pooling = false }.ToString()))
                {
                    connection.Open();
                    using var schema = connection.CreateCommand();
                    schema.CommandText = "CREATE TABLE logs (ts INTEGER, ts_nanos INTEGER, target TEXT, feedback_log_body TEXT)";
                    schema.ExecuteNonQuery();
                    using var insert = connection.CreateCommand();
                    insert.CommandText = "INSERT INTO logs VALUES ($ts, 0, $target, $body)";
                    insert.Parameters.AddWithValue("$ts", Now.ToUnixTimeSeconds());
                    insert.Parameters.AddWithValue("$target", "codex_api::endpoint::responses_websocket");
                    insert.Parameters.AddWithValue("$body", "responses_websocket.stream_request websocket event: {\"type\":\"codex.rate_limits\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":" +
                        Window(95, 300, reset) + ",\"secondary\":" + Window(99.5, 10080, Now.AddDays(1)) + "}}");
                    insert.ExecuteNonQuery();
                }
                var snapshot = (await new LocalLogUsageService(home).SnapshotsAsync(Now, true, false)).Single();
                Require(snapshot.Source == "Codex live rate limits", "synthetic SQLite rate event is read through the live path");
                if (reset <= Now) Unknown(snapshot, "expired SQLite quota cannot turn into 100%");
                else Equal(snapshot.Percent, 95, "fresh SQLite quota preserves the observed remainder");
                Equal(snapshot.Weekly?.PercentLeft, 99.5, "live weekly 99.5 cannot be rounded to 100");
            }
            finally { Delete(home); }
        }
    }

    private static async Task CheckMissingAndInvalidValues()
    {
        foreach (var invalid in new[]
        {
            "null", "{}", "{\"used_percent\":null}", "{\"used_percent\":true}",
            "{\"used_percent\":\"NaN\"}", "{\"used_percent\":-0.1}", "{\"used_percent\":100.1}"
        })
            Unknown(await WithCodex(invalid), "invalid quota cannot imply full availability");

        var missingTimestamp = await WithCodex(Window(95, 300, Now.AddHours(1)), omitTimestamp: true);
        Unknown(missingTimestamp, "filesystem modification time cannot replace a missing event timestamp");

        var missingPrimary = await WithCodex("null", Window(95.1, 10080, Now.AddDays(1)));
        Equal(missingPrimary.Percent, 95.1, "explicit sole weekly window remains available");
        Require(missingPrimary.PrimaryWindowLabel == "1W" && missingPrimary.Weekly == null,
            "weekly-only quota must never be shown as a fabricated 5h quota");
        var missingWeekly = await WithCodex(Window(95, 300, Now.AddHours(1)));
        Require(missingWeekly.Weekly?.PercentLeft == null && missingWeekly.Status == UsageStatus.Unknown,
            "absent weekly quota cannot imply full availability");
        foreach (var invalidWeekly in new[] { "{}", "{\"used_percent\":\"NaN\",\"window_minutes\":10080}" })
        {
            var partial = await WithCodex(Window(95, 300, Now.AddHours(1)), invalidWeekly);
            Equal(partial.Percent, 95, "valid primary survives invalid weekly data");
            Require(partial.Weekly?.PercentLeft == null && partial.Status == UsageStatus.Unknown,
                "invalid weekly quota cannot disappear into a ready status");
        }
        var unknownDuration = await WithCodex("{\"used_percent\":5}", "{}");
        Equal(unknownDuration.Percent, 95, "unknown duration retains an explicit primary quota");
        Require(unknownDuration.Status == UsageStatus.Unknown && unknownDuration.Weekly?.PercentLeft == null,
            "explicit malformed secondary stays unknown even without a known primary duration");
    }

    private static async Task CheckProviderAndWindowIdentity()
    {
        var nonWeekly = await WithCodex(Window(95, 300, Now.AddHours(1)), Window(99.5, 1440, Now.AddDays(1)));
        Require(nonWeekly.Weekly?.PercentLeft == null && nonWeekly.Status == UsageStatus.Unknown,
            "nonweekly secondary cannot become known weekly quota");
        var reversed = await WithCodex(Window(99.5, 10080, Now.AddDays(1)), Window(95.1, 300, Now.AddHours(1)));
        Equal(reversed.Percent, 95.1, "5h/weekly ordering follows explicit duration");
        Equal(reversed.Weekly?.PercentLeft, 99.5, "reordered weekly percentage keeps its precision");

        var home = TemporaryHome();
        try
        {
            WriteCodex(home, Event(Window(95, 300, Now.AddHours(1)), null, Now.AddMinutes(-1)) + "\n" +
                Event(Window(0, 300, Now.AddHours(1)), null, Now, limitId: "codex_other_model"));
            var snapshot = (await new LocalLogUsageService(home).SnapshotsAsync(Now, true, false)).Single();
            Equal(snapshot.Percent, 95, "named model bucket cannot overwrite General Codex quota");
        }
        finally { Delete(home); }
    }

    private static async Task CheckClaudeTokenLogsDoNotEstablishQuota()
    {
        foreach (var activity in new[] { Now.AddMinutes(-10), Now.AddHours(-6) })
        {
            var home = TemporaryHome();
            try
            {
                var projects = Path.Combine(home, ".claude", "projects", "synthetic");
                Directory.CreateDirectory(projects);
                File.WriteAllText(Path.Combine(projects, "conversation.jsonl"), JsonSerializer.Serialize(new
                {
                    type = "assistant", timestamp = Iso(activity), sessionId = "fixture-session", requestId = "fixture-request",
                    message = new { id = "fixture-message", model = "claude-fixture", usage = new
                    { input_tokens = 1_900_000, output_tokens = 0, cache_creation_input_tokens = 0, cache_read_input_tokens = 0 } }
                }));
                // Even a persisted learned cap may not turn conversation token
                // quantities into a subscription utilization measurement.
                var calibration = new ClaudeCalibrationStore(Path.Combine(home, "calibration.json"));
                calibration.Save(new ClaudeCalibration { CapEstimate = 2_000_000, SampleCount = 50, PlanKey = "claude_pro", UpdatedAt = Now });
                WriteCodex(home, Event(Window(95.1, 300, Now.AddHours(1)), null, Now));
                var snapshots = await new LocalLogUsageService(home, calibration).SnapshotsAsync(Now);
                var claude = snapshots.Single(s => s.Provider == UsageProvider.Claude);
                Unknown(claude, "Claude logged tokens cannot establish actual remaining subscription quota");
                Require(claude.ResetAt == null && claude.Weekly?.PercentLeft == null, "local block/calendar week cannot establish quota reset/windows");
                Require(claude.Message?.Contains("logs cannot determine") == true, "Claude fallback explains the measurement limit");
                Equal(snapshots.Single(s => s.Provider == UsageProvider.Codex).Percent, 95.1, "Claude token estimate cannot affect Codex quota");
            }
            finally { Delete(home); }
        }
    }

    private static async Task<UsageSnapshot> WithCodex(string primary, string? secondary = null,
        DateTimeOffset? recorded = null, bool omitTimestamp = false)
    {
        var home = TemporaryHome();
        try
        {
            WriteCodex(home, Event(primary, secondary, recorded ?? Now, omitTimestamp));
            return (await new LocalLogUsageService(home).SnapshotsAsync(Now, true, false)).Single();
        }
        finally { Delete(home); }
    }

    private static string Window(double left, int minutes, DateTimeOffset reset, bool remaining = false) =>
        "{\"" + (remaining ? "percent_left" : "used_percent") + "\":" +
        (remaining ? left : 100 - left).ToString("R", CultureInfo.InvariantCulture) +
        ",\"window_minutes\":" + minutes.ToString(CultureInfo.InvariantCulture) +
        ",\"resets_at\":" + reset.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture) + "}";

    private static string Event(string primary, string? secondary, DateTimeOffset recorded,
        bool omitTimestamp = false, string limitId = "codex") =>
        "{" + (omitTimestamp ? "" : "\"timestamp\":\"" + Iso(recorded) + "\",") +
        "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"" + limitId +
        "\",\"primary\":" + primary + (secondary == null ? "" : ",\"secondary\":" + secondary) + "}}}";

    private static void WriteCodex(string home, string json)
    {
        var sessions = Path.Combine(home, ".codex", "sessions");
        Directory.CreateDirectory(sessions);
        File.WriteAllText(Path.Combine(sessions, "fixture.jsonl"), json);
    }

    private static string Iso(DateTimeOffset date) => date.ToString("O", CultureInfo.InvariantCulture);
    private static string TemporaryHome() => Path.Combine(Path.GetTempPath(), "UsageKunLocalQuotaFixture-" + Guid.NewGuid());
    private static void Delete(string home) { if (Directory.Exists(home)) Directory.Delete(home, true); }
    private static void Unknown(UsageSnapshot snapshot, string message) =>
        Require(snapshot.Percent == null && snapshot.Used == null && snapshot.Status == UsageStatus.Unknown, message);
    private static void Equal(double? actual, double expected, string message) =>
        Require(actual is { } value && Math.Abs(value - expected) < 0.000001, message);
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Synthetic local quota regression failed: " + message);
    }
}
