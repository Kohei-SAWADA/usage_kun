using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Media;
using UsageKun.Core;

namespace UsageKun.App;

public partial class WidgetWindow : Window
{
    private static readonly Brush TextPrimaryBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xE0, 0xFF, 0xEB)));
    private static readonly Brush TextMutedBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x8F, 0xBD, 0x9C)));
    private static readonly Brush TextFaintBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x59, 0x80, 0x63)));
    private static readonly Brush BarTrackBrush = Frozen(new SolidColorBrush(Color.FromArgb(0x75, 0x2E, 0x52, 0x3D)));
    private static readonly Brush RowBackgroundBrush = Frozen(new SolidColorBrush(Color.FromArgb(0xB8, 0x08, 0x0F, 0x0B)));

    private readonly UsageStore _store;
    private readonly Action _openSettings;

    public WidgetWindow(UsageStore store, Action openSettings)
    {
        _store = store;
        _openSettings = openSettings;
        InitializeComponent();
        MaxHeight = Math.Max(120, SystemParameters.WorkArea.Height - 48);
        MaxWidth = Math.Max(200, SystemParameters.WorkArea.Width - 32);

        RestorePosition();
        SizeChanged += (_, _) => KeepOnScreen();
        _store.Changed += OnStoreChanged;
        Closed += (_, _) => _store.Changed -= OnStoreChanged;
        Render();
    }

    private void OnStoreChanged(object? sender, EventArgs e) => Render();

    private void RestorePosition()
    {
        var config = _store.Config;
        // Default to the top-left corner, mirroring the macOS pinned meter.
        var left = config.WidgetPositionX ?? SystemParameters.VirtualScreenLeft + 24;
        var top = config.WidgetPositionY ?? SystemParameters.VirtualScreenTop + 24;

        Left = Clamp(left, SystemParameters.VirtualScreenLeft,
            SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
        Top = Clamp(top, SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 80);
    }

    private static double Clamp(double value, double minimum, double maximum) =>
        Math.Min(Math.Max(value, minimum), Math.Max(minimum, maximum));

    private void KeepOnScreen()
    {
        // Adding providers or an unavailable-data explanation can grow the
        // meter. Keep its footer reachable without losing the saved position.
        Left = Clamp(Left, SystemParameters.VirtualScreenLeft,
            SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - ActualWidth);
        Top = Clamp(Top, SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - ActualHeight - 48);
    }

    private void OnDragPanel(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed)
        {
            return;
        }

        e.Handled = true;
        DragMove();
        _store.SaveWidgetPosition(Left, Top);
    }

    private void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _ = _store.RefreshAsync();
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _openSettings();
    }

    private void OnHideClick(object sender, RoutedEventArgs e)
    {
        var config = _store.Config.Clone();
        config.DesktopWidgetEnabled = false;
        _store.UpdateConfig(config);
    }

    private void Render()
    {
        ActionLabel.Text = _store.IsRefreshing
            ? "UPDATING"
            : _store.OverallStatus == UsageStatus.Unknown
              && DisplaySnapshots().Any(snapshot => snapshot.Provider == UsageProvider.Antigravity && snapshot.Status == UsageStatus.Unknown)
                ? "CHECK"
                : NextActionLabel(_store.OverallStatus).ToUpperInvariant();
        ActionLabel.Foreground = TintBrush(_store.OverallStatus);
        RefreshButton.IsEnabled = !_store.IsRefreshing;
        RefreshButton.Content = _store.IsRefreshing ? "…" : "⟳";
        RefreshButton.ToolTip = _store.IsRefreshing ? "Refreshing usage…" : "Refresh now";
        UpdatedText.Text = _store.IsRefreshing
            ? "REFRESHING…"
            : _store.UpdatedAt is { } updated ? $"UPDATED {updated.ToLocalTime():HH:mm:ss}" : "WAITING FOR USAGE";
        ErrorText.Text = _store.LastErrorMessage;
        ErrorText.Visibility = string.IsNullOrEmpty(_store.LastErrorMessage) ? Visibility.Collapsed : Visibility.Visible;

        RowsPanel.Children.Clear();
        var first = true;
        foreach (var snapshot in DisplaySnapshots())
        {
            var row = BuildRow(snapshot);
            row.Margin = new Thickness(0, first ? 0 : 11, 0, 0);
            RowsPanel.Children.Add(row);
            first = false;
        }

        if (first)
        {
            RowsPanel.Children.Add(new TextBlock
            {
                Text = _store.IsRefreshing ? "Loading usage…" : "No providers selected. Open Settings to choose a provider.",
                FontSize = 11,
                Foreground = TextMutedBrush,
                TextWrapping = TextWrapping.Wrap
            });
        }
    }

    /// Same provider ordering and visibility rules as the macOS desktop meter.
    private List<UsageSnapshot> DisplaySnapshots()
    {
        var config = _store.Config;
        var result = new List<UsageSnapshot>();

        foreach (var provider in new[] { UsageProvider.Codex, UsageProvider.Claude, UsageProvider.Antigravity })
        {
            var enabled = provider switch
            {
                UsageProvider.Claude => config.ClaudeProviderEnabled,
                UsageProvider.Codex => config.CodexProviderEnabled,
                UsageProvider.Antigravity => config.AntigravityProviderEnabled,
                _ => false
            };
            if (!enabled)
            {
                continue;
            }

            if (_store.Snapshots.FirstOrDefault(snapshot => snapshot.Provider == provider) is { } snapshot)
            {
                result.Add(snapshot);
            }
        }

        return result;
    }

    private static string NextActionLabel(UsageStatus status) => status switch
    {
        UsageStatus.Ok => "Go",
        UsageStatus.Warning => "Go light",
        UsageStatus.Critical => "Hold off",
        UsageStatus.Unknown => "Setup",
        UsageStatus.Error => "Check",
        _ => "Setup"
    };

    private FrameworkElement BuildRow(UsageSnapshot snapshot)
    {
        var accent = AccentBrush(snapshot.Provider);
        var accentColor = ((SolidColorBrush)accent).Color;

        var rows = new StackPanel();

        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 9) };

        var chip = new Border
        {
            Width = 25,
            Height = 25,
            CornerRadius = new CornerRadius(6),
            Background = Frozen(new SolidColorBrush(WithAlpha(accentColor, 0x29))),
            BorderBrush = Frozen(new SolidColorBrush(WithAlpha(accentColor, 0x6B))),
            BorderThickness = new Thickness(1),
            Child = new TextBlock
            {
                Text = snapshot.Provider.Mark(),
                FontFamily = new FontFamily("Consolas"),
                FontSize = 13,
                FontWeight = FontWeights.Black,
                Foreground = accent,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        DockPanel.SetDock(chip, Dock.Left);
        header.Children.Add(chip);

        var percentText = new TextBlock
        {
            Text = snapshot.PercentDisplay,
            FontSize = 18,
            FontWeight = FontWeights.Black,
            Foreground = accent,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0)
        };
        DockPanel.SetDock(percentText, Dock.Right);
        header.Children.Add(percentText);

        var titles = new StackPanel { Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock
        {
            Text = snapshot.Provider.DisplayName(),
            FontSize = 12,
            FontWeight = FontWeights.Black,
            Foreground = TextPrimaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        titles.Children.Add(new TextBlock
        {
            Text = snapshot.Provider == UsageProvider.Antigravity
                ? $"ANTIGRAVITY · {snapshot.PrimaryWindowTitle}"
                : $"{snapshot.PrimaryWindowTitle} PRIMARY",
            FontFamily = new FontFamily("Consolas"),
            FontSize = 8,
            FontWeight = FontWeights.Black,
            Foreground = TextFaintBrush,
            Margin = new Thickness(0, 2, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        header.Children.Add(titles);

        rows.Children.Add(header);
        rows.Children.Add(LimitLine(
            snapshot.PrimaryWindowLabel,
            snapshot.Percent,
            snapshot.ResetAt,
            snapshot.Percent == null ? snapshot.Provider == UsageProvider.Antigravity ? "Unknown" : snapshot.UsedDisplay : null,
            accentColor,
            barHeight: 8,
            isPrimary: true));

        if (snapshot.Weekly is { } weekly)
        {
            var weeklyLine = LimitLine(
                "1w",
                weekly.PercentLeft,
                weekly.ResetAt,
                weekly.Detail,
                accentColor,
                barHeight: 4,
                isPrimary: false);
            weeklyLine.Margin = new Thickness(0, 7, 0, 0);
            rows.Children.Add(weeklyLine);
        }

        if ((snapshot.Percent == null || snapshot.Status is UsageStatus.Unknown or UsageStatus.Error)
            && !string.IsNullOrWhiteSpace(snapshot.Message))
        {
            rows.Children.Add(new TextBlock
            {
                Text = snapshot.Message,
                FontSize = 11,
                Foreground = TextMutedBrush,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 8, 0, 0)
            });
        }

        var result = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = RowBackgroundBrush,
            BorderBrush = Frozen(new SolidColorBrush(WithAlpha(accentColor, 0x2E))),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10),
            Child = rows,
            ToolTip = $"{snapshot.Message}\nSource: {snapshot.Source}\nUpdated {snapshot.UpdatedAt.ToLocalTime():HH:mm:ss}"
        };
        AutomationProperties.SetName(result, $"{snapshot.Provider.DisplayName()} {snapshot.PrimaryWindowLabel} {snapshot.PercentDisplay}");
        return result;
    }

    private FrameworkElement LimitLine(
        string title,
        double? percent,
        DateTimeOffset? resetAt,
        string? detail,
        Color accentColor,
        double barHeight,
        bool isPrimary)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(title.Length > 3 ? 35 : 22) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleText = new TextBlock
        {
            Text = title.ToUpperInvariant(),
            FontFamily = new FontFamily("Consolas"),
            FontSize = isPrimary ? 10 : 8,
            FontWeight = FontWeights.Black,
            Foreground = isPrimary ? TextMutedBrush : TextFaintBrush,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(titleText, 0);
        grid.Children.Add(titleText);

        if (percent is { } percentValue && double.IsFinite(percentValue) && percentValue is >= 0 and <= 100)
        {
            var bar = Bar(percentValue, accentColor, barHeight, muted: !isPrimary);
            Grid.SetColumn(bar, 1);
            grid.Children.Add(bar);

            var percentText = new TextBlock
            {
                Text = Format.Percent(percentValue),
                FontFamily = new FontFamily("Consolas"),
                FontSize = isPrimary ? 11 : 9,
                FontWeight = FontWeights.Black,
                Foreground = isPrimary ? TextPrimaryBrush : TextMutedBrush,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(7, 0, 0, 0),
                MinWidth = 36,
                TextAlignment = TextAlignment.Right
            };
            Grid.SetColumn(percentText, 2);
            grid.Children.Add(percentText);

            var resetText = new TextBlock
            {
                Text = resetAt is { } reset ? Format.WidgetReset(reset, DateTimeOffset.Now) : "--",
                FontFamily = new FontFamily("Consolas"),
                FontSize = isPrimary ? 10 : 9,
                FontWeight = FontWeights.Bold,
                Foreground = TextMutedBrush,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(7, 0, 0, 0),
                MinWidth = 48,
                TextAlignment = TextAlignment.Right
            };
            Grid.SetColumn(resetText, 3);
            grid.Children.Add(resetText);
        }
        else
        {
            var detailText = new TextBlock
            {
                Text = (detail ?? "Unknown").ToUpperInvariant(),
                FontFamily = new FontFamily("Consolas"),
                FontSize = 9,
                FontWeight = FontWeights.Bold,
                Foreground = TextMutedBrush,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            Grid.SetColumn(detailText, 1);
            Grid.SetColumnSpan(detailText, 3);
            grid.Children.Add(detailText);
        }

        return grid;
    }

    private static FrameworkElement Bar(double percent, Color accentColor, double height, bool muted)
    {
        var clamped = Math.Min(Math.Max(percent, 0), 100);

        var track = new Border
        {
            Height = height,
            CornerRadius = new CornerRadius(height / 2),
            Background = muted
                ? Frozen(new SolidColorBrush(Color.FromArgb(0x3F, 0x2E, 0x52, 0x3D)))
                : BarTrackBrush,
            VerticalAlignment = VerticalAlignment.Center
        };

        var fill = new Grid();
        fill.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(clamped, GridUnitType.Star) });
        fill.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100 - clamped, GridUnitType.Star) });

        var level = new Border
        {
            CornerRadius = new CornerRadius(height / 2),
            Background = Frozen(new SolidColorBrush(WithAlpha(accentColor, muted ? (byte)0xA8 : (byte)0xFF))),
            MinWidth = clamped > 0 ? Math.Min(height, 2) : 0,
            Visibility = clamped > 0 ? Visibility.Visible : Visibility.Collapsed
        };
        Grid.SetColumn(level, 0);
        fill.Children.Add(level);

        track.Child = fill;
        return track;
    }

    private static Brush AccentBrush(UsageProvider provider)
    {
        var (r, g, b) = provider.Accent();
        return Frozen(new SolidColorBrush(Color.FromRgb(r, g, b)));
    }

    private static Brush TintBrush(UsageStatus status)
    {
        var (r, g, b) = status.Tint();
        return Frozen(new SolidColorBrush(Color.FromRgb(r, g, b)));
    }

    private static Color WithAlpha(Color color, byte alpha) =>
        Color.FromArgb(alpha, color.R, color.G, color.B);

    private static SolidColorBrush Frozen(SolidColorBrush brush)
    {
        brush.Freeze();
        return brush;
    }
}
