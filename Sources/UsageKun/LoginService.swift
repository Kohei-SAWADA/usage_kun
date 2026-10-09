import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginService: ObservableObject {
    @Published var enabled = false
    @Published var message = ""
    private let defaults: UserDefaults
    private let initializedKey = "loginStartup.initialized.v1"
    private let preferenceKey = "loginStartup.requested"
    private let pendingKey = "loginStartup.pendingFreshInstall"
    private let pathKey = "loginStartup.bundlePath"
    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let installedOverride: Bool?
    private let bundlePath: String
    init(defaults: UserDefaults = .standard, installed: Bool? = nil,
         bundlePath: String = Bundle.main.bundleURL.standardizedFileURL.path,
         status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.defaults = defaults; self.installedOverride = installed; self.bundlePath = bundlePath
        self.status = status; self.register = register; self.unregister = unregister
    }

    private var installed: Bool {
        if let installedOverride { return installedOverride }
        let path = bundlePath
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasSuffix(".app") && (path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/"))
    }

    func initialize(existingInstallation: Bool, requested: Bool = true) {
        refresh()
        if !installed {
            if !existingInstallation && !defaults.bool(forKey: initializedKey) {
                defaults.set(requested, forKey: pendingKey)
            }
            return
        } // Do not register a download/build/test copy.
        let initialized = defaults.bool(forKey: initializedKey)
        let registered = enabled
        let shouldRegister = LoginStartupPolicy.shouldRegister(initialized: initialized,
            existingInstallation: existingInstallation && !defaults.bool(forKey: pendingKey), requested: requested, registered: registered)
        if !initialized {
            // Mark before the OS call, so failures/approval never cause repeated automatic requests.
            defaults.set(true, forKey: initializedKey)
            defaults.set(existingInstallation && !defaults.bool(forKey: pendingKey) ? registered && requested : requested, forKey: preferenceKey)
            defaults.set(false, forKey: pendingKey)
            guard defaults.synchronize() else {
                message = "Could not save startup preference. Use Settings to try again."
                return
            }
        }
        if !initialized && !requested && registered { setEnabled(false) }
        else if shouldRegister { setEnabled(true) }
        else { refresh() }
        // SMAppService uses the bundle identity. Only repair a moved, still-enabled
        // installation; never recreate an item removed/disabled in System Settings.
        let path = bundlePath
        if initialized, status() == .enabled,
           defaults.bool(forKey: preferenceKey), let old = defaults.string(forKey: pathKey), old != path {
            do {
                try unregister()
                try register()
                refresh()
            } catch {
                refresh()
                message = "Could not update the moved app's login item. Toggle Launch at Login to retry."
                return
            }
        }
        if initialized, status() == .requiresApproval,
           let old = defaults.string(forKey: pathKey), old != path {
            message += " The app moved; approve it, then reopen it to update the login item."
            return
        }
        defaults.set(path, forKey: pathKey)
    }

    func refresh() {
        switch status() {
        case .enabled:
            enabled = true; message = "Enabled in macOS Login Items."
        case .requiresApproval:
            enabled = true; message = "Approval required in System Settings > General > Login Items. Automatic startup is pending."
        case .notRegistered:
            enabled = false; message = "Disabled in macOS Login Items."
        case .notFound:
            enabled = false; message = "Login item not found. Keep this app in Applications, then enable Launch at Login."
        @unknown default:
            enabled = false; message = "macOS login item status is unavailable."
        }
        if !installed { message = "Move this app to Applications before enabling Launch at Login." }
    }

    func setEnabled(_ value: Bool) {
        guard !value || installed else { refresh(); return }
        defaults.set(value, forKey: preferenceKey)
        defaults.set(true, forKey: initializedKey)
        guard defaults.synchronize() else {
            message = "Could not save startup preference. Try again."
            return
        }
        do {
            let status = status()
            if value && status != .enabled && status != .requiresApproval { try register() }
            if !value && (status == .enabled || status == .requiresApproval) { try unregister() }
            defaults.set(bundlePath, forKey: pathKey)
            refresh()
        } catch {
            refresh()
            message = "Could not update Launch at Login. Move the app to Applications and try again."
        }
    }
}
