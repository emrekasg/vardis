import Foundation

public struct QuotaWindow: Sendable, Equatable {
    /// 0...100, as the API reports it.
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// Plan limits from `/api/oauth/usage`, the call behind Claude Code's `/usage`.
public struct PlanQuota: Sendable, Equatable {
    public var fiveHour: QuotaWindow?
    public var sevenDay: QuotaWindow?
    public var sevenDayOpus: QuotaWindow?
    public var sevenDaySonnet: QuotaWindow?
    /// Any other window-shaped entries the API returned, by key.
    public var other: [String: QuotaWindow]
    public var fetchedAt: Date
}

public enum QuotaError: Error, Equatable {
    case unauthorized
    case http(Int)
    case invalidResponse
}

public struct QuotaClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    private let url: URL

    public init(session: URLSession = .shared, url: URL = QuotaClient.endpoint) {
        self.session = session
        self.url = url
    }

    public func fetch(accessToken: String) async throws -> PlanQuota {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw QuotaError.http(http.statusCode) }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> PlanQuota {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.invalidResponse }
        var q = PlanQuota(other: [:], fetchedAt: now)
        for (key, value) in obj {
            guard let w = window(value) else { continue }
            switch key {
            case "five_hour": q.fiveHour = w
            case "seven_day": q.sevenDay = w
            case "seven_day_opus": q.sevenDayOpus = w
            case "seven_day_sonnet": q.sevenDaySonnet = w
            default: q.other[key] = w
            }
        }
        return q
    }

    private static func window(_ v: Any) -> QuotaWindow? {
        guard let d = v as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (d["resets_at"] as? String).flatMap(date)
        return QuotaWindow(utilization: u, resetsAt: reset)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
