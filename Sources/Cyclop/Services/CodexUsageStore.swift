import Foundation

/// Codex has no standalone "check my quota" endpoint the way Claude does —
/// the rate-limit snapshot only ever comes back as a side effect of an actual
/// turn, embedded in the CLI's own local session log. So this is read
/// straight from that log instead: the same number the Codex TUI itself
/// would be showing, as of the last time Codex was actually used.
struct CodexUsageWindow: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Int?

    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

struct CodexCredits: Decodable {
    let hasCredits: Bool
    let balance: String?
}

struct CodexRateLimits: Decodable {
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
    let credits: CodexCredits?
}

private struct CodexEventLine: Decodable {
    let timestamp: String?
    let payload: Payload
    struct Payload: Decodable {
        let rateLimits: CodexRateLimits?
    }
}

/// Reads the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` file for
/// its last `rate_limits` snapshot — no token, no network, just the log the
/// Codex CLI already writes after every turn.
@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot: CodexRateLimits?
    /// When the snapshot's own event happened — the only honest freshness
    /// this can offer, since it is only ever as current as Codex's last turn.
    @Published private(set) var asOf: Date?

    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions")

    func reload() {
        guard let file = Self.latestRolloutFile(),
              let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else {
            snapshot = nil
            asOf = nil
            return
        }
        // ponytail: only the newest session file is checked — good enough
        // for a session used today; widen to the file before it if empty
        // "no data" reports turn out to be common on lighter days.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"rate_limits\":{") else { continue }
            guard let event = try? decoder.decode(CodexEventLine.self, from: Data(line.utf8)),
                  let rateLimits = event.payload.rateLimits else { continue }
            snapshot = rateLimits
            asOf = event.timestamp.flatMap(Self.parseTimestamp)
            return
        }
        snapshot = nil
        asOf = nil
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Session logs live under `sessions/<year>/<month>/<day>/`, named so
    /// that the lexically greatest entry at each level is also the newest.
    private static func latestRolloutFile() -> URL? {
        guard let year = latestChild(of: root) else { return nil }
        guard let month = latestChild(of: year) else { return nil }
        guard let day = latestChild(of: month) else { return nil }
        return latestChild(of: day, extension: "jsonl")
    }

    private static func latestChild(of directory: URL, extension ext: String? = nil) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        let filtered = ext.map { e in items.filter { $0.pathExtension == e } } ?? items
        return filtered.max { $0.lastPathComponent < $1.lastPathComponent }
    }
}
