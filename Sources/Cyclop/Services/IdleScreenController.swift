import AppKit
import SwiftUI
import QuartzCore

/// Gates whether the idle Canvas should keep ticking. Kept separate from the
/// window so open/close can freeze heavy drawing without tearing the host down.
@MainActor
final class IdleScreenSession: ObservableObject {
    /// When false, TimelineView stops and Canvas stays blank — open/close
    /// then only animates cheap window alpha.
    @Published private(set) var isLive = false

    func start() { isLive = true }
    func stop() { isLive = false }
}

/// Claims the whole screen so clicks never fall through to Finder while the
/// overlay is up. Dismisses only on a complete click that started here.
private final class IdleClickCatcher: NSView {
    var onDismiss: (() -> Void)?
    var armed = false
    private var downInside = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { armed }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downInside = armed
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if armed, downInside, bounds.contains(point) {
            onDismiss?()
        }
        downInside = false
    }
}

/// Fullscreen ASCII overlay that keeps the display awake.
@MainActor
final class IdleScreenController: NSObject {
    static let shared = IdleScreenController()

    /// Same curve and duration both ways — no spring vs easeIn mismatch.
    private static let fadeDuration: TimeInterval = 0.38

    private var window: NSWindow?
    private var catcher: IdleClickCatcher?
    private var displayCaffeinate: Process?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private let sessions = ProcessMonitorStore()
    private var session: IdleScreenSession?
    private var hideWork: DispatchWorkItem?
    private var isClosing = false

    private(set) var isActive = false

    private override init() {
        super.init()
    }

    func toggle() {
        isActive ? hide() : show()
    }

    /// Open after the current click finishes, so that mouse-up cannot punch
    /// through a half-built overlay onto the desktop.
    func show() {
        DispatchQueue.main.async { [weak self] in self?.present() }
    }

    private func present() {
        hideWork?.cancel()
        hideWork = nil
        if isActive, !isClosing { return }
        if isClosing { teardown() }
        isClosing = false
        isActive = true

        sessions.setActive(true)
        sessions.reload()

        let session = IdleScreenSession()
        self.session = session

        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.alphaValue = 0
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = false

        let catcher = IdleClickCatcher(frame: CGRect(origin: .zero, size: frame.size))
        catcher.autoresizingMask = [.width, .height]
        catcher.wantsLayer = true
        catcher.layer?.backgroundColor = NSColor.black.cgColor
        catcher.onDismiss = { [weak self] in self?.hide() }
        catcher.armed = false

        let hosting = NSHostingView(
            rootView: IdleScreenView(
                sessions: sessions,
                settings: IdleScreenSettings.shared,
                session: session
            )
        )
        hosting.frame = catcher.bounds
        hosting.autoresizingMask = [.width, .height]
        catcher.addSubview(hosting)

        window.contentView = catcher
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        self.catcher = catcher

        // Fade the black window first; start Canvas only when alpha is settled
        // so Portrait/Matrix never redraw mid-transition.
        animateAlpha(of: window, to: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { [weak self] in
            guard let self, self.isActive, !self.isClosing else { return }
            self.session?.start()
        }

        installEscMonitors()
        startDisplayCaffeinate()
        armClicksAfterOpeningGesture()
    }

    func hide() {
        hide(animated: true)
    }

    func hide(animated: Bool) {
        guard isActive else { return }
        if isClosing, animated { return }
        isClosing = true
        catcher?.armed = false
        hideWork?.cancel()
        removeEscMonitors()

        // Freeze Canvas first — Portrait/Matrix redraw during fade was the lag.
        session?.stop()

        guard animated, let window else {
            teardown()
            return
        }

        animateAlpha(of: window, to: 0)
        let work = DispatchWorkItem { [weak self] in
            self?.teardown()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration + 0.02, execute: work)
    }

    private func animateAlpha(of window: NSWindow, to value: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = value
        }
    }

    // MARK: - Click arming

    private func armClicksAfterOpeningGesture() {
        func arm() {
            guard isActive, !isClosing else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { arm() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.isActive, !self.isClosing else { return }
                self.catcher?.armed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { arm() }
    }

    private func installEscMonitors() {
        removeEscMonitors()
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 { self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                handler(event)
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
        }
    }

    private func removeEscMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func teardown() {
        hideWork = nil
        removeEscMonitors()
        window?.orderOut(nil)
        window = nil
        catcher = nil
        session = nil
        sessions.setActive(false)
        stopDisplayCaffeinate()
        isActive = false
        isClosing = false
    }

    // MARK: - Display awake

    /// Separate from Settings' lid-closed `caffeinate -s`: this one only
    /// covers the display for as long as the idle screen is up.
    private func startDisplayCaffeinate() {
        stopDisplayCaffeinate()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d display, -i idle sleep. Lid-closed system sleep stays on SleepManager.
        task.arguments = ["-di"]
        do {
            try task.run()
            displayCaffeinate = task
        } catch {
            NSLog("Cyclop: idle screen caffeinate failed: \(error.localizedDescription)")
        }
    }

    private func stopDisplayCaffeinate() {
        guard let task = displayCaffeinate else { return }
        if task.isRunning { task.terminate() }
        displayCaffeinate = nil
    }
}
