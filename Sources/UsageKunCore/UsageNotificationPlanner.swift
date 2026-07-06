import Foundation

public enum UsageNotificationPlanner {
    public struct Event: Equatable {
        public let providerName: String
        public let title: String
        public let body: String
        public let dedupKey: String

        public init(providerName: String, title: String, body: String, dedupKey: String) {
            self.providerName = providerName
            self.title = title
            self.body = body
            self.dedupKey = dedupKey
        }
    }

    public static func plan(
        previous: [UsageSnapshot],
        current: [UsageSnapshot],
        alreadyNotified: Set<String>
    ) -> (events: [Event], notified: Set<String>) {
        var events: [Event] = []
        var notified = alreadyNotified
        let previousByProvider = Dictionary(uniqueKeysWithValues: previous.map { ($0.provider, $0) })

        for snapshot in current {
            guard let previousSnapshot = previousByProvider[snapshot.provider] else {
                continue
            }

            let previousWindows = Dictionary(uniqueKeysWithValues: windows(for: previousSnapshot).map { ($0.id, $0) })

            for window in windows(for: snapshot) {
                guard let previousWindow = previousWindows[window.id],
                      let currentLeft = window.percentLeft else {
                    continue
                }

                let keyPrefix = "\(snapshot.provider.rawValue).\(window.id)"
                let resetChanged = previousWindow.resetAt != window.resetAt

                if resetChanged {
                    removeThresholdKeys(prefix: keyPrefix, from: &notified)
                }

                for threshold in thresholds {
                    let key = thresholdKey(prefix: keyPrefix, threshold: threshold)
                    if currentLeft > threshold + 15 {
                        notified.remove(key)
                    }
                }

                if let previousLeft = previousWindow.percentLeft {
                    for threshold in thresholds where previousLeft > threshold && currentLeft <= threshold {
                        let key = thresholdKey(prefix: keyPrefix, threshold: threshold)
                        guard !notified.contains(key) else { continue }

                        events.append(Event(
                            providerName: snapshot.provider.displayName,
                            title: "\(snapshot.provider.displayName): \(window.name) low",
                            body: "\(Int(currentLeft.rounded()))% left\(resetSuffix(window.resetAt))",
                            dedupKey: key
                        ))
                        notified.insert(key)
                    }

                    if let previousReset = previousWindow.resetAt,
                       previousReset <= snapshot.updatedAt,
                       currentLeft - previousLeft >= 20 {
                        let resetKey = "\(keyPrefix).reset.\(Int(previousReset.timeIntervalSince1970))"
                        if !notified.contains(resetKey) {
                            events.append(Event(
                                providerName: snapshot.provider.displayName,
                                title: "\(snapshot.provider.displayName): \(window.name) reset",
                                body: "\(Int(currentLeft.rounded()))% left.",
                                dedupKey: resetKey
                            ))
                            removeThresholdKeys(prefix: keyPrefix, from: &notified)
                            notified.insert(resetKey)
                        }
                    }
                }
            }
        }

        return (events, notified)
    }

    private static let thresholds: [Double] = [25, 10]

    private struct WindowState {
        let id: String
        let name: String
        let percentLeft: Double?
        let resetAt: Date?
    }

    private static func windows(for snapshot: UsageSnapshot) -> [WindowState] {
        var states = [
            WindowState(
                id: "5h",
                name: "5 hour window",
                percentLeft: snapshot.percent,
                resetAt: snapshot.resetAt
            )
        ]

        if let weekly = snapshot.weekly {
            states.append(WindowState(
                id: "weekly",
                name: "7 day window",
                percentLeft: weekly.percentLeft,
                resetAt: weekly.resetAt
            ))
        }

        return states
    }

    private static func thresholdKey(prefix: String, threshold: Double) -> String {
        "\(prefix).threshold\(Int(threshold))"
    }

    private static func removeThresholdKeys(prefix: String, from notified: inout Set<String>) {
        for threshold in thresholds {
            notified.remove(thresholdKey(prefix: prefix, threshold: threshold))
        }
    }

    private static func resetSuffix(_ resetAt: Date?) -> String {
        guard let resetAt else {
            return "."
        }

        return " (resets \(relativeResetText(resetAt)))."
    }

    private static func relativeResetText(_ date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}
