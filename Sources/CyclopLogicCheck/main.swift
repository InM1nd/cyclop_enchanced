import CyclopLogic
import Foundation

/// Assertions that do not need XCTest — Command Line Tools have no test SDK,
/// and CI should still catch a glow/grid regression without a full Xcode.
@main
enum CyclopLogicCheck {
    static func main() {
        var failed = 0

        func expect(_ cond: Bool, _ name: String) {
            if cond { return }
            FileHandle.standardError.write(Data("fail: \(name)\n".utf8))
            failed += 1
        }

        expect(
            MemoryGlow.notch(
                pressureIsRed: false,
                glowFromPercent: false,
                usedPercent: 99,
                yellowAt: 90,
                redAt: 95
            ) == .normal,
            "yellow pressure leaves the notch dark"
        )
        expect(
            MemoryGlow.notch(
                pressureIsRed: true,
                glowFromPercent: false,
                usedPercent: 10,
                yellowAt: 90,
                redAt: 95
            ) == .critical,
            "red pressure lights the notch"
        )
        expect(
            MemoryGlow.notch(
                pressureIsRed: false,
                glowFromPercent: false,
                usedPercent: 92,
                yellowAt: 90,
                redAt: 95
            ) == .normal,
            "percent is ignored until switched on"
        )
        expect(
            MemoryGlow.notch(
                pressureIsRed: false,
                glowFromPercent: true,
                usedPercent: 92,
                yellowAt: 90,
                redAt: 95
            ) == .warn,
            "percent yellow when enabled"
        )
        expect(
            MemoryGlow.notch(
                pressureIsRed: false,
                glowFromPercent: true,
                usedPercent: 96,
                yellowAt: 90,
                redAt: 95
            ) == .critical,
            "percent red outranks yellow"
        )
        expect(
            MemoryGlow.notch(
                pressureIsRed: true,
                glowFromPercent: true,
                usedPercent: 92,
                yellowAt: 90,
                redAt: 95
            ) == .critical,
            "pressure red outranks percent yellow"
        )

        expect(UsageGrid.rows(for: 1) == 1 && UsageGrid.columns(for: 1) == 1, "1 → 1×1")
        expect(UsageGrid.rows(for: 2) == 1 && UsageGrid.columns(for: 2) == 2, "2 → 1×2")
        expect(UsageGrid.rows(for: 3) == 1 && UsageGrid.columns(for: 3) == 3, "3 → 1×3")
        expect(UsageGrid.rows(for: 4) == 2 && UsageGrid.columns(for: 4) == 2, "4 → 2×2")

        if failed > 0 {
            FileHandle.standardError.write(Data("\(failed) checks failed\n".utf8))
            exit(1)
        }
        print("CyclopLogicCheck: ok")
    }
}
