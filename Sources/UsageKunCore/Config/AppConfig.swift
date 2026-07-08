import Foundation

public struct AppConfig: Codable, Equatable {
    public var localLogEnabled: Bool
    public var claudeOfficialUsageEnabled: Bool
    public var codexOfficialUsageEnabled: Bool
    public var refreshIntervalMinutes: Int
    public var desktopWidgetEnabled: Bool
    public var launchAtLoginEnabled: Bool
    public var menuBarShowsNumbers: Bool
    public var onboardingCompleted: Bool
    public var notificationsEnabled: Bool
    /// Claude plan for the local 5-hour estimate: "auto", "pro", "max_5x", or "max_20x".
    public var claudePlanOverride: String
    /// Providers to show. Unchecked providers are not fetched or displayed.
    public var claudeProviderEnabled: Bool
    public var codexProviderEnabled: Bool

    public init(
        localLogEnabled: Bool = true,
        claudeOfficialUsageEnabled: Bool = false,
        codexOfficialUsageEnabled: Bool = false,
        refreshIntervalMinutes: Int = 5,
        desktopWidgetEnabled: Bool = true,
        launchAtLoginEnabled: Bool = true,
        menuBarShowsNumbers: Bool = false,
        onboardingCompleted: Bool = false,
        notificationsEnabled: Bool = false,
        claudePlanOverride: String = "auto",
        claudeProviderEnabled: Bool = true,
        codexProviderEnabled: Bool = true
    ) {
        self.localLogEnabled = localLogEnabled
        self.claudeOfficialUsageEnabled = claudeOfficialUsageEnabled
        self.codexOfficialUsageEnabled = codexOfficialUsageEnabled
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.desktopWidgetEnabled = desktopWidgetEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.menuBarShowsNumbers = menuBarShowsNumbers
        self.onboardingCompleted = onboardingCompleted
        self.notificationsEnabled = notificationsEnabled
        self.claudePlanOverride = claudePlanOverride
        self.claudeProviderEnabled = claudeProviderEnabled
        self.codexProviderEnabled = codexProviderEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case localLogEnabled
        case claudeOfficialUsageEnabled
        case codexOfficialUsageEnabled
        case refreshIntervalMinutes
        case desktopWidgetEnabled
        case launchAtLoginEnabled
        case menuBarShowsNumbers
        case onboardingCompleted
        case notificationsEnabled
        case claudePlanOverride
        case claudeProviderEnabled
        case codexProviderEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        localLogEnabled = try container.decodeIfPresent(Bool.self, forKey: .localLogEnabled) ?? true
        claudeOfficialUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudeOfficialUsageEnabled) ?? false
        codexOfficialUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexOfficialUsageEnabled) ?? false
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 5
        desktopWidgetEnabled = try container.decodeIfPresent(Bool.self, forKey: .desktopWidgetEnabled) ?? true
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? true
        menuBarShowsNumbers = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowsNumbers) ?? false
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        claudePlanOverride = try container.decodeIfPresent(String.self, forKey: .claudePlanOverride) ?? "auto"
        claudeProviderEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudeProviderEnabled) ?? true
        codexProviderEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexProviderEnabled) ?? true
    }
}

public final class AppConfigStore {
    private let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configURL: URL? = nil) {
        if let configURL {
            self.configURL = configURL
        } else {
            let directory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/usage_kun", isDirectory: true)
            self.configURL = directory.appendingPathComponent("config.json")
        }

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }

        return (try? decoder.decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public func save(_ config: AppConfig) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }
}
