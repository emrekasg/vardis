import AppKit
import Foundation

/// Opens a command in the person's terminal app. Vardis never runs `claude` itself.
enum TerminalLauncher {
    static let bundleIDs: [String: [String]] = [
        "Terminal": ["com.apple.Terminal"],
        "iTerm": ["com.googlecode.iterm2"],
        "Ghostty": ["com.mitchellh.ghostty"],
        "Warp": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
    ]

    static var preferred: String { UserDefaults.standard.string(forKey: Pref.claudeTerminal) ?? "Terminal" }

    static func appURL(_ name: String) -> URL? {
        for id in bundleIDs[name] ?? [] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// Writes a self-deleting `.command` script to the caches folder and opens it with the chosen terminal.
    /// The script runs in an interactive login shell so `claude` is on PATH, and leaves the shell open afterwards.
    @discardableResult
    static func run(_ command: String, in app: String = preferred) -> Bool {
        guard let appURL = appURL(app) ?? appURL("Terminal") else { return false }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Vardis", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let script = caches.appending(path: "resume-\(UUID().uuidString.prefix(8)).command")
        let body = """
        #!/bin/zsh -il
        rm -f -- "$0"
        clear
        \(command)
        exec /bin/zsh -il

        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: config) { _, _ in }
        return true
    }
}
