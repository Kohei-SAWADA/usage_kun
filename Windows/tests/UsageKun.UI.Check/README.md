# Windows WPF integration checks

This isolated executable uses temporary configuration and in-memory fixtures. It does not invoke the product App.OnStartup, real providers, startup registration, or the normal tray. Every test window is marked TEST DATA ONLY and closed on exit.

```powershell
dotnet run --project Windows/tests/UsageKun.UI.Check
```

The checks exercise the actual XAML Click handlers for refresh, settings callbacks, Save and Cancel, plus 1W / 5H / LIMIT labels and three-provider layout on small screens. They do not simulate physical mouse input or validate native tray clicks. Success returns exit code 0; failures return 1 with diagnostics from synthetic test data.
