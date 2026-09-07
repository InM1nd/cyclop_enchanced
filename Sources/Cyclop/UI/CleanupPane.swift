import SwiftUI

/// Safe, regenerable caches: sized on the way in, deleted only where checked.
///
/// The Memory tab owns the scroll view — this is just the list and the
/// button, so pressure and cleanup move together.
struct CleanupList: View {
    @ObservedObject var cleanup: CleanupStore

    @State private var confirmArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !cleanup.fullDiskAccessOK {
                fullDiskAccessNotice
            }

            VStack(spacing: 1) {
                ForEach(cleanup.items) { item in
                    row(item)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )

            footer
        }
        .task(id: confirmArmed) {
            guard confirmArmed else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            confirmArmed = false
        }
    }

    private func row(_ item: CleanupItemState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: item.target.id))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.target.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Text(item.blockedReason ?? item.target.description)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(item.blockedReason == nil ? Theme.tertiary : Color.orange.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(sizeLabel(item.size))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { cleanup.setEnabled(item.target.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(item.blockedReason != nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .opacity(item.blockedReason == nil ? 1 : 0.6)
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "caches": return "internaldrive"
        case "npm": return "shippingbox"
        case "dotCache": return "terminal"
        case "pnpmStore": return "cube.box"
        case "dockerPrune": return "cube.transparent"
        case "appSupportCaches": return "square.stack.3d.up"
        case "cursorBackup": return "doc.badge.clock"
        case "cursorVacuum": return "arrow.triangle.2.circlepath"
        default: return "trash"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let freed = cleanup.lastFreed {
                Text(localized("Freed %@", humanSize(freed)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            } else if cleanup.isScanning {
                Text(localized("Scanning…"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            } else {
                Text(localized("Reclaimable: %@", humanSize(cleanup.totalReclaimable)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            cleanButton
        }
        .padding(.horizontal, 4)
    }

    private var nothingSelected: Bool {
        cleanup.items.allSatisfy { !$0.isEnabled || $0.blockedReason != nil }
    }

    private var cleanButton: some View {
        Button {
            if confirmArmed {
                confirmArmed = false
                Task { await cleanup.cleanNow() }
            } else {
                confirmArmed = true
            }
        } label: {
            HStack(spacing: 6) {
                if cleanup.isCleaning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: confirmArmed ? "checkmark.circle.fill" : "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(confirmArmed ? localized("Tap to Confirm") : localized("Clean Now"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(confirmArmed ? Color.red.opacity(0.55) : Theme.surfaceHover)
            )
        }
        .buttonStyle(.plain)
        .disabled(cleanup.isCleaning || cleanup.isScanning || !cleanup.fullDiskAccessOK || nothingSelected)
        .opacity((cleanup.isCleaning || cleanup.isScanning || !cleanup.fullDiskAccessOK || nothingSelected) ? 0.5 : 1)
    }

    private var fullDiskAccessNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Cyclop needs Full Disk Access to clean system caches"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            Text(localized("Quit and reopen Cyclop after granting access."))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Button {
                cleanup.openFullDiskAccessSettings()
            } label: {
                Text(localized("Open Full Disk Access Settings"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule(style: .continuous).fill(Theme.surfaceHover))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
    }

    private func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func sizeLabel(_ bytes: Int64?) -> String {
        guard let bytes else { return "–" }
        return humanSize(bytes)
    }
}
