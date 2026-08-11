import Foundation

/// Keeps the Mac awake with the lid closed by wrapping `caffeinate -s` — the
/// same one-job trick as the standalone LidAwake utility, folded in here
/// instead of running as a second menu-bar app. There is never more than one
/// child process in flight, and only the exact instance this manager
/// launched is ever terminated.
@MainActor
final class SleepManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private static let persistedKey = "keepAwakeEnabled"
    private var process: Process?

    init() {
        if UserDefaults.standard.bool(forKey: Self.persistedKey) {
            enable()
        }
    }

    func setEnabled(_ shouldBeEnabled: Bool) {
        shouldBeEnabled ? enable() : disable()
    }

    /// Called on quit — an orphaned `caffeinate` would otherwise keep the Mac
    /// awake forever with nothing left to turn it off from.
    func stop() {
        disable()
    }

    private func enable() {
        if let process, process.isRunning {
            isEnabled = true
            return
        }
        errorMessage = nil

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-s"]
        // Cleared before an intentional `terminate()` in `disable()`, so this
        // only ever fires on an unexpected exit — no identity check needed.
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleUnexpectedTermination() }
        }

        do {
            try task.run()
            process = task
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.persistedKey)
        } catch {
            NSLog("Cyclop: failed to launch caffeinate: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.persistedKey)
        }
    }

    private func disable() {
        guard let task = process else {
            isEnabled = false
            return
        }
        task.terminationHandler = nil
        if task.isRunning { task.terminate() }
        process = nil
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.persistedKey)
    }

    private func handleUnexpectedTermination() {
        guard process != nil else { return }
        process = nil
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.persistedKey)
        errorMessage = "caffeinate exited unexpectedly"
        NSLog("Cyclop: caffeinate exited unexpectedly")
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}
