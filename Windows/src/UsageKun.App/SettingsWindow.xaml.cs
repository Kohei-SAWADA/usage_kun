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
        ClaudeProviderCheck.IsChecked = config.ClaudeProviderEnabled;
        CodexProviderCheck.IsChecked = config.CodexProviderEnabled;
        AntigravityProviderCheck.IsChecked = config.AntigravityProviderEnabled;
        LocalLogCheck.IsChecked = config.LocalLogEnabled;
        ClaudeOfficialCheck.IsChecked = config.ClaudeOfficialUsageEnabled;
        CodexOfficialCheck.IsChecked = config.CodexOfficialUsageEnabled;
        AntigravityUsageCheck.IsChecked = config.AntigravityUsageEnabled;
        DesktopWidgetCheck.IsChecked = config.DesktopWidgetEnabled;
        LaunchAtLoginCheck.IsChecked = config.LaunchAtLoginEnabled;
        ConfigPathText.Text = $"usage_kun 0.4.1 · Windows\nSettings file: {new AppConfigStore().ConfigPath}";

        foreach (var minutes in IntervalChoices)
        {
            RefreshIntervalCombo.Items.Add(minutes);
        }
        RefreshIntervalCombo.SelectedItem = IntervalChoices.Contains(config.RefreshIntervalMinutes)
            ? config.RefreshIntervalMinutes
            : 5;

        ClaudePlanCombo.SelectedItem = ClaudePlanCombo.Items
            .OfType<ComboBoxItem>()
            .FirstOrDefault(item => (string)item.Tag == config.ClaudePlanOverride)
            ?? ClaudePlanCombo.Items[0];
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
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
        config.LaunchAtLoginEnabled = LaunchAtLoginCheck.IsChecked == true;
        config.RefreshIntervalMinutes = RefreshIntervalCombo.SelectedItem is int minutes ? minutes : 5;
        config.ClaudePlanOverride = ClaudePlanCombo.SelectedItem is ComboBoxItem item
            ? (string)item.Tag
            : "auto";

        _store.UpdateConfig(config);
        if (_store.LastErrorMessage is { } error)
        {
            SaveErrorText.Text = error;
            SaveErrorText.Visibility = Visibility.Visible;
            return;
        }
        Close();
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => Close();
}
