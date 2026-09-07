import CyclopLogic
import Darwin
import Foundation

/// RAM used, swap, disk, and the jetsam pressure Activity Monitor graphs.
///
/// The tab follows that graph. The collapsed notch does not: yellow jetsam
/// is treated as a workday baseline, and the island lights only when jetsam
/// is already red. Used-percent is an extra tripwire, off unless switched on.
@MainActor
final class MemoryPressureStore: ObservableObject {
    enum Level: String {
        case normal, warn, critical
    }

    @Published private(set) var level: Level = .normal
    @Published private(set) var usedPercent: Double = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    @Published private(set) var diskFree: Int64 = 0
    @Published private(set) var yellowThreshold: Int
    @Published private(set) var redThreshold: Int
    /// Off: the notch only lights on red (jetsam 3+).
    /// On: it also turns yellow/red when used RAM crosses the steppers.
    @Published private(set) var glowFromPercent: Bool

    let physicalMemory = ProcessInfo.processInfo.physicalMemory

    static let diskWarnBytes: Int64 = 20 * 1024 * 1024 * 1024
    static let defaultYellow = 90
    static let defaultRed = 95

    var diskIsLow: Bool { diskFree > 0 && diskFree < Self.diskWarnBytes }

    /// Notch colour. Yellow on the Activity Monitor graph is a workday
    /// baseline here, so the island stays dark until jetsam goes red.
    /// Percent is an extra tripwire, and only when the user turned it on.
    var glowLevel: Level {
        switch MemoryGlow.notch(
            pressureIsRed: level == .critical,
            glowFromPercent: glowFromPercent,
            usedPercent: usedPercent,
            yellowAt: yellowThreshold,
            redAt: redThreshold
        ) {
        case .normal: return .normal
        case .warn: return .warn
        case .critical: return .critical
        }
    }

    private var source: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private var tabIsActive = false

    private static let yellowKey = "memory.glow.yellowPercent"
    private static let redKey = "memory.glow.redPercent"
    private static let percentKey = "memory.glow.fromPercent"

    init() {
        let defaults = UserDefaults.standard
        let storedYellow = defaults.object(forKey: Self.yellowKey) as? Int
        let storedRed = defaults.object(forKey: Self.redKey) as? Int
        // 70/90 was the first shipped pair; treat it as "never customised".
        let yellowRaw: Int
        let redRaw: Int
        if storedYellow == nil && storedRed == nil || storedYellow == 70 && storedRed == 90 {
            yellowRaw = Self.defaultYellow
            redRaw = Self.defaultRed
        } else {
            yellowRaw = storedYellow ?? Self.defaultYellow
            redRaw = storedRed ?? Self.defaultRed
        }
        let yellow = Self.clampYellow(yellowRaw, red: redRaw)
        yellowThreshold = yellow
        redThreshold = Self.clampRed(redRaw, yellow: yellow)
        glowFromPercent = defaults.bool(forKey: Self.percentKey)
        if storedYellow != yellowThreshold || storedRed != redThreshold {
            persistThresholds()
        }
    }

    func start() {
        refreshAll()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Colour comes from sysctl, not from the dispatch flags —
                // `.critical` fires already at "urgent", while Activity
                // Monitor's graph is still yellow.
                self?.refreshAll()
            }
        }
        source.resume()
        self.source = source
        restartTimer()
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    /// Faster poll while the Memory tab is on screen; a slow one otherwise,
    /// so the collapsed rim can still flip when RAM crosses a threshold.
    func setActive(_ active: Bool) {
        tabIsActive = active
        refreshAll()
        restartTimer()
    }

    func adjustYellow(by delta: Int) {
        setYellow(yellowThreshold + delta)
    }

    func adjustRed(by delta: Int) {
        setRed(redThreshold + delta)
    }

    func setGlowFromPercent(_ on: Bool) {
        glowFromPercent = on
        UserDefaults.standard.set(on, forKey: Self.percentKey)
    }

    private func setYellow(_ value: Int) {
        yellowThreshold = Self.clampYellow(value, red: redThreshold)
        if redThreshold <= yellowThreshold {
            redThreshold = Self.clampRed(yellowThreshold + 5, yellow: yellowThreshold)
        }
        persistThresholds()
    }

    private func setRed(_ value: Int) {
        redThreshold = Self.clampRed(value, yellow: yellowThreshold)
        if yellowThreshold >= redThreshold {
            yellowThreshold = Self.clampYellow(redThreshold - 5, red: redThreshold)
        }
        persistThresholds()
    }

    private func persistThresholds() {
        let defaults = UserDefaults.standard
        defaults.set(yellowThreshold, forKey: Self.yellowKey)
        defaults.set(redThreshold, forKey: Self.redKey)
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval: TimeInterval = tabIsActive ? 5 : 15
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        timer.tolerance = tabIsActive ? 1 : 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshAll() {
        refreshLevel()
        refreshStats()
    }

    private func refreshLevel() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0
        guard ok else { return }
        // Activity Monitor: 0 green, 1–2 yellow, 3+ red. The notch ignores
        // yellow and only glows at critical — see `glowLevel`.
        switch value {
        case 0: level = .normal
        case 1, 2: level = .warn
        default: level = .critical
        }
    }

    private func refreshStats() {
        usedPercent = Self.ramUsedPercent(physical: physicalMemory)
        swapUsed = Self.swap().used
        swapTotal = Self.swap().total
        diskFree = Self.volumeFree()
    }

    private struct Swap {
        var total: UInt64
        var used: UInt64
    }

    /// Active + wired + compressed, over physical RAM. Cached files stay out
    /// so a machine that is "full" of browser cache does not sit at 95% red.
    private nonisolated static func ramUsedPercent(physical: UInt64) -> Double {
        guard physical > 0 else { return 0 }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let used = pages * UInt64(pageSize)
        return min(100, Double(used) / Double(physical) * 100)
    }

    private nonisolated static func swap() -> Swap {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return Swap(total: 0, used: 0)
        }
        return Swap(total: usage.xsu_total, used: usage.xsu_used)
    }

    private nonisolated static func volumeFree() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let fallback = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(fallback?.volumeAvailableCapacity ?? 0)
    }

    private static func clampYellow(_ value: Int, red: Int) -> Int {
        min(max(value, 40), min(red - 1, 95))
    }

    private static func clampRed(_ value: Int, yellow: Int) -> Int {
        max(min(value, 99), max(yellow + 1, 50))
    }
}
