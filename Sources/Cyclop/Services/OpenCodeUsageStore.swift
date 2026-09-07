import Foundation
import SQLite3

/// One usage window on the OpenCode Go plan — a 5-hour, weekly and monthly
/// one, each with a percentage of the dollar limit and seconds until reset.
struct OpenCodeUsageWindow: Decodable {
    /// `ok` while the plan covers it, `rate-limited` once the window is spent.
    let status: String?
    let resetInSec: Double?
    let usagePercent: Double?

    var resetDate: Date? {
        resetInSec.map { Date(timeIntervalSinceNow: $0) }
    }
}

/// The OpenCode Go plan's own numbers, straight off the official endpoint
/// the OpenCode console dashboard reads from (`/zen/go/v1/usage`, live since
/// 2026-08-11). Same idea as `CursorUsageStore`: no login of Cyclop's own —
/// the API key is the one the OpenCode CLI stored at `/connect`.
struct OpenCodeUsageSnapshot: Decodable {
    let rollingUsage: OpenCodeUsageWindow?
    let weeklyUsage: OpenCodeUsageWindow?
    let monthlyUsage: OpenCodeUsageWindow?
}

/// Token totals pulled out of OpenCode's own SQLite store — the same numbers
/// its `stats` command reports, broken into the components that make them up.
struct OpenCodeTokenBreakdown {
    let input: Int?
    let output: Int?
    let reasoning: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
}

/// One calendar window (today, this month) of tokens, plus this month's spend
/// per model so the card can say where the money actually went. There is no
/// plan window behind any of it — a quota only exists on the Go plan — so it
/// is shown raw rather than as a percentage.
struct OpenCodeLocalStats {
    let today: OpenCodeTokenBreakdown
    let month: OpenCodeTokenBreakdown
    /// Spend attributed per model this month, most expensive first.
    let modelCosts: [(model: String, cost: Double)]
    /// When the newest assistant message was written — the only honest
    /// freshness a local mirror can offer.
    let asOf: Date?
}

/// Whether the account holds an OpenCode Go plan — a live percentage only
/// exists for subscribers, everyone else gets a 403 with an entitlement error.
private enum OpenCodeFetchOutcome {
    case success(OpenCodeUsageSnapshot)
    case noPlan
    case failure
}

@MainActor
final class OpenCodeUsageStore: ObservableObject {
    /// The Go plan windows, when the account holds the plan.
    @Published private(set) var snapshot: OpenCodeUsageSnapshot?
    /// Usage and spend for the day and the month, mirrored from the local
    /// database — shown when there is no plan snapshot to display.
    @Published private(set) var local: OpenCodeLocalStats?
    /// True once a fetch has been tried and found no key at all — signed out
    /// is a different message than "OpenCode did not answer".
    @Published private(set) var noCredentials = false
    /// True once a fetch has been tried and failed while a key was found —
    /// offline, or the endpoint is unhappy.
    @Published private(set) var unreachable = false

    private var lastFetch: Date?
    /// Long enough that switching tabs back and forth does not hammer the
    /// endpoint; short enough that a number just spent shows up promptly.
    private static let minRefetchInterval: TimeInterval = 20

    func reload() {
        refreshLocal()
        if let lastFetch, Date().timeIntervalSince(lastFetch) < Self.minRefetchInterval { return }
        lastFetch = Date()
        Task { await fetchPlan() }
    }

    /// The local read is free and always fresh, so it runs on every reload;
    /// only the live endpoint is throttled.
    private func refreshLocal() {
        local = Self.localStats()
    }

    private func fetchPlan() async {
        guard let key = Self.token() else {
            snapshot = nil
            noCredentials = true
            unreachable = false
            return
        }
        switch await Self.fetchLive(key: key) {
        case .success(let fresh):
            snapshot = fresh
            noCredentials = false
            unreachable = false
        case .noPlan:
            snapshot = nil
            noCredentials = false
            unreachable = false
        case .failure:
            snapshot = nil
            noCredentials = false
            unreachable = true
        }
    }

