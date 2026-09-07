import Foundation

/// Who paints the collapsed island for RAM.
///
/// Activity Monitor yellow is a workday baseline (compression + swap), so the
/// notch stays dark until jetsam is already red. Used-percent is an extra
/// tripwire, and only when someone turned it on.
public enum MemoryGlow {
    public enum Notch: Equatable {
        case normal, warn, critical
    }

    public static func notch(
        pressureIsRed: Bool,
        glowFromPercent: Bool,
        usedPercent: Double,
        yellowAt: Int,
        redAt: Int
    ) -> Notch {
        let fromPressure: Notch = pressureIsRed ? .critical : .normal
        guard glowFromPercent else { return fromPressure }
        let fromPercent: Notch
        if usedPercent >= Double(redAt) {
            fromPercent = .critical
        } else if usedPercent >= Double(yellowAt) {
            fromPercent = .warn
        } else {
            fromPercent = .normal
        }
        switch (fromPressure, fromPercent) {
        case (.critical, _), (_, .critical): return .critical
        case (.warn, _), (_, .warn): return .warn
        default: return .normal
        }
    }
}
