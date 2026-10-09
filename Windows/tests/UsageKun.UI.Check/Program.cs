using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using UsageKun.App;
using UsageKun.Core;

namespace UsageKun.UI.Check;

internal static class Program
{
    private static int _checks;

    [STAThread]
    public static int Main()
    {
        // Deliberately use WPF Application, never the product App class: no
        // tray, singleton, startup registration, or real providers are started.
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Startup += async (_, _) =>
        {
            var exitCode = 0;
            var temporaryRoot = Path.Combine(Path.GetTempPath(), "usage-kun-ui-check-" + Guid.NewGuid().ToString("N"));
            var windows = new List<Window>();
            try
            {
                Console.WriteLine("usage_kun WPF integration check - TEST DATA ONLY");
                Directory.CreateDirectory(temporaryRoot);
                await RunChecksAsync(temporaryRoot, windows);
                Console.WriteLine($"PASS: {_checks} WPF checks; production config and credentials were not used.");
            }
            catch (Exception error)
            {
                exitCode = 1;
                // This runner handles only synthetic values and its own temp path.
                Console.Error.WriteLine("FAIL: " + error);
            }
            finally
            {
                foreach (var window in windows.Where(window => window.IsVisible).ToArray())
                    window.Close();
                try { if (Directory.Exists(temporaryRoot)) Directory.Delete(temporaryRoot, recursive: true); }
                catch (Exception error)
                {
                    exitCode = 1;
                    Console.Error.WriteLine("FAIL: temporary fixture cleanup: " + error.Message);
                }
                application.Shutdown(exitCode);
            }
        };
        return application.Run();
    }

