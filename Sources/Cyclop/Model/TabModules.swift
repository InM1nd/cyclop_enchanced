import Foundation

/// Which tabs show on the rails, and which rail each one sits on.
///
/// Settings itself is never optional and never leaves the right rail — without
/// it there would be no way back in.
@MainActor
final class TabModules: ObservableObject {
    private static let disabledKey = "tabModules.disabled"
    private static let leftKey = "tabModules.left"
    private static let rightKey = "tabModules.right"

    @Published private(set) var disabled: Set<String>
    @Published private(set) var left: [NotchViewModel.Tab]
    @Published private(set) var right: [NotchViewModel.Tab]

    /// One-tap rail layouts for common days. Each set is the tabs that stay
    /// on; everything else (except Settings) is turned off. Sides stay as
    /// the user left them — a preset is a filter, not a reshuffle.
    enum Preset: String, CaseIterable, Identifiable {
        case work, call, minimal

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .work: "Work"
            case .call: "Call"
            case .minimal: "Minimal"
            }
        }

        /// Tabs left enabled. Settings is always kept by `apply`.
        var enabled: Set<NotchViewModel.Tab> {
            switch self {
            case .work:
                [.media, .shelf, .clipboard, .snippets, .calendar, .notes, .credits, .pomodoro, .memory, .colorPicker]
            case .call:
                [.calendar, .notes, .teleprompter, .media]
            case .minimal:
                [.calendar, .notes]
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []
        disabled = Set(stored)
        let loaded = Self.loadRails()
        left = loaded.left
        right = loaded.right
    }

    func isEnabled(_ tab: NotchViewModel.Tab) -> Bool {
        if tab == .settings { return true }
        return !disabled.contains(tab.rawValue)
    }

    func isLeft(_ tab: NotchViewModel.Tab) -> Bool {
        left.contains(tab)
    }

    func setEnabled(_ tab: NotchViewModel.Tab, _ on: Bool) {
        guard tab != .settings else { return }
        if on {
            disabled.remove(tab.rawValue)
        } else {
            disabled.insert(tab.rawValue)
        }
        persistDisabled()
    }

    func apply(_ preset: Preset) {
        let keep = preset.enabled
        disabled = Set(
            NotchViewModel.Tab.toggleable
                .filter { !keep.contains($0) }
                .map(\.rawValue)
        )
        persistDisabled()
    }

    func setLeft(_ tab: NotchViewModel.Tab, _ onLeft: Bool) {
        guard tab != .settings else { return }
        left.removeAll { $0 == tab }
        right.removeAll { $0 == tab }
        if onLeft {
            left.append(tab)
        } else {
            insertOnRight(tab)
        }
        persistRails()
    }

    func move(_ tab: NotchViewModel.Tab, by offset: Int) {
        guard tab != .settings else { return }
        if let i = left.firstIndex(of: tab) {
            shift(&left, at: i, by: offset)
        } else if let i = right.firstIndex(of: tab) {
            shift(&right, at: i, by: offset, freezeLast: right.last == .settings)
        } else {
            return
        }
        persistRails()
    }

    private func insertOnRight(_ tab: NotchViewModel.Tab) {
        if let i = right.firstIndex(of: .settings) {
            right.insert(tab, at: i)
        } else {
            right.append(tab)
        }
    }

    private func shift(
        _ tabs: inout [NotchViewModel.Tab],
        at i: Int,
        by offset: Int,
        freezeLast: Bool = false
    ) {
        let last = freezeLast ? tabs.count - 2 : tabs.count - 1
        guard last >= 0 else { return }
        let j = min(max(i + offset, 0), last)
        guard j != i else { return }
        let item = tabs.remove(at: i)
        tabs.insert(item, at: j)
    }

    private func persistDisabled() {
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        objectWillChange.send()
    }

    private func persistRails() {
        UserDefaults.standard.set(left.map(\.rawValue), forKey: Self.leftKey)
        UserDefaults.standard.set(right.map(\.rawValue), forKey: Self.rightKey)
        objectWillChange.send()
    }

    private static func loadRails() -> (left: [NotchViewModel.Tab], right: [NotchViewModel.Tab]) {
        let defaults = UserDefaults.standard
        let storedLeft = tabs(defaults.stringArray(forKey: leftKey) ?? [])
        let storedRight = tabs(defaults.stringArray(forKey: rightKey) ?? [])
        if storedLeft.isEmpty && storedRight.isEmpty {
            return (NotchViewModel.Tab.defaultLeftRail, NotchViewModel.Tab.defaultRightRail)
        }

        var seen = Set<NotchViewModel.Tab>()
        var left = storedLeft.filter { $0 != .settings && seen.insert($0).inserted }
        var right = storedRight.filter { $0 != .settings && seen.insert($0).inserted }

        for tab in NotchViewModel.Tab.defaultLeftRail where tab != .settings && !seen.contains(tab) {
            left.append(tab)
            seen.insert(tab)
        }
        for tab in NotchViewModel.Tab.defaultRightRail where tab != .settings && !seen.contains(tab) {
            right.append(tab)
            seen.insert(tab)
        }
        right.append(.settings)
        return (left, right)
    }

    private static func tabs(_ raw: [String]) -> [NotchViewModel.Tab] {
        raw.compactMap(NotchViewModel.Tab.init(rawValue:))
    }
}
