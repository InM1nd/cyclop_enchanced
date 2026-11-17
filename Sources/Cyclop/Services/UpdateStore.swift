import AppKit
import CyclopLogic
import Security

/// Updates from GitHub releases without Sparkle. The trust anchor is the
/// app's own signature: the app inside the release image must satisfy the
/// running copy's designated requirement — same bundle id, same signing
/// certificate — or it is thrown away. An ad-hoc signed copy pins itself to
/// its own hash, nothing can satisfy that, so it is sent to the release page.
@MainActor
final class UpdateStore: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case installing
        case failed(String)
        /// A newer version exists but this copy cannot replace itself.
        case manualOnly(version: String)
    }

    @Published private(set) var state: State = .idle

    private nonisolated static let repo = "InM1nd/cyclop_enchanced"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var assetURL: URL?
    private var lastCheck: Date?

    /// Opening Settings checks at most once an hour — GitHub allows sixty
    /// anonymous calls an hour, and a release does not come out that often.
    func checkIfStale() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        check()
    }

    func check() {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        lastCheck = Date()
        Task {
            do {
                let release = try await Self.latestRelease()
                let version = AppVersion.strip(release.tagName)
                guard AppVersion.isNewer(version, than: Self.currentVersion),
                      let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                    state = .upToDate
                    return
                }
                assetURL = asset.browserDownloadUrl
                state = Self.canReplaceItself ? .available(version: version) : .manualOnly(version: version)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func install() {
        guard case .available(let version) = state, let assetURL else { return }
        state = .installing
        Task {
            do {
                let installed = Bundle.main.bundleURL
                let staged = try await Self.stage(from: assetURL, version: version, beside: installed)
                try Self.relaunch(replacing: installed, with: staged)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - GitHub

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
    }

    private nonisolated static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(localized("GitHub did not answer"))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    // MARK: - Install

    /// Translocated (run straight from Downloads or the image), in a folder
    /// it cannot write, or ad-hoc signed — any of these, and the update is a
    /// download from the release page instead.
    private static var canReplaceItself: Bool {
        let app = Bundle.main.bundleURL
        guard !app.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              let requirement = ownRequirement() else { return false }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return false }
        return !(text as String).hasPrefix("cdhash")
    }

    private nonisolated static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    /// Downloads and mounts the image, copies the app next to the installed
    /// one — so the final swap is a rename on one volume — and verifies it.
    private nonisolated static func stage(from url: URL, version: String, beside installed: URL) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "cyclop-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(localized("Download failed"))
        }
        let dmg = work.appending(path: "update.dmg")
        try fm.moveItem(at: downloaded, to: dmg)

        let mount = work.appending(path: "mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appending(path: "Cyclop.app")
        let staged = installed.deletingLastPathComponent().appending(path: ".Cyclop-update.app")
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", [source.path, staged.path])
        do {
            try verify(staged, version: version)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// The hard gate: no "install anyway".
    private nonisolated static func verify(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let inside = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              inside == version
        else { throw UpdateError(localized("The downloaded app is not the expected version")) }

        var staticCode: SecStaticCode?
        guard let requirement = ownRequirement(),
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),
                  requirement
              ) == errSecSuccess
        else { throw UpdateError(localized("The downloaded app is not signed by Cyclop")) }
    }

    /// A detached shell waits for this process to exit, swaps the bundles —
    /// putting the old one back if the swap fails — and opens the result.
    private static func relaunch(replacing installed: URL, with staged: URL) throws {
        let backup = installed.deletingLastPathComponent().appending(path: ".Cyclop-old.app")
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$4"
        if ! mv "$2" "$4"; then open "$2"; exit 1; fi
        if mv "$3" "$2"; then rm -rf "$4"; else mv "$4" "$2"; fi
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh",
                             String(ProcessInfo.processInfo.processIdentifier),
                             installed.path, staged.path, backup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(localized("%@ failed", (tool as NSString).lastPathComponent))
        }
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
