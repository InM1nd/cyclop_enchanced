import AppKit
import UserNotifications

/// Focus / break timer that lives in the notch: start it, close the panel,
/// come back when the chime says the phase is over.
@MainActor
final class PomodoroStore: ObservableObject {
    enum Phase: String {
        case work, shortBreak, longBreak
    }

    enum Preset: String, CaseIterable, Identifiable {
        case classic, short, long, custom
        var id: String { rawValue }

        /// `nil` for custom — the three minute fields are whatever the user left.
        var durations: (work: Int, shortBreak: Int, longBreak: Int)? {
            switch self {
            case .classic: return (25, 5, 15)
            case .short: return (15, 3, 10)
            case .long: return (50, 10, 20)
            case .custom: return nil
            }
        }
    }

    static let roundsUntilLongBreak = 4

    @Published private(set) var preset: Preset
    @Published private(set) var workMinutes: Int
    @Published private(set) var shortBreakMinutes: Int
    @Published private(set) var longBreakMinutes: Int

    @Published private(set) var phase: Phase = .work
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var isRunning = false
    /// Work sessions finished this run of the app — drives the long-break cadence.
    @Published private(set) var completedRounds = 0

    private static let presetKey = "pomodoro.preset"
    private static let workKey = "pomodoro.workMinutes"
    private static let shortKey = "pomodoro.shortBreakMinutes"
    private static let longKey = "pomodoro.longBreakMinutes"

    private let defaults = UserDefaults.standard
    private var endsAt: Date?
    private var timer: Timer?
    private var askedForNotifications = false

    init() {
        let work = Self.clampWork(defaults.object(forKey: Self.workKey) as? Int ?? 25)
        let shortBreak = Self.clampBreak(defaults.object(forKey: Self.shortKey) as? Int ?? 5)
        let longBreak = Self.clampBreak(defaults.object(forKey: Self.longKey) as? Int ?? 15)

        var resolved = Preset.classic
        if let raw = defaults.string(forKey: Self.presetKey),
           let stored = Preset(rawValue: raw) {
            resolved = stored
        }
        // A stored "classic" whose minutes were edited by hand is custom.
        if let durations = resolved.durations,
           (work, shortBreak, longBreak) != (durations.work, durations.shortBreak, durations.longBreak) {
            resolved = .custom
        }

        preset = resolved
        workMinutes = work
        shortBreakMinutes = shortBreak
        longBreakMinutes = longBreak
        remaining = TimeInterval(work * 60)
    }

    var phaseTitle: String {
        switch phase {
        case .work: return localized("Focus")
        case .shortBreak: return localized("Break")
        case .longBreak: return localized("Long Break")
        }
    }

    /// Phase whose colour should ring the collapsed island, if any.
    /// `nil` when the timer is idle — the notch goes back to plain black.
    var collapsedRimPhase: Phase? { isRunning ? phase : nil }

    var clock: String {
        let total = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Dots under the clock: filled for finished rounds in the current set of four.
    var roundIndexInSet: Int {
        completedRounds % Self.roundsUntilLongBreak
    }

    func selectPreset(_ next: Preset) {
        preset = next
        defaults.set(next.rawValue, forKey: Self.presetKey)
        guard let durations = next.durations else { return }
        workMinutes = durations.work
        shortBreakMinutes = durations.shortBreak
        longBreakMinutes = durations.longBreak
        persistDurations()
        if !isRunning {
            remaining = TimeInterval(durationMinutes(for: phase) * 60)
        }
    }

    func adjustWork(by delta: Int) { adjust(\.workMinutes, by: delta, clamp: Self.clampWork) }
    func adjustShortBreak(by delta: Int) { adjust(\.shortBreakMinutes, by: delta, clamp: Self.clampBreak) }
    func adjustLongBreak(by delta: Int) { adjust(\.longBreakMinutes, by: delta, clamp: Self.clampBreak) }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        requestNotificationsIfNeeded()
        if remaining <= 0 {
            remaining = TimeInterval(durationMinutes(for: phase) * 60)
        }
        endsAt = Date().addingTimeInterval(remaining)
        isRunning = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        guard isRunning else { return }
        syncRemainingFromClock()
        endsAt = nil
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Jump to the next phase without counting the current one as finished.
    func skip() {
        let wasRunning = isRunning
        pause()
        switch phase {
        case .work:
            phase = .shortBreak
        case .shortBreak, .longBreak:
            phase = .work
        }
        remaining = TimeInterval(durationMinutes(for: phase) * 60)
        if wasRunning { start() }
    }

    /// Back to a full Focus, stopped, rounds kept.
    func reset() {
        pause()
        phase = .work
        remaining = TimeInterval(workMinutes * 60)
    }

    // MARK: - Private

    private func adjust(
        _ keyPath: ReferenceWritableKeyPath<PomodoroStore, Int>,
        by delta: Int,
        clamp: (Int) -> Int
    ) {
        let next = clamp(self[keyPath: keyPath] + delta)
        guard next != self[keyPath: keyPath] else { return }
        self[keyPath: keyPath] = next
        if preset != .custom {
            preset = .custom
            defaults.set(Preset.custom.rawValue, forKey: Self.presetKey)
        }
        persistDurations()
        if !isRunning {
            remaining = TimeInterval(durationMinutes(for: phase) * 60)
        }
    }

    private func persistDurations() {
        defaults.set(workMinutes, forKey: Self.workKey)
        defaults.set(shortBreakMinutes, forKey: Self.shortKey)
        defaults.set(longBreakMinutes, forKey: Self.longKey)
    }

    private func durationMinutes(for phase: Phase) -> Int {
        switch phase {
        case .work: return workMinutes
        case .shortBreak: return shortBreakMinutes
        case .longBreak: return longBreakMinutes
        }
    }

    private func tick() {
        guard isRunning, let endsAt else { return }
        let left = endsAt.timeIntervalSinceNow
        if left <= 0 {
            remaining = 0
            finishPhase()
        } else {
            remaining = left
        }
    }

    private func syncRemainingFromClock() {
        if let endsAt {
            remaining = max(0, endsAt.timeIntervalSinceNow)
        }
    }

    private func finishPhase() {
        pause()
        announce()
        advance(completedWork: phase == .work)
        start()
    }

    private func advance(completedWork: Bool) {
        if completedWork {
            completedRounds += 1
            if completedRounds % Self.roundsUntilLongBreak == 0 {
                phase = .longBreak
            } else {
                phase = .shortBreak
            }
        } else {
            phase = .work
        }
        remaining = TimeInterval(durationMinutes(for: phase) * 60)
    }

    private func announce() {
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "Cyclop"
        content.body = phase == .work
            ? localized("Focus done — time for a break")
            : localized("Break over — back to focus")
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "pomodoro.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func requestNotificationsIfNeeded() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func clampWork(_ value: Int) -> Int { min(max(value, 1), 90) }
    private static func clampBreak(_ value: Int) -> Int { min(max(value, 1), 60) }
}
