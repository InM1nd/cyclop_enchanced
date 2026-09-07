import Foundation

/// How many Claude Code, Codex, Cursor Agent and OpenCode CLI processes are
/// running right now — a plain `ps` scan, matched by executable name.
///
/// ChatGPT's desktop app happens to bundle its own binary also named
/// `codex` (an internal codename, unrelated to the Codex CLI), so a codex
/// match is only counted outside `ChatGPT.app`. Claude.app and Cursor.app's
/// own processes report their full framework paths rather than a bare
/// executable name, so they never collide with the CLIs in the first place.
@MainActor
final class ProcessMonitorStore: ObservableObject {
    @Published private(set) var claudeCount = 0
    @Published private(set) var codexCount = 0
    @Published private(set) var cursorCount = 0
    @Published private(set) var opencodeCount = 0

    private var timer: Timer?
    /// Frequent enough that starting a session in another window shows up
    /// while this tab is still open, cheap enough that it costs nothing to
    /// ask five times a minute.
    private static let refreshInterval: TimeInterval = 5

    func setActive(_ active: Bool) {
        guard active else {
            timer?.invalidate()
            timer = nil
            return
        }
        reload()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reload() {
        Task {
            let counts = await Self.scan()
            claudeCount = counts.claude
            codexCount = counts.codex
            cursorCount = counts.cursor
            opencodeCount = counts.opencode
        }
    }

    private static nonisolated func scan() async -> (claude: Int, codex: Int, cursor: Int, opencode: Int) {
        await Task.detached(priority: .utility) {
            guard let output = commandNames() else { return (0, 0, 0, 0) }
            var claude = 0
            var codex = 0
            var cursor = 0
            var opencode = 0
            for line in output.split(separator: "\n") {
                let path = String(line)
                switch (path as NSString).lastPathComponent {
                case "claude": claude += 1
                case "codex" where !path.contains("ChatGPT.app"): codex += 1
                case "cursor-agent": cursor += 1
                case "opencode": opencode += 1
                default: break
                }
            }
            return (claude, codex, cursor, opencode)
        }.value
    }

    /// One command name per line, the same list `ps` shows in Activity Monitor.
    private static nonisolated func commandNames() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
