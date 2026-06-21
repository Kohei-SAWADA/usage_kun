import Combine
import Foundation

@MainActor
public protocol UsageService {
    func snapshots(now: Date) async -> [UsageSnapshot]
}

public final class MockUsageService: UsageService {
    public init() {}

    public func snapshots(now: Date) async -> [UsageSnapshot] {
        [
            UsageSnapshot(
                provider: .claude,
                status: .warning,
                used: 73,
                limit: 100,
                percent: 73,
                resetAt: Calendar.current.date(byAdding: .hour, value: 3, to: now),
                updatedAt: now,
                message: "Session limit is getting close.",
                source: "mock",
                unit: nil
            ),
            UsageSnapshot(
                provider: .codex,
                status: .ok,
                used: 41,
                limit: 100,
                percent: 41,
                resetAt: Calendar.current.date(byAdding: .hour, value: 7, to: now),
                updatedAt: now,
                message: "Enough room for a larger task.",
                source: "mock",
                unit: nil
            )
        ]
    }
}

public final class CompositeUsageService: UsageService {
    private let configStore: AppConfigStore
    private let credentialStore: KeychainCredentialStore
    private let localLogService: LocalLogUsageService
    private let cliOAuthService: CLIOAuthUsageService
    private let browserOAuthService: BrowserOAuthUsageService

    public init(
        configStore: AppConfigStore,
        credentialStore: KeychainCredentialStore,
        localLogService: LocalLogUsageService = LocalLogUsageService(),
        cliOAuthService: CLIOAuthUsageService = CLIOAuthUsageService(),
        browserOAuthService: BrowserOAuthUsageService = BrowserOAuthUsageService()
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.localLogService = localLogService
        self.cliOAuthService = cliOAuthService
        self.browserOAuthService = browserOAuthService
    }

    public func snapshots(now: Date) async -> [UsageSnapshot] {
        let config = configStore.load()
        var snapshots: [UsageSnapshot] = []

        if config.localLogEnabled || config.claudeOfficialUsageEnabled || config.codexOfficialUsageEnabled {
            let localSnapshots = config.localLogEnabled
                ? await localLogService.snapshots(now: now)
                : []

            var codex = localSnapshots.first { $0.provider == .codex }
            var claude = localSnapshots.first { $0.provider == .claude }

            if config.codexOfficialUsageEnabled {
                switch await cliOAuthService.codexSnapshot(now: now) {
                case .success(let snapshot):
                    codex = snapshot
                case .failure(let failure):
                    codex = Self.fallbackSnapshot(local: codex, provider: .codex, reason: failure.reason, now: now)
                }
            }

            if config.claudeOfficialUsageEnabled {
                switch await cliOAuthService.claudeSnapshot(now: now) {
                case .success(let snapshot):
                    claude = snapshot
                case .failure(let failure):
                    claude = Self.fallbackSnapshot(local: claude, provider: .claude, reason: failure.reason, now: now)
                }
            }

            if let codex {
                snapshots.append(codex)
            }

            if let claude {
                snapshots.append(claude)
            }
        }

        if config.openAIAdminEnabled || config.anthropicAdminEnabled {
            let adminService = AdminAPIUsageService(credentialStore: credentialStore)

            if config.openAIAdminEnabled {
                snapshots.append(await adminService.openAISnapshot(now: now))
            }

            if config.anthropicAdminEnabled {
                snapshots.append(await adminService.anthropicSnapshot(now: now))
            }
        }

        if config.cookieOAuthEnabled {
            snapshots.append(browserOAuthService.snapshot(config: config, now: now))
        }

        if snapshots.isEmpty {
            snapshots = disabledSnapshots(now: now)
        }

        return snapshots
    }