    private static async Task RunChecksAsync(string temporaryRoot, List<Window> windows)
    {
        var configStore = new AppConfigStore(Path.Combine(temporaryRoot, "config.json"));
        configStore.Save(new AppConfig
        {
            ClaudeProviderEnabled = false,
            CodexProviderEnabled = true,
            AntigravityProviderEnabled = false,
            LaunchAtLoginEnabled = false,
            LocalLogEnabled = false,
            ClaudePlanOverride = "max_5x",
            DesktopWidgetEnabled = true
        });
        var service = new FixtureUsageService { Current = [Quota(UsageProvider.Codex, 10080)] };
        var store = new UsageStore(service, configStore);
        await store.RefreshAsync();
        var settingsOpened = 0;
        var widget = new WidgetWindow(store, () => settingsOpened++);
        MarkTestWindow(widget);
        windows.Add(widget);
        widget.Show();
        await LayoutAsync(widget);

        var rows = Named<StackPanel>(widget, "RowsPanel");
        Check(rows.Children.Count == 1, "one selected provider renders one row");
        Check(HasText(widget, "1W") && !HasText(widget, "5H"), "weekly-only Codex renders 1W, with no 5H label");
        Check(HasText(widget, "1-WEEK PRIMARY"), "weekly-only Codex header is 1-WEEK");

        var refresh = Named<Button>(widget, "RefreshButton");
        var settingsButton = Named<Button>(widget, "SettingsButton");
        var beforeRefresh = service.CallCount;
        var beforePosition = new Point(widget.Left, widget.Top);
        var refreshGate = service.PauseNextRefresh();
        Click(refresh);
        await UntilAsync(() => service.CallCount == beforeRefresh + 1, "refresh handler reaches fixture provider");
        Check(store.IsRefreshing && !refresh.IsEnabled, "refresh Click handler disables the button while refreshing");
        Check(Named<TextBlock>(widget, "ActionLabel").Text == "UPDATING", "refresh handler displays UPDATING");
        Check(settingsButton.IsEnabled, "settings remains enabled while refreshing");
        Click(settingsButton);
        Check(settingsOpened == 1, "settings Click handler invokes its callback exactly once");
        Check(widget.Left == beforePosition.X && widget.Top == beforePosition.Y, "button handlers do not move the meter");
        refreshGate.SetResult();
        await UntilAsync(() => !store.IsRefreshing, "refresh completes");
        Check(service.CallCount == beforeRefresh + 1 && refresh.IsEnabled, "one click makes one refresh and re-enables the button");
        Check(Named<TextBlock>(widget, "UpdatedText").Text.StartsWith("UPDATED "), "completed refresh displays update time");

        service.Current = [Quota(UsageProvider.Codex, 300) with { Weekly = new UsageWindow(60, DateTimeOffset.Now.AddDays(6)) }];
        await store.RefreshAsync();
        Check(HasText(widget, "5H") && HasText(widget, "1W"), "dual-limit Codex renders both 5H and 1W");
        Check(HasText(widget, "5-HOUR PRIMARY"), "5-hour Codex header is 5-HOUR");

        await CheckPercentRenderingAsync(service, store, widget, rows);

        service.Current = [Quota(UsageProvider.Codex, null)];
        await store.RefreshAsync();
        Check(HasText(widget, "LIMIT") && !HasText(widget, "5H") && !HasText(widget, "1W"), "unknown-duration Codex renders LIMIT without invented duration");

        service.Current = [Quota(UsageProvider.Codex, 10080), Quota(UsageProvider.Claude, 300), Quota(UsageProvider.Antigravity, 300)];
        var allProviders = store.Config.Clone();
        allProviders.ClaudeProviderEnabled = true;
        allProviders.AntigravityProviderEnabled = true;
        store.UpdateConfig(allProviders);
        await UntilAsync(() => !store.IsRefreshing, "three-provider refresh completes");
        await LayoutAsync(widget);
        Check(rows.Children.Count == 3 && HasText(widget, "Gemini (Antigravity)"), "all three providers render with Gemini name");
        Check(widget.ActualHeight <= widget.MaxHeight + 1, "three-provider meter respects work-area height");

        service.Current =
        [
            Quota(UsageProvider.Codex, 300) with { Percent = 95, Weekly = new UsageWindow(84, DateTimeOffset.Now.AddDays(6)) },
            Quota(UsageProvider.Claude, 300) with { Percent = 41, Weekly = new UsageWindow(33, DateTimeOffset.Now.AddDays(6)) },
            Quota(UsageProvider.Antigravity, 300) with { Percent = 61, Weekly = new UsageWindow(72, DateTimeOffset.Now.AddDays(6)) }
        ];
        await store.RefreshAsync();
        var providerRows = rows.Children.Cast<DependencyObject>().ToArray();
        Check(HasText(providerRows[0], "Codex") && HasText(providerRows[0], "95%") && HasText(providerRows[0], "84%")
            && !HasText(providerRows[0], "41%"), "Codex renders only its own primary and weekly quotas");
        Check(HasText(providerRows[1], "Claude Code") && HasText(providerRows[1], "41%") && HasText(providerRows[1], "33%")
            && !HasText(providerRows[1], "95%"), "Claude renders only its own primary and weekly quotas");
        Check(HasText(providerRows[2], "Gemini (Antigravity)") && HasText(providerRows[2], "61%") && HasText(providerRows[2], "72%")
            && !HasText(providerRows[2], "95%"), "Antigravity renders only its own primary and weekly quotas");

        // A deliberately small viewport exercises scrolling even on a large
        // developer monitor. Every row visibly identifies its synthetic data.
        var longMessage = "TEST DATA. " + string.Concat(Enumerable.Repeat(
            "Quota is unavailable in this fixture. Open the provider application, sign in, then refresh the usage meter. ", 3));
        service.Current = service.Current.Select(snapshot => snapshot with
        {
            Percent = null,
            Status = UsageStatus.Unknown,
            Message = longMessage
        }).ToArray();
        widget.MaxHeight = Math.Min(widget.MaxHeight, 400);
        await store.RefreshAsync();
        await LayoutAsync(widget);
        var rowScroll = Descendants<ScrollViewer>(widget).Single();
        Check(rows.Children.Count == 3 && widget.ActualHeight <= 401, "long unavailable-data rows stay inside the small-screen meter");
        Check(rowScroll.ExtentHeight > rowScroll.ViewportHeight, "overflowing provider rows can scroll");
        Check(IsInsideWindow(Named<TextBlock>(widget, "UpdatedText"), widget), "meter update footer remains visible while rows scroll");
        Check(IsInsideWindow(refresh, widget) && IsInsideWindow(settingsButton, widget), "meter buttons remain visible while rows scroll");

        var settings = NewSettings(store, temporaryRoot, windows);
        settings.MaxHeight = Math.Min(settings.MaxHeight, 400);
        settings.Show();
        await LayoutAsync(settings);
        var save = ContentButton(settings, "Save");
        var cancel = ContentButton(settings, "Cancel");
        Check(IsInsideWindow(save, settings) && IsInsideWindow(cancel, settings), "settings Save/Cancel stay visible on a small screen");
        var settingsScroll = Descendants<ScrollViewer>(settings).First();
        Check(settingsScroll.ExtentHeight > settingsScroll.ViewportHeight, "settings options can scroll on a small screen");
        Check(settings.FindName("ClaudePlanCombo") == null,
            "settings no longer offers a Claude plan selector that would imply a local quota estimate");
        Check(Named<TextBlock>(settings, "ClaudeQuotaHelpText").Text.Contains("Enable Claude usage sync"),
            "settings explains that Claude remaining quota needs usage sync");

        Named<CheckBox>(settings, "ClaudeProviderCheck").IsChecked = false;
        Named<CheckBox>(settings, "CodexProviderCheck").IsChecked = true;
        Named<CheckBox>(settings, "AntigravityProviderCheck").IsChecked = true;
        Named<CheckBox>(settings, "ClaudeOfficialCheck").IsChecked = true;
        Named<CheckBox>(settings, "CodexOfficialCheck").IsChecked = true;
        Named<CheckBox>(settings, "AntigravityUsageCheck").IsChecked = true;
        Named<CheckBox>(settings, "LaunchAtLoginCheck").IsChecked = false;
        Named<CheckBox>(settings, "DesktopWidgetCheck").IsChecked = false;
        Named<ComboBox>(settings, "RefreshIntervalCombo").SelectedItem = 10;
        Click(save);
        await UntilAsync(() => !store.IsRefreshing, "settings-triggered fixture refresh completes");
        var saved = configStore.Load();
        Check(!settings.IsVisible, "Save Click handler closes settings");
        Check(!saved.ClaudeProviderEnabled && saved.CodexProviderEnabled && saved.AntigravityProviderEnabled,
            "Save persists provider selection to the temporary config");
        Check(saved.ClaudeOfficialUsageEnabled && saved.CodexOfficialUsageEnabled && saved.AntigravityUsageEnabled,
            "Save persists sync opt-ins only to the temporary config");
        Check(saved.RefreshIntervalMinutes == 10 && !saved.DesktopWidgetEnabled && !saved.LaunchAtLoginEnabled,
            "Save persists behavior choices without running the product app");
        Check(saved.ClaudePlanOverride == "max_5x", "Save preserves the unused legacy Claude plan preference");

        var beforeCancel = File.ReadAllText(configStore.ConfigPath);
        var canceledSettings = NewSettings(store, temporaryRoot, windows);
        canceledSettings.Show();
        await LayoutAsync(canceledSettings);
        Named<CheckBox>(canceledSettings, "CodexProviderCheck").IsChecked = false;
        Named<ComboBox>(canceledSettings, "RefreshIntervalCombo").SelectedItem = 60;
        Click(ContentButton(canceledSettings, "Cancel"));
        Check(!canceledSettings.IsVisible, "Cancel Click handler closes settings");
        Check(File.ReadAllText(configStore.ConfigPath) == beforeCancel && store.Config.CodexProviderEnabled
            && store.Config.RefreshIntervalMinutes == 10, "Cancel leaves saved config and active choices unchanged");
    }

