import Foundation

public final class BrowserOAuthUsageService {
    public init() {}

    public func snapshot(config: AppConfig, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .browserOAuth,
            status: .unknown,
            used: nil,
            limit: nil,
            percent: nil,
            resetAt: nil,
            updatedAt: now,
            message: "Opt-in is enabled for \(config.browserSource.displayName). Automatic cookie reading will be implemented after safety review.",
            source: "explicit opt-in",
            unit: nil,
            metricTitle: "Status",
            secondaryTitle: "Target",
            secondaryValue: config.browserSource.displayName
        )
    }
}
