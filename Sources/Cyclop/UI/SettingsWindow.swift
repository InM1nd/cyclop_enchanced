import AppKit
import SwiftUI

struct SettingsWindowRoot: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        SettingsPane(
            shelf: vm.shelf,
            sleepManager: vm.sleepManager,
            memory: vm.memory,
            usageProviders: vm.usageProviders,
            compact: false,
            onPreviewYellow: { vm.previewMemoryWarn() },
            onPreviewRed: { vm.previewMemoryCritical() },
            onPreviewMeeting: { vm.previewMeeting() }
        )
        .padding(16)
        .frame(minWidth: 380, minHeight: 520, alignment: .topLeading)
        .background(Color.black)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private var hosting: NSHostingView<SettingsWindowRoot>?
    private var didPlace = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("Settings")
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        self.init(window: window)
    }

    func present(vm: NotchViewModel) {
        let root = SettingsWindowRoot(vm: vm)
        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            hosting = view
            window?.contentView = view
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !didPlace {
            window?.center()
            didPlace = true
        }
    }
}
