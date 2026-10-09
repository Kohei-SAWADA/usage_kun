using Microsoft.Win32;
using UsageKun.Core;

namespace UsageKun.App;

/// One per-user Run value. Never changes StartupApproved or requests elevation.
internal static class LaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovalKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "usage_kun";
    public static string? LastError { get; private set; }

    private static bool Blocked()
    {
        using var approval = Registry.CurrentUser.OpenSubKey(ApprovalKeyPath);
        return approval?.GetValue(ValueName) is byte[] { Length: > 0 } bytes && bytes[0] != 0 && bytes[0] != 2;
    }

    public static void Initialize(AppConfig config, AppConfigStore store)
    {
        var initialized = config.LaunchAtLoginInitialized;
        var existing = File.Exists(store.ConfigPath);
        if (!initialized)
        {
            // Persist before registering. A failed save never changes OS startup.
            config.LaunchAtLoginInitialized = true;
            try { store.Save(config); }
            catch { LastError = "Could not save startup preference. No login item was changed."; return; }
        }
        Apply(config.LaunchAtLoginEnabled, initialized, existing, explicitChange: false);
    }

    public static void Apply(bool enabled, bool initialized = true, bool existing = true, bool explicitChange = true)
    {
        LastError = null;
        try
        {
            using var read = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            var current = read?.GetValue(ValueName) as string;
            var executable = Environment.ProcessPath;
            if (executable == null || !Path.GetFileName(executable).Equals("UsageKun.exe", StringComparison.OrdinalIgnoreCase))
            {
                LastError = "Start UsageKun.exe from its permanent installation folder."; return;
            }
            var command = $"\"{executable}\"";
            var action = LoginStartupPolicy.Decide(initialized, existing, enabled,
                current != null, Blocked(), current != null && current != command, explicitChange);
            if (action == LoginStartupAction.None) return;
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (key == null) { LastError = "Windows blocked access to the startup entry."; return; }
            if (action == LoginStartupAction.Remove) key.DeleteValue(ValueName, throwOnMissingValue: false);
            else if (current != command) key.SetValue(ValueName, command);
        }
        catch { LastError = "Windows could not update startup. Check Settings > Apps > Startup or your organization policy."; }
    }

    public static string StatusMessage()
    {
        if (LastError != null) return LastError;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            var entry = key?.GetValue(ValueName) as string;
            if (entry == null) return "Disabled: no Windows startup entry.";
            if (Blocked()) return "Disabled by Windows. Enable usage_kun in Settings > Apps > Startup.";
            if (entry != $"\"{Environment.ProcessPath}\"") return "Startup points to another location. Toggle Start with Windows to update it.";
            return "Enabled in Windows startup.";
        }
        catch { return "Windows startup status is unavailable (access denied or policy)."; }
    }
}
