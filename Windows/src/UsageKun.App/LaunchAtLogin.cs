using Microsoft.Win32;

namespace UsageKun.App;

/// Windows counterpart of the macOS LaunchAtLoginService: a per-user
/// HKCU Run entry, no admin rights or installer required.
internal static class LaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "usage_kun";

    public static void Apply(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (key == null)
            {
                return;
            }

            if (enabled)
            {
                if (Environment.ProcessPath is { } executable)
                {
                    key.SetValue(ValueName, $"\"{executable}\"");
                }
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // Never block the meter over a registry policy restriction.
        }
    }
}
