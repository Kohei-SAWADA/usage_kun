import Foundation
import CoreFoundation

private final class AntigravityNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The ephemeral CSRF credential must never leave the discovered local server.
        completionHandler(nil)
    }
}

/// Reads the same Gemini quota summary used by Antigravity's Models & Usage screen.
/// Authentication stays with the running IDE; only its ephemeral local CSRF token is used.
@MainActor
public final class AntigravityUsageService {
    public init() {}

    public func snapshot(now: Date) async -> UsageSnapshot {
        guard !Task.isCancelled else { return Self.cancelled(now: now) }
        let connections = await Task.detached { AntigravityConnection.discover() }.value
        guard !Task.isCancelled else { return Self.cancelled(now: now) }
        guard !connections.isEmpty else {
            return Self.unavailable(now: now, message: "Open Antigravity IDE and sign in to read Gemini quota.")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: AntigravityNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var partial: UsageSnapshot?
        // A server exposes separate TLS and HTTP sockets. Its local HTTP socket is sufficient;
        // never weaken certificate validation to probe the TLS socket.
        for connection in connections.prefix(8) {
            guard !Task.isCancelled else { return Self.cancelled(now: now) }
            guard (1...65535).contains(connection.port),
                  let url = URL(string: "http://127.0.0.1:\(connection.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"request":{},"forceRefresh":true}"#.utf8)
            request.timeoutInterval = 3
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(connection.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")

            do {
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled else { return Self.cancelled(now: now) }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= 1_048_576,
                      let reading = Self.parseSummary(data: data, now: now) else { continue }
                if reading.percent != nil && reading.weekly?.percentLeft != nil { return reading }
                if partial == nil || Self.knownWindowCount(reading) > Self.knownWindowCount(partial!) {
                    partial = reading
                }
            } catch {
                // Never expose a response body, credential, or URLSession diagnostic.
                if Task.isCancelled { return Self.cancelled(now: now) }
            }
        }
        return partial ?? Self.unavailable(now: now, message: "Antigravity quota is unavailable. Open its Models & Usage settings, then refresh.")
    }

    /// Installed Antigravity protobuf schema: response.groups[].buckets[] uses a
    /// `remaining` oneof. `remainingFraction: 0` is explicit exhaustion; an absent
    /// fraction is unknown. This differs from the older GetUserStatus model quota.
    public nonisolated static func parseSummary(data: Data, now: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let groups = response["groups"] as? [[String: Any]] else { return nil }
        let geminiGroups = groups.filter { ($0["displayName"] as? String) == "Gemini Models" }
        guard geminiGroups.count == 1 else { return nil }
        let buckets = geminiGroups[0]["buckets"] as? [[String: Any]] ?? []
        let primary = window(in: buckets, id: "gemini-5h", window: "5h")
        let weekly = window(in: buckets, id: "gemini-weekly", window: "weekly")
        let complete = primary.percentLeft != nil && weekly.percentLeft != nil
        let status: UsageStatus
        if let primaryLeft = primary.percentLeft, let weeklyLeft = weekly.percentLeft {
            status = UsageStatusRules.status(primaryLeft: primaryLeft, weeklyLeft: weeklyLeft)
        } else if [primary.percentLeft, weekly.percentLeft].compactMap({ $0 }).contains(where: { $0 <= 15 }) {
            // A known low window remains actionable even if the other one is unavailable.
            status = .critical
        } else {
            status = .unknown
        }
        return UsageSnapshot(
            provider: .antigravity, status: status,
            used: primary.percentLeft, limit: nil, percent: primary.percentLeft,
            resetAt: primary.resetAt, updatedAt: now,
            message: complete
                ? "Gemini quota from Antigravity Models & Usage."
                : "Some Gemini quota is unavailable. Open Antigravity Models & Usage, then refresh. Missing values remain unknown.",
            source: "Antigravity local quota", unit: "%", metricTitle: "5 hour left",
            weekly: weekly
        )
    }

    private nonisolated static func window(in buckets: [[String: Any]], id: String, window: String) -> UsageWindow {
        let matches = buckets.filter { ($0["bucketId"] as? String) == id }
        guard matches.count == 1,
              matches[0]["window"] == nil || (matches[0]["window"] as? String) == window,
              isEnabled(matches[0]) else {
            return UsageWindow(percentLeft: nil, resetAt: nil)
        }
        let bucket = matches[0]
        var percent: Double?
        if bucket["remainingAmount"] == nil,
           let number = bucket["remainingFraction"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           (0...1).contains(number.doubleValue) {
            percent = number.doubleValue * 100
        }
        var reset: Date?
        if let text = bucket["resetTime"] as? String {
            let formatter = ISO8601DateFormatter()
            reset = formatter.date(from: text)
            if reset == nil {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text)
            }
        }
        // Preserve the returned time. A passed reset never implies a replenished quota.
        return UsageWindow(percentLeft: percent, resetAt: reset)
    }

    private nonisolated static func isEnabled(_ bucket: [String: Any]) -> Bool {
        guard let disabled = bucket["disabled"] else { return true }
        guard let number = disabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        // Antigravity's own quota component hides the value for a disabled bucket.
        return !number.boolValue
    }

    private nonisolated static func knownWindowCount(_ snapshot: UsageSnapshot) -> Int {
        (snapshot.percent == nil ? 0 : 1) + (snapshot.weekly?.percentLeft == nil ? 0 : 1)
    }

    private nonisolated static func cancelled(now: Date) -> UsageSnapshot {
        unavailable(now: now, message: "Antigravity quota refresh was cancelled.")
    }

    private nonisolated static func unavailable(now: Date, message: String) -> UsageSnapshot {
        UsageSnapshot(provider: .antigravity, status: .unknown, used: nil, limit: nil, percent: nil,
                      resetAt: nil, updatedAt: now, message: message,
                      source: "Antigravity local quota", unit: "%", metricTitle: "5 hour left",
                      weekly: UsageWindow(percentLeft: nil, resetAt: nil))
    }
}
