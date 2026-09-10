using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace UsageKun.Core;

public sealed record OfficialRateWindow(double UsedPercent, DateTimeOffset? ResetsAt, int? WindowMinutes)
{
    public double LeftPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

public sealed record OfficialUsageReading(OfficialRateWindow Primary, OfficialRateWindow? Secondary, string? PlanLabel);
public sealed record OfficialUsageResult(UsageSnapshot? Snapshot, string? FailureReason);

public interface IOfficialUsageService
{
    Task<OfficialUsageResult> SnapshotAsync(UsageProvider provider, DateTimeOffset now);
}

/// Uses an existing CLI sign-in only after the composite service's explicit opt-in.
/// Credentials stay in memory for one request: no refresh, persistence, or logging.
public sealed class CLIOAuthUsageService : IOfficialUsageService
{
    private readonly string _home;
    private readonly HttpClient _client;
    private static readonly HttpClient SharedClient = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false
    }) { Timeout = TimeSpan.FromSeconds(15) };

    public CLIOAuthUsageService(string? home = null, HttpClient? client = null)
    {
        _home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _client = client ?? SharedClient;
    }

    public async Task<OfficialUsageResult> SnapshotAsync(UsageProvider provider, DateTimeOffset now)
    {
        if (provider is not (UsageProvider.Codex or UsageProvider.Claude))
            return new(null, "This provider does not support CLI usage sync.");

        var claude = provider == UsageProvider.Claude;
        var name = claude ? "Claude Code" : "Codex";
        try
        {
            var path = Path.Combine(_home, claude ? ".claude" : ".codex", claude ? ".credentials.json" : "auth.json");
            if (!File.Exists(path) || new FileInfo(path).Length > 1_048_576)
                return new(null, $"{name} sign-in was not found in this Windows profile. Sign in with the Windows {name} CLI first.");

            using var credentials = JsonDocument.Parse(await File.ReadAllTextAsync(path));
            var tokenContainer = JsonValue.Property(credentials.RootElement, claude ? "claudeAiOauth" : "tokens");
            var token = JsonValue.String(tokenContainer, claude ? "accessToken" : "access_token");
            if (string.IsNullOrWhiteSpace(token))
                return new(null, $"{name} CLI sign-in was not found. Sign in with {name} in Windows first.");
            if (claude && JsonValue.Number(tokenContainer, "expiresAt") is { } expires && expires > 0 &&
                expires <= now.ToUnixTimeMilliseconds())
                return new(null, "Claude Code sign-in token has expired. Open Claude Code in Windows to refresh it.");

            using var request = new HttpRequestMessage(HttpMethod.Get, claude
                ? "https://api.anthropic.com/api/oauth/usage"
                : "https://chatgpt.com/backend-api/wham/usage");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            if (claude)
            {
                request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
                request.Headers.TryAddWithoutValidation("User-Agent", "claude-code/2.1.0 (external, cli)");
            }
            else
            {
                request.Headers.Add("Origin", "https://chatgpt.com");
                request.Headers.Referrer = new Uri("https://chatgpt.com/");
                if (JsonValue.String(tokenContainer, "account_id") is { Length: > 0 } account)
                    request.Headers.Add("ChatGPT-Account-Id", account);
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode)
            {
                var reason = response.StatusCode switch
                {
                    HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden =>
                        $"{name} rejected the sign-in (HTTP {(int)response.StatusCode}). Open the Windows {name} CLI and sign in again.",
                    HttpStatusCode.TooManyRequests => $"{name} usage is rate limited (HTTP 429). Wait before refreshing again.",
                    _ => $"{name} usage endpoint returned HTTP {(int)response.StatusCode}. Try again later."
                };
                return new(null, reason);
            }

            var body = await JsonValue.ReadBoundedAsync(response.Content, timeout.Token);
            var reading = claude ? ParseClaudeOAuthUsage(body, now) : ParseCodexWhamUsage(body, now);
            if (reading == null)
                return new(null, $"{name} returned an unrecognized usage format. Open the CLI usage screen, then refresh.");
            return new(MakeSnapshot(provider, reading, now, claude ? "Claude official usage API" : "Codex official usage API",
                claude ? "Official numbers, same as /usage in Claude Code." : "Official numbers, same as /status in Codex."), null);
        }
        catch (IOException)
        {
            return new(null, $"Could not read the Windows {name} sign-in. Open its CLI and sign in again.");
        }
        catch (UnauthorizedAccessException)
        {
            return new(null, $"Cannot read the Windows {name} sign-in in this user profile.");
        }
        catch (JsonException)
        {
            return new(null, $"{name} sign-in or usage data has an unexpected format. Open its CLI and sign in again.");
        }
        catch
        {
            // Never expose HTTP diagnostics, response bodies, headers, or credentials.
            return new(null, $"Could not reach the {name} usage endpoint. Check the network, then refresh.");
        }
    }

    public static UsageSnapshot MakeSnapshot(UsageProvider provider, OfficialUsageReading reading,
        DateTimeOffset now, string source, string detail)
    {
        var primary = reading.Primary;
        var weekly = reading.Secondary is { } secondary
            ? new UsageWindow(secondary.LeftPercent, secondary.ResetsAt) : null;
        return new UsageSnapshot
        {
            Provider = provider,
            Status = UsageStatusRules.Status(primary.LeftPercent, weekly?.PercentLeft),
            Used = primary.LeftPercent, Percent = primary.LeftPercent, ResetAt = primary.ResetsAt,
            UpdatedAt = now, Source = source, Unit = "%",
            MetricTitle = primary.WindowMinutes == 10080 ? "1 week left" : "Usage left",
            SecondaryValue = primary.ResetsAt is { } reset ? Format.WidgetReset(reset, now) : "--",
            Message = detail + (string.IsNullOrEmpty(reading.PlanLabel) ? "" : $" Plan: {reading.PlanLabel}."),
            Weekly = weekly, PrimaryWindowMinutes = primary.WindowMinutes
        };
    }

    public static OfficialUsageReading? ParseClaudeOAuthUsage(string json, DateTimeOffset now)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            OfficialRateWindow? Window(string key, int minutes)
            {
                var value = JsonValue.Property(root, key);
                return JsonValue.Number(value, "utilization") is { } used
                    ? new(Math.Clamp(used, 0, 100), JsonValue.Reset(JsonValue.Property(value, "resets_at"), now), minutes)
                    : null;
            }
            var primary = Window("five_hour", 300);
            var secondary = Window("seven_day", 10080);
            return primary == null ? null : new(primary, secondary, null);
        }
        catch (JsonException) { return null; }
    }

    public static OfficialUsageReading? ParseCodexWhamUsage(string json, DateTimeOffset now)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var container = JsonValue.First(root, "rate_limits", "rate_limit");
            if (container.ValueKind != JsonValueKind.Object) container = root;
            return ParseCodexWindows(container, now) is { } reading
                ? reading with { PlanLabel = JsonValue.String(root, "plan_type") ?? JsonValue.String(root, "plan") }
                : null;
        }
        catch (JsonException) { return null; }
    }

    internal static OfficialUsageReading? ParseCodexWindows(JsonElement container, DateTimeOffset now)
    {
        var primary = CodexWindow(JsonValue.First(container, "primary", "primary_window", "five_hour"), now);
        var secondary = CodexWindow(JsonValue.First(container, "secondary", "secondary_window", "weekly"), now);
        if (primary == null) { primary = secondary; secondary = null; }
        if (primary?.WindowMinutes is { } first && secondary?.WindowMinutes is { } second && first > second)
            (primary, secondary) = (secondary, primary);
        return primary == null ? null : new(primary, secondary, null);
    }

    private static OfficialRateWindow? CodexWindow(JsonElement value, DateTimeOffset now)
    {
        var used = JsonValue.Number(value, "used_percent") ?? JsonValue.Number(value, "usage_percent");
        if (used == null && (JsonValue.Number(value, "percent_left") ?? JsonValue.Number(value, "remaining_percent")) is { } left)
            used = 100 - left;
        if (used == null) return null;
        var reset = JsonValue.Reset(JsonValue.First(value, "resets_at", "reset_at", "reset_time_ms"), now);
        if (reset == null && (JsonValue.Number(value, "resets_in_seconds") ?? JsonValue.Number(value, "reset_after_seconds")) is { } seconds)
            reset = JsonValue.AddSeconds(now, seconds);
        var minutes = JsonValue.Number(value, "window_minutes") ??
            (JsonValue.Number(value, "limit_window_seconds") ?? JsonValue.Number(value, "window_duration_seconds")) / 60;
        return new(Math.Clamp(used.Value, 0, 100), reset,
            minutes is > 0 and <= int.MaxValue ? (int)minutes.Value : null);
    }
}

