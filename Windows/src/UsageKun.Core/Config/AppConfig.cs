using System.Text.Json;
using System.Text.Json.Serialization;

namespace UsageKun.Core;

/// Shares the macOS config.json schema (camelCase keys, missing keys fall back
/// to the same defaults). The widgetPosition* keys are Windows-only additions;
/// the macOS decoder ignores unknown keys, so the schema stays compatible.
public sealed class AppConfig
{
    public bool LocalLogEnabled { get; set; } = true;
    public bool ClaudeOfficialUsageEnabled { get; set; }
    public bool CodexOfficialUsageEnabled { get; set; }
    public bool AntigravityUsageEnabled { get; set; }
    public int RefreshIntervalMinutes { get; set; } = 5;
    public bool DesktopWidgetEnabled { get; set; } = true;
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
            return JsonSerializer.Deserialize<AppConfig>(json, SerializerOptions) ?? new AppConfig();
        }
        catch
        {
            return new AppConfig();
        }
    }

    public void Save(AppConfig config)
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