    private static async Task CheckPercentRenderingAsync(FixtureUsageService service, UsageStore store,
        WidgetWindow widget, StackPanel rows)
    {
        // These are normalized REMAINING percentages, not live account data
        // or API cost. Used percentages are converted in provider fixtures.
        var boundaries = new (double Left, string Text)[]
        {
            (95, "95%"), (94.9, "94.9%"), (95.1, "95.1%"),
            (99, "99%"), (99.5, "99.5%"), (100, "100%")
        };
        var tray = typeof(WidgetWindow).Assembly.GetType("UsageKun.App.TrayIcon")
            ?? throw new InvalidOperationException("Tray rendering type was not found.");
        var tooltip = tray.GetMethod("TooltipPercent", BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("Tray tooltip formatter was not found.");
        var fill = tray.GetMethod("MeterFillHeight", BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("Tray meter renderer was not found.");

        foreach (var (left, expected) in boundaries)
        {
            service.Current = [Quota(UsageProvider.Codex, 300) with
            {
                Percent = left,
                Used = left,
                Weekly = new UsageWindow(left, DateTimeOffset.Now.AddDays(6))
            }];
            await store.RefreshAsync();
            await LayoutAsync(widget);
            var row = rows.Children.Cast<DependencyObject>().Single();
            Check(Descendants<TextBlock>(row).Count(block => block.Text == expected) == 3,
                $"remaining {left} renders {expected} in header, primary and weekly lines");
            var bars = Descendants<Grid>(row).Where(grid => grid.ColumnDefinitions.Count == 2
                && grid.ColumnDefinitions.Cast<ColumnDefinition>().All(column => column.Width.GridUnitType == GridUnitType.Star)).ToArray();
            Check(bars.Length == 2 && bars.All(bar => bar.ColumnDefinitions[0].Width.Value == left
                && Math.Abs(bar.ColumnDefinitions[1].Width.Value - (100 - left)) < 0.000001),
                $"remaining {left} keeps its precise primary and weekly bar proportions");
            Check(Equals(tooltip.Invoke(null, [left, UsageStatus.Ok]), expected + " left"),
                $"remaining {left} keeps the same tray tooltip precision");
            var fillHeight = (int)(fill.Invoke(null, [left, 28]) ?? -1);
            Check(left == 100 ? fillHeight == 28 : fillHeight < 28,
                $"remaining {left} fills the entire tray meter only at exact 100");
        }

        service.Current = [Quota(UsageProvider.Codex, 300) with
        {
            Percent = 94.9,
            Used = 94.9,
            Weekly = new UsageWindow(95.1, DateTimeOffset.Now.AddDays(6))
        }];
        await store.RefreshAsync();
        Check(HasText(widget, "94.9%") && HasText(widget, "95.1%") && !HasText(widget, "100%"),
            "primary and weekly remaining values render independently");

        service.Current = [Quota(UsageProvider.Codex, 300) with
        {
            Percent = 95,
            Weekly = new UsageWindow(null, null)
        }];
        await store.RefreshAsync();
        Check(HasText(widget, "95%") && HasText(widget, "UNKNOWN") && !HasText(widget, "100%"),
            "an unreported weekly quota renders UNKNOWN without inventing 100%");

        foreach (var invalid in new double?[] { null, double.NaN, double.PositiveInfinity, -1, 101 })
        {
            service.Current = [Quota(UsageProvider.Codex, 300) with
            {
                Percent = invalid,
                Used = null,
                Status = UsageStatus.Unknown,
                Weekly = new UsageWindow(invalid, null)
            }];
            await store.RefreshAsync();
            await LayoutAsync(widget);
            Check(HasText(widget, "--%") && HasText(widget, "UNKNOWN") && !HasText(widget, "100%"),
                "an unknown or invalid remaining quota renders unavailable without a numeric fallback");
            Check(Equals(tooltip.Invoke(null, [invalid, UsageStatus.Unknown]), "Unknown"),
                "an unknown or invalid remaining quota renders Unknown in the tray tooltip");
        }

        service.Current = [Quota(UsageProvider.Codex, 300) with
        {
            Percent = 100,
            Weekly = new UsageWindow(100, DateTimeOffset.Now.AddDays(6))
        }];
        await store.RefreshAsync();
        Check(HasText(widget, "100%"), "the refresh failure fixture starts from a real synthetic 100%");
        service.FailNextRefresh();
        await store.RefreshAsync();
        Check(HasText(widget, "--%") && HasText(widget, "UNKNOWN") && !HasText(widget, "100%"),
            "a failed refresh replaces the previous 100% with unknown primary and weekly quotas");
        Check(Named<TextBlock>(widget, "ErrorText").IsVisible && store.MostConstrainedPercent == null,
            "a failed refresh shows its safe explanation and leaves the tray quota unknown");

        service.Current = [Quota(UsageProvider.Codex, 300) with
        {
            Percent = 100,
            UpdatedAt = DateTimeOffset.Now.AddHours(-1),
            Weekly = new UsageWindow(100, DateTimeOffset.Now.AddDays(6))
        }];
        await store.RefreshAsync();
        Check(HasText(widget, "--%") && !HasText(widget, "100%"),
            "an expired snapshot cannot display an old 100% as current quota");

        service.Current = [Quota(UsageProvider.Codex, 300) with
        {
            Percent = 100,
            ResetAt = DateTimeOffset.Now.AddMinutes(-1),
            Weekly = new UsageWindow(95, DateTimeOffset.Now.AddDays(6))
        }];
        await store.RefreshAsync();
        Check(HasText(widget, "--%") && HasText(widget, "95%") && !HasText(widget, "100%"),
            "an elapsed primary window is unknown while its current weekly quota stays distinct");
    }

    private static SettingsWindow NewSettings(UsageStore store, string temporaryRoot, List<Window> windows)
    {
        var settings = new SettingsWindow(store);
        MarkTestWindow(settings);
        Named<TextBlock>(settings, "ConfigPathText").Text = "TEST DATA ONLY\nTemporary settings: " + temporaryRoot;
        windows.Add(settings);
        return settings;
    }

    private static void MarkTestWindow(Window window)
    {
        window.AllowsTransparency = false;
        window.WindowStyle = WindowStyle.SingleBorderWindow;
        window.Title = "usage_kun UI CHECK - TEST DATA ONLY";
        window.ShowInTaskbar = true;
        window.Topmost = false;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = SystemParameters.WorkArea.Left + 16;
        window.Top = SystemParameters.WorkArea.Top + 16;
    }

    private static UsageSnapshot Quota(UsageProvider provider, int? minutes) => new()
    {
        Provider = provider,
        Status = UsageStatus.Ok,
        Percent = 71,
        Used = 71,
        Limit = 100,
        Unit = "%",
        UpdatedAt = DateTimeOffset.Now,
        ResetAt = DateTimeOffset.Now.AddHours(minutes == 10080 ? 121 : 4),
        PrimaryWindowMinutes = minutes,
        Source = "TEST DATA",
        Message = "TEST DATA ONLY. No account or real usage was read."
    };

    private static T Named<T>(FrameworkElement root, string name) where T : FrameworkElement =>
        root.FindName(name) as T ?? throw new InvalidOperationException($"Control '{name}' was not found.");

    private static Button ContentButton(DependencyObject root, string content) =>
        Descendants<Button>(root).Single(button => Equals(button.Content, content));

    private static bool HasText(DependencyObject root, string text) => Descendants<TextBlock>(root).Any(block => block.Text == text);

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T match) yield return match;
            foreach (var descendant in Descendants<T>(child)) yield return descendant;
        }
    }

    private static bool IsInsideWindow(FrameworkElement element, Window window)
    {
        var bounds = element.TransformToAncestor(window).TransformBounds(new Rect(element.RenderSize));
        return element.IsVisible && bounds.Top >= 0 && bounds.Left >= 0
            && bounds.Bottom <= window.ActualHeight + 1 && bounds.Right <= window.ActualWidth + 1;
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, button));

    private static async Task LayoutAsync(Window window)
    {
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        window.UpdateLayout();
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
    }

    private static async Task UntilAsync(Func<bool> predicate, string operation)
    {
        var watch = Stopwatch.StartNew();
        while (!predicate())
        {
            if (watch.Elapsed > TimeSpan.FromSeconds(10)) throw new TimeoutException(operation);
            await Task.Delay(20);
        }
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
    }

    private static void Check(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException(name);
        _checks++;
        Console.WriteLine("PASS " + name);
    }

    private sealed class FixtureUsageService : IUsageService
    {
        private readonly object _sync = new();
        private IReadOnlyList<UsageSnapshot> _current = [];
        private TaskCompletionSource? _nextGate;
        private bool _failNextRefresh;
        private int _callCount;
        public int CallCount { get { lock (_sync) return _callCount; } }
        public IReadOnlyList<UsageSnapshot> Current
        {
            get { lock (_sync) return _current; }
            set { lock (_sync) _current = value; }
        }

        public TaskCompletionSource PauseNextRefresh()
        {
            lock (_sync)
            {
                _nextGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                return _nextGate;
            }
        }

        public void FailNextRefresh()
        {
            lock (_sync) _failNextRefresh = true;
        }

        public async Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now)
        {
            TaskCompletionSource? gate;
            IReadOnlyList<UsageSnapshot> snapshots;
            bool fail;
            lock (_sync)
            {
                _callCount++;
                gate = _nextGate;
                _nextGate = null;
                snapshots = _current;
                fail = _failNextRefresh;
                _failNextRefresh = false;
            }
            if (gate != null) await gate.Task;
            if (fail) throw new InvalidOperationException("TEST DATA ONLY. Synthetic refresh failure.");
            return snapshots;
        }
    }
}
