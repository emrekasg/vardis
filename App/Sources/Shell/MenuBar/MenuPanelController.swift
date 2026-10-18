import AppKit
import SwiftUI
import VardisCore

/// Tab and visibility of the panel, shared with its SwiftUI content.
@MainActor
@Observable
final class MenuPanelState {
    var tab: MenuTab = MenuBarPrefs.shared.enabledTabs.first ?? .overview {
        didSet {
            guard tab != oldValue else { return }
            let tabs = MenuBarPrefs.shared.enabledTabs
            forward = (tabs.firstIndex(of: tab) ?? 0) >= (tabs.firstIndex(of: oldValue) ?? 0)
        }
    }
    /// Direction of the last tab change, for the slide.
    private(set) var forward = true
    var isOpen = false
}

/// Borderless, non-activating panel: takes keys (Esc) without pulling Vardis to the front.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the panel under the status item. Content is built on first open, kept while open and for
/// two minutes after, then dropped so a closed panel costs no memory, layout or rendering.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 372
    static let cornerRadius: CGFloat = 18
    /// `--panel-theme light|dark` for snapshot runs; never stored.
    static let snapshotTheme: PanelTheme? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--panel-theme"), i + 1 < a.count else { return nil }
        return PanelTheme(rawValue: a[i + 1])
    }()

    var anchor: () -> NSStatusBarButton? = { nil }
    let state = MenuPanelState()

    private let live: LiveModel
    private let models: AppModels
    private let openWindow: (Screen?) -> Void
    private let openSettings: () -> Void
    private let restoreSampling: () -> Void

    private var panel: MenuPanel?
    private var container: NSView?
    private var host: NSView?
    private var monitors: [Any] = []
    private var appSwitchObserver: NSObjectProtocol?
    private var dropTask: Task<Void, Never>?
    private var closedAt: TimeInterval = 0
    private var contentHeight: CGFloat = 0
    private(set) var lastOpenTiming: (build: Double, draw: Double, total: Double)?

    var isOpen: Bool { panel?.isVisible ?? false }

    init(live: LiveModel, models: AppModels, openWindow: @escaping (Screen?) -> Void, openSettings: @escaping () -> Void, restoreSampling: @escaping () -> Void) {
        self.live = live
        self.models = models
        self.openWindow = openWindow
        self.openSettings = openSettings
        self.restoreSampling = restoreSampling
        super.init()
        observeTheme()
        observeTab()
    }

    func toggle(clickedAt: TimeInterval?) {
        if isOpen { close(); return }
        // A click on the item that also closed the panel (outside-click monitor) must not reopen it.
        guard ProcessInfo.processInfo.systemUptime - closedAt > 0.2 else { return }
        open(clickedAt: clickedAt)
    }

    // MARK: Open / close

    func open(clickedAt: TimeInterval? = nil) {
        let t0 = clickedAt ?? ProcessInfo.processInfo.systemUptime
        dropTask?.cancel()
        dropTask = nil
        live.setPresenting("menubar", true)
        live.isFast = true
        let built = ProcessInfo.processInfo.systemUptime
        let p = panel ?? makePanel()
        if host == nil { buildContent(in: p) }
        // Every open starts on the first tab (Overview unless the user reordered them).
        if !CommandLine.arguments.contains("--tab") { state.tab = MenuBarPrefs.shared.enabledTabs.first ?? .overview }
        state.isOpen = true
        updateClaudePresence()
        applyTheme()
        let tBuild = ProcessInfo.processInfo.systemUptime
        if let host, host.intrinsicContentSize.height > 0 { contentHeight = host.intrinsicContentSize.height }
        position(p)
        p.orderFrontRegardless()
        p.makeKey()
        anchor()?.highlight(true)
        installMonitors()
        p.displayIfNeeded()
        let tDraw = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            let total = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            let timing = (build: (tBuild - built) * 1000, draw: (tDraw - built) * 1000, total: total)
            self?.lastOpenTiming = timing
            StatusBarController.log.info("panel open: build \(timing.build, format: .fixed(precision: 1)) ms, first draw \(timing.draw, format: .fixed(precision: 1)) ms, click to frame \(timing.total, format: .fixed(precision: 1)) ms")
            if CommandLine.arguments.contains("--print-launch") || CommandLine.arguments.contains("--menubar-open-test") {
                FileHandle.standardError.write(Data(String(format: "menubar_open_ms build=%.1f draw=%.1f total=%.1f\n", timing.build, timing.draw, total).utf8))
            }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        closedAt = ProcessInfo.processInfo.systemUptime
        removeMonitors()
        panel.orderOut(nil)
        anchor()?.highlight(false)
        state.isOpen = false
        updateClaudePresence()
        live.setPresenting("menubar", false)
        restoreSampling()
        scheduleDrop()
    }

    /// Builds and lays out the content without showing it (the pointer is on the status item).
    /// Dropped again two minutes later if the panel never opens.
    func prepare() {
        guard host == nil, !isOpen else { return }
        let p = panel ?? makePanel()
        buildContent(in: p)
        applyTheme()
        if let host {
            contentHeight = max(host.intrinsicContentSize.height, 120)
            position(p)
            // Draw once, invisibly, so the window backing and the first raster exist before the click.
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.displayIfNeeded()
            p.orderOut(nil)
            p.alphaValue = 1
        }
        scheduleDrop()
    }

    private func scheduleDrop() {
        dropTask?.cancel()
        dropTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120), tolerance: .seconds(10))
            guard let self, !Task.isCancelled, !self.isOpen else { return }
            self.host?.removeFromSuperview()
            self.host = nil
        }
    }

    // MARK: Building

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.delegate = self
        p.onCancel = { [weak self] in self?.close() }

        // Opaque on purpose: text and charts must never sit on a busy desktop behind the panel.
        let c = NSView(frame: p.contentRect(forFrameRect: p.frame))
        c.autoresizingMask = [.width, .height]
        c.wantsLayer = true
        c.layer?.cornerRadius = Self.cornerRadius
        c.layer?.cornerCurve = .continuous
        c.layer?.masksToBounds = true
        c.layer?.borderWidth = 1
        p.contentView = c
        container = c
        panel = p
        return p
    }

    private func buildContent(in p: MenuPanel) {
        let root = MenuPanelView(
            state: state,
            open: { [weak self] screen in self?.close(); self?.openWindow(screen) },
            settings: { [weak self] in self?.close(); SettingsView.request(.menuBar); self?.openSettings() },
            onHeight: { [weak self] h in self?.heightChanged(h) })
            .environment(live)
            .environment(models.claude)
            .environment(models.cleanup)
            .environment(models.history)
        let h = NSHostingView(rootView: root)
        h.appearance = panel?.appearance
        // Intrinsic size only: the panel follows the content's height; the hosting view never resizes the window itself.
        h.sizingOptions = [.intrinsicContentSize]
        h.frame = p.contentView?.bounds ?? .zero
        h.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(h)
        host = h
        applyTheme()
    }

    private func heightChanged(_ h: CGFloat) {
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        guard let panel, panel.isVisible else { return }
        var f = panel.frame
        let top = f.maxY
        f.size.height = ceil(h)
        f.origin.y = top - f.size.height
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    private func position(_ p: NSPanel) {
        let height = ceil(max(contentHeight, 120))
        guard let button = anchor(), let w = button.window else {
            // No status item (snapshot runs): top right of the main screen.
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            p.setFrame(NSRect(x: vf.maxX - Self.width - 12, y: vf.maxY - height - 6, width: Self.width, height: height), display: false)
            return
        }
        let r = w.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = w.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? r
        var x = r.midX - Self.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - Self.width - 8)
        p.setFrame(NSRect(x: x, y: r.minY - 6 - height, width: Self.width, height: height), display: false)
        p.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        // Snapshot runs render the panel while other apps take focus; keep it open for them.
        guard !CommandLine.arguments.contains("--menubar-snapshot") else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Clicks on the status item toggle through its action; clicks inside the panel are its own.
                if event.window !== self.panel && event.window !== self.anchor()?.window { self.close() }
            }
            return event
        }) { monitors.append(m) }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
    }

    // MARK: Observation

    /// Light or dark as the user chose, else whatever the menu bar itself is drawn in right now
    /// (the menu bar follows the wallpaper and system setting, not Vardis's own Appearance).
    private func applyTheme() {
        let appearance: NSAppearance = switch Self.snapshotTheme ?? MenuBarPrefs.shared.theme {
        case .light: NSAppearance(named: .aqua)!
        case .dark: NSAppearance(named: .darkAqua)!
        case .system:
            NSAppearance(named: anchor()?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .darkAqua : .aqua)!
        }
        if panel?.appearance?.name != appearance.name {
            panel?.appearance = appearance
            host?.appearance = appearance
        }
        appearance.performAsCurrentDrawingAppearance {
            container?.layer?.backgroundColor = PanelColor.background.cgColor
            container?.layer?.borderColor = PanelColor.border.cgColor
        }
    }

    private func observeTheme() {
        withObservationTracking { _ = MenuBarPrefs.shared.theme } onChange: { [weak self] in
            Task { @MainActor in self?.applyTheme(); self?.observeTheme() }
        }
    }

    private func observeTab() {
        withObservationTracking { _ = state.tab } onChange: { [weak self] in
            Task { @MainActor in self?.updateClaudePresence(); self?.observeTab() }
        }
    }

    /// Claude's live session scan runs only while its tab is on screen.
    private func updateClaudePresence() {
        models.claude.setPresenting("menubar", state.isOpen && state.tab == .claude)
    }
}

