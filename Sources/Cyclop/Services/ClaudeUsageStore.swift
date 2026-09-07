import Foundation

/// One rolling limit window — Claude Code tracks a five-hour and a seven-day
/// one side by side.
struct ClaudeUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: Date?
}

/// Pay-as-you-go credits spent once the plan's own windows run out. Absent on
/// plans that never turned it on, which is why every field here is optional.
struct ClaudeExtraUsage: Decodable {
    let isEnabled: Bool
    let utilization: Double?
    let currency: String?
    /// `used_credits` / `monthly_limit` arrive as minor units — cents, not
    /// euros — same idea as Stripe's `amount_minor`. Divided through once
    /// here so nothing downstream has to remember the scale.
    private let usedCredits: Double?
    private let monthlyLimit: Double?
    private let decimalPlaces: Int?

    var used: Double? { usedCredits.map { $0 / scale } }
    var limit: Double? { monthlyLimit.map { $0 / scale } }
    private var scale: Double { pow(10, Double(decimalPlaces ?? 2)) }
}

struct ClaudeUsageSnapshot: Decodable {
    let fiveHour: ClaudeUsageWindow
    let sevenDay: ClaudeUsageWindow
    let extraUsage: ClaudeExtraUsage?
}

/// Claude's own numbers, fetched the same way the Claude Code CLI's status
/// line does: the OAuth token it already stored at login — Keychain first,
/// its credentials file as a fallback — sent to the account's own usage
/// endpoint. No login of Cyclop's own, no third-party plugin to depend on;
/// the token is one Claude Code already put on this Mac.
///
/// Re-fetched on every visit to the tab, like `SnippetStore.reload()` re-reads
/// its file — except the source here is a live endpoint, not a file, so a
/// short-lived cache guards against a network round trip on every hover.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    /// True once a fetch has been tried and found no token at all — signed
    /// out is a different message than "Claude did not answer".
    @Published private(set) var noCredentials = false
    /// True once a fetch has been tried and failed while a token was found —
    /// offline, or Claude's endpoint is unhappy.
    @Published private(set) var unreachable = false

    private var lastFetch: Date?
    /// Long enough that switching tabs back and forth does not hammer the
    /// endpoint; short enough that a number just spent shows up promptly.
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
        UsageTokenCache.clearClaude()
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

    /// Claude Code's file first (no dialog), then a silent Keychain read,
    /// then Cyclop's own cache, then one prompt that is cached afterwards.
    private static func token() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = extractAccessToken(data) {
            UsageTokenCache.storeClaude(token)
            return token
        }
        if let data = UsageTokenCache.keychain(service: "Claude Code-credentials", allowPrompt: false),
           let token = extractAccessToken(data) {
            UsageTokenCache.storeClaude(token)
            return token
        }
        if let cached = UsageTokenCache.claude { return cached }
        if let data = UsageTokenCache.keychain(service: "Claude Code-credentials", allowPrompt: true),
           let token = extractAccessToken(data) {
            UsageTokenCache.storeClaude(token)
            return token
        }
        return nil
    }

    private static func extractAccessToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String {
            return token
        }
        return json["accessToken"] as? String
    }

    /// Same request the status line makes: zero LLM tokens spent, five
    /// seconds to answer or it is treated as unreachable.
    private static func fetchLive(token: String) async -> ClaudeUsageSnapshot? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(string)")
            }
            return date
        }
        return try? decoder.decode(ClaudeUsageSnapshot.self, from: data)
    }
}
