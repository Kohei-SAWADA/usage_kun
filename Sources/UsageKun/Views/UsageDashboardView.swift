import SwiftUI
import UsageKunCore

@MainActor
final class DashboardRouter: ObservableObject {
    @Published var selectedTab: DashboardTab = .usage
}

struct UsageDashboardView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var router: DashboardRouter

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $router.selectedTab) {
                ForEach(DashboardTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Group {
                switch router.selectedTab {
                case .usage:
                    ScrollView {
                        VStack(spacing: 12) {
                            if store.snapshots.isEmpty {
                                EmptyUsageView()
                            } else {
                                ForEach(store.snapshots) { snapshot in
                                    UsageCardView(snapshot: snapshot)
                                }
                            }

                            FooterView(updatedAt: store.updatedAt, isRefreshing: store.isRefreshing) {
                                store.refresh()
                            }
                        }
                        .padding(16)
                    }
                case .settings:
                    SettingsView(store: store)
                }
            }
        }
        .frame(width: 420, height: 680)
        .background(AppTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("usage_kun")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Claude / Codex usage meter")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textMuted)
                }

                Spacer()

                StatusPill(status: store.overallStatus)
            }

            HStack(spacing: 10) {
                MetricBlock(title: "Codex 5h", value: store.codexFiveHourLabel)
                MetricBlock(title: "Next move", value: nextActionLabel)
            }
        }
        .padding(16)
        .background(AppTheme.header)
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

enum DashboardTab: String, CaseIterable, Identifiable {
    case usage
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage:
            "Usage"
        case .settings:
            "Settings"
        }
    }
}

private struct EmptyUsageView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sync data")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Enable local log sync in Settings.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MetricBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textFaint)

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FooterView: View {
    let updatedAt: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Data sources")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textFaint)

                Text("local-first sync")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
            }

            Spacer()

            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath.circle" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(AppTheme.panelHover)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Refresh")
        }
        .padding(12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
