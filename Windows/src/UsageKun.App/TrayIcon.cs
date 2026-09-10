using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using UsageKun.Core;

namespace UsageKun.App;

/// System tray residency: the Windows counterpart of the macOS menu bar item.
/// The icon is drawn at runtime as a small vertical meter of the most
/// constrained remaining percent, tinted with the overall status color.
internal sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
    private readonly UsageStore _store;
    private readonly Action _toggleWidget;
    private readonly ToolStripMenuItem _toggleWidgetItem;
    private readonly ToolStripMenuItem _refreshItem;
    private Icon? _currentIcon;

    public TrayIcon(UsageStore store, Action toggleWidget, Action refresh, Action openSettings, Action quit)
    {
        _store = store;
        _toggleWidget = toggleWidget;

        var menu = new ContextMenuStrip();
        _toggleWidgetItem = new ToolStripMenuItem("Show usage meter", null, (_, _) => toggleWidget());
        menu.Items.Add(_toggleWidgetItem);
        _refreshItem = new ToolStripMenuItem("Refresh now", null, (_, _) => refresh());
        menu.Items.Add(_refreshItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Settings...", null, (_, _) => openSettings()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit usage_kun", null, (_, _) => quit()));
        menu.Opening += (_, _) =>
        {
            _toggleWidgetItem.Text = _store.Config.DesktopWidgetEnabled
                ? "Hide usage meter"
                : "Show usage meter";
        };

        _notifyIcon = new NotifyIcon
        {
            ContextMenuStrip = menu,
            Visible = true
        };
        _notifyIcon.MouseUp += (_, args) =>
        {
            if (args.Button == MouseButtons.Left)
            {
                _toggleWidget();
            }
        };

        _store.Changed += OnStoreChanged;
        Update();
    }

    private void OnStoreChanged(object? sender, EventArgs e) => Update();

    private void Update()
    {
        var entries = _store.TrayEntries;
        _refreshItem.Enabled = !_store.IsRefreshing;
        _refreshItem.Text = _store.IsRefreshing ? "Refreshing…" : "Refresh now";
        var tooltipLines = new List<string> { _store.IsRefreshing ? "usage_kun · updating" : "usage_kun" };
        foreach (var entry in entries)
        {
            var percent = entry.PercentLeft is { } left
                ? $"{(int)Math.Round(left, MidpointRounding.AwayFromZero)}% left"
                : entry.Status.Label();
            tooltipLines.Add($"{entry.Mark} {percent}");
        }

        if (entries.Count == 0)
        {
            tooltipLines.Add("Choose providers in Settings");
        }

        // NotifyIcon.Text is limited to 127 chars; the meter stays terse anyway.
        var text = string.Join("\n", tooltipLines);
        _notifyIcon.Text = text.Length <= 127 ? text : text[..127];

        var previousIcon = _currentIcon;
        _currentIcon = DrawMeterIcon(_store.MostConstrainedPercent, _store.OverallStatus);
        _notifyIcon.Icon = _currentIcon;
        previousIcon?.Dispose();
    }

    private static Icon DrawMeterIcon(double? percentLeft, UsageStatus status)
    {
        const int size = 32;
        const int barWidth = 16;
        const int barHeight = 28;
        var barLeft = (size - barWidth) / 2;
        var barTop = (size - barHeight) / 2;

        var (r, g, b) = status.Tint();
        var tint = Color.FromArgb(r, g, b);

        using var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);

            using var trackPath = RoundedRect(new Rectangle(barLeft, barTop, barWidth, barHeight), 5);
            using (var trackBrush = new SolidBrush(Color.FromArgb(88, tint)))
            {
                graphics.FillPath(trackBrush, trackPath);
            }

            if (percentLeft is { } percent)
            {
                var clamped = Math.Min(Math.Max(percent, 0), 100);
                var fillHeight = (int)Math.Round(barHeight * clamped / 100);
                if (fillHeight >= 3)
                {
                    var fillRect = new Rectangle(barLeft, barTop + (barHeight - fillHeight), barWidth, fillHeight);
                    using var fillPath = RoundedRect(fillRect, 5);
                    using var fillBrush = new SolidBrush(tint);
                    graphics.FillPath(fillBrush, fillPath);
                }
            }
            else
            {
                // No percent yet (setup/error): a centered dot instead of a level.
                using var dotBrush = new SolidBrush(tint);
                graphics.FillEllipse(dotBrush, size / 2 - 3, size / 2 - 3, 6, 6);
            }

            using var borderPen = new Pen(Color.FromArgb(200, tint), 1.6f);
            graphics.DrawPath(borderPen, trackPath);
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var fromHandle = Icon.FromHandle(handle);
            return (Icon)fromHandle.Clone();
        }
        finally
        {
            // GetHicon allocates an unmanaged icon that Icon.FromHandle does not own.
            DestroyIcon(handle);
        }
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        var diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        var arc = new Rectangle(bounds.Location, new Size(diameter, diameter));

        path.AddArc(arc, 180, 90);
        arc.X = bounds.Right - diameter;
        path.AddArc(arc, 270, 90);
        arc.Y = bounds.Bottom - diameter;
        path.AddArc(arc, 0, 90);
        arc.X = bounds.Left;
        path.AddArc(arc, 90, 90);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        _store.Changed -= OnStoreChanged;
        _notifyIcon.Visible = false;
        _notifyIcon.ContextMenuStrip?.Dispose();
        _notifyIcon.Dispose();
        _currentIcon?.Dispose();
    }
}
