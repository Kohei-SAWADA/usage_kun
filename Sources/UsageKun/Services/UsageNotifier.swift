import Combine
import Foundation
import UserNotifications
import UsageKunCore

@MainActor
final class UsageNotifier {
    private var previousSnapshots: [UsageSnapshot] = []
    private var alreadyNotified = Set<String>()
    private var cancellable: AnyCancellable?

    static func requestAuthorizationIfPossible() {
        guard Bundle.main.bundleIdentifier != nil else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func start(store: UsageStore) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        cancellable = store.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] snapshots in
                guard let self, let store else { return }
                self.handle(snapshots: snapshots, config: store.config)
            }
    }

    private func handle(snapshots: [UsageSnapshot], config: AppConfig) {
        guard config.notificationsEnabled else {
            previousSnapshots = snapshots
            return
        }

        let plan = UsageNotificationPlanner.plan(
            previous: previousSnapshots,
            current: snapshots,
            alreadyNotified: alreadyNotified
        )
        previousSnapshots = snapshots
        alreadyNotified = plan.notified

        for event in plan.events {
            deliver(event)
        }
    }

    private func deliver(_ event: UsageNotificationPlanner.Event) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: event.dedupKey,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
