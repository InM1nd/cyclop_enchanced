import AppKit
import Foundation

/// One line item on the Clean tab: a fixed, hand-picked cache location, how
/// to size it, and how to remove it. Kept data-driven so a new target is one
/// array entry, not a new code path through the store or the pane.
struct CleanupTarget: Identifiable {
    enum Kind {
        /// Empty everything inside a folder; the folder itself stays.
        case wholeFolderContents
        /// Delete one exact file.
        case exactFile
        /// Delete each directory `resolve()` returns, whole — used for the
        /// allow-listed cache-folder scan, where the resolver itself finds
        /// the leaves and this just removes them.
        case exactDirectories
        /// Run a Process command; nothing to size ahead of time.
        case shellCommand(executable: String, arguments: [String])
        /// VACUUM a sqlite database in place via the `sqlite3` CLI.
        case sqliteVacuum
    }

    let id: String
    let title: String
    let description: String
    let kind: Kind
    let defaultOn: Bool
    /// Cheap check — PATH lookups, file existence, one quick process launch.
    /// False hides the row entirely (e.g. pnpm not installed).
    let isAvailable: () -> Bool
    /// A reason to show in place of the toggle when the row is visible but
    /// the action itself is currently blocked (e.g. Cursor is running).
    let isBlocked: () -> String?
    /// Paths this target acts on. Unused for `.shellCommand`.
    let resolve: () -> [URL]
}

/// Runtime state for one target — the static definition plus what scanning
/// found and whether the user has it checked.
struct CleanupItemState: Identifiable {
    var id: String { target.id }
    let target: CleanupTarget
    var isEnabled: Bool
    /// Bytes it would reclaim, or nil when unsizable ahead of time
    /// (`.shellCommand` targets — the row shows "–" instead).
    var size: Int64?
    var blockedReason: String?
}

/// Scans the fixed cleanup targets, lets the user pick which to run, and
/// deletes only those — the Clean tab's backing store.
@MainActor
final class CleanupStore: ObservableObject {
    @Published private(set) var items: [CleanupItemState] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var lastFreed: Int64?
    @Published private(set) var fullDiskAccessOK = true

    private static let flippedKey = "cleanup.flippedTargets"
    /// Ids whose on/off state differs from `target.defaultOn` — only the
    /// exceptions are stored, since most targets keep their default forever.
    private var flipped: Set<String>

    init() {
        flipped = Set(UserDefaults.standard.stringArray(forKey: Self.flippedKey) ?? [])
    }

