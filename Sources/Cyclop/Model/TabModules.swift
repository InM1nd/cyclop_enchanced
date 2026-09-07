import Foundation

/// Which tabs show on the rails. Settings itself is never optional — without
/// it there would be no way back in.
@MainActor
final class TabModules: ObservableObject {
    private static let key = "tabModules.disabled"

    @Published private(set) var disabled: Set<String>

    /// One-tap rail layouts for common days. Each set is the tabs that stay
    /// on; everything else (except Settings) is turned off.
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
                // Desk day: capture + agenda + focus + usage. Translate and
                // teleprompter stay off until someone asks for them.
                [.media, .shelf, .clipboard, .snippets, .calendar, .notes, .credits, .pomodoro, .memory, .colorPicker]
            case .call:
                // Meeting stretch: agenda, speaking notes, join link nearby.
                [.calendar, .notes, .teleprompter, .media]
            case .minimal:
                [.calendar, .notes]
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        disabled = Set(stored)
    }

    func isEnabled(_ tab: NotchViewModel.Tab) -> Bool {
        if tab == .settings { return true }
        return !disabled.contains(tab.rawValue)
    }

    func setEnabled(_ tab: NotchViewModel.Tab, _ on: Bool) {
        guard tab != .settings else { return }
        if on {
            disabled.remove(tab.rawValue)
        } else {
            disabled.insert(tab.rawValue)
        }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.key)
    }

    func apply(_ preset: Preset) {
        let keep = preset.enabled
        disabled = Set(
            NotchViewModel.Tab.toggleable
                .filter { !keep.contains($0) }
                .map(\.rawValue)
        )
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.key)
    }
}
