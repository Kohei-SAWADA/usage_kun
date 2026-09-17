using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace UsageKun.Core;

/// Port of the macOS LocalLogUsageService. Reads known Claude Code and Codex
/// local logs under the user profile and aggregates them into UsageSnapshots.
///
/// Codex quota comes from the newest General rate-limit reading across session
/// JSONL and the live logs_2.sqlite database. SQLite is bundled with the Windows
/// app and opened read-only; no external sqlite3 installation is required.
public sealed class LocalLogUsageService : IUsageService
{
    private readonly string _home;
    private readonly ClaudeCalibrationStore _calibrationStore;
    private double? _lastClaudeBlockWeightedUsed;
    private DateTimeOffset? _lastClaudeBlockComputedAt;
    private string? _lastClaudePlanKey;

    /// "auto" resolves the plan from ~/.claude.json; "pro", "max_5x", and
    /// "max_20x" force that plan's cap for the local estimate.
    public string ClaudePlanOverride { get; set; } = "auto";

    public LocalLogUsageService(string? home = null, ClaudeCalibrationStore? calibrationStore = null)
    {
        _home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _calibrationStore = calibrationStore ?? new ClaudeCalibrationStore();
    }

    public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now) =>
        SnapshotsAsync(now, codexEnabled: true, claudeEnabled: true);

    public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now, bool codexEnabled, bool claudeEnabled)
    {
        var snapshots = new List<UsageSnapshot>();
        if (codexEnabled) snapshots.Add(CodexSnapshot(now));
        if (claudeEnabled) snapshots.Add(ClaudeSnapshot(now));
        return Task.FromResult<IReadOnlyList<UsageSnapshot>>(snapshots);
    }

    /// Feeds one official used% sample into the Claude cap calibration.
    /// Called after opt-in official Claude sync, using the matching local block.
    public void RecordClaudeOfficialSample(double usedPercent, DateTimeOffset now)
    {
        if (_lastClaudeBlockWeightedUsed is not { } weighted ||
            _lastClaudeBlockComputedAt is not { } computedAt ||
            _lastClaudePlanKey is not { } planKey ||
            weighted <= 200_000 ||
            usedPercent < 10 ||
            (now - computedAt).TotalSeconds >= 600)
        {
            return;
        }

        var sample = weighted / (usedPercent / 100);
        if (sample <= 500_000 || sample >= 500_000_000)
        {
            return;
        }

        ClaudeCalibration next;
        if (_calibrationStore.Load() is { } existing && existing.PlanKey == planKey)
        {
            existing.CapEstimate = existing.CapEstimate * 0.7 + sample * 0.3;
            existing.SampleCount += 1;
            existing.UpdatedAt = now;
            next = existing;
        }
        else
        {
            next = new ClaudeCalibration
            {
                CapEstimate = sample,
                SampleCount = 1,
                PlanKey = planKey,
                UpdatedAt = now
            };
        }

        try
        {
            _calibrationStore.Save(next);
        }
        catch
        {
            // Calibration is best-effort; the plan default keeps working.
        }
    }

    public static double ClaudeCostEstimateUsd(
        string? model,
        double input,
        double output,
        double cacheWrite,
        double cacheWrite5m,
        double cacheWrite1h,
        double cacheRead)
    {
        var usage = new ClaudeTokenUsage(input, output, cacheWrite, cacheRead, cacheWrite5m, cacheWrite1h);
        return ClaudePricing.EstimateUsd(model, usage);
    }

    // MARK: - Codex

    private UsageSnapshot CodexSnapshot(DateTimeOffset now)
    {
        if (LatestCodexRateLimit() is { } rateLimit)
        {
            var primary = rateLimit.Primary;
            var secondary = rateLimit.Secondary;
            // If the recorded 5h window already expired, Codex has reset the limit
            // but no new rate_limits event has arrived yet. Show a fresh window
            // instead of continuing to display the stale used % and a "0m" reset.
            var primaryExpired = primary.ResetsAt is { } primaryReset && primaryReset <= now;
            var leftPercent = primaryExpired ? 100 : primary.LeftPercent;
            var resetAt = primaryExpired ? null : primary.ResetsAt;
            var resetText = primaryExpired
                ? "fresh"
                : resetAt is { } value ? Format.WidgetReset(value, now) : "--";

            UsageWindow? weekly = null;
            if (secondary != null)
            {
                var secondaryExpired = secondary.ResetsAt is { } secondaryReset && secondaryReset <= now;
                var secondaryLeft = secondaryExpired
                    ? 100
                    : (int)Math.Round(secondary.LeftPercent, MidpointRounding.AwayFromZero);
                weekly = new UsageWindow(secondaryLeft, secondaryExpired ? null : secondary.ResetsAt);
            }

            var rawUsedPercent = primaryExpired
                ? 0
                : (int)Math.Round(primary.UsedPercent, MidpointRounding.AwayFromZero);
            var message = primaryExpired
                ? "Usage window reset. Waiting for the next Codex call to refresh the live limit."
                : $"Showing remaining quota from General usage limits. Raw used value is {rawUsedPercent}%.";
            // The logged value only updates while Codex is running, so flag stale data:
            // the real used % can only have decayed since it was recorded.
            var ageMinutes = (int)((now - rateLimit.UpdatedAt).TotalSeconds / 60);
            if (!primaryExpired && ageMinutes >= 30)
            {
                var ageText = ageMinutes >= 60 ? $"{ageMinutes / 60}h {ageMinutes % 60}m" : $"{ageMinutes}m";
                message += $" Recorded {ageText} ago; actual usage may be lower.";
            }

            return new UsageSnapshot
            {
                Provider = UsageProvider.Codex,
                Status = UsageStatusRules.Status(leftPercent, weekly?.PercentLeft),
                Used = leftPercent,
                Limit = null,
                Percent = leftPercent,
                ResetAt = resetAt,
                UpdatedAt = rateLimit.UpdatedAt,
                Message = message,
                Source = rateLimit.Source,
                Unit = "%",
                MetricTitle = "Usage left",
                SecondaryTitle = "Reset",
                SecondaryValue = resetText,
                Weekly = weekly,
                PrimaryWindowMinutes = primary.WindowMinutes
            };
        }

        return new UsageSnapshot
        {
            Provider = UsageProvider.Codex,
            Status = UsageStatus.Unknown,
            Used = null,
            Limit = null,
            Percent = null,
            ResetAt = null,
            UpdatedAt = now,
            Message = "No Codex rate-limit logs found in this Windows profile. Start a Windows Codex conversation or enable official CLI sync in Settings.",
            Source = "local ~/.codex",
            Unit = null,
            MetricTitle = "Usage limit",
            SecondaryTitle = "Reset"
        };
    }

    private CodexRateLimitSnapshot? LatestCodexRateLimit()
    {
        var latest = LatestCodexLiveRateLimit();
        var sessions = Path.Combine(_home, ".codex", "sessions");
        if (!Directory.Exists(sessions))
        {
            return latest;
        }

        var files = JsonlFiles(sessions)
            .OrderByDescending(FileModificationDate)
            .Take(50);

        foreach (var file in files)
        {
            ReadCodexRateLimits(file, snapshot =>
            {
                if (latest == null || snapshot.UpdatedAt > latest.UpdatedAt)
                {
                    latest = snapshot;
                }
            });
        }

        return latest;
    }

    private CodexRateLimitSnapshot? LatestCodexLiveRateLimit()
    {
        var database = Path.Combine(_home, ".codex", "logs_2.sqlite");
        if (!File.Exists(database)) return null;

        try
        {
            using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = database,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
                DefaultTimeout = 1
            }.ToString());
            connection.Open();
            using var command = connection.CreateCommand();
            // Match the macOS source and exclude response/tool content before
            // reading any bodies. Never execute SQL or JSON supplied by a log.
            command.CommandText = """
                SELECT ts, ts_nanos, feedback_log_body
                FROM logs
                WHERE target = 'codex_api::endpoint::responses_websocket'
                  AND feedback_log_body LIKE '%responses_websocket.stream_request%'
                  AND feedback_log_body LIKE '%websocket event: {"type":"codex.rate_limits"%'
                  AND feedback_log_body NOT LIKE '%response.output_item%'
                  AND feedback_log_body NOT LIKE '%function_call%'
                  AND feedback_log_body NOT LIKE '%ToolCall%'
                  AND length(feedback_log_body) <= 1048576
                ORDER BY ts DESC, ts_nanos DESC;
                """;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                try
                {
                    if (reader.IsDBNull(0) || reader.IsDBNull(1) || reader.IsDBNull(2)) continue;
                    var seconds = reader.GetInt64(0);
                    var nanos = reader.GetInt64(1);
                    if (seconds <= 0 || nanos is < 0 or >= 1_000_000_000) continue;
                    var updatedAt = DateTimeOffset.FromUnixTimeSeconds(seconds).AddTicks(nanos / 100);
                    var body = reader.GetString(2);
                    const string marker = "websocket event: ";
                    var start = body.IndexOf(marker, StringComparison.Ordinal);
                    if (start < 0) continue;
                    var jsonReader = new Utf8JsonReader(Encoding.UTF8.GetBytes(body[(start + marker.Length)..]));
                    // Parse one object so tracing metadata after the event is allowed.
                    using var document = JsonDocument.ParseValue(ref jsonReader);
                    var root = document.RootElement;
                    if (GetString(root, "type") != "codex.rate_limits" ||
                        !IsGeneralCodexLimit(GetString(root, "metered_limit_name") ?? GetString(root, "limit_name")))
                        continue;
                    var limits = JsonValue.Property(root, "rate_limits");
                    if (!IsGeneralCodexLimit(GetString(limits, "limit_id")) ||
                        CLIOAuthUsageService.ParseCodexWindows(limits, updatedAt) is not { } reading)
                        continue;
                    return CodexSnapshotFromReading(reading, updatedAt, "Codex live rate limits");
                }
                catch (JsonException) { /* Ignore malformed or partially written events. */ }
                catch (ArgumentOutOfRangeException) { /* Ignore invalid event timestamps. */ }
                catch (InvalidCastException) { /* Ignore rows that do not match the log schema. */ }
                catch (FormatException) { /* Ignore invalid timestamp columns. */ }
                catch (OverflowException) { /* Ignore out-of-range timestamp columns. */ }
            }
        }
        catch (SqliteException) { /* Missing schema, corrupt, busy, or unreadable: use session logs. */ }
        catch (IOException) { /* Codex may rotate the database during a refresh. */ }
        catch (UnauthorizedAccessException) { /* Keep session fallback when access is denied. */ }
        return null;
    }

    // Codex's default quota bucket is "codex"; older logs omit the identifier.
    // Named model buckets must never overwrite the General usage card.
    private static bool IsGeneralCodexLimit(string? limitId) =>
        string.IsNullOrWhiteSpace(limitId) || limitId.Trim().Equals("codex", StringComparison.OrdinalIgnoreCase);

    private static CodexRateLimitSnapshot CodexSnapshotFromReading(OfficialUsageReading reading,
        DateTimeOffset updatedAt, string source) => new(updatedAt,
        new CodexRateLimit(reading.Primary.UsedPercent, reading.Primary.WindowMinutes, reading.Primary.ResetsAt),
        reading.Secondary is { } secondary
            ? new CodexRateLimit(secondary.UsedPercent, secondary.WindowMinutes, secondary.ResetsAt) : null,
        source);

    private static void ReadCodexRateLimits(string file, Action<CodexRateLimitSnapshot> onSnapshot)
    {
        IEnumerable<string> lines;
        try
        {
            lines = File.ReadLines(file);
        }
        catch
        {
            return;
        }

        foreach (var line in lines)
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;

                if (root.ValueKind != JsonValueKind.Object ||
                    !root.TryGetProperty("payload", out var payload) ||
                    payload.ValueKind != JsonValueKind.Object ||
                    GetString(payload, "type") != "token_count" ||
                    !payload.TryGetProperty("rate_limits", out var rateLimits) ||
                    rateLimits.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                if (!IsGeneralCodexLimit(GetString(rateLimits, "limit_id"))) continue;
                var updatedAt = ParseDate(GetString(root, "timestamp")) ?? FileModificationDate(file);
                if (CLIOAuthUsageService.ParseCodexWindows(rateLimits, updatedAt) is not { } reading) continue;
                onSnapshot(CodexSnapshotFromReading(reading, updatedAt, "Codex session rate limits"));
            }
            catch (JsonException)
            {
                // Skip malformed lines; session files can be mid-write.
            }
        }
    }

    // MARK: - Claude

    private UsageSnapshot ClaudeSnapshot(DateTimeOffset now)
    {
        var projects = Path.Combine(_home, ".claude", "projects");
        if (!Directory.Exists(projects))
        {
            ClearLastClaudeBlock();
            return new UsageSnapshot
            {
                Provider = UsageProvider.Claude,
                Status = UsageStatus.Unknown,
                Used = null,
                Limit = null,
                Percent = null,
                ResetAt = null,
                UpdatedAt = now,
                Message = @"%USERPROFILE%\.claude\projects was not found. Sign in and use Claude Code to sync local usage.",
                Source = "local",
                Unit = "tok",
                MetricTitle = "5 hour left",
                SecondaryTitle = "Reset"
            };
        }

        var stats = new ClaudeLogStats();
        var dayStart = StartOfDay(now);
        var weekStart = StartOfWeek(now);

        foreach (var file in JsonlFiles(projects))
        {
            ReadClaudeJsonl(file, dayStart, weekStart, stats);
        }

        if (stats.UsageEntries == 0)
        {
            ClearLastClaudeBlock();
            return new UsageSnapshot
            {
                Provider = UsageProvider.Claude,
                Status = UsageStatus.Unknown,
                Used = null,
                Limit = null,
                Percent = null,
                ResetAt = null,
                UpdatedAt = now,
                Message = "No Claude usage rows found yet. usage_kun checks Claude Code conversation logs.",
                Source = "local ~/.claude",
                Unit = "tok",
                MetricTitle = "5 hour left",
                SecondaryTitle = "Reset"
            };
        }

        var blocks = BuildClaudeBlocks(stats.Events);
        var activeBlock = blocks.FirstOrDefault(block => now >= block.StartTime && now < block.EndTime);
        var (planCap, planLabel, planKey) = ClaudePlanCap();
        var usedWeighted = activeBlock?.Weighted ?? 0;
        var usedTokens = activeBlock?.Tokens ?? 0;
        var leftPercent = Math.Max(0, Math.Min(100, 100 - usedWeighted / planCap * 100));
        var resetAt = activeBlock?.EndTime;
        _lastClaudeBlockWeightedUsed = usedWeighted;
        _lastClaudeBlockComputedAt = now;
        _lastClaudePlanKey = planKey;

        var costText = stats.TodayEstimatedCost > 0
            ? " est. " + stats.TodayEstimatedCost.ToString("$0.00", CultureInfo.InvariantCulture)
            : "";
        var resetText = resetAt is { } reset ? Format.RelativeReset(reset, now) : "--";
        var weekly = new UsageWindow(null, null, $"{Format.Compact(stats.WeekTokens)} tok this week");

        var message =
            $"{planLabel} plan, 5h block: {Format.Compact(usedWeighted)} weighted tok of {Format.Compact(planCap)} (raw {Format.Compact(usedTokens)} tok). " +
            $"Today: {stats.TodaySessions.Count} sessions{costText}.";

        return new UsageSnapshot
        {
            Provider = UsageProvider.Claude,
            Status = UsageStatusRules.Status(leftPercent, weekly.PercentLeft),
            Used = leftPercent,
            Limit = null,
            Percent = leftPercent,
            ResetAt = resetAt,
            UpdatedAt = stats.LastUpdated ?? now,
            Message = message,
            Source = "local ~/.claude",
            Unit = "%",
            MetricTitle = "5 hour left",
            SecondaryTitle = "Reset",
            SecondaryValue = resetText,
            Weekly = weekly
        };
    }

    private void ClearLastClaudeBlock()
    {
        _lastClaudeBlockWeightedUsed = null;
        _lastClaudeBlockComputedAt = null;
        _lastClaudePlanKey = null;
    }

    internal static readonly TimeSpan ClaudeBlockDuration = TimeSpan.FromHours(5);

    internal static List<ClaudeBlock> BuildClaudeBlocks(IEnumerable<ClaudeUsageEvent> events)
    {
        var sorted = events.OrderBy(usageEvent => usageEvent.Timestamp);
        var blocks = new List<ClaudeBlock>();

        foreach (var usageEvent in sorted)
        {
            if (blocks.Count > 0)
            {
                var last = blocks[^1];
                var gap = usageEvent.Timestamp - last.LastActivity;
                var pastEnd = usageEvent.Timestamp >= last.EndTime;
                if (gap < ClaudeBlockDuration && !pastEnd)
                {
                    last.Tokens += usageEvent.Tokens;
                    last.Weighted += usageEvent.Weighted;
                    last.LastActivity = usageEvent.Timestamp;
                    continue;
                }
            }

            var start = RoundedDownToHour(usageEvent.Timestamp);
            blocks.Add(new ClaudeBlock
            {
                StartTime = start,
                EndTime = start + ClaudeBlockDuration,
                Tokens = usageEvent.Tokens,
                Weighted = usageEvent.Weighted,
                LastActivity = usageEvent.Timestamp
            });
        }

        return blocks;
    }

    private (double Cap, string Label, string Key) ClaudePlanCap()
    {
        string? organizationType = null;
        var rateLimitTiers = new List<string>();
        var path = Path.Combine(_home, ".claude.json");

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("oauthAccount", out var oauth) &&
                oauth.ValueKind == JsonValueKind.Object)
            {
                organizationType = GetString(oauth, "organizationType");
                foreach (var key in new[] { "userRateLimitTier", "organizationRateLimitTier" })
                {
                    if (GetString(oauth, key) is { Length: > 0 } tier)
                    {
                        rateLimitTiers.Add(tier);
                    }
                }
            }
        }
        catch
        {
            // Missing or unreadable ~/.claude.json falls back to the estimated plan.
        }

        var resolution = ResolveClaudePlan(organizationType, rateLimitTiers, ClaudePlanOverride);

        if (_calibrationStore.Load() is { } calibration && calibration.PlanKey == resolution.Key)
        {
            return (calibration.CapEstimate, $"{resolution.Label} (calibrated)", resolution.Key);
        }

        return (resolution.Cap, resolution.Label, resolution.Key);
    }

    /// Maps the account fields in ~/.claude.json to a 5-hour cap estimate.
    /// organizationType is plain "claude_max" for both Max tiers; the 5x/20x
    /// distinction only appears in the rate-limit tier strings
    /// (e.g. "default_claude_max_20x"), so both must be considered.
    public static ClaudePlanResolution ResolveClaudePlan(
        string? organizationType,
        IReadOnlyList<string> rateLimitTiers,
        string overrideKey)
    {
        switch (overrideKey)
        {
            case "pro":
                return new ClaudePlanResolution(ClaudePlanCaps.Pro, "Pro (manual)", "claude_pro");
            case "max_5x":
                return new ClaudePlanResolution(ClaudePlanCaps.Max5x, "Max 5x (manual)", "claude_max_5x");
            case "max_20x":
                return new ClaudePlanResolution(ClaudePlanCaps.Max20x, "Max 20x (manual)", "claude_max_20x");
        }

        var orgType = (organizationType ?? "").ToLowerInvariant();
        var tierText = string.Join(" ", rateLimitTiers).ToLowerInvariant();

        if (orgType.Contains("max") || tierText.Contains("max"))
        {
            if (orgType.Contains("20x") || tierText.Contains("20x"))
            {
                return new ClaudePlanResolution(ClaudePlanCaps.Max20x, "Max 20x", "claude_max_20x");
            }

            if (orgType.Contains("5x") || tierText.Contains("5x"))
            {
                return new ClaudePlanResolution(ClaudePlanCaps.Max5x, "Max 5x", "claude_max_5x");
            }

            return new ClaudePlanResolution(ClaudePlanCaps.Max5x, "Max", "claude_max");
        }

        if (orgType.Contains("pro"))
        {
            return new ClaudePlanResolution(ClaudePlanCaps.Pro, "Pro", "claude_pro");
        }

        if (orgType.Contains("team") || orgType.Contains("enterprise"))
        {
            // No public per-seat cap; start from the Pro cap and let official
            // sync calibration adjust it.
            var label = orgType.Contains("team") ? "Team (estimated)" : "Enterprise (estimated)";
            return new ClaudePlanResolution(ClaudePlanCaps.Pro, label, orgType);
        }

        return new ClaudePlanResolution(ClaudePlanCaps.Pro, "estimated", "estimated");
    }

    private void ReadClaudeJsonl(
        string file,
        DateTimeOffset dayStart,
        DateTimeOffset weekStart,
        ClaudeLogStats stats)
    {
        IEnumerable<string> lines;
        try
        {
            lines = File.ReadLines(file);
        }
        catch
        {
            return;
        }

        foreach (var line in lines)
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;

                if (root.ValueKind != JsonValueKind.Object ||
                    !root.TryGetProperty("message", out var message) ||
                    message.ValueKind != JsonValueKind.Object ||
                    !message.TryGetProperty("usage", out var usage) ||
                    usage.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var timestamp = ParseDate(GetString(root, "timestamp"));
                var eventDate = timestamp ?? DateTimeOffset.MinValue;
                var tokenUsage = ClaudeTokenUsage.FromJson(usage);
                var tokens = tokenUsage.Total;
                if (tokens <= 0)
                {
                    continue;
                }

                var messageId = GetString(message, "id");
                var requestId = GetString(root, "requestId");
                if (messageId != null && requestId != null &&
                    !stats.SeenRequestKeys.Add($"{requestId}:{messageId}"))
                {
                    continue;
                }

                var model = GetString(message, "model");
                var sessionId = GetString(root, "sessionId");
                stats.UsageEntries += 1;
                stats.LastUpdated = stats.LastUpdated is { } previous && previous > eventDate
                    ? previous
                    : eventDate;

                if (timestamp is { } eventTimestamp)
                {
                    stats.Events.Add(new ClaudeUsageEvent(eventTimestamp, tokens, tokenUsage.Weighted));
                }

                if (eventDate >= weekStart)
                {
                    stats.WeekTokens += tokens;
                    if (sessionId != null)
                    {
                        stats.WeekSessions.Add(sessionId);
                    }
                }

                if (eventDate >= dayStart)
                {
                    stats.TodayTokens += tokens;
                    stats.TodayEstimatedCost += ClaudePricing.EstimateUsd(model, tokenUsage);
                    if (sessionId != null)
                    {
                        stats.TodaySessions.Add(sessionId);
                    }
                }
            }
            catch (JsonException)
            {
                // Skip malformed lines; log files can be mid-write.
            }
        }
    }

    // MARK: - Shared helpers

    private static IEnumerable<string> JsonlFiles(string directory)
    {
        try
        {
            return Directory.EnumerateFiles(directory, "*.jsonl", new EnumerationOptions
            {
                RecurseSubdirectories = true,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.Hidden | FileAttributes.System
            }).ToList();
        }
        catch
        {
            return [];
        }
    }

    public static DateTimeOffset RoundedDownToHour(DateTimeOffset date)
    {
        var local = date.ToLocalTime();
        return new DateTimeOffset(local.Year, local.Month, local.Day, local.Hour, 0, 0, local.Offset);
    }

    private static DateTimeOffset StartOfDay(DateTimeOffset date)
    {
        var local = date.ToLocalTime();
        return new DateTimeOffset(local.Year, local.Month, local.Day, 0, 0, 0, local.Offset);
    }

    private static DateTimeOffset StartOfWeek(DateTimeOffset date)
    {
        var startOfDay = StartOfDay(date);
        var firstDayOfWeek = CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
        var daysBack = ((int)startOfDay.DayOfWeek - (int)firstDayOfWeek + 7) % 7;
        return startOfDay.AddDays(-daysBack);
    }

    internal static DateTimeOffset? ParseDate(string? value)
    {
        if (value == null)
        {
            return null;
        }

        return DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out var date)
            ? date
            : null;
    }

    private static DateTimeOffset FileModificationDate(string file)
    {
        try
        {
            return new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero);
        }
        catch
        {
            return DateTimeOffset.MinValue;
        }
    }

    internal static string? GetString(JsonElement element, string property) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    internal static double? FlexibleDouble(JsonElement element, string property)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(property, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.Number => value.GetDouble(),
            JsonValueKind.String when double.TryParse(
                value.GetString(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var parsed) => parsed,
            _ => null
        };
    }
}

