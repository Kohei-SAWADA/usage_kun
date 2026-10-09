import Foundation

/// Persistent first-launch decision. OS removals/denials are never undone on restart.
struct LoginStartupPolicy {
    static func shouldRegister(initialized: Bool, existingInstallation: Bool,
                               requested: Bool, registered: Bool) -> Bool {
        !initialized && !existingInstallation && requested && !registered
    }
}
