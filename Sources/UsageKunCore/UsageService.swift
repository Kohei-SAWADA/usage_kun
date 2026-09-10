import Combine
import Foundation

@MainActor
public protocol UsageService {
    func snapshots(now: Date) async -> [UsageSnapshot]
}

public struct MenuBarEntry: Equatable {
    public let mark: String
    public let percentLeft: Double?
    public let status: UsageStatus

    public init(mark: String, percentLeft: Double?, status: UsageStatus) {
        self.mark = mark
        self.percentLeft = percentLeft
        self.status = status
    }
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
    private let localLogService: LocalLogUsageService
    private let cliOAuthService: CLIOAuthUsageService
    private let antigravitySnapshot: @MainActor (Date) async -> UsageSnapshot

    public init(
        configStore: AppConfigStore,
        localLogService: LocalLogUsageService = LocalLogUsageService(),
        cliOAuthService: CLIOAuthUsageService = CLIOAuthUsageService(),
        antigravitySnapshot: @escaping @MainActor (Date) async -> UsageSnapshot = { now in
            await AntigravityUsageService().snapshot(now: now)
        }
    ) {
        self.configStore = configStore
        self.localLogService = localLogService
        self.cliOAuthService = cliOAuthService
        self.antigravitySnapshot = antigravitySnapshot
    }

    public func snapshots(now: Date) async -> [UsageSnapshot] {
        let config = configStore.load()
        localLogService.claudePlanOverride = config.claudePlanOverride
        var snapshots: [UsageSnapshot] = []

        if config.localLogEnabled || config.claudeOfficialUsageEnabled || config.codexOfficialUsageEnabled {
            let localSnapshots = config.localLogEnabled
                ? await localLogService.snapshots(now: now, providers: Set([
                    config.codexProviderEnabled ? UsageProvider.codex : nil,
                    config.claudeProviderEnabled ? UsageProvider.claude : nil
                ].compactMap { $0 }))
                : []

            var codex = config.codexProviderEnabled
                ? localSnapshots.first { $0.provider == .codex }
                : nil
            var claude = config.claudeProviderEnabled
                ? localSnapshots.first { $0.provider == .claude }
                : nil

            if config.codexProviderEnabled, config.codexOfficialUsageEnabled {
                switch await cliOAuthService.codexSnapshot(now: now) {
                case .success(let snapshot):
                    codex = snapshot
                case .failure(let failure):
                    codex = Self.fallbackSnapshot(local: codex, provider: .codex, reason: failure.reason, now: now)
                }
            }

            if config.claudeProviderEnabled, config.claudeOfficialUsageEnabled {
                switch await cliOAuthService.claudeSnapshot(now: now) {
                case .success(let snapshot):
                    claude = snapshot
                    if config.localLogEnabled, let leftPercent = snapshot.percent {
                        localLogService.recordClaudeOfficialSample(usedPercent: 100 - leftPercent, now: now)
                    }
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

        // Preserve a visible setup state for each selected provider even when
        // another provider already returned live data.
        for placeholder in disabledSnapshots(now: now) {
            let enabled = placeholder.provider == .codex ? config.codexProviderEnabled : config.claudeProviderEnabled
            if enabled, !snapshots.contains(where: { $0.provider == placeholder.provider }) {
                snapshots.append(placeholder)
            }
        }
        snapshots.sort { $0.provider == .codex && $1.provider != .codex }

        if config.antigravityProviderEnabled, configStore.load().antigravityProviderEnabled, !Task.isCancelled {
            snapshots.append(await antigravitySnapshot(now))
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
                secondaryValue: local.secondaryValue,
                weekly: local.weekly,
                primaryWindowMinutes: local.primaryWindowMinutes
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
                message: "Choose local logs or official CLI sync.",
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
    @Published public private(set) var lastErrorMessage: String?

    private let service: UsageService
    private let configStore: AppConfigStore
    private var configRevision = 0
    private var refreshPending = false

    public init(
        service: UsageService,
        configStore: AppConfigStore = AppConfigStore()
    ) {
        self.service = service
        self.configStore = configStore
        config = configStore.load()
    }

    public var menuBarEntries: [MenuBarEntry] {
        Self.menuBarEntries(snapshots: snapshots)
    }

    public nonisolated static func menuBarEntries(snapshots: [UsageSnapshot]) -> [MenuBarEntry] {
        [UsageProvider.claude, .codex, .antigravity].compactMap { provider in
            guard let snapshot = snapshots.first(where: { $0.provider == provider }) else {
                return nil
            }

            let effectivePercent: Double?
            if provider == .antigravity, snapshot.weekly?.percentLeft == nil {
                effectivePercent = nil
            } else if let primary = snapshot.percent {
                effectivePercent = min(primary, snapshot.weekly?.percentLeft ?? 100)
            } else {
                effectivePercent = nil
            }

            return MenuBarEntry(
                mark: provider.mark,
                percentLeft: effectivePercent,
                status: snapshot.status
            )
        }
    }

    public var mostConstrainedPercent: Double? {
        let entries = menuBarEntries
        guard !entries.contains(where: { $0.percentLeft == nil }) else { return nil }
        return entries.compactMap(\.percentLeft).min()
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
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        let revision = configRevision

        Task { @MainActor in
            let result = await service.snapshots(now: Date())
            // A provider toggle during an in-flight fetch must take effect
            // immediately after that fetch, rather than waiting for the timer.
            if revision == configRevision { snapshots = result }
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    public func updateConfig(_ newConfig: AppConfig) {
        configRevision += 1
        config = newConfig
        snapshots.removeAll { snapshot in
            switch snapshot.provider {
            case .claude: !newConfig.claudeProviderEnabled
            case .codex: !newConfig.codexProviderEnabled
            case .antigravity: !newConfig.antigravityProviderEnabled
            }
        }

        do {
            try configStore.save(newConfig)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to save settings."
        }

        refresh()
    }
}
