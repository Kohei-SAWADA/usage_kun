using System.Text.Json;
using System.Text.Json.Serialization;

namespace UsageKun.Core;

/// Shares the macOS config.json schema (camelCase keys). Windows sync sources
/// default on; explicit saved choices are preserved. The alwaysOnTop and widgetPosition* keys are Windows-only additions;
/// the macOS decoder ignores unknown keys, so the schema stays compatible.
public sealed class AppConfig
{
    public bool LocalLogEnabled { get; set; } = true;
    public bool ClaudeOfficialUsageEnabled { get; set; } = true;
    public bool CodexOfficialUsageEnabled { get; set; } = true;
    public bool AntigravityUsageEnabled { get; set; } = true;
    /// Windows only: granted by the explicit Start sync action, independently of source selections.
    /// Missing or unreadable approval never authorizes log, credential, or network access.
    public bool SyncApproved { get; set; }
    public int RefreshIntervalMinutes { get; set; } = 5;
    public bool DesktopWidgetEnabled { get; set; } = true;
    /// Windows only: keep app windows above other apps. Defaults off, including for older configs.
    public bool AlwaysOnTop { get; set; }
    public bool LaunchAtLoginEnabled { get; set; } = true;
    public bool LaunchAtLoginInitialized { get; set; }
    public bool MenuBarShowsNumbers { get; set; }
    public bool OnboardingCompleted { get; set; }
    public bool NotificationsEnabled { get; set; }

    /// Legacy plan preference retained for settings compatibility; Windows quota does not use token caps.
    public string ClaudePlanOverride { get; set; } = "auto";

    /// Providers to show. Unchecked providers are not fetched or displayed.
    public bool ClaudeProviderEnabled { get; set; } = true;
    public bool CodexProviderEnabled { get; set; } = true;
    public bool AntigravityProviderEnabled { get; set; }

    public bool IsProviderEnabled(UsageProvider provider) => provider switch
    {
        UsageProvider.Claude => ClaudeProviderEnabled,
        UsageProvider.Codex => CodexProviderEnabled,
        UsageProvider.Antigravity => AntigravityProviderEnabled,
        _ => false
    };

    /// Windows only: last floating-widget position in device-independent pixels.
    public double? WidgetPositionX { get; set; }
    public double? WidgetPositionY { get; set; }

    public AppConfig Clone() => (AppConfig)MemberwiseClone();
}

public sealed class AppConfigStore
{
    private bool _syncApprovalSuspended;
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    public string ConfigPath { get; }

    public AppConfigStore(string? configPath = null)
    {
        ConfigPath = configPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "usage_kun",
            "config.json");
    }

    public AppConfig Load()
    {
        try
        {
            var json = File.ReadAllText(ConfigPath);
            var config = JsonSerializer.Deserialize<AppConfig>(json, SerializerOptions) ?? new AppConfig();
            using var document = JsonDocument.Parse(json);
            // Do not infer approval from onboarding or checked sources. Ambiguous
            // duplicate approval keys must also fail closed, regardless of key order.
            var approvals = document.RootElement.EnumerateObject()
                .Where(property => property.Name.Equals("syncApproved", StringComparison.OrdinalIgnoreCase)).ToArray();
            config.SyncApproved = !_syncApprovalSuspended && approvals.Length == 1
                && approvals[0].Value.ValueKind == JsonValueKind.True;
            return config;
        }
        catch
        {
            return new AppConfig();
        }
    }

    public void Save(AppConfig config)
    {
        var saved = config.Clone();
        // Widget/startup/settings persistence may preserve approval, never repair
        // missing approval from a cached object after corruption or deletion.
        saved.SyncApproved = saved.SyncApproved && Load().SyncApproved;
        WriteConfig(saved);
    }

    /// The explicit Start sync action is the only path that grants approval.
    public void SaveWithSyncApproval(AppConfig config)
    {
        var saved = config.Clone();
        saved.SyncApproved = true;
        WriteConfig(saved);
        _syncApprovalSuspended = false;
    }

    // If a settings/approval write fails, the shared service store stays paused
    // even when an older approved file still exists. Explicit Start sync can retry.
    internal void SuspendSyncApproval() => _syncApprovalSuspended = true;

    private void WriteConfig(AppConfig config)
    {
        var directory = Path.GetDirectoryName(ConfigPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        // Write-then-move keeps a crash from truncating the existing config.
        var temporaryPath = ConfigPath + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(config, SerializerOptions));
        File.Move(temporaryPath, ConfigPath, overwrite: true);
    }
}