    var totalReclaimable: Int64 {
        items.filter { $0.isEnabled && $0.blockedReason == nil }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    func isEnabled(_ target: CleanupTarget) -> Bool {
        flipped.contains(target.id) ? !target.defaultOn : target.defaultOn
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = items.firstIndex(where: { $0.target.id == id }) else { return }
        let target = items[index].target
        if on == target.defaultOn {
            flipped.remove(id)
        } else {
            flipped.insert(id)
        }
        UserDefaults.standard.set(Array(flipped).sorted(), forKey: Self.flippedKey)
        items[index].isEnabled = on
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        Task { await performScan() }
    }

    /// A harmless probe: reading the user's own Caches folder needs Full
    /// Disk Access on some systems and never does on others, but either way
    /// it is the cheapest stand-in for "can Clean Now actually delete
    /// anything", asked before the button is pressed rather than after.
    /// Run off the main thread — same reasoning `SettingsPane.refreshUsage`
    /// gives for not walking a folder on the thread the panel lives on.
    private nonisolated static func probeFullDiskAccess() -> Bool {
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: caches.path)) != nil
    }

    private func performScan() async {
        isScanning = true
        // A fresh scan means "back to browsing", not "just finished" — the
        // freed-space banner is a one-time confirmation, not a sticky state.
        lastFreed = nil
        let built = Self.allTargets
        var next: [CleanupItemState] = []
        for target in built {
            let available = await Task.detached(priority: .utility) { target.isAvailable() }.value
            guard available else { continue }
            let size = await Task.detached(priority: .utility) { Self.computeSize(for: target) }.value
            next.append(CleanupItemState(
                target: target,
                isEnabled: isEnabled(target),
                size: size,
                blockedReason: target.isBlocked()
            ))
        }
        items = next
        fullDiskAccessOK = await Task.detached(priority: .utility) { Self.probeFullDiskAccess() }.value
        isScanning = false
    }

    func cleanNow() async {
        guard !isCleaning, !isScanning else { return }
        isCleaning = true
        let targets = items.filter { $0.isEnabled && $0.blockedReason == nil }.map(\.target)
        let before = Self.availableCapacity()
        await Task.detached(priority: .utility) {
            for target in targets { Self.perform(target) }
        }.value
        let after = Self.availableCapacity()
        isCleaning = false
        // Rescan first so the list reflects what is actually left on disk,
        // then stamp the freed total — otherwise the rescan above would wipe
        // the very number this method just measured.
        await performScan()
        lastFreed = max(0, after - before)
    }

    // MARK: - Sizing

    private nonisolated static func computeSize(for target: CleanupTarget) -> Int64? {
        switch target.kind {
        case .wholeFolderContents:
            guard let root = target.resolve().first else { return nil }
            return FileManager.default.allocatedSize(of: root)
        case .exactDirectories:
            return target.resolve().reduce(Int64(0)) { $0 + FileManager.default.allocatedSize(of: $1) }
        case .exactFile, .sqliteVacuum:
            guard let file = target.resolve().first else { return nil }
            let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey])
            return Int64(values?.fileAllocatedSize ?? 0)
        case .shellCommand:
            return nil
        }
    }

    private nonisolated static func availableCapacity() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    // MARK: - Cleaning

    /// Runs off the main actor — file trees and processes take as long as
    /// they take, and this is the thread the whole panel lives on.
    private nonisolated static func perform(_ target: CleanupTarget) {
        let fm = FileManager.default
        switch target.kind {
        case .wholeFolderContents:
            guard let root = target.resolve().first,
                  let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { return }
            for child in children { try? fm.removeItem(at: child) }
        case .exactFile:
            guard let file = target.resolve().first else { return }
            try? fm.removeItem(at: file)
        case .exactDirectories:
            for dir in target.resolve() { try? fm.removeItem(at: dir) }
        case .shellCommand(let executable, let arguments):
            guard !executable.isEmpty else { return }
            run(executable, arguments)
        case .sqliteVacuum:
            guard let file = target.resolve().first, let sqlite3 = which("sqlite3") else { return }
            run(sqlite3, [file.path, "VACUUM;"])
        }
    }

    @discardableResult
    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// `which <name>` via Process/Pipe.
    private nonisolated static func which(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    // MARK: - Targets

    private nonisolated static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Exact, case-sensitive names this app will ever delete under
    /// `~/Library/Application Support` — leaves of the recursive scan below.
    /// Never a substring match: "Local Storage", "IndexedDB", and anything
    /// else merely cache-adjacent stays untouched.
    private nonisolated static let cacheDirAllowlist: Set<String> = [
        "Cache", "Cache_Data", "CachedData", "Code Cache", "GPUCache",
        "DawnWebGPUCache", "DawnGraphiteCache", "Crashpad", "CachedExtensionVSIXs",
        "crx_cache", "appcache", "BrowserCaches", "PersistentCache",
        "component_crx_cache", "CacheStorage", ".cache",
    ]

    /// Subtrees the recursive scan never even walks into, let alone deletes
    /// from — the spec's "explicitly do not touch" list. `vm_bundles` is the
    /// hard requirement (a VM disk image, not a cache; a nested `.cache` or
    /// `Cache` directory inside a guest filesystem would otherwise match the
    /// allowlist by name and get wiped). The three Cursor paths mirror the
    /// spec's own carve-out for real extension/editor state living next to
    /// the database this feature otherwise touches.
    private nonisolated static var excludedRoots: [URL] {
        [
            home.appendingPathComponent("Library/Application Support/Claude/vm_bundles", isDirectory: true),
            cursorSupportDir.appendingPathComponent("User/workspaceStorage", isDirectory: true),
            cursorSupportDir.appendingPathComponent("User/History", isDirectory: true),
            cursorSupportDir.appendingPathComponent("User/globalStorage", isDirectory: true),
        ]
    }

    private nonisolated static func findAllowlistedCacheDirs() -> [URL] {
        let root = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        let excluded = excludedRoots
        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if excluded.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard cacheDirAllowlist.contains(url.lastPathComponent) else { continue }
            matches.append(url)
            // A match is a leaf: stop here rather than also collecting
            // whatever cache subfolders happen to live inside it.
            enumerator.skipDescendants()
        }
        return matches
    }

    private nonisolated static var cursorSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
    }

    private nonisolated static var cursorRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92"
        }
    }

    private nonisolated static var allTargets: [CleanupTarget] {
        let dockerSocket = home.appendingPathComponent(".docker/run/docker.sock")
        let dockerPath = which("docker")
        let npmDir = home.appendingPathComponent(".npm", isDirectory: true)
        let cacheDir = home.appendingPathComponent(".cache", isDirectory: true)
        let cursorBackup = cursorSupportDir.appendingPathComponent("User/globalStorage/state.vscdb.backup")
        let cursorDB = cursorSupportDir.appendingPathComponent("User/globalStorage/state.vscdb")

        return [
            CleanupTarget(
                id: "caches",
                title: localized("App & System Caches"),
                description: localized("Everything in ~/Library/Caches — every app rebuilds this from scratch."),
                kind: .wholeFolderContents,
                defaultOn: true,
                isAvailable: { true },
                isBlocked: { nil },
                resolve: { [home.appendingPathComponent("Library/Caches", isDirectory: true)] }
            ),
            CleanupTarget(
                id: "npm",
                title: localized("npm Package Cache"),
                description: localized("~/.npm — npm re-downloads packages as needed."),
                kind: .wholeFolderContents,
                defaultOn: true,
                isAvailable: { FileManager.default.fileExists(atPath: npmDir.path) },
                isBlocked: { nil },
                resolve: { [npmDir] }
            ),
            CleanupTarget(
                id: "dotCache",
                title: localized("CLI Tool Cache"),
                description: localized("~/.cache — shared cache folder used by many command-line dev tools."),
                kind: .wholeFolderContents,
                defaultOn: true,
                isAvailable: { FileManager.default.fileExists(atPath: cacheDir.path) },
                isBlocked: { nil },
                resolve: { [cacheDir] }
            ),
            CleanupTarget(
                id: "pnpmStore",
                title: localized("pnpm Store"),
                description: localized("Runs “pnpm store prune” to drop packages nothing references anymore."),
                kind: .shellCommand(executable: which("pnpm") ?? "", arguments: ["store", "prune"]),
                defaultOn: true,
                isAvailable: { which("pnpm") != nil },
                isBlocked: { nil },
                resolve: { [] }
            ),
            CleanupTarget(
                id: "dockerPrune",
                title: localized("Docker Unused Data"),
                description: localized("Removes ALL unused images, containers, and volumes not currently in use — off by default, more destructive than the rest."),
                kind: .shellCommand(executable: dockerPath ?? "", arguments: ["system", "prune", "-a", "--volumes", "-f"]),
                defaultOn: false,
                isAvailable: {
                    guard FileManager.default.fileExists(atPath: dockerSocket.path), let dockerPath else { return false }
                    return run(dockerPath, ["system", "df"])
                },
                isBlocked: { nil },
                resolve: { [] }
            ),
            CleanupTarget(
                id: "appSupportCaches",
                title: localized("App Cache Subfolders"),
                description: localized("Cache-style folders (Cache, GPUCache, Code Cache…) found anywhere under Application Support. Never touches saved app data."),
                kind: .exactDirectories,
                defaultOn: true,
                isAvailable: { true },
                isBlocked: { nil },
                resolve: { findAllowlistedCacheDirs() }
            ),
            CleanupTarget(
                id: "cursorBackup",
                title: localized("Cursor Database Backup"),
                description: localized("state.vscdb.backup — a leftover backup file, always safe to remove."),
                kind: .exactFile,
                defaultOn: true,
                isAvailable: { FileManager.default.fileExists(atPath: cursorBackup.path) },
                isBlocked: { nil },
                resolve: { [cursorBackup] }
            ),
            CleanupTarget(
                id: "cursorVacuum",
                title: localized("Compact Cursor Database"),
                description: localized("VACUUMs state.vscdb, reclaiming space from a known chat-history bloat bug. No data is lost."),
                kind: .sqliteVacuum,
                defaultOn: true,
                isAvailable: { FileManager.default.fileExists(atPath: cursorDB.path) },
                isBlocked: { cursorRunning ? localized("Quit Cursor first to compact its database") : nil },
                resolve: { [cursorDB] }
            ),
        ]
    }
}

private extension FileManager {
    /// Recursive allocated size of everything under `url`. Used instead of
    /// shelling out to `du -sh`, which this only falls back to if a target
    /// ever needs sizing this can't reach.
    func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]),
                  values.isDirectory != true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
