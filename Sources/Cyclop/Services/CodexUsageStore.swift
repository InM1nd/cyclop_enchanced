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

    /// The log only updates on a Codex turn, so a window that has reset since
    /// still carries its old percentage — a reset in the past means 0% used.
    var isExpired: Bool { resetDate.map { $0 <= Date() } ?? false }
    var currentPercent: Double? { isExpired ? 0 : usedPercent }
    var currentResetDate: Date? { isExpired ? nil : resetDate }
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

    private var lastFetch: Date?
    /// Long enough that switching tabs back and forth does not re-read
    /// session logs continuously; short enough that fresh quota updates appear.
    private static let minRefetchInterval: TimeInterval = 20

    private static nonisolated let root = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions")

    func reload(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < Self.minRefetchInterval { return }
        lastFetch = Date()
        Task {
            let result = await Self.loadLatest()
            self.snapshot = result?.snapshot
            self.asOf = result?.asOf
        }
    }

    private static nonisolated func loadLatest() async -> (snapshot: CodexRateLimits, asOf: Date?)? {
        await Task.detached(priority: .utility) {
            // ponytail: newest three files — a session that just started has no
            // snapshot yet, the one before it usually does.
            for file in latestRolloutFiles().prefix(3) {
                if let found = readLatestRateLimits(from: file) { return found }
            }
            return nil
        }.value
    }

    /// Reads from the end of the file in expanding windows so even gigabyte-sized
    /// session logs don't exhaust memory or block execution.
    private static nonisolated func readLatestRateLimits(from url: URL) -> (snapshot: CodexRateLimits, asOf: Date?)? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        guard let fileSize = try? fileHandle.seekToEnd(), fileSize > 0 else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Try reading expanding windows from the end of the file: 256 KB, 1 MB, 4 MB, up to 32 MB
        var windowSize: UInt64 = 256 * 1024
        let maxWindow: UInt64 = min(fileSize, 32 * 1024 * 1024)

        while true {
            let currentReadSize = min(fileSize, windowSize)
            let offset = fileSize - currentReadSize
            do {
                try fileHandle.seek(toOffset: offset)
                let data = fileHandle.readData(ofLength: Int(currentReadSize))
                if let parsed = parseRateLimits(from: data, isStartOfFile: offset == 0, decoder: decoder) {
                    return parsed
                }
            } catch {
                return nil
            }

            if currentReadSize >= maxWindow { break }
            windowSize = min(windowSize * 4, maxWindow)
        }
        return nil
    }

    private static nonisolated func parseRateLimits(from data: Data, isStartOfFile: Bool, decoder: JSONDecoder) -> (snapshot: CodexRateLimits, asOf: Date?)? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // If we didn't start at offset 0, the first line is likely partial; drop it.
        if !isStartOfFile && !lines.isEmpty {
            lines.removeFirst()
        }
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\":{") else { continue }
            guard let event = try? decoder.decode(CodexEventLine.self, from: Data(line.utf8)),
                  let rateLimits = event.payload.rateLimits,
                  // Other buckets (`limit_id: "premium"`) carry null windows;
                  // they would blank the card if taken as the latest.
                  rateLimits.primary != nil || rateLimits.secondary != nil else { continue }
            let asOf = event.timestamp.flatMap(Self.parseTimestamp)
            return (rateLimits, asOf)
        }
        return nil
    }

    private static nonisolated func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Newest by modification time, not by the date in the path. A long-lived
    /// Codex session keeps appending to the folder it was born in — lexical
    /// "latest day" then points at a quieter newer folder and freezes Usage.
    private static nonisolated func latestRolloutFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            files.append((url, date))
        }
        return files.sorted { $0.date > $1.date }.map(\.url)
    }
}
