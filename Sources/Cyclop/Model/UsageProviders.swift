import Foundation

/// The brand cards on the Usage tab. Order here is render order, both in the
/// grid and in the Settings toggle list.
enum UsageProvider: String, CaseIterable, Identifiable {
    case claude, codex, cursor, opencode

    var id: String { rawValue }

    /// Brand names, not translated — same call as the all-caps labels
    /// already drawn on each card.
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow"
        case .opencode: "terminal"
        }
    }
}

/// Near-square grid shared by the card layout and the window's body height —
/// both need the same row count to agree, or the panel and the grid drift
/// apart. rows = ⌊√n⌋, cols = ⌈n/rows⌉: 3 → 1×3, 4 → 2×2, 6 → 2×3, width
/// grows before height does, since the panel has more of that to give.
enum UsageGrid {
    /// Gap between cards, both across and down — `CreditsPane`'s `LazyVGrid`
    /// spacing, mirrored here so the window's body-height math agrees with it.
    static let rowSpacing: CGFloat = 8

    static func rows(for count: Int) -> Int {
        guard count > 1 else { return max(count, 1) }
        return max(Int(Double(count).squareRoot()), 1)
    }

    static func columns(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        return Int((Double(count) / Double(rows(for: count))).rounded(.up))
    }
}

/// Which brand cards show on the Usage tab. A separate on/off set from
/// `TabModules`: hiding the whole Usage tab and hiding one card inside it
/// are different questions, so they get different storage.
@MainActor
final class UsageProviderSettings: ObservableObject {
    private static let key = "usageProviders.disabled"

    @Published private(set) var disabled: Set<String>

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        disabled = Set(stored)
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        !disabled.contains(provider.rawValue)
    }

    /// Providers left on, in `UsageProvider`'s declared order — what the
    /// grid actually renders.
    var enabled: [UsageProvider] {
        UsageProvider.allCases.filter(isEnabled)
    }

    func setEnabled(_ provider: UsageProvider, _ on: Bool) {
        if on {
            disabled.remove(provider.rawValue)
        } else {
            disabled.insert(provider.rawValue)
        }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.key)
    }
}
