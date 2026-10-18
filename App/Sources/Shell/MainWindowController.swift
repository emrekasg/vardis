import AppKit
import SwiftUI

/// The window is built once at launch and kept hidden, so opening it is just ordering it front.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let live: LiveModel
    private let nav: Navigation

    init(live: LiveModel, nav: Navigation, models: AppModels) {
        self.live = live
        self.nav = nav
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar makes the title bar 52 pt tall, so the traffic lights sit on the
        // centre line of the SwiftUI toolbar drawn under it.
        let toolbar = NSToolbar(identifier: "VardisMain")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VardisMain")
        window.minSize = NSSize(width: 1100, height: 720)
        window.contentView = NSHostingView(rootView: MainView().environment(live).environment(nav)
            .environment(models.claude).environment(models.cleanup).environment(models.history))
        window.delegate = self
        // Fast sampling follows the screen too, so leaving Now for a static screen slows the loop.
        withObservationTracking { _ = nav.screen } onChange: { [weak self] in Task { @MainActor in self?.observeScreen() } }
        if window.frame.origin == .zero { window.center() }
        // Lay out once offscreen so the first open does no layout work.
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func observeScreen() {
        updateSampling()
        withObservationTracking { _ = nav.screen } onChange: { [weak self] in Task { @MainActor in self?.observeScreen() } }
    }

    private var dropTree: Task<Void, Never>?

    func show(_ screen: Screen? = nil) {
        let started = ContinuousClock.now
        if let screen { nav.screen = screen }
        dropTree?.cancel()
        nav.windowOpen = true
        live.setPresenting("main", true)
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateSampling()
        if CommandLine.arguments.contains("--print-launch") {
            // Time to the end of the next run loop turn, which includes the first display of the window.
            DispatchQueue.main.async {
                FileHandle.standardError.write(Data(String(format: "window_open_ms=%.1f\n", (ContinuousClock.now - started).milliseconds).utf8))
            }
        }
    }

    var isVisible: Bool { window.isVisible && window.occlusionState.contains(.visible) }

    func updateSampling() {
        live.setPresenting("main", isVisible)
        live.isFast = isVisible && nav.screen.wantsFastSampling
    }

    /// `--snapshot <path> [--screen <rawValue>] [--palette <query>]` renders the window into a PNG and quits.
    /// `--screen settings [--pane <name>]` and `--screen onboarding [--step <n>]` render those windows instead.
    /// Used for README screenshots and visual checks without Screen Recording permission.
    func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        func arg(_ name: String) -> String? {
            guard let j = args.firstIndex(of: name), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        var target: NSWindow = window
        switch arg("--screen") {
        case "settings":
            let pane = arg("--pane").flatMap { p in SettingsPane.allCases.first { $0.rawValue == p || "\($0)" == p } } ?? .general
            target = auxSnapshotWindow(NSHostingView(rootView: SettingsView(initialPane: pane).environment(live)), size: NSSize(width: 900, height: 660))
        case "onboarding":
            let step = arg("--step").flatMap(Int.init) ?? 1
            target = auxSnapshotWindow(NSHostingView(rootView: OnboardingView(initialStep: step) {}), size: NSSize(width: 760, height: 560))
        case let raw?:
            if let s = Screen(rawValue: raw) { nav.screen = s }
            fallthrough
        default:
            show()
            if args.contains("--palette") { nav.paletteOpen = true }
        }
        let shot = target
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if args.contains("--hit-test") { self.printToolbarHitTest() }
            guard let view = shot.contentView else { return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Borrows the main window for an aux view, so it draws through the same path as the screens.
    private func auxSnapshotWindow(_ view: NSView, size: NSSize) -> NSWindow {
        // Never let a snapshot overwrite the saved main window frame.
        window.setFrameAutosaveName("")
        window.toolbar = nil
        window.minSize = size
        window.contentView = view
        window.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        show()
        return window
    }

    /// Prints which view receives a click on the toolbar search field, to check the title bar passes clicks through.
    private func printToolbarHitTest() {
        guard let frameView = window.contentView?.superview else { return }
        let p = NSPoint(x: window.frame.width - 100, y: window.frame.height - 26)
        let hit = frameView.hitTest(p)
        FileHandle.standardError.write(Data("toolbar_hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")\n".utf8))
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the view tree for two minutes so a quick reopen is instant; after that drop it,
        // so a closed window costs no layout, rendering or memory.
        dropTree?.cancel()
        dropTree = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120), tolerance: .seconds(10))
            guard let self, !Task.isCancelled, !self.window.isVisible else { return }
            self.nav.windowOpen = false
        }
        live.setPresenting("main", false)
        live.isFast = false
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateSampling() }
}
