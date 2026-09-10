namespace UsageKun.Core;

public interface IUsageService
{
    Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now);
}

/// One provider line for the tray tooltip/icon; mirrors MenuBarEntry on macOS.
public sealed record TrayEntry(string Mark, double? PercentLeft, UsageStatus Status);

public sealed class MockUsageService : IUsageService
{
    public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now)
    {
        IReadOnlyList<UsageSnapshot> snapshots =
        [
            new UsageSnapshot
            {
                Provider = UsageProvider.Claude,
                Status = UsageStatus.Warning,
                Used = 73,
                Limit = 100,
                Percent = 73,
                ResetAt = now.AddHours(3),
                UpdatedAt = now,
                Message = "Session limit is getting close.",
                Source = "mock"
            },
            new UsageSnapshot
            {
                Provider = UsageProvider.Codex,
                Status = UsageStatus.Ok,
                Used = 41,
                Limit = 100,
                Percent = 41,
                ResetAt = now.AddHours(7),
                UpdatedAt = now,
                Message = "Enough room for a larger task.",
                Source = "mock"
            }
        ];

        return Task.FromResult(snapshots);
    }
}

/// Selects only enabled providers and opt-in sources. Failed official reads keep
/// a usable local estimate and append a reason, or show an explicit setup/error.
public sealed class CompositeUsageService : IUsageService
{
    private readonly AppConfigStore _configStore;
    private readonly LocalLogUsageService _localLogService;
    private readonly IOfficialUsageService _officialService;
    private readonly IAntigravityUsageService _antigravityService;

    public CompositeUsageService(AppConfigStore configStore, LocalLogUsageService? localLogService = null,
        IOfficialUsageService? officialService = null, IAntigravityUsageService? antigravityService = null)
    {
        _configStore = configStore;
        _localLogService = localLogService ?? new LocalLogUsageService();
        _officialService = officialService ?? new CLIOAuthUsageService();
        _antigravityService = antigravityService ?? new AntigravityUsageService();
    }

    public async Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now)
    {
        var config = _configStore.Load();
        _localLogService.ClaudePlanOverride = config.ClaudePlanOverride;
        var local = config.LocalLogEnabled
            ? await _localLogService.SnapshotsAsync(now, config.CodexProviderEnabled, config.ClaudeProviderEnabled)
            : Array.Empty<UsageSnapshot>();
        var tasks = new List<Task<UsageSnapshot>>();
        foreach (var provider in new[] { UsageProvider.Codex, UsageProvider.Claude, UsageProvider.Antigravity })
        {
            if (!config.IsProviderEnabled(provider)) continue;
            tasks.Add(ReadProviderAsync(provider));
        }
        return await Task.WhenAll(tasks);

        async Task<UsageSnapshot> ReadProviderAsync(UsageProvider provider)
        {
            if (provider == UsageProvider.Antigravity)
                return config.AntigravityUsageEnabled ? await _antigravityService.SnapshotAsync(now) :
                    AntigravityUsageService.Unavailable(now, "Enable Antigravity sync in Settings, then open and sign in to Antigravity IDE in Windows.");
            var estimate = local.FirstOrDefault(snapshot => snapshot.Provider == provider);
            var officialEnabled = provider == UsageProvider.Claude ? config.ClaudeOfficialUsageEnabled : config.CodexOfficialUsageEnabled;
            if (officialEnabled)
            {
                var result = await _officialService.SnapshotAsync(provider, now);
                if (result.Snapshot is { } official && official.Provider == provider)
                {
                    if (provider == UsageProvider.Claude && config.LocalLogEnabled && official.Percent is { } percent)
                        _localLogService.RecordClaudeOfficialSample(100 - percent, now);
                    return official;
                }
                var reason = result.FailureReason ?? "The usage provider returned an unexpected result.";
                if (estimate != null)
                    return estimate with { Message = (estimate.Message is { Length: > 0 } text ? text + " " : "") + "Official sync unavailable: " + reason };
                return new UsageSnapshot
                {
                    Provider = provider, Status = UsageStatus.Error, UpdatedAt = now,
                    Source = provider == UsageProvider.Claude ? "Claude official usage API" : "Codex official usage API",
                    Unit = "%", MetricTitle = "Usage left", Message = reason
                };
            }
            return estimate ?? new UsageSnapshot
            {
                Provider = provider, Status = UsageStatus.Unknown, UpdatedAt = now,
                Source = "disabled", MetricTitle = "Status", SecondaryTitle = "Sync",
                Message = "Enable local logs or official CLI sync in Settings."
            };
        }
    }
}

