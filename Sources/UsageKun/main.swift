import AppKit
import Combine
import SwiftUI
import UsageKunCore

private final class InteractiveDesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var desktopWindow: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var lastRefreshIntervalMinutes: Int = -1
    private let usageStore: UsageStore
    private let dashboardRouter = DashboardRouter()

    override init() {
        let configStore = AppConfigStore()
        let credentialStore = KeychainCredentialStore()
        usageStore = UsageStore(
            service: CompositeUsageService(
                configStore: configStore,
                credentialStore: credentialStore
            ),
            configStore: configStore,
            credentialStore: credentialStore
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupApplicationMenu()
        setupStatusItem()
        setupPopover()
        setupDesktopWidget()
        observeUsageChanges()
        scheduleRefreshTimer(intervalMinutes: usageStore.config.refreshIntervalMinutes)
        _ = LaunchAtLoginService.apply(isEnabled: usageStore.config.launchAtLoginEnabled)
        usageStore.refresh()
    }

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit usage_kun",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = StatusIconRenderer.image(
                percent: usageStore.highestUsagePercent,
                status: usageStore.overallStatus
            )
            button.imagePosition = .imageLeading
            button.title = " usage"
            button.toolTip = "usage_kun"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 680)
        popover.contentViewController = NSHostingController(
            rootView: UsageDashboardView(store: usageStore, router: dashboardRouter)
        )
        self.popover = popover
    }

    private func setupDesktopWidget() {
        let size = NSSize(width: 312, height: 188)
        let panel = InteractiveDesktopPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "usage_kun"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.contentView = FirstMouseHostingView(
            rootView: DesktopWidgetView(
                store: usageStore,
                onOpenSettings: { [weak self] in
                    self?.presentPopoverFromStatusItem(selectedTab: .settings)
                }
            )
        )

        desktopWindow = panel
        syncDesktopWidgetVisibility(isEnabled: usageStore.config.desktopWidgetEnabled)
    }

    private func observeUsageChanges() {
        usageStore.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        usageStore.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.syncDesktopWidgetVisibility(isEnabled: config.desktopWidgetEnabled)
                self?.scheduleRefreshTimer(intervalMinutes: config.refreshIntervalMinutes)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.usageStore.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionDesktopWidget()
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            presentPopover(relativeTo: button)
        }
    }

    private func presentPopoverFromStatusItem(selectedTab: DashboardTab? = nil) {
        guard let button = statusItem?.button else { return }
        presentPopover(relativeTo: button, selectedTab: selectedTab)
    }

    private func presentPopover(relativeTo button: NSStatusBarButton, selectedTab: DashboardTab? = nil) {
        guard let popover else { return }

        if let selectedTab {
            dashboardRouter.selectedTab = selectedTab
        }

        usageStore.refresh()

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleRefreshTimer(intervalMinutes: Int) {
        let clamped = max(1, intervalMinutes)
        if clamped == lastRefreshIntervalMinutes, refreshTimer != nil {
            return
        }
        lastRefreshIntervalMinutes = clamped

        refreshTimer?.invalidate()
        let interval = TimeInterval(clamped) * 60
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.usageStore.refresh()
            }
        }
        timer.tolerance = max(5, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = StatusIconRenderer.image(
            percent: usageStore.highestUsagePercent,
            status: usageStore.overallStatus
        )
    }

    private func syncDesktopWidgetVisibility(isEnabled: Bool) {
        guard let desktopWindow else { return }

        if isEnabled {
            positionDesktopWidget()
            desktopWindow.orderFrontRegardless()
        } else {
            desktopWindow.orderOut(nil)
        }
    }

    private func positionDesktopWidget() {
        guard let desktopWindow,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let margin: CGFloat = 18
        let visibleFrame = screen.visibleFrame
        let size = desktopWindow.frame.size
        let origin = NSPoint(
            x: visibleFrame.minX + margin,
            y: visibleFrame.maxY - size.height - margin
        )

        desktopWindow.setFrameOrigin(origin)
    }
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
