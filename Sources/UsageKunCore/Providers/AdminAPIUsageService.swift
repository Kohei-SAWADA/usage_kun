import Foundation

@MainActor
public final class AdminAPIUsageService {
    private let credentialStore: KeychainCredentialStore
    private let session: URLSession

    public init(credentialStore: KeychainCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public func openAISnapshot(now: Date) async -> UsageSnapshot {
        guard let key = credentialStore.read(.openAIAdminKey), !key.isEmpty else {
            return UsageSnapshot(
                provider: .openaiAPI,
                status: .unknown,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "OpenAI Admin key is not saved. Save it in Settings to sync the Usage/Costs API.",
                source: "OpenAI Admin API",
                unit: "USD",
                metricTitle: "Month cost",
                secondaryTitle: "Period"
            )
        }

        guard key.hasPrefix("sk-admin-") else {
            return apiErrorSnapshot(
                provider: .openaiAPI,
                now: now,
                message: "The saved key does not look like an OpenAI Admin API key. Regular sk- / sk-proj- keys cannot fetch costs. Save an Admin key starting with sk-admin-."
            )
        }

        do {
            let start = Self.monthStartUnix(for: now)
            let url = URL(string: "https://api.openai.com/v1/organization/costs?start_time=\(start)&bucket_width=1d&limit=31")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await session.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode, 200..<300 ~= statusCode else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = APIErrorMessage.extract(from: data)
                return apiErrorSnapshot(
                    provider: .openaiAPI,
                    now: now,
                    message: "OpenAI Costs API returned HTTP \(statusCode). \(detail) Check the Admin key scope and Organization Owner access."
                )
            }

            let total = OpenAICostsResponse.totalCostUSD(from: data)
            return UsageSnapshot(
                provider: .openaiAPI,
                status: .ok,
                used: total,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "Monthly organization cost from OpenAI Costs API. This is separate from Codex ChatGPT plan limits.",
                source: "OpenAI Admin API",
                unit: "USD",
                metricTitle: "Month cost",
                secondaryTitle: "Period",
                secondaryValue: "Month to date"
            )
        } catch {
            return apiErrorSnapshot(provider: .openaiAPI, now: now, message: "Could not connect to OpenAI Costs API. Check the network and saved Keychain value.")
        }
    }

    public func anthropicSnapshot(now: Date) async -> UsageSnapshot {
        guard let key = credentialStore.read(.anthropicAdminKey), !key.isEmpty else {
            return UsageSnapshot(
                provider: .anthropicAPI,
                status: .unknown,
                used: nil,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "Anthropic Admin key is not saved. Personal accounts cannot use the Admin API.",
                source: "Anthropic Admin API",
                unit: "USD",
                metricTitle: "Month cost",
                secondaryTitle: "Period"
            )
        }

        do {
            let start = Self.monthStartISO8601(for: now)
            let end = Self.iso8601(now)
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: start),
                URLQueryItem(name: "ending_at", value: end),
                URLQueryItem(name: "limit", value: "31")
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("usage_kun/0.1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode, 200..<300 ~= statusCode else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = APIErrorMessage.extract(from: data)
                return apiErrorSnapshot(
                    provider: .anthropicAPI,
                    now: now,
                    message: "Anthropic Cost API returned HTTP \(statusCode). \(detail) Check the Admin key and organization access."
                )
            }

            let total = AnthropicCostResponse.totalCostUSD(from: data)
            return UsageSnapshot(
                provider: .anthropicAPI,
                status: .ok,
                used: total,
                limit: nil,
                percent: nil,
                resetAt: nil,
                updatedAt: now,
                message: "Monthly organization cost from Anthropic Cost API. This is separate from personal Claude plan limits.",
                source: "Anthropic Admin API",
                unit: "USD",
                metricTitle: "Month cost",
                secondaryTitle: "Period",
                secondaryValue: "Month to date"
            )
        } catch {
            return apiErrorSnapshot(provider: .anthropicAPI, now: now, message: "Could not connect to Anthropic Cost API. Check the network and saved Keychain value.")
        }
    }

    private func apiErrorSnapshot(provider: UsageProvider, now: Date, message: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            status: .error,
            used: nil,
            limit: nil,
            percent: nil,
            resetAt: nil,
            updatedAt: now,
            message: message,
            source: provider == .openaiAPI ? "OpenAI Admin API" : "Anthropic Admin API",
            unit: "USD",
            metricTitle: "Month cost",
            secondaryTitle: "Period"
        )
    }

    private static func monthStartUnix(for date: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        return Int((calendar.date(from: components) ?? date).timeIntervalSince1970)
    }

    private static func monthStartISO8601(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        return iso8601(calendar.date(from: components) ?? date)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private enum OpenAICostsResponse {
    static func totalCostUSD(from data: Data) -> Double {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]] else {
            return 0
        }

        return buckets.reduce(0) { partial, bucket in
            let results = bucket["results"] as? [[String: Any]] ?? []
            return partial + results.reduce(0) { subtotal, result in
                let amount = result["amount"] as? [String: Any]
                return subtotal + double(amount?["value"])
            }
        }
    }
}

private enum AnthropicCostResponse {
    static func totalCostUSD(from data: Data) -> Double {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]] else {
            return 0
        }

        return buckets.reduce(0) { partial, bucket in
            let results = bucket["results"] as? [[String: Any]] ?? []
            return partial + results.reduce(0) { subtotal, result in
                subtotal + double(result["amount"])
            }
        }
    }
}

private func double(_ value: Any?) -> Double {
    if let value = value as? Double {
        return value
    }

    if let value = value as? Int {
        return Double(value)
    }

    if let value = value as? String {
        return Double(value) ?? 0
    }

    return 0
}

private enum APIErrorMessage {
    static func extract(from data: Data) -> String {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        if let error = root["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return sanitized(message)
            }

            if let type = error["type"] as? String {
                return sanitized(type)
            }
        }

        if let message = root["message"] as? String {
            return sanitized(message)
        }

        return ""
    }

    private static func sanitized(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\(trimmed) "
    }
}
