using System.Globalization;
using System.Net;
using UsageKun.Core;

// All payloads and sign-in files here are synthetic. No real account or CLI log
// is read; the injected HTTP handler never sends a request to the network.
internal static class OAuthQuotaChecks
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-09T12:00:00Z", CultureInfo.InvariantCulture);

    public static async Task RunAsync()
    {
        CheckPercentagePrecision();
        CheckWindowsAndSchemas();
        CheckExpiredWindows();
        await CheckTransportFailures();
    }

    private static void CheckPercentagePrecision()
    {
        foreach (var (left, display) in new[]
        {
            (95.0, "95%"), (94.9, "94.9%"), (95.1, "95.1%"),
            (99.0, "99%"), (99.5, "99.5%"), (100.0, "100%")
        })
        {
            var invariantLeft = left.ToString(CultureInfo.InvariantCulture);
            var invariantUsed = (100 - left).ToString(CultureInfo.InvariantCulture);
            var fromUsed = CLIOAuthUsageService.ParseCodexWhamUsage(
                "{\"rate_limit\":{\"primary_window\":{\"used_percent\":" + invariantUsed + ",\"window_minutes\":300}}}", Now);
            var fromRemaining = CLIOAuthUsageService.ParseCodexWhamUsage(
                "{\"rate_limits\":{\"primary\":{\"remaining_percent\":" + invariantLeft + ",\"window_minutes\":300}}}", Now);
            var claude = CLIOAuthUsageService.ParseClaudeOAuthUsage(
                "{\"five_hour\":{\"utilization\":" + invariantUsed + "}}", Now);
            foreach (var reading in new[] { fromUsed, fromRemaining, claude })
            {
                Assert(reading != null, "valid percentage fixture should parse");
                Close(reading!.Primary.LeftPercent, left, "used and remaining percentages must convert exactly once");
                var snapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, reading, Now, "synthetic", "synthetic");
                Assert(snapshot.PercentDisplay == display && snapshot.UsedDisplay == display,
                    "decimal quota must survive both percent display routes");
            }
            Assert(Format.Percent(left) == display, "shared Windows percentage display must preserve reported precision");
        }

        Assert(Format.Percent(99.95) != "100%" && Format.Percent(99.9999) != "100%",
            "rounding must never manufacture a full quota");
        Assert(Format.Percent(0.01) == "<0.1%", "small positive remaining quota must not be presented as exhausted");
        foreach (var invalid in new double?[] { null, -0.1, 100.1, double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            Assert(Format.Percent(invalid) == "--%", "invalid percentages must remain unknown");

        // Claude OAuth's utilization uses percentage points, even below one.
        var smallUtilization = CLIOAuthUsageService.ParseClaudeOAuthUsage("""{"five_hour":{"utilization":0.95}}""", Now);
        Close(smallUtilization?.Primary.LeftPercent, 99.05, "OAuth percentage must never be mistaken for a utilization fraction");
    }

    private static void CheckWindowsAndSchemas()
    {
        Assert(CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":5,"window_minutes":10080},"secondary":{"used_percent":95,"window_minutes":10080}}""", Now) == null,
            "duplicate quota durations must not silently discard a more constrained reading");
        foreach (var invalid in new[] { "-5", "101", "\"NaN\"", "\"Infinity\"", "true", "null" })
        {
            Assert(CLIOAuthUsageService.ParseCodexWhamUsage("{\"primary\":{\"used_percent\":" + invalid + "}}", Now) == null,
                "invalid used percentages must not be clamped into a full or empty quota");
            Assert(CLIOAuthUsageService.ParseCodexWhamUsage("{\"primary\":{\"remaining_percent\":" + invalid + "}}", Now) == null,
                "invalid remaining percentages must not be clamped into a full or empty quota");
            Assert(CLIOAuthUsageService.ParseClaudeOAuthUsage("{\"five_hour\":{\"utilization\":" + invalid + "}}", Now) == null,
                "invalid Claude utilization must remain unknown");
        }
        Assert(CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":-5,"remaining_percent":95}}""", Now) == null,
            "an invalid supplied used percentage must not be silently replaced by another field");

        var reversed = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limit":{"primary_window":{"used_percent":10,"window_minutes":10080},"secondary_window":{"used_percent":5,"window_minutes":300}}}""", Now);
        Assert(reversed?.Primary.WindowMinutes == 300 && reversed.Secondary?.WindowMinutes == 10080,
            "duration metadata must determine 5h and weekly roles");
        var reversedSnapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, reversed!, Now, "synthetic", "synthetic");
        Close(reversedSnapshot.Percent, 95, "reversed windows should preserve 5h percentage");
        Close(reversedSnapshot.Weekly?.PercentLeft, 90, "reversed windows should preserve weekly percentage");

        var weeklyOnly = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800}}}""", Now);
        var weeklySnapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, weeklyOnly!, Now, "synthetic", "synthetic");
        Assert(weeklySnapshot.PrimaryWindowLabel == "1W" && weeklySnapshot.Weekly == null,
            "weekly-only quota must not invent a 5h window or duplicate weekly quota");
        var weeklyOnlyNull = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800},"secondary_window":null}}""", Now);
        var weeklyNullSnapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, weeklyOnlyNull!, Now, "synthetic", "synthetic");
        Assert(weeklyNullSnapshot.Status == UsageStatus.Ok && weeklyNullSnapshot.Weekly == null && weeklyNullSnapshot.PrimaryWindowLabel == "1W",
            "an explicitly absent secondary window on a weekly-only plan must stay distinct from malformed quota");
        var secondaryOnly = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limits":{"primary":null,"secondary":{"percent_left":95.1,"window_minutes":10080}}}""", Now);
        Assert(secondaryOnly?.Primary.WindowMinutes == 10080 && secondaryOnly.Secondary == null,
            "a missing primary window must not become 100% remaining");
        var claudeWeeklyOnly = CLIOAuthUsageService.ParseClaudeOAuthUsage("""{"five_hour":null,"seven_day":{"utilization":5}}""", Now);
        Assert(claudeWeeklyOnly?.Primary.WindowMinutes == 10080 && claudeWeeklyOnly.Secondary == null,
            "missing Claude 5h must retain the actual weekly window label");

        var nonWeekly = CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":5,"window_minutes":300},"secondary":{"used_percent":20,"window_minutes":1440}}""", Now);
        var nonWeeklySnapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, nonWeekly!, Now, "synthetic", "synthetic");
        Assert(nonWeeklySnapshot.Weekly?.PercentLeft == null && nonWeeklySnapshot.Status == UsageStatus.Unknown,
            "a secondary slot with a one-day duration must not establish a reported weekly quota");
        var noDuration = CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":5},"secondary":{"used_percent":20}}""", Now);
        var noDurationSnapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, noDuration!, Now, "synthetic", "synthetic");
        Assert(noDurationSnapshot.PrimaryWindowLabel == "LIMIT" && noDurationSnapshot.Weekly?.PercentLeft == null && noDurationSnapshot.Status == UsageStatus.Unknown,
            "missing duration metadata must not fabricate 5h or known weekly percentages");

        var unknownSecondary = CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":5},"secondary":{"used_percent":"NaN","window_minutes":10080}}""", Now);
        Assert(unknownSecondary?.HasUnknownSecondary == true &&
            CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, unknownSecondary!, Now, "synthetic", "synthetic").Status == UsageStatus.Unknown,
            "an explicitly invalid secondary must not disappear into an unconstrained Ready status");
        var fiveHourOnly = CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":5,"window_minutes":300}}""", Now);
        var fiveHourSnapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, fiveHourOnly!, Now, "synthetic", "synthetic");
        Assert(fiveHourSnapshot.Weekly is { PercentLeft: null } && fiveHourSnapshot.Status == UsageStatus.Unknown,
            "a missing weekly quota must remain explicitly unknown beside a reported 5h quota");

        var preferred = CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limits":{"unrelated":true},"rate_limit":{"primary_window":{"used_percent":5,"window_minutes":300}}}""", Now);
        Close(preferred?.Primary.LeftPercent, 95, "general rate_limit must survive another rate_limits container");
        Assert(CLIOAuthUsageService.ParseCodexWhamUsage("""{"limit_id":"chatgpt","primary":{"used_percent":5,"window_minutes":300}}""", Now) == null,
            "ChatGPT-named quota must never masquerade as Codex quota");
        Assert(CLIOAuthUsageService.ParseCodexWhamUsage("""{"rate_limit":{"limit_id":"named-model","primary":{"used_percent":5}}}""", Now) == null,
            "named model quota must never masquerade as the Codex general quota");
        Assert(CLIOAuthUsageService.ParseCodexWhamUsage("""{"credits":{"balance":95},"api_usage":{"used_percent":5},"chatgpt":{"remaining_percent":95}}""", Now) == null,
            "credits, API billing and ChatGPT quota do not establish Codex subscription quota");
        foreach (var json in new[] { "{}", "[]", "null", "{", "\"unavailable\"" })
        {
            Assert(CLIOAuthUsageService.ParseCodexWhamUsage(json, Now) == null, "missing or malformed Codex quota stays unknown");
            Assert(CLIOAuthUsageService.ParseClaudeOAuthUsage(json, Now) == null, "missing or malformed Claude quota stays unknown");
        }
    }

    private static void CheckExpiredWindows()
    {
        foreach (var used in new[] { 5.0, 5.1, 4.9, 1.0, 0.5, 0.0 })
        {
            var reading = new OfficialUsageReading(new OfficialRateWindow(used, Now.AddSeconds(-1), 300),
                new OfficialRateWindow(10, Now.AddDays(1), 10080), null);
            var snapshot = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, reading, Now, "synthetic", "synthetic");
            Assert(snapshot.Percent == null && snapshot.Used == null && snapshot.PercentDisplay == "--%" && snapshot.Status == UsageStatus.Unknown,
                "an elapsed reset must invalidate the old primary percentage, never infer 100%");
            Close(snapshot.Weekly?.PercentLeft, 90, "a still-current weekly window remains available");
        }
        var expiredWeekly = new OfficialUsageReading(new OfficialRateWindow(5, Now.AddHours(1), 300),
            new OfficialRateWindow(5, Now, 10080), null);
        var partial = CLIOAuthUsageService.MakeSnapshot(UsageProvider.Claude, expiredWeekly, Now, "synthetic", "synthetic");
        Assert(partial.Weekly?.PercentLeft == null && partial.Status == UsageStatus.Unknown,
            "an expired weekly window remains unknown at the exact reset boundary");
        Close(partial.Percent, 95, "a current primary window must retain its reported decimal");
        var invalid = new OfficialUsageReading(new OfficialRateWindow(-5, null, 300), null, null);
        Assert(CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, invalid, Now, "synthetic", "synthetic").Percent == null,
            "direct invalid readings must not manufacture 100% remaining either");
        var resetNow = CLIOAuthUsageService.ParseCodexWhamUsage("""{"primary":{"used_percent":5,"window_minutes":300,"reset_after_seconds":0}}""", Now);
        Assert(resetNow?.Primary.ResetsAt == Now &&
            CLIOAuthUsageService.MakeSnapshot(UsageProvider.Codex, resetNow!, Now, "synthetic", "synthetic").Percent == null,
            "zero seconds until reset is an elapsed window, not an unspecified future reset");
    }

    private static async Task CheckTransportFailures()
    {
        var home = Path.Combine(Path.GetTempPath(), "UsageKunOAuthSynthetic-" + Guid.NewGuid());
        Directory.CreateDirectory(Path.Combine(home, ".codex"));
        Directory.CreateDirectory(Path.Combine(home, ".claude"));
        try
        {
            var codexPath = Path.Combine(home, ".codex", "auth.json");
            var claudePath = Path.Combine(home, ".claude", ".credentials.json");
            const string codexSignIn = """{"tokens":{"access_token":"synthetic-token","account_id":"synthetic-account"}}""";
            const string claudeSignIn = """{"claudeAiOauth":{"accessToken":"synthetic-token","expiresAt":9999999999999}}""";
            await File.WriteAllTextAsync(codexPath, codexSignIn);
            await File.WriteAllTextAsync(claudePath, claudeSignIn);
            using var handler = new SyntheticHandler();
            using var client = new HttpClient(handler);
            var service = new CLIOAuthUsageService(home, client);
            foreach (var provider in new[] { UsageProvider.Codex, UsageProvider.Claude })
            {
                handler.Status = HttpStatusCode.OK;
                handler.Body = provider == UsageProvider.Codex
                    ? """{"rate_limit":{"primary_window":{"used_percent":5.1,"window_minutes":300}}}"""
                    : """{"five_hour":{"utilization":5.1}}""";
                var success = await service.SnapshotAsync(provider, Now);
                Close(success.Snapshot?.Percent, 94.9, "successful HTTP fixture must preserve fractional quota");
                foreach (var status in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.Forbidden, HttpStatusCode.TooManyRequests, HttpStatusCode.InternalServerError })
                {
                    handler.Status = status;
                    handler.Body = "synthetic-private-diagnostic";
                    var result = await service.SnapshotAsync(provider, Now);
                    Assert(result.Snapshot == null && result.FailureReason != null && !result.FailureReason.Contains("synthetic-private"),
                        "failure after success must give sanitized unknown data instead of cached or fabricated full quota");
                }
                handler.Status = HttpStatusCode.OK;
                var malformed = await service.SnapshotAsync(provider, Now);
                Assert(malformed.Snapshot == null, "unknown successful HTTP payload must not become 100%");
            }
            // Switching an existing Codex account must use the current sign-in
            // for this request, never reuse the previous account's usage value.
            const string switchedSignIn = """{"tokens":{"access_token":"synthetic-token-two","account_id":"synthetic-account-two"}}""";
            await File.WriteAllTextAsync(codexPath, switchedSignIn);
            handler.Status = HttpStatusCode.OK;
            handler.Body = """{"rate_limit":{"primary_window":{"used_percent":0.5,"window_minutes":300}}}""";
            var switched = await service.SnapshotAsync(UsageProvider.Codex, Now);
            Close(switched.Snapshot?.Percent, 99.5, "account switch must use the new HTTP reading");
            Assert(handler.LastAccount == "synthetic-account-two" && handler.LastToken == "synthetic-token-two",
                "account switch must use only the current sign-in headers");
            var count = handler.Count;
            Assert((await service.SnapshotAsync(UsageProvider.Antigravity, Now)).Snapshot == null && handler.Count == count,
                "unrelated provider must never use Codex or Claude OAuth credentials");
            Assert(await File.ReadAllTextAsync(codexPath) == switchedSignIn && await File.ReadAllTextAsync(claudePath) == claudeSignIn,
                "usage sync must never rewrite sign-in fixtures");
        }
        finally { Directory.Delete(home, recursive: true); }
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("OAuth quota check failed: " + message);
    }

    private static void Close(double? actual, double expected, string message) =>
        Assert(actual is { } value && Math.Abs(value - expected) < 0.000001, message);

    private sealed class SyntheticHandler : HttpMessageHandler
    {
        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        public string Body { get; set; } = "synthetic-private-diagnostic";
        public string? LastAccount { get; private set; }
        public string? LastToken { get; private set; }
        public int Count { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Count++;
            LastAccount = request.Headers.TryGetValues("ChatGPT-Account-Id", out var accounts) ? accounts.Single() : null;
            LastToken = request.Headers.Authorization?.Parameter;
            return Task.FromResult(new HttpResponseMessage(Status) { Content = new StringContent(Body) });
        }
    }
}
