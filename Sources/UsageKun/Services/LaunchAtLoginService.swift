import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginService {
    static func apply(isEnabled: Bool) -> String? {
        do {
            if isEnabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    return nil
                case .requiresApproval:
                    return approvalMessage
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                    return statusMessage()
                @unknown default:
                    try SMAppService.mainApp.register()
                    return statusMessage()
                }
            } else {
                if SMAppService.mainApp.status == .enabled
                    || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                return nil
            }
        } catch {
            return "Could not update Launch at Login. Make sure you are running from UsageKun.app."
        }
    }

    static func statusMessage() -> String? {
        switch SMAppService.mainApp.status {
        case .enabled:
            return nil
        case .requiresApproval:
            return approvalMessage
        case .notRegistered:
            return nil
        case .notFound:
            return "Launch at Login is available only when UsageKun is running as UsageKun.app."
        @unknown default:
            return nil
        }
    }

    private static var approvalMessage: String {
        "Allow usage-kun in macOS System Settings > General > Login Items."
    }
}
