import Foundation
import Security

public struct OfficialSyncFailure: Error {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct OfficialRateWindow {
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowMinutes: Int?

    public var leftPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    public init(usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

public struct OfficialUsageReading {
    public let primary: OfficialRateWindow
    public let secondary: OfficialRateWindow?
    public let planLabel: String?

    public init(primary: OfficialRateWindow, secondary: OfficialRateWindow?, planLabel: String?) {
        self.primary = primary
        self.secondary = secondary
        self.planLabel = planLabel
    }
}

/// Fetches the official usage numbers that the Claude Code and Codex CLIs show in
/// `/usage` and `/status`, by reusing the sign-in tokens those CLIs already keep on
/// this machine. Read-only: tokens are never refreshed, copied elsewhere, or logged,
/// and they are sent only to their own vendor's endpoint.
@MainActor
public final class CLIOAuthUsageService {
    private let home: URL
    private let session: URLSession

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession = .shared) {
        self.home = home
        self.session = session
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    public func claudeSnapshot(now: Date) async -> Result<UsageSnapshot, OfficialSyncFailure> {
        let credentials: ClaudeOAuthCredentials
        switch claudeCredentials() {
        case .success(let value):
            credentials = value
        case .failure(let failure):
            return .failure(failure)
        }

        if let expiresAt = credentials.expiresAt, expiresAt <= now {
            return .failure(OfficialSyncFailure(
                reason: "Claude Code sign-in token has expired. Open Claude Code once to refresh it."
            ))
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Without a claude-code User-Agent this endpoint answers from an
        // aggressively rate-limited bucket and returns persistent 429s.
        request.setValue("claude-code/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                return .failure(OfficialSyncFailure(reason: "No HTTP response from the Claude usage endpoint."))
            }

            switch statusCode {
            case 200..<300:
                data = body
            case 401, 403:
                return .failure(OfficialSyncFailure(
                    reason: "Claude usage endpoint rejected the token (HTTP \(statusCode)). Open Claude Code once to refresh the sign-in."
                ))
            case 429:
                return .failure(OfficialSyncFailure(
                    reason: "Claude usage endpoint is rate limiting (HTTP 429). It recovers automatically."
                ))
            default:
                return .failure(OfficialSyncFailure(reason: "Claude usage endpoint returned HTTP \(statusCode)."))
            }
        } catch {
            return .failure(OfficialSyncFailure(reason: "Could not reach the Claude usage endpoint. Check the network."))
        }

        guard let reading = Self.parseClaudeOAuthUsage(data: data, now: now) else {
            return .failure(OfficialSyncFailure(reason: "Claude usage endpoint returned an unexpected format."))
        }

        return .success(Self.makeSnapshot(
            provider: .claude,
            reading: reading,
            now: now,
            source: "Claude official usage API",
            detail: "Official numbers, same as /usage in Claude Code."
        ))
    }

    private struct ClaudeOAuthCredentials {
        let accessToken: String
        let expiresAt: Date?
    }

    private func claudeCredentials() -> Result<ClaudeOAuthCredentials, OfficialSyncFailure> {
        var json: [String: Any]?

        if let data = Self.readGenericPassword(service: "Claude Code-credentials") {
            json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        if json == nil {
            // Older installs and Linux keep the same JSON in a plain file.
            let fileURL = home.appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: fileURL) {
                json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }

        guard let oauth = json?["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            return .failure(OfficialSyncFailure(
                reason: "Claude Code sign-in was not found in the Keychain. Sign in with Claude Code first, and allow Keychain access when macOS asks."
            ))
        }

        var expiresAt: Date?
        if let millis = oauth["expiresAt"] as? Double, millis > 0 {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        } else if let millis = oauth["expiresAt"] as? Int, millis > 0 {
            expiresAt = Date(timeIntervalSince1970: Double(millis) / 1000)
        }

        return .success(ClaudeOAuthCredentials(accessToken: accessToken, expiresAt: expiresAt))
    }

    private nonisolated static func readGenericPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }

        return item as? Data
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    public func codexSnapshot(now: Date) async -> Result<UsageSnapshot, OfficialSyncFailure> {
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = authJSON["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            return .failure(OfficialSyncFailure(
                reason: "Codex sign-in was not found in ~/.codex/auth.json. Sign in with the Codex CLI first."
            ))
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if let accountId = tokens["account_id"] as? String, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                return .failure(OfficialSyncFailure(reason: "No HTTP response from the ChatGPT usage endpoint."))
            }

