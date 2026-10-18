import AppKit
import VardisCore
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let live = LiveModel()
    private let nav = Navigation()
    private let models = AppModels()
    private var windowController: MainWindowController?
    private var statusBar: StatusBarController?
    private var aux: AuxWindows?
    private var hotKey: GlobalHotKey?
    private var lastStatusTitles = ""
    static let signposter = OSSignposter(subsystem: "app.vardis", category: "launch")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = Self.signposter.beginInterval("launch")
        Pref.registerDefaults()
        Appearance.apply(UserDefaults.standard.string(forKey: Pref.appearance) ?? "light")
        // Status items first: they are what the user sees at launch. The main window is built on the
        // next run loop turn (or synchronously on the first open, if that comes sooner).
        aux = AuxWindows(live: live)
        statusBar = StatusBarController(live: live) { [weak self] screen in self?.mainWindow().show(screen) }
        live.onEveryTick { [weak self] s in
            // Redrawing a status item costs more than the sample behind it; skip ticks that change nothing visible.
            guard let self else { return }
            let titles = Fmt.percent(s.cpu.total) + "|" + Fmt.bytes(s.memory.used)
            guard titles != self.lastStatusTitles else { return }
            self.lastStatusTitles = titles
            self.statusBar?.update(s)
        }
        live.start()
        models.start(live: live)
        hotKey = GlobalHotKey { [weak self] in self?.mainWindow().show() }
        NotificationCenter.default.addObserver(forName: .vardisShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.aux?.showOnboarding { [weak self] in self?.mainWindow().show(.now) } }
        }
        Self.signposter.endInterval("launch", state)
        LaunchTiming.finished()
        if CommandLine.arguments.contains("--print-launch") { FileHandle.standardError.write(Data(String(format: "launch_ms=%.1f\n", LaunchTiming.milliseconds ?? -1).utf8)) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.mainMenu = self.makeMenu()
            let wc = self.mainWindow()
            if CommandLine.arguments.contains("--snapshot") {
                wc.snapshotIfRequested()
            } else if !UserDefaults.standard.bool(forKey: Pref.onboardingDone) {
                self.aux?.showOnboarding { [weak self] in self?.mainWindow().show(.now) }
            } else if CommandLine.arguments.contains("--show") {
                wc.show()
            }
        }
    }

    /// The main window, built once. Normally prebuilt right after launch so opening it only orders it front.
    private func mainWindow() -> MainWindowController {
        if let windowController { return windowController }
        let state = Self.signposter.beginInterval("build window")
        let wc = MainWindowController(live: live, nav: nav, models: models)
        Self.signposter.endInterval("build window", state)
        windowController = wc
        return wc
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow().show()
        return true
    }

    @objc func openSettings(_ sender: Any?) { aux?.showSettings() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Vardis", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Vardis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Vardis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        return main
    }
}

/// Time from process start to the end of applicationDidFinishLaunching, shown in Settings › Performance.
enum LaunchTiming {
    @MainActor static private(set) var milliseconds: Double?

    @MainActor static func finished() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        milliseconds = (Date().timeIntervalSince1970 - startSeconds) * 1000
    }
}

/// Feature models, created at launch. Each starts its own background work off the main thread.
@MainActor
final class AppModels {
    let claude = ClaudeModel()
    let cleanup = CleanupModel()
    let history = HistoryModel()

    func start(live: LiveModel) {
        // VARDIS_DISABLE=claude,cleanup,history turns models off, for measuring what each one costs.
        let off = Set((ProcessInfo.processInfo.environment["VARDIS_DISABLE"] ?? "").split(separator: ",").map(String.init))
        if !off.contains("claude") {
            claude.start()
            ClaudeStatusItem.install(model: claude)
        }
        if !off.contains("cleanup") { cleanup.start() }
        if !off.contains("history") { history.start(live: live) }
    }
}
