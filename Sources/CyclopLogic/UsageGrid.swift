import CoreGraphics

/// Near-square grid shared by the Usage cards and the window's body height.
/// Width grows first: 1 → one card, 2 → two across, 3 → three across, 4 → 2×2.
public enum UsageGrid {
    public static let rowSpacing: CGFloat = 8

    public static func rows(for count: Int) -> Int {
        guard count > 1 else { return max(count, 1) }
        return max(Int(Double(count).squareRoot()), 1)
    }

    public static func columns(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        return Int((Double(count) / Double(rows(for: count))).rounded(.up))
    }
}
