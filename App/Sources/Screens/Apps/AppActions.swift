import AppKit
import Darwin
import VardisCore

/// Quit, force quit, restart and reveal. Every action that ends a process asks first;
/// Vardis never ends a process on its own.
@MainActor
enum AppActions {
    static func reveal(_ app: AppSample, executable: String?) {
        if let url = app.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let executable, !executable.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: executable)])
        }
    }

    static func confirm(_ title: String, _ detail: String, button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = destructive ? .critical : .warning
        let ok = alert.addButton(withTitle: button)
        ok.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks, then asks the app to quit (it may ask to save). Processes outside LaunchServices get SIGTERM.
    static func quit(_ app: AppSample) {
        guard confirm("Quit \(app.name)?", "\(app.name) may ask you to save changes.", button: "Quit") else { return }
        signal(app, force: false)
    }

    /// Always asks; unsaved work is lost.
    static func forceQuit(_ app: AppSample) {
        guard confirm("Force quit \(app.name)?", "Unsaved changes in \(app.name) will be lost.", button: "Force Quit", destructive: true) else { return }
        signal(app, force: true)
    }

    /// Asks, quits, waits for every process of the app to exit, then opens it again.
    static func restart(_ app: AppSample) {
        guard let url = app.bundleURL else { return }
        guard confirm("Restart \(app.name)?", "\(app.name) quits (it may ask you to save changes) and opens again once it has exited.", button: "Restart") else { return }
        let running = runningApps(app)
        for r in running { r.terminate() }
        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(30)
            while running.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard running.allSatisfy(\.isTerminated) else {
                let alert = NSAlert()
                alert.messageText = "\(app.name) did not quit"
                alert.informativeText = "It may be waiting for you to save or confirm. Vardis did not reopen it."
                alert.runModal()
                return
            }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func runningApps(_ app: AppSample) -> [NSRunningApplication] {
        app.processIDs.compactMap { NSRunningApplication(processIdentifier: $0) }
    }

    private static func signal(_ app: AppSample, force: Bool) {
        let me = getpid()
        for pid in app.processIDs where pid != me && pid > 1 {
            if let running = NSRunningApplication(processIdentifier: pid) {
                _ = force ? running.forceTerminate() : running.terminate()
            } else if app.bundleURL == nil {
                // Command-line tools: helpers of a bundled app quit with the app, so only tools get signals.
                kill(pid, force ? SIGKILL : SIGTERM)
            }
        }
    }
}
