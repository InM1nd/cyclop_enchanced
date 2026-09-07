import Foundation

enum UsageProvider: String, CaseIterable, Identifiable {
    case claude, codex, cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow"
        }
    }
}

enum UsageGrid {
    static let rowSpacing: CGFloat = 8

    /// Width grows first: 1 → one card, 2 → two across, 3 → three across,
    /// 4 → 2×2. `Int(sqrt(3))` is 1, so three providers stay on a single row.
    static func rows(for count: Int) -> Int {
        guard count > 1 else { return max(count, 1) }
        return max(Int(Double(count).squareRoot()), 1)
    }

    static func columns(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        return Int((Double(count) / Double(rows(for: count))).rounded(.up))
    }
}

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
