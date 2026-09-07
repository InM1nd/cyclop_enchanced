import SwiftUI
import ServiceManagement

/// What used to live in the status bar menu, minus the two items that belong
/// there: opening the panel and hiding its contents are both things people
/// reach for in a hurry, often without wanting to open the panel at all — the
/// rest is configuration, read rarely, and reads better as a tab like any
/// other than as a menu that grows a new row per feature.
struct SettingsPane: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var sleepManager: SleepManager
    @ObservedObject var memory: MemoryPressureStore
    @ObservedObject var usageProviders: UsageProviderSettings
    @ObservedObject var modules: TabModules
    var setModuleEnabled: (NotchViewModel.Tab, Bool) -> Void
    var applyModulePreset: (TabModules.Preset) -> Void
    var compact: Bool = true
    var onOpenFull: (() -> Void)? = nil
    var onPreviewYellow: () -> Void
    var onPreviewRed: () -> Void
    var onPreviewMeeting: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    toggleRow(
                        symbol: "cup.and.saucer.fill",
                        title: localized("Keep Awake with Lid Closed"),
                        isOn: keepAwakeBinding
                    )
                }

                section(localized("Usage")) {
                    ForEach(UsageProvider.allCases) { provider in
                        toggleRow(
                            symbol: provider.symbol,
                            title: provider.title,
                            isOn: Binding(
                                get: { usageProviders.isEnabled(provider) },
                                set: { usageProviders.setEnabled(provider, $0) }
                            )
                        )
                    }
                }

                if compact {
                    actionRow(symbol: "slider.horizontal.3", title: localized("All Settings…")) {
                        onOpenFull?()
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surface)
                    )
                }

                if !compact {
                section(localized("Idle Screen")) {
                    IdleScreenStyleSection()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }

                section(localized("Modules")) {
                    HStack(spacing: 6) {
                        ForEach(TabModules.Preset.allCases) { preset in
                            Button {
                                applyModulePreset(preset)
                            } label: {
                                Text(localized(preset.titleKey))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .background(
                                        Capsule(style: .continuous).fill(Theme.surfaceHover)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)

                    ForEach(NotchViewModel.Tab.toggleable) { tab in
                        toggleRow(
                            symbol: tab.symbol,
                            title: tab.title,
                            isOn: Binding(
                                get: { modules.isEnabled(tab) },
                                set: { setModuleEnabled(tab, $0) }
                            )
                        )
                    }
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        ScreenshotVault.reveal()
                    }
                    actionRow(
                        symbol: "trash",
                        title: clearTitle,
                        disabled: screenshotUsage.files == 0
                    ) {
                        ScreenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
                    }
                }

                section(localized("Memory glow")) {
                    toggleRow(
                        symbol: "percent",
                        title: localized("Also glow from RAM used"),
                        isOn: glowFromPercentBinding
                    )
                    HStack(spacing: 8) {
                        glowStepper(
                            symbol: "circle.fill",
                            tint: Color(red: 1.0, green: 0.78, blue: 0.20),
                            title: localized("Yellow at"),
                            value: memory.yellowThreshold,
                            decrement: { memory.adjustYellow(by: -5) },
                            increment: { memory.adjustYellow(by: 5) }
                        )
                        glowStepper(
                            symbol: "circle.fill",
                            tint: Color(red: 1.0, green: 0.35, blue: 0.32),
                            title: localized("Red at"),
                            value: memory.redThreshold,
                            decrement: { memory.adjustRed(by: -5) },
                            increment: { memory.adjustRed(by: 5) }
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .opacity(memory.glowFromPercent ? 1 : 0.4)
                    .disabled(!memory.glowFromPercent)
                    Text(localized("Notch glows only when the graph is red."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                section(localized("Preview glow")) {
                    actionRow(symbol: "circle.fill", title: localized("Preview yellow")) {
                        onPreviewYellow()
                    }
                    actionRow(symbol: "circle.fill", title: localized("Preview red")) {
                        onPreviewRed()
                    }
                    actionRow(symbol: "sparkle", title: localized("Preview meeting")) {
                        onPreviewMeeting()
                    }
                }

                section(localized("Snippets")) {
                    actionRow(symbol: "doc.text", title: localized("Show Snippets File")) {
                        SnippetStore.reveal()
                    }
                }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            refreshUsage()
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { sleepManager.isEnabled },
            set: { sleepManager.setEnabled($0) }
        )
    }

    private var glowFromPercentBinding: Binding<Bool> {
        Binding(
            get: { memory.glowFromPercent },
            set: { memory.setGlowFromPercent($0) }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                UserDefaults.standard.set(wants, forKey: NotchViewModel.saveClipboardImagesKey)
            }
        )
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func glowStepper(
        symbol: String,
        tint: Color,
        title: String,
        value: Int,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            HStack(spacing: 6) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surfaceHover))
                }
                .buttonStyle(.plain)
                Text("\(value)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 36)
                Button(action: increment) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surfaceHover))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(
        symbol: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - Idle Screen style + colour

/// Isolated from `SettingsPane` so colour edits cannot rebuild General/Modules.
private struct IdleScreenStyleSection: View {
    @ObservedObject private var settings = IdleScreenSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(IdleScreenSettings.Style.allCases) { style in
                    let selected = settings.style == style
                    Button {
                        settings.style = style
                    } label: {
                        Text(localized(style.titleKey))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(selected ? Color.black : Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? settings.color(for: style) : Theme.surfaceHover)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            colorSliders
        }
    }

    private var colorSliders: some View {
        let hsb = settings.hsb(for: settings.style)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localized("Color"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(settings.color(for: settings.style))
                    .frame(width: 22, height: 14)
                Text(settings.hex(for: settings.style))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            ColorStrip(
                value: hsb.hue,
                colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
                    Color(hue: $0, saturation: 0.9, brightness: 1)
                }
            ) { hue in
                settings.setHSB(
                    hue: hue,
                    saturation: max(hsb.saturation, 0.15),
                    brightness: max(hsb.brightness, 0.35),
                    for: settings.style
                )
            }
            ColorStrip(
                value: hsb.saturation,
                colors: [
                    Color(hue: hsb.hue, saturation: 0, brightness: max(hsb.brightness, 0.35)),
                    Color(hue: hsb.hue, saturation: 1, brightness: max(hsb.brightness, 0.35)),
                ]
            ) { saturation in
                settings.setHSB(
                    hue: hsb.hue,
                    saturation: saturation,
                    brightness: max(hsb.brightness, 0.35),
                    for: settings.style
                )
            }
        }
    }
}

/// A gradient strip with a knob, dragged anywhere along its length.
private struct ColorStrip: View {
    var value: Double
    var colors: [Color]
    var onChange: (Double) -> Void

    private let knob: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: min(max(value, 0), 1) * max(width - knob, 0))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let track = max(width - knob, 1)
                        onChange(min(max((drag.location.x - knob / 2) / track, 0), 1))
                    }
            )
        }
        .frame(height: knob)
    }
}
