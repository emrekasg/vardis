import Foundation
import VardisCore

/// Vardis-managed Claude Code accounts and account switching.
///
/// Each managed account is its own config dir, `~/.vardis/accounts/<name>`. Switching never touches another app's
/// keychain item: a PATH shim, `~/.vardis/bin/claude`, reads `~/.vardis/active-account` (the real path of the active
/// config dir, or `default`) and runs the real Claude Code with `CLAUDE_CONFIG_DIR` set to that path. Claude Code
/// names its keychain item after the config dir it sees, so each account keeps its own login, and the default
/// account keeps using `~/.claude` untouched. Running sessions already resolved their dir and keep it.
public enum ClaudeAccounts {
    public static var root: URL {
        URL(fileURLWithPath: ClaudeHome.realHomeDirectory, isDirectory: true).appendingPathComponent(Brand.dotFolderName, isDirectory: true)
    }
    public static var accountsDir: URL { root.appendingPathComponent("accounts", isDirectory: true) }
    public static var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public static var shimURL: URL { binDir.appendingPathComponent("claude") }
    public static var activeFile: URL { root.appendingPathComponent("active-account") }
    public static var realClaudeFile: URL { root.appendingPathComponent("claude-real") }

    // MARK: Active account file

    /// The active config dir, or nil for the stock `~/.claude` (empty file, `default`, or no file).
    public static func readActive(file: URL = activeFile) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty, line != "default", line.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: line, isDirectory: true).standardizedFileURL
    }

    /// Atomically rewrites the active-account file: a temporary file renamed over the old one.
    /// The default home is written as `default`, others as their real (symlink-resolved) path.
    public static func writeActive(_ home: ClaudeHome, file: URL = activeFile) throws {
        let line = home.isDefault ? "default" : home.url.resolvingSymlinksInPath().standardizedFileURL.path
        try atomicWrite(line + "\n", to: file, permissions: 0o644)
    }

    static func atomicWrite(_ text: String, to url: URL, permissions: Int) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: Shim

    /// The shim script. Reads both state files with the shell's `read` builtin (no subprocesses), so the overhead is
    /// one `sh` start. Prints nothing unless it cannot find Claude Code. Forwards every argument and the exit code.
    public static func shimScript(root: URL = root) -> String {
        let r = Shell.quote(root.path)
        let bin = Shell.quote(root.appendingPathComponent("bin").path)
        return """
        #!/bin/sh
        # Installed by Vardis. Runs Claude Code with the account chosen in Vardis (\(root.path)/active-account).
        vardis_root=\(r)
        vardis_bin=\(bin)
        real=
        IFS= read -r real 2>/dev/null <"$vardis_root/claude-real"
        if [ -z "$real" ] || [ ! -x "$real" ]; then
          real=
          old_ifs=$IFS
          IFS=:
          for d in $PATH; do
            [ "$d" = "$vardis_bin" ] && continue
            [ -n "$d" ] && [ -x "$d/claude" ] && { real="$d/claude"; break; }
          done
          IFS=$old_ifs
          if [ -z "$real" ]; then
            echo "claude: Claude Code not found (Vardis shim in $vardis_bin)" >&2
            exit 127
          fi
          printf '%s\n' "$real" 2>/dev/null >"$vardis_root/claude-real"
        fi
        acct=
        IFS= read -r acct 2>/dev/null <"$vardis_root/active-account"
        case "$acct" in
          ""|default) unset CLAUDE_CONFIG_DIR ;;
          *) CLAUDE_CONFIG_DIR=$acct; export CLAUDE_CONFIG_DIR ;;
        esac
        exec "$real" "$@"

        """
    }

    /// Writes the shim (if its content changed) and records the real `claude`. Returns the real binary, if found.
    @discardableResult
    public static func installShim() throws -> String? {
        let script = shimScript()
        if (try? String(contentsOf: shimURL, encoding: .utf8)) != script {
            try atomicWrite(script, to: shimURL, permissions: 0o755)
        }
        let recorded = (try? String(contentsOf: realClaudeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recorded, isRealClaude(recorded) { return recorded }
        guard let real = resolveRealClaude() else { return nil }
        try atomicWrite(real + "\n", to: realClaudeFile, permissions: 0o644)
        return real
    }

    static func isRealClaude(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix(binDir.path + "/") && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The real `claude` executable, never the shim: common install locations, then every `claude` the login shell knows.
    public static func resolveRealClaude() -> String? {
        let home = ClaudeHome.realHomeDirectory
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let c = candidates.first(where: isRealClaude) { return c }
        return loginShell(["-lic", "whence -ap claude 2>/dev/null || which -a claude"])
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: isRealClaude)
    }

    // MARK: Shell setup

    public enum ShellKind: String, Sendable { case zsh, bash, fish }

    public static var userShell: ShellKind {
        let path = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let name = (path as NSString).lastPathComponent
        return name == "bash" ? .bash : name == "fish" ? .fish : .zsh
    }

    public static func shellPath(_ kind: ShellKind) -> String {
        switch kind {
        case .zsh: "/bin/zsh"
        case .bash: "/bin/bash"
        case .fish: ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "fish"
        }
    }

    /// Startup file the PATH line goes into.
    public static func startupFile(_ kind: ShellKind) -> URL {
        let home = URL(fileURLWithPath: ClaudeHome.realHomeDirectory)
        switch kind {
        case .zsh: return home.appendingPathComponent(".zshrc")
        case .bash: return home.appendingPathComponent(".bash_profile")
        case .fish: return home.appendingPathComponent(".config/fish/config.fish")
        }
    }

    public static func pathLine(_ kind: ShellKind) -> String {
        switch kind {
        case .zsh, .bash: #"export PATH="$HOME/.vardis/bin:$PATH""#
        case .fish: #"fish_add_path --prepend --path $HOME/.vardis/bin"#
        }
    }

    public static func startupFileHasLine(_ kind: ShellKind) -> Bool {
        guard let text = try? String(contentsOf: startupFile(kind), encoding: .utf8) else { return false }
        return text.contains(".vardis/bin")
    }

    /// Appends the PATH line to the shell's startup file. Call only after the person confirmed, naming the file.
    public static func appendPathLine(_ kind: ShellKind) throws {
        let fm = FileManager.default
        let file = startupFile(kind)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o644]) }
        let h = try FileHandle(forWritingTo: file)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data("\n# Added by Vardis: `claude` uses the account chosen in Vardis\n\(pathLine(kind))\n".utf8))
    }

    /// True when a new login shell resolves `claude` to the shim. Starts a shell; call off the main thread.
    public static func shimIsFirstOnPath(_ kind: ShellKind = userShell) -> Bool {
        let out = loginShell(["-lic", "command -v claude"], shell: shellPath(kind))
        return out.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } == shimURL.path
    }

    static func loginShell(_ args: [String], shell: String = "/bin/zsh") -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell.hasPrefix("/") ? shell : "/usr/bin/env")
        p.arguments = shell.hasPrefix("/") ? args : [shell] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Every folder under `~/.vardis/accounts`, with or without transcripts yet.
    public static func managedHomes() -> [ClaudeHome] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: accountsDir.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            var isDir: ObjCBool = false
            let url = accountsDir.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return ClaudeHome(url: url, label: name)
        }
    }

    /// Valid account names: letters, digits, `-` and `_`, up to 32 characters.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    public static func createHome(named name: String) throws -> ClaudeHome {
        let url = accountsDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ClaudeHome(url: url, label: name)
    }

    /// `.claude.json` for a config dir: `~/.claude.json` for the default home, `<dir>/.claude.json` otherwise.
    static func globalConfig(for home: ClaudeHome) -> URL {
        if home.isDefault { return URL(fileURLWithPath: ClaudeHome.realHomeDirectory).appendingPathComponent(".claude.json") }
        return home.url.appendingPathComponent(".claude.json")
    }

    /// Plan name from the signed-in account's tier ("Max 20×", "Pro"), read from Claude Code's own config.
    /// Only tier fields are read; no names or emails.
    public static func plan(for home: ClaudeHome) -> String? {
        guard let o = oauthAccount(home) else { return nil }
        let tier = ((o["organizationRateLimitTier"] as? String) ?? (o["userRateLimitTier"] as? String) ?? "").lowercased()
        let type = ((o["organizationType"] as? String) ?? "").lowercased()
        if tier.contains("max_20x") || tier.contains("20x") { return "Max 20\u{00D7}" }
        if tier.contains("max_5x") || tier.contains("5x") { return "Max 5\u{00D7}" }
        if type.contains("max") { return "Max" }
        if type.contains("pro") || tier.contains("pro") { return "Pro" }
        if type.contains("team") { return "Team" }
        if type.contains("enterprise") { return "Enterprise" }
        return type.isEmpty ? nil : type.replacingOccurrences(of: "claude_", with: "").capitalized
    }

    /// Signed in: Claude Code recorded an OAuth account for this dir, or left a credentials file.
    public static func isSignedIn(_ home: ClaudeHome) -> Bool {
        if oauthAccount(home) != nil { return true }
        return FileManager.default.fileExists(atPath: home.url.appendingPathComponent(".credentials.json").path)
    }

    private static func oauthAccount(_ home: ClaudeHome) -> [String: Any]? {
        guard let data = try? Data(contentsOf: globalConfig(for: home)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["oauthAccount"] as? [String: Any]
    }
}
