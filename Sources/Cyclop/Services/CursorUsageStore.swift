import Foundation

/// Cursor's dashboard splits the billing cycle into two pools — "Cursor
/// Models" (its own, cheaper models) and "Other Models" (everything else,
/// which spills into on-demand spend once exhausted) — and the response
/// carries a ready-made percentage for each, but only inside a sentence meant
/// for display (`"You've used 1% of your included total usage"`). The
/// numeric `auto_percent_used` / `api_percent_used` fields sit next to it and
/// look like the same thing, but disagreed with what the dashboard actually
/// showed when compared side by side — so the message text, not the numeric
/// fields, is the one trusted here.
struct CursorUsageResponse: Decodable {
    let billingCycleEnd: String?
    let autoModelSelectedDisplayMessage: String?
    let namedModelSelectedDisplayMessage: String?

    var resetDate: Date? {
        guard let billingCycleEnd, let ms = Double(billingCycleEnd) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    var cursorModelsPercent: Double? { Self.percent(in: autoModelSelectedDisplayMessage) }
    var otherModelsPercent: Double? { Self.percent(in: namedModelSelectedDisplayMessage) }

    private static func percent(in message: String?) -> Double? {
        guard let message, let range = message.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) else {
            return nil
        }
        return Double(message[range].dropLast())
    }
}

/// Same shape as `ClaudeUsageStore`: the Cursor CLI's own Connect-RPC call
/// (`aiserver.v1.DashboardService/GetCurrentPeriodUsage`), authorized with
/// the access token Cursor already stored in Keychain at login. No account
/// of Cyclop's own, and a live number rather than a local guess.
@MainActor
final class CursorUsageStore: ObservableObject {
    @Published private(set) var snapshot: CursorUsageResponse?
    @Published private(set) var noCredentials = false
    @Published private(set) var unreachable = false

    private var lastFetch: Date?
    private static let minRefetchInterval: TimeInterval = 20

    func reload(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < Self.minRefetchInterval { return }
        lastFetch = Date()
        Task { await fetch() }
    }

    private func fetch() async {
        guard let token = Self.token() else {
            noCredentials = true
            unreachable = false
            return
        }
        if let fresh = await Self.fetchLive(token: token) {
            snapshot = fresh
            noCredentials = false
            unreachable = false
            return
        }
        UsageTokenCache.clearCursor()
        if let retry = Self.token(), retry != token,
           let fresh = await Self.fetchLive(token: retry) {
            snapshot = fresh
            noCredentials = false
            unreachable = false
            return
        }
        unreachable = true
        noCredentials = false
    }

    private static func token() -> String? {
        if let data = UsageTokenCache.keychain(
            service: "cursor-access-token",
            account: "cursor-user",
            allowPrompt: false
        ), let token = String(data: data, encoding: .utf8), !token.isEmpty {
            UsageTokenCache.storeCursor(token)
            return token
        }
        if let cached = UsageTokenCache.cursor { return cached }
        if let data = UsageTokenCache.keychain(
            service: "cursor-access-token",
            account: "cursor-user",
            allowPrompt: true
        ), let token = String(data: data, encoding: .utf8), !token.isEmpty {
            UsageTokenCache.storeCursor(token)
            return token
        }
        return nil
    }

    private static func fetchLive(token: String) async -> CursorUsageResponse? {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }
}
