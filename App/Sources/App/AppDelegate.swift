import AppKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let live = LiveModel()
    private let nav = Navigation()
    private var windowController: MainWindowController?
    private var statusBar: StatusBarController?
    private var aux: AuxWindows?
    private var hotKey: GlobalHotKey?
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
        let wc = MainWindowController(live: live, nav: nav)
        windowController = wc
        aux = AuxWindows(live: live)
        statusBar = StatusBarController(live: live) { [weak wc] screen in wc?.show(screen) }
        live.onTick = { [weak self] s in self?.statusBar?.update(s) }
        live.start()
        hotKey = GlobalHotKey { [weak wc] in wc?.show() }
        NSApp.mainMenu = makeMenu()
        NotificationCenter.default.addObserver(forName: .vardisShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.aux?.showOnboarding { [weak wc] in wc?.show(.now) } }
        }
        Self.signposter.endInterval("launch", state)
        LaunchTiming.finished()
        if CommandLine.arguments.contains("--print-launch") { FileHandle.standardError.write(Data(String(format: "launch_ms=%.1f\n", LaunchTiming.milliseconds ?? -1).utf8)) }

        if CommandLine.arguments.contains("--snapshot") {
            wc.snapshotIfRequested()
        } else if !UserDefaults.standard.bool(forKey: Pref.onboardingDone) {
            aux?.showOnboarding { [weak wc] in wc?.show(.now) }
        } else if CommandLine.arguments.contains("--show") {
            wc.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
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
