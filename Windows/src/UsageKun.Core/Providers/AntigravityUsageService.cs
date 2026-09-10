using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace UsageKun.Core;

public interface IAntigravityUsageService
{
    Task<UsageSnapshot> SnapshotAsync(DateTimeOffset now);
}

/// Reads the running Windows IDE's local Models & Usage quota. The ephemeral
/// CSRF credential never leaves loopback and is neither persisted nor logged.
public sealed class AntigravityUsageService : IAntigravityUsageService
{
    public async Task<UsageSnapshot> SnapshotAsync(DateTimeOffset now)
    {
        var connections = await DiscoverAsync();
        if (connections.Count == 0)
            return Unavailable(now, "Open Antigravity IDE in Windows and sign in to read Gemini quota.");

        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false, UseCookies = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(3) };
        UsageSnapshot? partial = null;
        using var overallTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        foreach (var connection in connections.Take(8))
        {
            if (overallTimeout.IsCancellationRequested) break;
            try
            {
                // Probe only HTTP. Never relax TLS validation for a local TLS socket.
                using var request = new HttpRequestMessage(HttpMethod.Post,
                    $"http://127.0.0.1:{connection.Port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary");
                request.Content = new StringContent("{\"request\":{},\"forceRefresh\":true}", Encoding.UTF8, "application/json");
                request.Headers.Add("Connect-Protocol-Version", "1");
                request.Headers.Add("x-codeium-csrf-token", connection.CsrfToken);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(overallTimeout.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(3));
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                if (response.StatusCode != System.Net.HttpStatusCode.OK) continue;
                var reading = ParseSummary(await JsonValue.ReadBoundedAsync(response.Content, timeout.Token), now);
                if (reading == null) continue;
                if (reading.Percent != null && reading.Weekly?.PercentLeft != null) return reading;
                if (partial == null || KnownWindows(reading) > KnownWindows(partial)) partial = reading;
            }
            catch
            {
                // Do not expose a body, CSRF token, or network diagnostic.
            }
        }
        return partial ?? Unavailable(now, "Antigravity quota is unavailable. Open its Models & Usage settings in Windows, then refresh.");
    }

    public static UsageSnapshot? ParseSummary(string json, DateTimeOffset now)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var groups = JsonValue.Property(JsonValue.Property(document.RootElement, "response"), "groups");
            if (groups.ValueKind != JsonValueKind.Array) return null;
            var gemini = groups.EnumerateArray().Where(group => JsonValue.String(group, "displayName") == "Gemini Models").ToList();
            if (gemini.Count != 1) return null;
            var buckets = JsonValue.Property(gemini[0], "buckets");
            var primary = Window(buckets, "gemini-5h", "5h");
            var weekly = Window(buckets, "gemini-weekly", "weekly");
            var complete = primary.PercentLeft != null && weekly.PercentLeft != null;
            var status = complete ? UsageStatusRules.Status(primary.PercentLeft!.Value, weekly.PercentLeft) :
                primary.PercentLeft <= 15 || weekly.PercentLeft <= 15 ? UsageStatus.Critical : UsageStatus.Unknown;
            return new UsageSnapshot
            {
                Provider = UsageProvider.Antigravity, Status = status,
                Used = primary.PercentLeft, Percent = primary.PercentLeft,
                ResetAt = primary.ResetAt, UpdatedAt = now, Weekly = weekly,
                Source = "Antigravity local quota", Unit = "%", MetricTitle = "5 hour left",
                Message = complete ? "Gemini quota from Antigravity Models & Usage." :
                    "Some Gemini quota is unavailable. Open Antigravity Models & Usage, then refresh. Missing values remain unknown."
            };
        }
        catch (JsonException) { return null; }
    }

    private static UsageWindow Window(JsonElement buckets, string id, string window)
    {
        if (buckets.ValueKind != JsonValueKind.Array) return new(null, null);
        var matches = buckets.EnumerateArray().Where(bucket => JsonValue.String(bucket, "bucketId") == id).ToList();
        if (matches.Count != 1) return new(null, null);
        var bucket = matches[0];
        var windowValue = JsonValue.Property(bucket, "window");
        if (windowValue.ValueKind != JsonValueKind.Undefined && JsonValue.String(bucket, "window") != window) return new(null, null);
        var disabled = JsonValue.Property(bucket, "disabled");
        if (disabled.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.False)) return new(null, null);
        var fraction = JsonValue.Property(bucket, "remainingFraction");
        double? percent = null;
        if (JsonValue.Property(bucket, "remainingAmount").ValueKind == JsonValueKind.Undefined &&
            fraction.ValueKind == JsonValueKind.Number && fraction.TryGetDouble(out var number) &&
            double.IsFinite(number) && number is >= 0 and <= 1)
            percent = number * 100;
        // A passed reset time never implies replenished Gemini quota.
        return new(percent, LocalLogUsageService.ParseDate(JsonValue.String(bucket, "resetTime")));
    }

    private static int KnownWindows(UsageSnapshot snapshot) =>
        (snapshot.Percent == null ? 0 : 1) + (snapshot.Weekly?.PercentLeft == null ? 0 : 1);

    internal static UsageSnapshot Unavailable(DateTimeOffset now, string message) => new()
    {
        Provider = UsageProvider.Antigravity, Status = UsageStatus.Unknown,
        UpdatedAt = now, Message = message, Source = "Antigravity local quota",
        Unit = "%", MetricTitle = "5 hour left", Weekly = new UsageWindow(null, null)
    };

    private sealed class Connection(int port, string csrfToken)
    {
        public int Port { get; } = port;
        public string CsrfToken { get; } = csrfToken;
    }

    private static async Task<IReadOnlyList<Connection>> DiscoverAsync()
    {
        if (!OperatingSystem.IsWindows()) return [];
        // Select actual Antigravity executables belonging to this user first.
        // Only those processes' command lines and listening ports are inspected.
        const string script = """
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $rows = @()
            $candidates = Get-CimInstance Win32_Process -Filter "Name='language_server_windows_x64.exe' OR Name='language_server_windows_arm64.exe' OR Name='language_server_windows_arm.exe'"
            foreach ($candidate in $candidates) {
                if (-not $candidate.ExecutablePath -or $candidate.ExecutablePath -notmatch '(?i)\\resources\\app\\extensions\\antigravity\\bin\\language_server_windows_(x64|arm64|arm)\.exe$') { continue }
                $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid
                if ($owner.Sid -ne $sid) { continue }
                $match = [regex]::Match($candidate.CommandLine, '--csrf_token(?:=|\s+)([A-Za-z0-9_-]+)(?:\s|$)')
                if (-not $match.Success) { continue }
                $ports = @(Get-NetTCPConnection -State Listen -OwningProcess $candidate.ProcessId -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::1', '::') } | Select-Object -ExpandProperty LocalPort -Unique | Sort-Object | Select-Object -First 4)
                foreach ($port in $ports) { $rows += @{ port = [int]$port; csrfToken = $match.Groups[1].Value } }
                if ($rows.Count -ge 12) { break }
            }
            ConvertTo-Json -InputObject @($rows) -Compress
            """;
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-EncodedCommand");
        start.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(script)));
        using var process = new Process { StartInfo = start };
        try
        {
            if (!process.Start()) return [];
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            var output = await outputTask;
            _ = await errorTask;
            if (process.ExitCode != 0 || output.Length > 65536) return [];
            using var document = JsonDocument.Parse(output);
            if (document.RootElement.ValueKind != JsonValueKind.Array) return [];
            var result = new List<Connection>();
            foreach (var row in document.RootElement.EnumerateArray().Take(12))
            {
                var port = JsonValue.Number(row, "port");
                var token = JsonValue.String(row, "csrfToken");
                if (port is >= 1 and <= 65535 && port.Value == (int)port.Value &&
                    token is { Length: > 0 and <= 4096 } && token.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-'))
                    result.Add(new((int)port.Value, token));
            }
            return result;
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            return [];
        }
    }
}
