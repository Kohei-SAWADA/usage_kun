import CoreGraphics
import Foundation
import UsageKunCore

enum AppWindowLayout {
    static let popoverWidth: CGFloat = 420
    static let desktopWidth: CGFloat = 312

    static func enabledProviderCount(in config: AppConfig) -> Int {
        [config.codexProviderEnabled, config.claudeProviderEnabled].filter { $0 }.count
    }

    static func isProviderEnabled(_ provider: UsageProvider, in config: AppConfig) -> Bool {
        switch provider {
        case .claude:
            return config.claudeProviderEnabled
        case .codex:
            return config.codexProviderEnabled
        }
    }

    static func popoverSize(selectedTab: DashboardTab, providerCount: Int) -> CGSize {
        CGSize(width: popoverWidth, height: popoverHeight(selectedTab: selectedTab, providerCount: providerCount))
    }

    static func desktopSize(providerCount: Int) -> CGSize {
        CGSize(width: desktopWidth, height: desktopHeight(providerCount: providerCount))
    }

    private static func popoverHeight(selectedTab: DashboardTab, providerCount: Int) -> CGFloat {
        switch selectedTab {
        case .settings:
            return 680
        case .usage:
            switch normalizedProviderCount(providerCount) {
            case 0:
                return 380
            case 1:
                return 520
            default:
                return 680
            }
        }
    }

    private static func desktopHeight(providerCount: Int) -> CGFloat {
        switch normalizedProviderCount(providerCount) {
        case 0:
            return 92
        case 1:
            return 178
        default:
            return 260
        }
    }

    private static func normalizedProviderCount(_ providerCount: Int) -> Int {
        min(max(providerCount, 0), 2)
    }
}
