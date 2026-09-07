import SwiftUI

struct ColorPickerPane: View {
    @ObservedObject var picker: ColorPickerStore
    @State private var copiedKind: CopiedKind?

    private enum CopiedKind {
        case hex, rgb
    }

    var body: some View {
        HStack(spacing: 16) {
            swatch
            details
            Spacer(minLength: 0)
            eyedropper
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 2)
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(picker.current?.swiftUIColor ?? Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = picker.current {
                valueRow(
                    label: "HEX",
                    value: current.hex,
                    copied: copiedKind == .hex
                ) {
                    picker.copyHex()
                    flash(.hex)
                }
                valueRow(
                    label: "RGB",
                    value: current.rgbLabel,
                    copied: copiedKind == .rgb
                ) {
                    picker.copyRGB()
                    flash(.rgb)
                }
            } else {
                Text(localized("Pick a colour from the screen"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Text(localized("It copies as HEX automatically"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }

            if !picker.recent.isEmpty {
                recentRow
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentRow: some View {
        HStack(spacing: 6) {
            ForEach(picker.recent) { color in
                Button {
                    picker.selectRecent(color)
                    flash(.hex)
                } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(color.hex)
            }
        }
    }

    private var eyedropper: some View {
        Button {
            picker.pickFromScreen()
        } label: {
            Image(systemName: "eyedropper.halffull")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.surfaceHover))
                .opacity(picker.isSampling ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(picker.isSampling)
        .help(localized("Pick from Screen"))
    }

    private func valueRow(
        label: String,
        value: String,
        copied: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 28, alignment: .leading)
                Text(copied ? localized("Copied") : value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func flash(_ kind: CopiedKind) {
        withAnimation(.easeOut(duration: 0.12)) { copiedKind = kind }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if copiedKind == kind {
                withAnimation(.easeOut(duration: 0.15)) { copiedKind = nil }
            }
        }
    }
}
