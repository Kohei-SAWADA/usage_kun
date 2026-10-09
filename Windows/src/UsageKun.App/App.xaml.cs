using System.Windows;
using System.Windows.Threading;
using UsageKun.Core;

namespace UsageKun.App;

public partial class App : Application
{
    private Mutex? _singleInstanceMutex;
    private UsageStore? _store;
    private TrayIcon? _trayIcon;
    private WidgetWindow? _widget;
    private SettingsWindow? _settings;
    private DispatcherTimer? _refreshTimer;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(initiallyOwned: true, @"Local\usage_kun_windows", out var isFirstInstance);
        if (!isFirstInstance)
        {
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        var configStore = new AppConfigStore();
        _store = new UsageStore(new CompositeUsageService(configStore), configStore);
        LaunchAtLogin.Initialize(_store.Config, configStore);
        _store.Changed += OnStoreChanged;

        _trayIcon = new TrayIcon(
            _store,
            toggleWidget: ToggleWidget,
            refresh: () => _ = _store.RefreshAsync(),
            openSettings: OpenSettings,
            quit: Shutdown);

        _refreshTimer = new DispatcherTimer();
        _refreshTimer.Tick += (_, _) => _ = _store.RefreshAsync();
        ApplyRefreshInterval();
        _refreshTimer.Start();

        SyncWidgetVisibility();
        _ = _store.RefreshAsync();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

    private void OnStoreChanged(object? sender, EventArgs e)
    {
        ApplyRefreshInterval();
        SyncWidgetVisibility();

    }

    private void ApplyRefreshInterval()
    {
        if (_refreshTimer == null || _store == null)
        {
            return;
        }

        var minutes = Math.Max(1, _store.Config.RefreshIntervalMinutes);
        var interval = TimeSpan.FromMinutes(minutes);
        if (_refreshTimer.Interval != interval)
        {
            _refreshTimer.Interval = interval;
        }
    }

    private void SyncWidgetVisibility()
    {
        if (_store == null)
        {
            return;
        }

        if (_store.Config.DesktopWidgetEnabled)
        {
            if (_widget == null)
            {
                _widget = new WidgetWindow(_store, OpenSettings);
                _widget.Closed += (_, _) => _widget = null;
                _widget.Show();
            }
        }
        else if (_widget != null)
        {
            var widget = _widget;
            _widget = null;
            widget.Close();
        }
    }

    private void ToggleWidget()
    {
        if (_store == null)
        {
            return;
        }

        var config = _store.Config.Clone();
        config.DesktopWidgetEnabled = !config.DesktopWidgetEnabled;
        _store.UpdateConfig(config);
    }

    private void OpenSettings()
    {
        if (_store == null)
        {
            return;
        }

        if (_settings == null)
        {
            _settings = new SettingsWindow(_store);
            _settings.Closed += (_, _) => _settings = null;
            _settings.Show();
        }

        // The settings window is independent of the meter, so it stays usable
        // when the meter is hidden from this same settings window.
        if (_settings.WindowState == WindowState.Minimized)
        {
            _settings.WindowState = WindowState.Normal;
        }
        _settings.Activate();
        _settings.Focus();
    }
}