            switch statusCode {
            case 200..<300:
                data = body
            case 401:
                return .failure(OfficialSyncFailure(
                    reason: "Codex sign-in token has expired (HTTP 401). Run codex once to refresh it."
                ))
            case 403:
                return .failure(OfficialSyncFailure(
                    reason: "ChatGPT usage endpoint refused this account (HTTP 403)."
                ))
            default:
                return .failure(OfficialSyncFailure(reason: "ChatGPT usage endpoint returned HTTP \(statusCode)."))
            }
        } catch {
            return .failure(OfficialSyncFailure(reason: "Could not reach the ChatGPT usage endpoint. Check the network."))
        }

        guard let reading = Self.parseCodexWhamUsage(data: data, now: now) else {
            return .failure(OfficialSyncFailure(reason: "ChatGPT usage endpoint returned an unexpected format."))
        }

        return .success(Self.makeSnapshot(
            provider: .codex,
            reading: reading,
            now: now,
            source: "Codex official usage API",
            detail: "Official numbers, same as /status in Codex."
        ))
    }

    // MARK: - Shared snapshot building

    public nonisolated static func makeSnapshot(
        provider: UsageProvider,
        reading: OfficialUsageReading,
        now: Date,
        source: String,
        detail: String
    ) -> UsageSnapshot {
        let leftPercent = reading.primary.leftPercent
        let resetAt = reading.primary.resetsAt
        let resetText = resetAt.map(Self.relativeResetText) ?? "--"
        let weekly = reading.secondary.map {
            UsageWindow(percentLeft: $0.leftPercent, resetAt: $0.resetsAt)
        }

        var messageParts = [detail]
        if let plan = reading.planLabel, !plan.isEmpty {
            messageParts.append("Plan: \(plan).")
        }

        return UsageSnapshot(
            provider: provider,
            status: UsageStatusRules.status(primaryLeft: leftPercent, weeklyLeft: weekly?.percentLeft),
            used: leftPercent,
            limit: nil,
            percent: leftPercent,
            resetAt: resetAt,
            updatedAt: now,
            message: messageParts.joined(separator: " "),
            source: source,
            unit: "%",
            metricTitle: "5 hour left",
            secondaryTitle: "Reset",
            secondaryValue: resetText,
            weekly: weekly
        )
    }

    // MARK: - Parsers (public so UsageKunCoreCheck can verify them)

    public nonisolated static func parseClaudeOAuthUsage(data: Data, now: Date) -> OfficialUsageReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let primary = claudeWindow(root["five_hour"], fallbackMinutes: 300) else {
            return nil
        }

        let secondary = claudeWindow(root["seven_day"], fallbackMinutes: 7 * 24 * 60)
        return OfficialUsageReading(primary: primary, secondary: secondary, planLabel: nil)
    }

    private nonisolated static func claudeWindow(_ value: Any?, fallbackMinutes: Int) -> OfficialRateWindow? {
        guard let object = value as? [String: Any],
              let utilization = double(object["utilization"]) else {
            return nil
        }

        return OfficialRateWindow(
            usedPercent: min(max(utilization, 0), 100),
            resetsAt: parseResetValue(object["resets_at"], now: Date()),
            windowMinutes: fallbackMinutes
        )
    }

    public nonisolated static func parseCodexWhamUsage(data: Data, now: Date) -> OfficialUsageReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let container = (root["rate_limits"] as? [String: Any])
            ?? (root["rate_limit"] as? [String: Any])
            ?? root

        var primary = codexWindow(container["primary"] ?? container["primary_window"] ?? container["five_hour"], now: now)
        var secondary = codexWindow(container["secondary"] ?? container["secondary_window"] ?? container["weekly"], now: now)

        // If the response only labels windows by duration, keep the shorter one as primary.
        if let first = primary, let second = secondary,
           let firstMinutes = first.windowMinutes, let secondMinutes = second.windowMinutes,
           firstMinutes > secondMinutes {
            primary = second
            secondary = first
        }

        guard let primary else {
            return nil
        }

        let plan = (root["plan_type"] as? String) ?? (root["plan"] as? String)
        return OfficialUsageReading(primary: primary, secondary: secondary, planLabel: plan)
    }

    private nonisolated static func codexWindow(_ value: Any?, now: Date) -> OfficialRateWindow? {
        guard let object = value as? [String: Any] else {
            return nil
        }

        let usedPercent: Double
        if let used = double(object["used_percent"]) ?? double(object["usage_percent"]) {
            usedPercent = used
        } else if let left = double(object["percent_left"]) ?? double(object["remaining_percent"]) {
            usedPercent = 100 - left
        } else {
            return nil
        }

        var resetsAt = parseResetValue(
            object["resets_at"] ?? object["reset_at"] ?? object["reset_time_ms"],
            now: now
        )
        if resetsAt == nil,
           let seconds = double(object["resets_in_seconds"]) ?? double(object["reset_after_seconds"]),
           seconds > 0 {
            resetsAt = now.addingTimeInterval(seconds)
        }

        var windowMinutes: Int?
        if let minutes = double(object["window_minutes"]) {
            windowMinutes = Int(minutes)
        } else if let seconds = double(object["limit_window_seconds"]) ?? double(object["window_duration_seconds"]) {
            windowMinutes = Int(seconds / 60)
        }

        return OfficialRateWindow(
            usedPercent: min(max(usedPercent, 0), 100),
            resetsAt: resetsAt,
            windowMinutes: windowMinutes
        )
    }

    private nonisolated static func parseResetValue(_ value: Any?, now: Date) -> Date? {
        if let text = value as? String {
            if let date = parseISO8601(text) {
                return date
            }

            if let numeric = Double(text) {
                return dateFromEpoch(numeric, now: now)
            }

            return nil
        }

        if let numeric = double(value) {
            return dateFromEpoch(numeric, now: now)
        }

        return nil
    }

    private nonisolated static func dateFromEpoch(_ value: Double, now: Date) -> Date? {
        guard value > 0 else { return nil }

        // Relative seconds vs absolute seconds vs absolute milliseconds.
        if value < 100_000_000 {
            return now.addingTimeInterval(value)
        }

        if value < 100_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }

        return Date(timeIntervalSince1970: value / 1000)
    }

    private nonisolated static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }

        // ISO8601DateFormatter rejects some fractional-second lengths (e.g. microseconds).
        if let dotIndex = value.firstIndex(of: ".") {
            let head = value[..<dotIndex]
            let tail = value[value.index(after: dotIndex)...]
            if let zoneStart = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
                return formatter.date(from: String(head) + String(tail[zoneStart...]))
            }
        }

        return nil
    }

    private nonisolated static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private nonisolated static func relativeResetText(_ date: Date) -> String {
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
