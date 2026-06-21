import Foundation

public enum BrowserSource: String, Codable, CaseIterable, Identifiable {
    case chrome
    case safari
    case edge
    case brave
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chrome:
            "Google Chrome"
        case .safari:
            "Safari"
        case .edge:
            "Microsoft Edge"
        case .brave:
            "Brave"
        case .manual:
            "Manual"
        }
    }
}

public struct AppConfig: Codable, Equatable {
    public var localLogEnabled: Bool
    public var claudeOfficialUsageEnabled: Bool
    public var codexOfficialUsageEnabled: Bool
    public var openAIAdminEnabled: Bool
    public var anthropicAdminEnabled: Bool
    public var cookieOAuthEnabled: Bool
    public var browserSource: BrowserSource
    public var refreshIntervalMinutes: Int
    public var desktopWidgetEnabled: Bool
    public var launchAtLoginEnabled: Bool

    public init(
        localLogEnabled: Bool = true,
        claudeOfficialUsageEnabled: Bool = false,
        codexOfficialUsageEnabled: Bool = false,
        openAIAdminEnabled: Bool = false,
        anthropicAdminEnabled: Bool = false,
        cookieOAuthEnabled: Bool = false,
        browserSource: BrowserSource = .chrome,
        refreshIntervalMinutes: Int = 5,
        desktopWidgetEnabled: Bool = true,
        launchAtLoginEnabled: Bool = true
    ) {
        self.localLogEnabled = localLogEnabled
        self.claudeOfficialUsageEnabled = claudeOfficialUsageEnabled
        self.codexOfficialUsageEnabled = codexOfficialUsageEnabled
        self.openAIAdminEnabled = openAIAdminEnabled
        self.anthropicAdminEnabled = anthropicAdminEnabled
        self.cookieOAuthEnabled = cookieOAuthEnabled
        self.browserSource = browserSource
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.desktopWidgetEnabled = desktopWidgetEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case localLogEnabled
        case claudeOfficialUsageEnabled
        case codexOfficialUsageEnabled
        case openAIAdminEnabled
        case anthropicAdminEnabled
        case cookieOAuthEnabled
        case browserSource
        case refreshIntervalMinutes
        case desktopWidgetEnabled
        case launchAtLoginEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        localLogEnabled = try container.decodeIfPresent(Bool.self, forKey: .localLogEnabled) ?? true
        claudeOfficialUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudeOfficialUsageEnabled) ?? false
        codexOfficialUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexOfficialUsageEnabled) ?? false
        openAIAdminEnabled = try container.decodeIfPresent(Bool.self, forKey: .openAIAdminEnabled) ?? false
        anthropicAdminEnabled = try container.decodeIfPresent(Bool.self, forKey: .anthropicAdminEnabled) ?? false
        cookieOAuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .cookieOAuthEnabled) ?? false
        browserSource = try container.decodeIfPresent(BrowserSource.self, forKey: .browserSource) ?? .chrome
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 5
        desktopWidgetEnabled = try container.decodeIfPresent(Bool.self, forKey: .desktopWidgetEnabled) ?? true
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? true
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
