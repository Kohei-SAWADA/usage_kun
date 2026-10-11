using System.Windows;
using System.Windows.Controls;
using UsageKun.Core;

namespace UsageKun.App;

public partial class SettingsWindow : Window
{
    private static readonly int[] IntervalChoices = [1, 2, 5, 10, 15, 30, 60];

    private readonly UsageStore _store;

    public SettingsWindow(UsageStore store)
    {
        _store = store;
        InitializeComponent();
        MaxHeight = Math.Max(200, SystemParameters.WorkArea.Height - 48);
        MaxWidth = Math.Max(280, SystemParameters.WorkArea.Width - 32);

        var config = _store.Config;
        Topmost = config.AlwaysOnTop;
        ClaudeProviderCheck.IsChecked = config.ClaudeProviderEnabled;
        CodexProviderCheck.IsChecked = config.CodexProviderEnabled;
        AntigravityProviderCheck.IsChecked = config.AntigravityProviderEnabled;
        LocalLogCheck.IsChecked = config.LocalLogEnabled;
        ClaudeOfficialCheck.IsChecked = config.ClaudeOfficialUsageEnabled;
        CodexOfficialCheck.IsChecked = config.CodexOfficialUsageEnabled;
        AntigravityUsageCheck.IsChecked = config.AntigravityUsageEnabled;
        UpdateSyncApprovalDisplay();
        DesktopWidgetCheck.IsChecked = config.DesktopWidgetEnabled;
        AlwaysOnTopCheck.IsChecked = config.AlwaysOnTop;
        LaunchAtLoginCheck.IsChecked = config.LaunchAtLoginEnabled;
        StartupStatusText.Text = LaunchAtLogin.StatusMessage();
        ConfigPathText.Text = $"usage_kun 0.4.7 · Windows\nSettings file: {new AppConfigStore().ConfigPath}";

        foreach (var minutes in IntervalChoices)
        {
            RefreshIntervalCombo.Items.Add(minutes);
        }
        RefreshIntervalCombo.SelectedItem = IntervalChoices.Contains(config.RefreshIntervalMinutes)
            ? config.RefreshIntervalMinutes
            : 5;
        _store.Changed += OnStoreChanged;
        Closed += (_, _) => _store.Changed -= OnStoreChanged;
    }

    private void OnStoreChanged(object? sender, EventArgs e) => UpdateSyncApprovalDisplay();

    private void UpdateSyncApprovalDisplay()
    {
        // Leave unsaved source choices alone when a timer discovers lost approval.
        StartSyncButton.Visibility = _store.Config.SyncApproved ? Visibility.Collapsed : Visibility.Visible;
        SyncApprovalHelpText.Text = _store.Config.SyncApproved
            ? "Sync has been started. Only selected sources and providers are read."
            : "Sync is paused. Review the selected sources, then choose Start sync to allow local log reads, " +
                "existing CLI sign-in reads, and usage requests. Save keeps sync paused.";
    }

    private void OnSaveClick(object sender, RoutedEventArgs e) => SaveSettings(startSync: false);

    private void OnStartSyncClick(object sender, RoutedEventArgs e) => SaveSettings(startSync: true);

    private void SaveSettings(bool startSync)
    {
        var config = _store.Config.Clone();
        config.ClaudeProviderEnabled = ClaudeProviderCheck.IsChecked == true;
        config.CodexProviderEnabled = CodexProviderCheck.IsChecked == true;
        config.AntigravityProviderEnabled = AntigravityProviderCheck.IsChecked == true;
        config.LocalLogEnabled = LocalLogCheck.IsChecked == true;
        config.ClaudeOfficialUsageEnabled = ClaudeOfficialCheck.IsChecked == true;
        config.CodexOfficialUsageEnabled = CodexOfficialCheck.IsChecked == true;
        config.AntigravityUsageEnabled = AntigravityUsageCheck.IsChecked == true;
        config.DesktopWidgetEnabled = DesktopWidgetCheck.IsChecked == true;
        config.AlwaysOnTop = AlwaysOnTopCheck.IsChecked == true;
        config.LaunchAtLoginEnabled = LaunchAtLoginCheck.IsChecked == true;
        var startupChanged = config.LaunchAtLoginEnabled != _store.Config.LaunchAtLoginEnabled;
        if (startupChanged) config.LaunchAtLoginInitialized = true;
        config.RefreshIntervalMinutes = RefreshIntervalCombo.SelectedItem is int minutes ? minutes : 5;

        if (startSync) _store.StartSync(config);
        else _store.UpdateConfig(config);
        if (_store.LastErrorMessage is { } error)
        {
            SaveErrorText.Text = error;
            SaveErrorText.Visibility = Visibility.Visible;
            return;
        }
        if (startupChanged)
        {
            LaunchAtLogin.Apply(config.LaunchAtLoginEnabled);
            StartupStatusText.Text = LaunchAtLogin.StatusMessage();
            if (LaunchAtLogin.LastError != null || StartupStatusText.Text.StartsWith("Disabled by Windows")) return;
        }
        Close();
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => Close();
}
