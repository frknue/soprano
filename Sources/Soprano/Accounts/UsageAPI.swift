import Foundation

/// A valid access token for one row, used to ask the provider about that
/// account's usage when omp does not report on it.
struct UsageCredential: Sendable {
    let rowId: String
    let identity: AccountIdentity
    let accessToken: String
    /// Codex: the ChatGPT account id the request is made for.
    var accountId: String?
}

enum UsageAPIError: LocalizedError {
    case http(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .http(let status): return "The usage service answered \(status)."
        case .unreadable: return "The usage service sent something Soprano could not read."
        }
    }
}

/// The providers' own rate-limit endpoints — the same ones Claude Code, the
/// Codex CLI and omp read.
enum UsageAPI {
    static let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let claudeProfileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func claudeUsage(accessToken: String, session: URLSession = .shared) async throws -> AccountUsage {
        let data = try await get(claudeUsageURL, headers: claudeHeaders(accessToken), session: session)
        return try parseClaudeUsage(data, now: Date())
    }

    /// Who an access token belongs to: proof of identity independent of the
    /// files that merely claim it.
    static func claudeProfile(accessToken: String, session: URLSession = .shared) async throws -> AccountIdentity {
        let data = try await get(claudeProfileURL, headers: claudeHeaders(accessToken), session: session)
        guard let identity = parseClaudeProfile(data) else { throw UsageAPIError.unreadable }
        return identity
    }

    static func codexUsage(
        accessToken: String,
        accountId: String?,
        session: URLSession = .shared
    ) async throws -> AccountUsage {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": "codex-cli",
            "Accept": "application/json",
        ]
        if let accountId { headers["ChatGPT-Account-Id"] = accountId }
        let data = try await get(codexUsageURL, headers: headers, session: session)
        return try parseCodexUsage(data, now: Date())
    }

    // MARK: - Parsing

    /// `{"five_hour": {"utilization": 9, "resets_at": "…"}, "seven_day": …}`;
    /// utilization is a percentage.
    static func parseClaudeUsage(_ data: Data, now: Date) throws -> AccountUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAPIError.unreadable
        }
        let buckets: [(key: String, label: String)] = [
            ("five_hour", "5h"),
            ("seven_day", "7d"),
            ("seven_day_opus", "7d opus"),
            ("seven_day_sonnet", "7d sonnet"),
        ]
        var windows: [UsageWindow] = []
        for bucket in buckets {
            guard let entry = object[bucket.key] as? [String: Any],
                  let utilization = number(entry["utilization"])
            else { continue }
            windows.append(UsageWindow(
                label: bucket.label,
                usedFraction: max(0, utilization) / 100,
                resetsAt: date(entry["resets_at"])
            ))
        }
        guard !windows.isEmpty else { throw UsageAPIError.unreadable }
        return AccountUsage(windows: windows, fetchedAt: now)
    }

    /// `{"account": {"email": …}, "organization": {"uuid": …}}`.
    static func parseClaudeProfile(_ data: Data) -> AccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = object["account"] as? [String: Any]
        let organization = object["organization"] as? [String: Any]
        let email = (account?["email"] as? String)
            ?? (account?["email_address"] as? String)
            ?? (object["email"] as? String)
        guard let email, !email.isEmpty else { return nil }
        return AccountIdentity(email: email, organizationId: organization?["uuid"] as? String)
    }

    /// `{"rate_limit": {"primary_window": {"used_percent": 15,
    /// "limit_window_seconds": 604800, "reset_at": 1791959189}, …}}`.
    static func parseCodexUsage(_ data: Data, now: Date) throws -> AccountUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = object["rate_limit"] as? [String: Any]
        else { throw UsageAPIError.unreadable }
        var windows: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let entry = rateLimit[key] as? [String: Any],
                  let usedPercent = number(entry["used_percent"])
            else { continue }
            let seconds = number(entry["limit_window_seconds"])
            var resetsAt = date(entry["reset_at"])
            if resetsAt == nil, let after = number(entry["reset_after_seconds"]) {
                resetsAt = now.addingTimeInterval(after)
            }
            windows.append(UsageWindow(
                label: seconds.map(windowLabel) ?? (key == "primary_window" ? "primary" : "secondary"),
                usedFraction: min(max(usedPercent, 0), 100) / 100,
                resetsAt: resetsAt
            ))
        }
        guard !windows.isEmpty else { throw UsageAPIError.unreadable }
        return AccountUsage(windows: windows, fetchedAt: now)
    }

    /// "5h" for 18 000 s, "7d" for 604 800 s.
    static func windowLabel(seconds: Double) -> String {
        let hours = Int((seconds / 3600).rounded())
        return hours < 24 || hours % 24 != 0 ? "\(hours)h" : "\(hours / 24)d"
    }

    // MARK: - Helpers

    private static func claudeHeaders(_ accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
            "Accept": "application/json",
        ]
    }

    private static func get(_ url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UsageAPIError.http(status) }
        return data
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// ISO 8601 text (with or without fractional seconds), or epoch seconds or
    /// milliseconds — the providers use all three.
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), !(value is String) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // Microsecond precision, which ISO8601DateFormatter rejects.
        let trimmed = text.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}
