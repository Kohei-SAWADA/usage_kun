import SwiftUI
import UsageKunCore

struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header

            VStack(spacing: 11) {
                ForEach(displaySnapshots) { snapshot in
                    DesktopWidgetRow(snapshot: snapshot)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 312, height: 260)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.background.opacity(0.96))
                .overlay(WidgetGrid())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.barTrack, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("usage")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(nextActionLabel.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(store.overallStatus.tint)
                    .tracking(0.8)
                    .lineLimit(1)
            }

            Spacer()

            DesktopIconButton(
                systemName: store.isRefreshing ? "arrow.triangle.2.circlepath.circle" : "arrow.clockwise",
                help: "Refresh",
                action: store.refresh
            )

            DesktopIconButton(
                systemName: "gearshape",
                help: "Settings",
                action: onOpenSettings
            )
        }
    }

    private var displaySnapshots: [UsageSnapshot] {
        let primaryProviders: [UsageProvider] = [.codex, .claude]
        let primary = primaryProviders.compactMap { provider in
            store.snapshots.first { $0.provider == provider }
        }

        if !primary.isEmpty {
            return Array(primary.prefix(2))
        }

        return Array(store.snapshots.prefix(2))
    }

    private var nextActionLabel: String {
        // Overall status covers whichever providers are enabled; codexStatus
        // alone would stick at "Setup" when Codex is hidden in Settings.
        switch store.overallStatus {
        case .ok:
            "Go"
        case .warning:
            "Go light"
        case .critical:
            "Hold off"
        case .unknown:
            "Setup"
        case .error:
            "Check"
        }
    }
}

private struct DesktopIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.textMuted)
        .background(AppTheme.panelHover)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.barTrack.opacity(0.8), lineWidth: 1)
        )
        .help(help)
    }
}

private struct DesktopWidgetRow: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let accent = snapshot.provider.accent

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ProviderLogo(provider: snapshot.provider, color: accent, size: 15)
                    .frame(width: 25, height: 25)
                    .background(accent.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(accent.opacity(0.42), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.provider.displayName)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)

                    Text("5-HOUR PRIMARY")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(AppTheme.textFaint)
                        .tracking(0.5)
                }

                Spacer(minLength: 8)

                Text(snapshot.percentDisplay)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(spacing: 7) {
                DesktopLimitLine(
                    title: "5h",
                    percent: snapshot.percent,
                    resetAt: snapshot.resetAt,
                    detail: snapshot.percent == nil ? snapshot.usedDisplay : nil,
                    accent: accent,
                    height: 8,
                    isPrimary: true
                )

                if let weekly = snapshot.weekly {
                    DesktopLimitLine(
                        title: "1w",
                        percent: weekly.percentLeft,
                        resetAt: weekly.resetAt,
                        detail: weekly.detail,
                        accent: accent,
                        height: 4,
                        isPrimary: false
                    )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.panel.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

private struct DesktopLimitLine: View {
    let title: String
    let percent: Double?
    let resetAt: Date?
    let detail: String?
    let accent: Color
    let height: CGFloat
    let isPrimary: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: isPrimary ? 10 : 8, weight: .black, design: .monospaced))
                .foregroundStyle(isPrimary ? AppTheme.textMuted : AppTheme.textFaint)
                .frame(width: 22, alignment: .leading)

            if let percent {
                DesktopWidgetBar(percent: percent, accent: accent, height: height, muted: !isPrimary)

                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: isPrimary ? 11 : 9, weight: .black, design: .monospaced))
                    .foregroundStyle(isPrimary ? AppTheme.textPrimary : AppTheme.textMuted)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)

                Text(resetAt.map(Self.resetText) ?? "--")
                    .font(.system(size: isPrimary ? 10 : 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textMuted)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            } else if let detail {
                Text(detail.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private static func resetText(_ resetAt: Date) -> String {
        let seconds = max(Int(resetAt.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

private struct DesktopWidgetBar: View {
    let percent: Double
    let accent: Color
    let height: CGFloat
    let muted: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = width * min(max(percent, 0), 100) / 100

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(AppTheme.barTrack.opacity(muted ? 0.54 : 1))

                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(accent.opacity(muted ? 0.66 : 1))
                    .frame(width: max(height, fill))
                    .shadow(color: accent.opacity(muted ? 0.14 : 0.34), radius: muted ? 3 : 7)
            }
        }
        .frame(height: height)
    }
}

private struct WidgetGrid: View {
    var body: some View {
        Canvas { context, size in
            let color = GraphicsContext.Shading.color(AppTheme.accent.opacity(0.045))
            for y in stride(from: CGFloat(0), through: size.height, by: CGFloat(6)) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: color, lineWidth: 0.35)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
