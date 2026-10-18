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

    func show(_ screen: Screen? = nil) {
        if let screen { nav.screen = screen }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateSampling()
    }

    var isVisible: Bool { window.isVisible && window.occlusionState.contains(.visible) }

    func updateSampling() {
        live.setPresenting("main", isVisible)
        live.isFast = isVisible && nav.screen.wantsFastSampling
    }

    /// `--snapshot <path> [--screen <rawValue>]` renders the window into a PNG and quits.
    /// Used for README screenshots and visual checks without Screen Recording permission.
    func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        if let j = args.firstIndex(of: "--screen"), j + 1 < args.count, let s = Screen(rawValue: args[j + 1]) { nav.screen = s }
        show()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        live.setPresenting("main", false)
        live.isFast = false
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateSampling() }
}
