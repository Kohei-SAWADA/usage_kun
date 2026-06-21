import SwiftUI
import UsageKunCore

struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 9) {
                ForEach(displaySnapshots) { snapshot in
                    DesktopWidgetRow(snapshot: snapshot)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 312, height: 188)
        .background(AppTheme.background.opacity(0.96))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.barTrack, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("usage")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(nextActionLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.overallStatus.tint)
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
        switch store.codexStatus {
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
        .help(help)
    }
}

private struct DesktopWidgetRow: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let accent = snapshot.provider.accent

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderLogo(provider: snapshot.provider, color: accent, size: 15)
                    .frame(width: 24, height: 24)
                    .background(accent.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.provider.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)

                    Text(detailText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                Text(snapshot.percentDisplay)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            DesktopWidgetBar(percent: snapshot.percent ?? 0, accent: accent)
        }
    }

    private var detailText: String {
        if let secondaryValue = snapshot.secondaryValue {
            return "\(snapshot.secondaryTitle) \(secondaryValue)"
        }

        if let resetAt = snapshot.resetAt {
            return "Reset in \(resetText(resetAt))"
        }

        return snapshot.message ?? snapshot.status.label
    }

    private func resetText(_ resetAt: Date) -> String {
        let seconds = max(Int(resetAt.timeIntervalSinceNow), 0)
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

private struct DesktopWidgetBar: View {
    let percent: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = width * min(max(percent, 0), 100) / 100

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(AppTheme.barTrack)

                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(accent)
                    .frame(width: max(5, fill))
            }
        }
        .frame(height: 5)
    }
}
