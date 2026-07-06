import SwiftUI
import UsageKunCore

@MainActor
final class DashboardRouter: ObservableObject {
    @Published var selectedTab: DashboardTab = .usage
}

struct UsageDashboardView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var router: DashboardRouter
    @State private var onboardingDetection = OnboardingDetector.Detection(
        claudeSignInFound: false,
        codexSignInFound: false
    )
    @State private var didCheckOnboarding = false

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
                            if shouldShowOnboarding {
                                OnboardingBanner(
                                    detection: onboardingDetection,
                                    onEnable: enableOfficialSyncFromOnboarding,
                                    onDismiss: completeOnboarding
                                )
                            }

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
        .onAppear(perform: checkOnboardingIfNeeded)
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

    private var shouldShowOnboarding: Bool {
        !store.config.onboardingCompleted
            && !store.config.claudeOfficialUsageEnabled
            && !store.config.codexOfficialUsageEnabled
            && onboardingDetection.anyFound
    }

    private func checkOnboardingIfNeeded() {
        guard !didCheckOnboarding else { return }
        didCheckOnboarding = true

        let detection = OnboardingDetector.detect()
        onboardingDetection = detection

        guard !store.config.onboardingCompleted else { return }
        if store.config.claudeOfficialUsageEnabled || store.config.codexOfficialUsageEnabled || !detection.anyFound {
            completeOnboarding()
        }
    }

    private func enableOfficialSyncFromOnboarding() {
        var config = store.config
        config.claudeOfficialUsageEnabled = onboardingDetection.claudeSignInFound
        config.codexOfficialUsageEnabled = onboardingDetection.codexSignInFound
        config.onboardingCompleted = true
        store.updateConfig(config)
    }

    private func completeOnboarding() {
        guard !store.config.onboardingCompleted else { return }
        var config = store.config
        config.onboardingCompleted = true
        store.updateConfig(config)
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

private struct OnboardingBanner: View {
    let detection: OnboardingDetector.Detection
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Get exact numbers")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("\(providerText) sign-ins were found on this Mac. Turn on official sync to show the same numbers as /usage and /status.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button(action: onEnable) {
                    Text("Use official sync")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .background(AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Button(action: onDismiss) {
                    Text("Keep estimates")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .background(AppTheme.panelHover)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if detection.claudeSignInFound {
                Text("macOS will ask for Keychain access once for Claude Code.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.accent.opacity(0.38), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var providerText: String {
        switch (detection.claudeSignInFound, detection.codexSignInFound) {
        case (true, true):
            "Claude Code and Codex"
        case (true, false):
            "Claude Code"
        case (false, true):
            "Codex"
        case (false, false):
            "No CLI"
        }
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
