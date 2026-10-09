import Foundation
import ServiceManagement

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func synchronize() -> Bool { true }
}

@main
struct LoginChecks {
    @MainActor static func main() throws {
        func expect(_ value: Bool, _ label: String) { precondition(value, label) }
        let defaults = MemoryDefaults()
        var state = SMAppService.Status.notRegistered
        var registrations = 0, removals = 0
        func service(path: String = "/Applications/Test.app", installed: Bool = true) -> LoginService {
            LoginService(defaults: defaults, installed: installed, bundlePath: path, status: { state },
                register: { registrations += 1; state = .enabled },
                unregister: { removals += 1; state = .notRegistered })
        }
        service().initialize(existingInstallation: false)
        expect(registrations == 1, "fresh install registers once")
        // Serialize then reconstruct the preference store, equivalent to a new process.
        let data = try JSONSerialization.data(withJSONObject: defaults.values)
        defaults.values = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        service().initialize(existingInstallation: true)
        expect(registrations == 1, "restart must not register again")
        service().setEnabled(false)
        service().initialize(existingInstallation: true)
        expect(registrations == 1 && removals == 1, "explicit off survives restart")
        service().setEnabled(true)
        state = .notRegistered // User removes item in macOS settings.
        service().initialize(existingInstallation: true)
        expect(registrations == 2, "OS off survives restart")
        state = .requiresApproval
        let pending = service(); pending.initialize(existingInstallation: true)
        expect(pending.message.contains("Approval required") && registrations == 2, "pending approval is shown without re-registering")
        state = .enabled
        service(path: "/Applications/Moved.app").initialize(existingInstallation: true)
        expect(registrations == 3 && removals == 2, "moved enabled bundle is repaired once")
        service(path: "/Applications/Moved.app").initialize(existingInstallation: true)
        expect(registrations == 3, "move repair is not repeated")
        defaults.values = [:]; state = .notRegistered
        service().initialize(existingInstallation: true, requested: false)
        expect(registrations == 3, "legacy explicit off is preserved")
        defaults.values = [:]
        service().initialize(existingInstallation: true)
        expect(registrations == 3, "legacy OS off is preserved")
        defaults.values = [:]
        service(installed: false).initialize(existingInstallation: false)
        expect(registrations == 3, "download/build copies do not register")
        service().initialize(existingInstallation: true)
        expect(registrations == 4, "fresh default registers after moving to Applications")
        defaults.values = [:]; state = .notRegistered
        let failure = LoginService(defaults: defaults, installed: true, status: { state }, register: { throw CocoaError(.fileWriteNoPermission) })
        failure.initialize(existingInstallation: false)
        expect(failure.message.contains("Could not"), "OS failure is visible")
        failure.initialize(existingInstallation: false)
        expect(!failure.enabled, "failed automatic registration is not retried")
        print("Login startup checks passed (isolated OS backend and persisted preference reconstruction).")
    }
}