    private static func fallbackSnapshot(
        local: UsageSnapshot?,
        provider: UsageProvider,
        reason: String,
        now: Date
    ) -> UsageSnapshot {
        if let local {
            let baseMessage = local.message.map { "\($0) " } ?? ""
            return UsageSnapshot(
                provider: local.provider,
                status: local.status,
                used: local.used,
                limit: local.limit,
                percent: local.percent,
                resetAt: local.resetAt,
                updatedAt: local.updatedAt,
                message: "\(baseMessage)Official sync unavailable: \(reason)",
                source: local.source,
                unit: local.unit,
                metricTitle: local.metricTitle,
                secondaryTitle: local.secondaryTitle,
                secondaryValue: local.secondaryValue
            )
        }

        return UsageSnapshot(
            provider: provider,
            status: .error,
            used: nil,
            limit: nil,
            percent: nil,
            resetAt: nil,
            updatedAt: now,
            message: reason,
            source: provider == .claude ? "Claude official usage API" : "Codex official usage API",
            unit: "%",
            metricTitle: "5 hour left",
            secondaryTitle: "Reset"
        )
    }

    private func disabledSnapshots(now: Date) -> [UsageSnapshot] {
        [
            UsageSnapshot(
                provider: .codex,
                status: .unknown,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "Enable a sync source in Settings.",
                source: "disabled",
                unit: nil,
                metricTitle: "Status",
                secondaryTitle: "Sync"
            ),
            UsageSnapshot(
                provider: .claude,
                status: .unknown,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "Choose local logs, Admin API, or Cookie/OAuth.",
                source: "disabled",
                unit: nil,
                metricTitle: "Status",
                secondaryTitle: "Sync"
            )
        ]
    }
}

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var snapshots: [UsageSnapshot] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var config: AppConfig
    @Published public private(set) var hasOpenAIAdminKey: Bool
    @Published public private(set) var hasAnthropicAdminKey: Bool
    @Published public private(set) var hasManualCookieHeader: Bool
    @Published public private(set) var lastErrorMessage: String?

    private let service: UsageService
    private let configStore: AppConfigStore
    private let credentialStore: KeychainCredentialStore

    public init(
        service: UsageService,
        configStore: AppConfigStore = AppConfigStore(),
        credentialStore: KeychainCredentialStore = KeychainCredentialStore()
    ) {
        self.service = service
        self.configStore = configStore
        self.credentialStore = credentialStore
        config = configStore.load()
        hasOpenAIAdminKey = credentialStore.hasValue(for: .openAIAdminKey)
        hasAnthropicAdminKey = credentialStore.hasValue(for: .anthropicAdminKey)
        hasManualCookieHeader = credentialStore.hasValue(for: .manualCookieHeader)
    }

    public var highestUsagePercent: Double {
        snapshots.compactMap(\.percent).max() ?? 0
    }

    public var highestUsageLabel: String {
        snapshots.contains { $0.percent != nil }
            ? "\(Int(highestUsagePercent.rounded()))%"
            : "Syncing"
    }

    public var codexFiveHourLabel: String {
        guard let snapshot = snapshots.first(where: { $0.provider == .codex }),
              let percent = snapshot.percent else {
            return "--%"
        }

        return "\(Int(percent.rounded()))%"
    }

    public var codexStatus: UsageStatus {
        snapshots.first(where: { $0.provider == .codex })?.status ?? .unknown
    }

    public var overallStatus: UsageStatus {
        snapshots.map(\.status).max() ?? .unknown
    }

    public var updatedAt: Date? {
        snapshots.map(\.updatedAt).max()
    }

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { @MainActor in
            let result = await service.snapshots(now: Date())
            snapshots = result
            isRefreshing = false
        }
    }

    public func updateConfig(_ newConfig: AppConfig) {
        config = newConfig

        do {
            try configStore.save(newConfig)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to save settings."
        }

        refresh()
    }

    public func saveCredential(_ value: String, for key: CredentialKey) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try credentialStore.save(trimmed, for: key)
            reloadCredentialPresence()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to save to Keychain."
        }

        refresh()
    }

    public func deleteCredential(_ key: CredentialKey) {
        credentialStore.delete(key)
        reloadCredentialPresence()
        refresh()
    }

    private func reloadCredentialPresence() {
        hasOpenAIAdminKey = credentialStore.hasValue(for: .openAIAdminKey)
        hasAnthropicAdminKey = credentialStore.hasValue(for: .anthropicAdminKey)
        hasManualCookieHeader = credentialStore.hasValue(for: .manualCookieHeader)
    }
}