    /// The key the OpenCode CLI writes when its `/connect` command stores a
    /// provider credential — one JSON file in the data directory, no Keychain
    /// entry of its own. Only the hosted `opencode` provider is read, which is
    /// the one the plan windows belong to.
    private static func token() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = json["opencode"] as? [String: Any],
              let key = provider["key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    /// Same endpoint the console dashboard polls. Five seconds to answer or
    /// it is treated as unreachable; a 403 means the key is fine but the
    /// account carries no Go subscription.
    private static func fetchLive(key: String) async -> OpenCodeFetchOutcome {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.timeoutInterval = 5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure
        }
        if http.statusCode == 403 { return .noPlan }
        guard http.statusCode == 200 else { return .failure }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(OpenCodeUsageSnapshot.self, from: data) else {
            return .failure
        }
        return .success(snapshot)
    }

    /// Totals for the current calendar day and month, plus this month's spend
    /// per model and the newest message timestamp, in one read-only pass over
    /// the messages table. `time_created` is milliseconds since the epoch —
    /// the same convention the rest of the store uses. JSON1 functions are
    /// used so the `data` blobs do not need to be parsed in Swift.
    private static func localStats() -> OpenCodeLocalStats? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return nil }
        defer { sqlite3_close(db) }

        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        guard let today = Self.breakdown(db: db, since: todayStart),
              let month = Self.breakdown(db: db, since: monthStart),
              let asOf = Self.latestAssistantTime(db: db) else { return nil }
        return OpenCodeLocalStats(
            today: today,
            month: month,
            modelCosts: Self.modelCosts(db: db, since: monthStart),
            asOf: asOf
        )
    }

    /// `sum(tokens.*)` over assistant messages at or after `since`. Assistant
    /// messages are the only ones that carry token counts; `coalesce` keeps a
    /// window with no messages from collapsing into NULLs.
    private static func breakdown(db: OpaquePointer, since: Date) -> OpenCodeTokenBreakdown? {
        let sql = """
        SELECT coalesce(sum(json_extract(data, '$.tokens.input')), 0),
               coalesce(sum(json_extract(data, '$.tokens.output')), 0),
               coalesce(sum(json_extract(data, '$.tokens.reasoning')), 0),
               coalesce(sum(json_extract(data, '$.tokens.cache.read')), 0),
               coalesce(sum(json_extract(data, '$.tokens.cache.write')), 0)
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
          AND time_created >= ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return OpenCodeTokenBreakdown(
            input: Int(sqlite3_column_int64(stmt, 0)),
            output: Int(sqlite3_column_int64(stmt, 1)),
            reasoning: Int(sqlite3_column_int64(stmt, 2)),
            cacheRead: Int(sqlite3_column_int64(stmt, 3)),
            cacheWrite: Int(sqlite3_column_int64(stmt, 4))
        )
    }

    /// Spend per model at or after `since`, most expensive first. Capped at
    /// three so a long tail of free models never overflows the card.
    private static func modelCosts(db: OpaquePointer, since: Date) -> [(model: String, cost: Double)] {
        let sql = """
        SELECT coalesce(json_extract(data, '$.modelID'), '?') AS model,
               coalesce(sum(json_extract(data, '$.cost')), 0) AS spend
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
          AND time_created >= ?
        GROUP BY model
        ORDER BY spend DESC
        LIMIT 3
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        var rows: [(model: String, cost: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = String(cString: sqlite3_column_text(stmt, 0))
            rows.append((model, sqlite3_column_double(stmt, 1)))
        }
        return rows
    }

    /// The timestamp of the newest assistant message — `nil` when the store
    /// holds no assistant message at all, which the card renders as "no
    /// sessions yet".
    private static func latestAssistantTime(db: OpaquePointer) -> Date? {
        let sql = "SELECT max(time_created) FROM message WHERE json_extract(data, '$.role') = 'assistant'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)) / 1000)
    }
}
