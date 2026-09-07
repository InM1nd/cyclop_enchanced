import SwiftUI

/// Activity Monitor's Memory Pressure, plus the caches that free SSD space
/// when RAM has already spilled into swap.
struct MemoryPane: View {
    @ObservedObject var memory: MemoryPressureStore
    @ObservedObject var cleanup: CleanupStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                pressureCard
                statsRow
                CleanupList(cleanup: cleanup)
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pressureCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Self.color(for: memory.level))
                .frame(width: 10, height: 10)
                .shadow(color: Self.color(for: memory.level).opacity(0.8), radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(memory.usedPercent.rounded()))%")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(Self.caption(for: memory))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.title(for: memory.level))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                Text(localized("Jetsam"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            stat(
                title: localized("Swap"),
                value: bytes(Int64(memory.swapUsed)),
                warn: memory.swapUsed > 0 && memory.level != .normal
            )
            stat(
                title: localized("Disk free"),
                value: bytes(memory.diskFree),
                warn: memory.diskIsLow
            )
        }
    }

    private func stat(title: String, value: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Color(red: 1.0, green: 0.78, blue: 0.20) : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func color(for level: MemoryPressureStore.Level) -> Color {
        switch level {
        case .normal: return Color(red: 0.35, green: 0.82, blue: 0.55)
        case .warn: return Color(red: 1.0, green: 0.78, blue: 0.20)
        case .critical: return Color(red: 1.0, green: 0.35, blue: 0.32)
        }
    }

    private static func title(for level: MemoryPressureStore.Level) -> String {
        switch level {
        case .normal: return localized("Memory Pressure · Green")
        case .warn: return localized("Memory Pressure · Yellow")
        case .critical: return localized("Memory Pressure · Red")
        }
    }

    private static func caption(for memory: MemoryPressureStore) -> String {
        if memory.glowFromPercent {
            return hint(for: memory.glowLevel)
        }
        switch memory.glowLevel {
        case .critical:
            return localized("The Mac is swapping. Close tabs, then clean caches below.")
        case .warn:
            return hint(for: .warn)
        case .normal:
            if memory.level == .warn {
                return localized("Graph is yellow. Notch stays dark until red.")
            }
            return localized("Notch stays dark until red.")
        }
    }

    private static func hint(for level: MemoryPressureStore.Level) -> String {
        switch level {
        case .normal: return localized("Running optimally.")
        case .warn: return localized("Close unneeded tabs and quit unused apps.")
        case .critical: return localized("The Mac is swapping. Close tabs, then clean caches below.")
        }
    }
}
