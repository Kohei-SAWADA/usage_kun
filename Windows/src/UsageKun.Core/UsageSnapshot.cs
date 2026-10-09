using System.Globalization;

namespace UsageKun.Core;

public enum UsageProvider
{
    Claude,
    Codex,
    Antigravity
}

public static class UsageProviderInfo
{
    public static string DisplayName(this UsageProvider provider) => provider switch
    {
        UsageProvider.Claude => "Claude Code",
        UsageProvider.Codex => "Codex",
        UsageProvider.Antigravity => "Gemini (Antigravity)",
        _ => provider.ToString()
    };

    public static string Mark(this UsageProvider provider) => provider switch
    {
        UsageProvider.Claude => "C",
        UsageProvider.Antigravity => "G",
        _ => "X"
    };

    /// Accent color as sRGB bytes; the UI layer converts to its own color type.
    /// Values mirror UsageProvider.accent in the macOS UsageKunCore.
    public static (byte R, byte G, byte B) Accent(this UsageProvider provider) => provider switch
    {
        UsageProvider.Codex => (168, 112, 255),
        UsageProvider.Antigravity => (77, 179, 255),
        _ => (255, 140, 46)
    };
}

public enum UsageStatus
{
    Ok,
    Warning,
    Critical,
    Unknown,
    Error
}

public static class UsageStatusInfo
{
    /// Severity order for aggregation; mirrors UsageStatus.rank on macOS.
    public static int Rank(this UsageStatus status) => status switch
    {
        UsageStatus.Ok => 0,
        UsageStatus.Unknown => 1,
        UsageStatus.Warning => 2,
        UsageStatus.Critical => 3,
        UsageStatus.Error => 4,
        _ => 1
    };

    public static string Label(this UsageStatus status) => status switch
    {
        UsageStatus.Ok => "Ready",
        UsageStatus.Warning => "Watch",
        UsageStatus.Critical => "Low",
        UsageStatus.Unknown => "Setup",
        UsageStatus.Error => "Error",
        _ => "Setup"
    };

    /// Status tint as sRGB bytes; mirrors UsageStatus.tint on macOS.
    public static (byte R, byte G, byte B) Tint(this UsageStatus status) => status switch
    {
        UsageStatus.Ok => (41, 255, 133),
        UsageStatus.Warning => (148, 255, 51),
        UsageStatus.Critical => (204, 255, 71),
        UsageStatus.Unknown => (92, 143, 107),
        UsageStatus.Error => (10, 224, 87),
        _ => (92, 143, 107)
    };

    public static UsageStatus MostSevere(IEnumerable<UsageStatus> statuses)
    {
        var result = UsageStatus.Unknown;
        var found = false;

        foreach (var status in statuses)
        {
            if (!found || status.Rank() > result.Rank())
            {
                result = status;
                found = true;
            }
        }

        return result;
    }
}

public sealed record UsageWindow(double? PercentLeft, DateTimeOffset? ResetAt, string? Detail = null);

public static class UsageStatusRules
{
    public static UsageStatus Status(double primaryLeft, double? weeklyLeft)
    {
        var effectiveLeft = Math.Min(primaryLeft, weeklyLeft ?? 100);

        if (effectiveLeft <= 15)
        {
            return UsageStatus.Critical;
        }

        if (effectiveLeft <= 35)
        {
            return UsageStatus.Warning;
        }

        return UsageStatus.Ok;
    }
}

public sealed record UsageSnapshot
{
    public required UsageProvider Provider { get; init; }
    public required UsageStatus Status { get; init; }
    public double? Used { get; init; }
    public double? Limit { get; init; }
    public double? Percent { get; init; }
    public DateTimeOffset? ResetAt { get; init; }
    public required DateTimeOffset UpdatedAt { get; init; }
    public string? Message { get; init; }
    public string Source { get; init; } = "mock";
    public string? Unit { get; init; }
    public string MetricTitle { get; init; } = "Usage";
    public string SecondaryTitle { get; init; } = "Reset";
    public string? SecondaryValue { get; init; }
    public UsageWindow? Weekly { get; init; }
    private int? _primaryWindowMinutes;
    public int? PrimaryWindowMinutes
    {
        get => _primaryWindowMinutes ?? (Provider == UsageProvider.Codex ? null : 300);
        init => _primaryWindowMinutes = value;
    }