/// Display state the UI subscribes to; mirrors UsageStore on macOS.
/// Refresh must be driven from a single thread (the WPF dispatcher).
public sealed class UsageStore
{
    private const string RefreshFailureMessage = "Usage refresh failed. Check the sync sources in Settings, then refresh.";
    private readonly IUsageService _service;
    private readonly AppConfigStore _configStore;
    private int _configRevision;
    private bool _refreshPending;

    public IReadOnlyList<UsageSnapshot> Snapshots { get; private set; } = [];
    public bool IsRefreshing { get; private set; }
    public AppConfig Config { get; private set; }
    public string? LastErrorMessage { get; private set; }

    /// Raised after snapshots, refresh state, or config change.
    public event EventHandler? Changed;

    public UsageStore(IUsageService service, AppConfigStore? configStore = null)
    {
        _service = service;
        _configStore = configStore ?? new AppConfigStore();
        Config = _configStore.Load();
    }

    public IReadOnlyList<TrayEntry> TrayEntries => TrayEntriesFor(Snapshots);

    public static IReadOnlyList<TrayEntry> TrayEntriesFor(IReadOnlyList<UsageSnapshot> snapshots)
    {
        var entries = new List<TrayEntry>();

        foreach (var provider in new[] { UsageProvider.Claude, UsageProvider.Codex, UsageProvider.Antigravity })
        {
            if (snapshots.FirstOrDefault(snapshot => snapshot.Provider == provider) is not { } snapshot)
            {
                continue;
            }

            double? effectivePercent = provider == UsageProvider.Antigravity && snapshot.Weekly?.PercentLeft == null
                ? null
                : snapshot.Percent is { } primary
                ? Math.Min(primary, snapshot.Weekly?.PercentLeft ?? 100)
                : null;

            entries.Add(new TrayEntry(provider.Mark(), effectivePercent, snapshot.Status));
        }

        return entries;
    }

    public double? MostConstrainedPercent
    {
        get
        {
            var entries = TrayEntries;
            if (entries.Any(entry => entry.PercentLeft == null)) return null;
            double? minimum = null;
            foreach (var entry in entries)
            {
                if (entry.PercentLeft is { } percent && (minimum == null || percent < minimum))
                {
                    minimum = percent;
                }
            }

            return minimum;
        }
    }

    public UsageStatus OverallStatus => UsageStatusInfo.MostSevere(Snapshots.Select(snapshot => snapshot.Status));

    public DateTimeOffset? UpdatedAt
    {
        get
        {
            DateTimeOffset? latest = null;
            foreach (var snapshot in Snapshots)
            {
                if (latest == null || snapshot.UpdatedAt > latest)
                {
                    latest = snapshot.UpdatedAt;
                }
            }

            return latest;
        }
    }

    public async Task RefreshAsync()
    {
        if (IsRefreshing)
        {
            _refreshPending = true;
            return;
        }

        IsRefreshing = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            do
            {
                _refreshPending = false;
                var revision = _configRevision;
                try
                {
                    // Log parsing is file-heavy; keep it off the UI thread.
                    var result = await Task.Run(() => _service.SnapshotsAsync(DateTimeOffset.Now));
                    if (revision == _configRevision)
                    {
                        Snapshots = result.Where(snapshot => Config.IsProviderEnabled(snapshot.Provider)).ToArray();
                        if (LastErrorMessage == RefreshFailureMessage) LastErrorMessage = null;
                    }
                }
                catch
                {
                    // Provider failures must never crash the app or expose diagnostics.
                    if (revision == _configRevision)
                        LastErrorMessage = RefreshFailureMessage;
                }
            } while (_refreshPending);
        }
        finally
        {
            IsRefreshing = false;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// Windows only: persists the floating-widget position after a drag.
    /// Unlike UpdateConfig this neither refreshes nor raises Changed, so a
    /// drag never kicks off a log rescan.
    public void SaveWidgetPosition(double x, double y)
    {
        var config = Config.Clone();
        config.WidgetPositionX = x;
        config.WidgetPositionY = y;
        Config = config;

        try
        {
            _configStore.Save(config);
        }
        catch
        {
            // Position persistence is best-effort.
        }
    }

    public void UpdateConfig(AppConfig newConfig)
    {
        _configRevision++;
        Config = newConfig.Clone();
        Snapshots = Snapshots.Where(snapshot => newConfig.IsProviderEnabled(snapshot.Provider)).ToArray();

        try
        {
            _configStore.Save(newConfig);
            LastErrorMessage = null;
        }
        catch
        {
            LastErrorMessage = "Failed to save settings.";
        }

        Changed?.Invoke(this, EventArgs.Empty);
        _ = RefreshAsync();
    }
}
