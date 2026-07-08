import SwiftUI
import UsageKunCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLoginMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsSection(title: "Meter", subtitle: "display") {
                    ToggleRow(
                        title: "Launch at login",
                        caption: "Start usage_kun automatically when you sign in to macOS.",
                        isOn: launchAtLoginBinding
                    )

                    if let launchAtLoginMessage {
                        SettingsNote(text: launchAtLoginMessage)
                    }

                    Divider().overlay(AppTheme.barTrack)

                    ToggleRow(
                        title: "Pinned home meter",
                        caption: "Show the compact meter at the top-left of the desktop.",
                        isOn: configBinding(\.desktopWidgetEnabled)
                    )

                    Divider().overlay(AppTheme.barTrack)

                    ToggleRow(
                        title: "Compact menu numbers",
                        caption: "Use C/X percentages instead of the usage label and meter.",
                        isOn: configBinding(\.menuBarShowsNumbers)
                    )

                    Divider().overlay(AppTheme.barTrack)

                    ToggleRow(
                        title: "Notifications",
                        caption: "Alert when remaining drops below 25% / 10%, and when a window resets (works in the packaged app).",
                        isOn: notificationsBinding
                    )

                    Divider().overlay(AppTheme.barTrack)

                    RefreshIntervalRow(minutes: refreshIntervalBinding)
                }

                SettingsSection(title: "Sync", subtitle: "local logs") {
                    ToggleRow(
                        title: "Local log sync",
                        caption: "Read known usage logs under ~/.codex and ~/.claude.",
                        isOn: configBinding(\.localLogEnabled)
                    )

                    Divider().overlay(AppTheme.barTrack)

                    ClaudePlanRow(selection: configBinding(\.claudePlanOverride))

                    SettingsNote(
                        text: "Only local usage logs are read. Conversation text is not displayed or sent anywhere."
                    )
                }

                SettingsSection(title: "Official usage", subtitle: "CLI sign-in") {
                    ToggleRow(
                        title: "Claude official usage",
                        caption: "Use the Claude Code sign-in (Keychain) to fetch the exact numbers /usage shows. macOS asks for Keychain access once.",
                        isOn: configBinding(\.claudeOfficialUsageEnabled)
                    )

                    Divider().overlay(AppTheme.barTrack)

                    ToggleRow(
                        title: "Codex official usage",
                        caption: "Use the Codex sign-in (~/.codex/auth.json) to fetch live rate limits from ChatGPT.",
                        isOn: configBinding(\.codexOfficialUsageEnabled)
                    )

                    SettingsNote(
                        text: "Tokens are read locally and sent only to their own vendor's usage endpoint. They are never stored, refreshed, or logged. If a fetch fails, the local log estimate is shown instead."
                    )
                }

                if let message = store.lastErrorMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UsageStatus.error.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(UsageStatus.error.tint.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(16)
        }
        .onAppear {
            launchAtLoginMessage = LaunchAtLoginService.apply(isEnabled: store.config.launchAtLoginEnabled)
                ?? LaunchAtLoginService.statusMessage()
        }
    }

    private func configBinding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { store.config[keyPath: keyPath] },
            set: { value in
                var config = store.config
                config[keyPath: keyPath] = value
                store.updateConfig(config)
            }
        )
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { store.config.refreshIntervalMinutes },
            set: { value in
                var config = store.config
                config.refreshIntervalMinutes = min(max(value, 1), 60)
                store.updateConfig(config)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.config.launchAtLoginEnabled },
            set: { value in
                var config = store.config
                config.launchAtLoginEnabled = value
                store.updateConfig(config)
                launchAtLoginMessage = LaunchAtLoginService.apply(isEnabled: value)
                    ?? LaunchAtLoginService.statusMessage()
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.config.notificationsEnabled },
            set: { value in
                var config = store.config
                config.notificationsEnabled = value
                store.updateConfig(config)

                if value {
                    UsageNotifier.requestAuthorizationIfPossible()
                }
            }
        )
    }

}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textFaint)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RefreshIntervalRow: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh interval")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Lower values update faster but wake the app more often.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack(spacing: 8) {
                Text("\(minutes)m")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)

                Stepper("", value: $minutes, in: 1...60, step: 1)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }
}

private struct ClaudePlanRow: View {
    @Binding var selection: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude plan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Sets the 5-hour cap for the local Claude estimate. Auto reads the plan from ~/.claude.json; pick your plan manually if the estimate looks off. Official usage sync is always exact regardless of this setting.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Picker("", selection: $selection) {
                Text("Auto").tag("auto")
                Text("Pro").tag("pro")
                Text("Max 5x").tag("max_5x")
                Text("Max 20x").tag("max_20x")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 96)
        }
    }
}

private struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppTheme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}

private struct ToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}