    public string PrimaryWindowLabel => PrimaryWindowMinutes switch
    {
        null or <= 0 => "LIMIT",
        int minutes when minutes % 10080 == 0 => $"{minutes / 10080}W",
        int minutes when minutes % 1440 == 0 => $"{minutes / 1440}D",
        int minutes when minutes % 60 == 0 => $"{minutes / 60}H",
        int minutes => $"{minutes}M"
    };

    public string PrimaryWindowTitle => PrimaryWindowMinutes switch
    {
        300 => "5-HOUR",
        10080 => "1-WEEK",
        _ => PrimaryWindowLabel
    };

    public string UsedDisplay
    {
        get
        {
            if (Used is not { } used)
            {
                return "--";
            }

            if (Limit is { } limit)
            {
                return $"{FormatMetric(used)}/{FormatMetric(limit)}";
            }

            return FormatMetric(used);
        }
    }

    public string PercentDisplay => Format.Percent(Percent);

    private string FormatMetric(double value)
    {
        if (Unit == "USD")
        {
            return value.ToString("$0.00", CultureInfo.InvariantCulture);
        }

        if (Unit == "%")
        {
            return Format.Percent(value);
        }

        var number = Format.Compact(value);

        if (!string.IsNullOrEmpty(Unit))
        {
            return $"{number} {Unit}";
        }

        return number;
    }
}

public static class Format
{
    public static bool IsValidPercent(double value) => double.IsFinite(value) && value is >= 0 and <= 100;

    /// Preserve a reported decimal without turning an almost-full quota into 100%.
    /// Invalid or unavailable percentages remain unknown on every Windows surface.
    public static string Percent(double? value)
    {
        if (value is not { } percent || !IsValidPercent(percent)) return "--%";
        if (percent == 100) return "100%";
        var rounded = Math.Round(percent, 1, MidpointRounding.AwayFromZero);
        if (rounded == 0 && percent > 0) return "<0.1%";
        return Math.Min(rounded, 99.9).ToString("0.#", CultureInfo.InvariantCulture) + "%";
    }

    public static string Compact(double value)
    {
        if (Math.Abs(value) >= 1_000_000)
        {
            return (value / 1_000_000).ToString("0.0", CultureInfo.InvariantCulture) + "M";
        }

        if (Math.Abs(value) >= 1_000)
        {
            return (value / 1_000).ToString("0.0", CultureInfo.InvariantCulture) + "K";
        }

        return value.ToString("0", CultureInfo.InvariantCulture);
    }

    /// "3h 12m" / "42m" — used for the primary reset column.
    public static string RelativeReset(DateTimeOffset resetAt, DateTimeOffset now)
    {
        var seconds = Math.Max((int)(resetAt - now).TotalSeconds, 0);
        var hours = seconds / 3600;
        var minutes = seconds % 3600 / 60;

        if (hours > 0)
        {
            return $"{hours}h {minutes}m";
        }

        return $"{minutes}m";
    }

    /// "2d 4h" / "3h 12m" / "42m" — used for weekly reset columns in the widget.
    public static string WidgetReset(DateTimeOffset resetAt, DateTimeOffset now)
    {
        var seconds = Math.Max((int)(resetAt - now).TotalSeconds, 0);
        var days = seconds / 86_400;
        var hours = seconds % 86_400 / 3600;
        var minutes = seconds % 3600 / 60;

        if (days > 0)
        {
            return $"{days}d {hours}h";
        }

        if (hours > 0)
        {
            return $"{hours}h {minutes}m";
        }

        return $"{minutes}m";
    }
}