// MARK: - Snapshot and timing runs

extension MenuPanelController {
    /// `--menubar-snapshot <png> [--tab <name>]`: opens the panel, renders it into a PNG and quits.
    func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--menubar-snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        if let j = args.firstIndex(of: "--tab"), j + 1 < args.count, args[j + 1] == "settings" {
            snapshotSettingsPane(to: path)
            return
        }
        if let j = args.firstIndex(of: "--tab"), j + 1 < args.count,
           let tab = MenuTab.allCases.first(where: { $0.rawValue.lowercased() == args[j + 1].lowercased() || $0.title.lowercased() == args[j + 1].lowercased() }) {
            state.tab = tab
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            self.open()
            try? await Task.sleep(for: .seconds(3))
            guard let panel = self.panel, let view = self.host else { return }
            let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            Self.writeSnapshot(rep, size: view.bounds.size, dark: dark, to: path)
            NSApp.terminate(nil)
        }
    }

    /// `--tab settings`: the Settings › Menu Bar pane on its own (the pane scrolls inside Settings, which a view snapshot cannot capture).
    private func snapshotSettingsPane(to path: String) {
        let view = NSHostingView(rootView: MenuBarPaneSnapshot().environment(live))
        let size = view.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Composites the content over the panel's own opaque background, clipped to its rounded shape.
    /// `--backdrop`: also places it on a dark, busy-ish desktop with the window shadow, to judge contrast.
    private static func writeSnapshot(_ content: NSBitmapImageRep, size: NSSize, dark: Bool, to path: String) {
        let backdrop = CommandLine.arguments.contains("--backdrop")
        let margin: CGFloat = backdrop ? 48 : 0
        let full = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let scale = CGFloat(content.pixelsWide) / max(1, size.width)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(full.width * scale), pixelsHigh: Int(full.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = full
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        if backdrop {
            NSGradient(colors: [NSColor(hex: 0x1B2A44), NSColor(hex: 0x16181D), NSColor(hex: 0x2B2233)])?.draw(in: NSRect(origin: .zero, size: full), angle: -60)
            // A few terminal-like lines, so low-contrast text would show.
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
            for i in 0..<Int(full.height / 22) {
                NSAttributedString(string: "$ git status && xcodebuild -scheme Vardis build   # line \(i)", attributes: attrs).draw(at: NSPoint(x: 8, y: CGFloat(i) * 22 + 4))
            }
        }
        let rect = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        if backdrop {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (dark ? NSColor(hex: 0x1C1C1E) : NSColor(hex: 0xF2F2F4)).setFill()
        rect.fill()
        content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `--menubar-open-test`: opens and closes the panel five times, printing each open's timing, then quits.
    func runOpenTest() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // `--hover`: the pointer reaches the item 300 ms before the click, as it does for a person.
            for _ in 0..<5 {
                if CommandLine.arguments.contains("--hover") {
                    self.prepare()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                self.open()
                try? await Task.sleep(for: .seconds(1))
                self.close()
                try? await Task.sleep(for: .milliseconds(400))
            }
            NSApp.terminate(nil)
        }
    }
}
