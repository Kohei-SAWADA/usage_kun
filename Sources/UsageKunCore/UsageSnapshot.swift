import Foundation
import SwiftUI

public enum UsageProvider: String, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        }
    }

    public var mark: String {
        switch self {
        case .claude:
            "C"
        case .codex:
            "X"
        }
    }

    public var accent: Color {
        switch self {
        case .codex:
            Color(red: 0.66, green: 0.44, blue: 1.00)
        case .claude:
            Color(red: 1.00, green: 0.55, blue: 0.18)
        }
    }
}

public enum UsageStatus: String, Comparable {
    case ok
    case warning
    case critical
    case unknown
    case error

    public var rank: Int {
        switch self {
        case .ok:
            0
        case .unknown:
            1
        case .warning:
            2
        case .critical:
            3
        case .error:
            4
        }
    }

    public var label: String {
        switch self {
        case .ok:
            "Ready"
        case .warning:
            "Watch"
        case .critical:
            "Low"
        case .unknown:
            "Setup"
        case .error:
            "Error"
        }
    }

    public var tint: Color {
        switch self {
        case .ok:
            Color(red: 0.16, green: 1.00, blue: 0.52)
        case .warning:
            Color(red: 0.58, green: 1.00, blue: 0.20)
        case .critical:
            Color(red: 0.80, green: 1.00, blue: 0.28)
        case .unknown:
            Color(red: 0.36, green: 0.56, blue: 0.42)
        case .error:
            Color(red: 0.04, green: 0.88, blue: 0.34)
        }
    }

    public static func < (lhs: UsageStatus, rhs: UsageStatus) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct UsageWindow: Equatable {
    public let percentLeft: Double?
    public let resetAt: Date?
    public let detail: String?

    public init(percentLeft: Double?, resetAt: Date?, detail: String? = nil) {
        self.percentLeft = percentLeft
        self.resetAt = resetAt
        self.detail = detail
    }
}

public enum UsageStatusRules {
    public static func status(primaryLeft: Double, weeklyLeft: Double?) -> UsageStatus {
        let effectiveLeft = min(primaryLeft, weeklyLeft ?? 100)

        if effectiveLeft <= 15 {
            return .critical
        }

        if effectiveLeft <= 35 {
            return .warning
        }

        return .ok
    }
}

public struct UsageSnapshot: Identifiable, Equatable {
    public let provider: UsageProvider
    public let status: UsageStatus
    public let used: Double?
    public let limit: Double?
    public let percent: Double?
    public let resetAt: Date?
    public let updatedAt: Date
    public let message: String?
    public let source: String
    public let unit: String?
    public let metricTitle: String
    public let secondaryTitle: String
    public let secondaryValue: String?
    public let weekly: UsageWindow?

    public var id: UsageProvider { provider }

    public init(
        provider: UsageProvider,
        status: UsageStatus,
        used: Double?,
        limit: Double?,
        percent: Double?,
        resetAt: Date?,
        updatedAt: Date,
        message: String?,
        source: String = "mock",
        unit: String? = nil,
        metricTitle: String = "Usage",
        secondaryTitle: String = "Reset",
        secondaryValue: String? = nil,
        weekly: UsageWindow? = nil
    ) {
        self.provider = provider
        self.status = status
        self.used = used
        self.limit = limit
        self.percent = percent
        self.resetAt = resetAt
        self.updatedAt = updatedAt
        self.message = message
        self.source = source
        self.unit = unit
        self.metricTitle = metricTitle
        self.secondaryTitle = secondaryTitle
        self.secondaryValue = secondaryValue
        self.weekly = weekly
    }

    public var usedDisplay: String {
        guard let used else { return "--" }

        if let limit {
            return "\(formatMetric(used))/\(formatMetric(limit))"
        }

        return formatMetric(used)
    }

    public var percentDisplay: String {
        guard let percent else { return "--%" }
        return "\(Int(percent.rounded()))%"
    }

    private func formatMetric(_ value: Double) -> String {
        if unit == "USD" {
            return String(format: "$%.2f", value)
        }

        if unit == "%" {
            return "\(Int(value.rounded()))%"
        }

        let number: String
        let absolute = abs(value)

        if absolute >= 1_000_000 {
            number = String(format: "%.1fM", value / 1_000_000)
        } else if absolute >= 1_000 {
            number = String(format: "%.1fK", value / 1_000)
        } else {
            number = String(format: "%.0f", value)
        }

        if let unit, !unit.isEmpty {
            return "\(number) \(unit)"
        }

        return number
    }
}