internal static class JsonValue
{
    internal static JsonElement Property(JsonElement element, string property) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(property, out var value) ? value : default;
    internal static JsonElement First(JsonElement element, params string[] properties)
    {
        foreach (var property in properties)
            if (Property(element, property) is var value && value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)) return value;
        return default;
    }
    internal static string? String(JsonElement element, string property) =>
        Property(element, property) is var value && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    internal static double? Number(JsonElement element, string property) => Number(Property(element, property));
    internal static double? Number(JsonElement value)
    {
        double parsed;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out parsed) && double.IsFinite(parsed)) return parsed;
        if (value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(),
            System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out parsed) && double.IsFinite(parsed)) return parsed;
        return null;
    }
    internal static DateTimeOffset? Reset(JsonElement value, DateTimeOffset now)
    {
        if (value.ValueKind == JsonValueKind.String && LocalLogUsageService.ParseDate(value.GetString()) is { } date) return date;
        if (Number(value) is not { } number || number <= 0) return null;
        try
        {
            if (number < 100_000_000) return AddSeconds(now, number);
            return DateTimeOffset.FromUnixTimeMilliseconds((long)(number < 100_000_000_000 ? number * 1000 : number));
        }
        catch (ArgumentOutOfRangeException) { return null; }
    }
    internal static DateTimeOffset? AddSeconds(DateTimeOffset now, double seconds)
    {
        try { return seconds > 0 && double.IsFinite(seconds) ? now.AddSeconds(seconds) : null; }
        catch (ArgumentOutOfRangeException) { return null; }
    }
    internal static async Task<string> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        const int maximum = 1_048_576;
        if (content.Headers.ContentLength > maximum) throw new JsonException();
        await using var stream = await content.ReadAsStreamAsync(cancellationToken);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int count;
        while ((count = await stream.ReadAsync(chunk, cancellationToken)) > 0)
        {
            if (buffer.Length + count > maximum) throw new JsonException();
            buffer.Write(chunk, 0, count);
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }
}