internal sealed record CodexRateLimitSnapshot(
    DateTimeOffset UpdatedAt,
    CodexRateLimit Primary,
    CodexRateLimit? Secondary,
    string Source);

internal sealed record CodexRateLimit(double UsedPercent, int? WindowMinutes, DateTimeOffset? ResetsAt)
{
    public double LeftPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

internal sealed class ClaudeLogStats
{
    public int UsageEntries;
    public double TodayTokens;
    public double WeekTokens;
    public double TodayEstimatedCost;
    public HashSet<string> TodaySessions { get; } = [];
    public HashSet<string> WeekSessions { get; } = [];
    public DateTimeOffset? LastUpdated;
    public List<ClaudeUsageEvent> Events { get; } = [];
    public HashSet<string> SeenRequestKeys { get; } = [];
}

internal static class ClaudePlanCaps
{
    // Initial estimates for deduplicated Claude Code weighted tokens.
    public const double Pro = 2_000_000;
    public const double Max5x = 10_000_000;
    public const double Max20x = 40_000_000;
}

public sealed record ClaudePlanResolution(double Cap, string Label, string Key);

internal sealed record ClaudeUsageEvent(DateTimeOffset Timestamp, double Tokens, double Weighted);

internal sealed class ClaudeBlock
{
    public DateTimeOffset StartTime;
    public DateTimeOffset EndTime;
    public double Tokens;
    public double Weighted;
    public DateTimeOffset LastActivity;
}

internal readonly record struct ClaudeTokenUsage(
    double Input,
    double Output,
    double CacheCreation,
    double CacheRead,
    double CacheCreation5m,
    double CacheCreation1h)
{
    public static ClaudeTokenUsage FromJson(JsonElement usage)
    {
        var cacheCreation5m = 0.0;
        var cacheCreation1h = 0.0;
        if (usage.ValueKind == JsonValueKind.Object &&
            usage.TryGetProperty("cache_creation", out var cacheCreationObject) &&
            cacheCreationObject.ValueKind == JsonValueKind.Object)
        {
            cacheCreation5m = LocalLogUsageService.FlexibleDouble(cacheCreationObject, "ephemeral_5m_input_tokens") ?? 0;
            cacheCreation1h = LocalLogUsageService.FlexibleDouble(cacheCreationObject, "ephemeral_1h_input_tokens") ?? 0;
        }

        return new ClaudeTokenUsage(
            LocalLogUsageService.FlexibleDouble(usage, "input_tokens") ?? 0,
            LocalLogUsageService.FlexibleDouble(usage, "output_tokens") ?? 0,
            LocalLogUsageService.FlexibleDouble(usage, "cache_creation_input_tokens") ?? 0,
            LocalLogUsageService.FlexibleDouble(usage, "cache_read_input_tokens") ?? 0,
            cacheCreation5m,
            cacheCreation1h);
    }

    // cache_creation_input_tokens already equals ephemeral_5m + ephemeral_1h,
    // so do not add the breakdown again.
    public double Total => Input + Output + CacheCreation + CacheRead;

    // Approximates Claude Code's session usage metric.
    // Cache reads count at the same 10% rate as their pricing discount.
    public double Weighted => Input + Output + CacheCreation + CacheRead * 0.1;
}

internal static class ClaudePricing
{
    private readonly record struct Rate(
        double Input,
        double Output,
        double CacheWrite5m,
        double CacheWrite1h,
        double CacheRead);

    public static double EstimateUsd(string? model, ClaudeTokenUsage usage)
    {
        var rate = RateFor(model);
        const double million = 1_000_000.0;

        double write5m;
        double write1h;
        if (usage.CacheCreation5m > 0 || usage.CacheCreation1h > 0)
        {
            write5m = usage.CacheCreation5m;
            write1h = usage.CacheCreation1h;
        }
        else
        {
            write5m = usage.CacheCreation;
            write1h = 0;
        }

        return (usage.Input * rate.Input
            + usage.Output * rate.Output
            + write5m * rate.CacheWrite5m
            + write1h * rate.CacheWrite1h
            + usage.CacheRead * rate.CacheRead) / million;
    }

    private static Rate RateFor(string? model)
    {
        var normalized = (model ?? "").ToLowerInvariant();

        if (normalized.Contains("fable") || normalized.Contains("mythos"))
        {
            return new Rate(10, 50, 12.5, 20, 1.0);
        }

        if (normalized.Contains("opus-4-1") || normalized.Contains("opus-4-0") || normalized.Contains("claude-3-opus"))
        {
            return new Rate(15, 75, 18.75, 30, 1.5);
        }

        if (normalized.Contains("opus"))
        {
            return new Rate(5, 25, 6.25, 10, 0.5);
        }

        if (normalized.Contains("haiku"))
        {
            return new Rate(1, 5, 1.25, 2, 0.1);
        }

        return new Rate(3, 15, 3.75, 6, 0.3);
    }
}
