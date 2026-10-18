import AppKit
import Observation
import SwiftUI
import VardisClaude
import VardisCore

/// Runs the official `claude auth login` for a new Vardis-managed config dir and reports its progress.
/// Success is the sign-in appearing for that dir, not anything the CLI prints.
@MainActor
@Observable
final class LoginRunner {
    enum Step: Int, Comparable {
        case idle, starting, browser, waiting, done, failed
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var step: Step = .idle
    private(set) var problem: String?
    /// The sign-in page, when the CLI printed one (to reopen it if the browser did not open).
    private(set) var signInURL: URL?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private(set) var home: ClaudeHome?

    func start(name: String) {
        guard step == .idle || step == .failed else { return }
        problem = nil
        signInURL = nil
        guard ClaudeAccounts.isValidName(name) else { fail("Use letters, digits, - or _."); return }
        guard !FileManager.default.fileExists(atPath: ClaudeAccounts.accountsDir.appendingPathComponent(name).path) else {
            fail("An account with that name exists."); return
        }
        step = .starting
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { LoginRunner.findClaude() }.value
            guard let self, self.step == .starting else { return }
            guard let found else { self.fail("Claude Code is not installed for this user (no `claude` found)."); return }
            self.launch(claudePath: found, name: name)
        }
    }

    private func launch(claudePath: String, name: String) {
        let home: ClaudeHome
        do { home = try ClaudeAccounts.createHome(named: name) } catch { fail("Could not create \(ClaudeAccounts.accountsDir.path)."); return }
        self.home = home

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["CLAUDE_CONFIG_DIR=\(home.url.path)", claudePath, "auth", "login"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ((claudePath as NSString).deletingLastPathComponent) + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            // Output is scanned for a sign-in link only; it is never stored or logged.
            let url = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
                .first { $0.hasPrefix("https://") }.flatMap { URL(string: String($0)) }
            Task { @MainActor in self?.sawOutput(url) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.finished(code) }
        }
        process = p
        do { try p.run() } catch { fail("Could not start Claude Code."); return }
        // The browser normally opens within a second or two of starting.
        poll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if let self, self.step == .starting { self.step = .browser }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let home = self.home else { return }
                if self.step == .browser { self.step = .waiting }
                if ClaudeAccounts.isSignedIn(home) { self.step = .done; return }
            }
        }
    }

    private func sawOutput(_ url: URL?) {
        if let url, url.host?.contains("claude") == true || url.host?.contains("anthropic") == true { signInURL = url }
        if step == .starting { step = .browser }
    }

    private func finished(_ code: Int32) {
        process = nil
        guard step != .done else { return }
        if let home, ClaudeAccounts.isSignedIn(home) { step = .done; poll?.cancel(); return }
        if step != .failed { fail(code == 0 ? "Sign-in did not finish." : "Claude Code stopped before sign-in finished.") }
    }

    private func fail(_ message: String) {
        poll?.cancel()
        problem = message
        step = .failed
    }

    /// Stops the CLI and removes the new folder if nothing was saved in it.
    func cancel() {
        poll?.cancel()
        process?.terminate()
        process = nil
        if step != .done, let home, ((try? FileManager.default.contentsOfDirectory(atPath: home.url.path)) ?? []).isEmpty {
            try? FileManager.default.removeItem(at: home.url)
        }
        step = .idle
    }

    /// The real `claude` executable (never Vardis's own shim).
    nonisolated static func findClaude() -> String? { ClaudeAccounts.resolveRealClaude() }
}

struct AddAccountSheet: View {
    let close: () -> Void
    @Environment(ClaudeModel.self) private var claude
    @State private var name = ""
    @State private var runner = LoginRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Claude account").font(.titleV).foregroundStyle(Theme.text)
                Text("Vardis runs Claude Code\u{2019}s own sign-in in a separate folder, so this account never touches your others.")
                    .font(.calloutV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                TextField("Name, for example Work", text: $name).textFieldStyle(.roundedBorder).disabled(runner.step > .idle && runner.step != .failed)
                    .onSubmit(begin)
                Text("~/.vardis/accounts/\(name.isEmpty ? "name" : name)").font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 10) {
                stepRow(.starting, "Start `claude auth login`")
                stepRow(.browser, "Browser opened \u{2014} sign in to the account you want to add")
                stepRow(.waiting, "Waiting for the sign-in to arrive")
                stepRow(.done, "Signed in")
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let url = runner.signInURL, runner.step < .done {
                Button("Open the sign-in page again") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.calloutV).foregroundStyle(Theme.accent)
            }
            if let p = runner.problem { Text(p).font(.calloutV).foregroundStyle(Theme.red) }
            HStack {
                Spacer()
                if runner.step == .done {
                    Button("Done") { claude.reloadAccounts(); Task { await claude.refreshQuotas() }; close() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Cancel") { runner.cancel(); close() }.buttonStyle(SecondaryButtonStyle())
                    Button("Sign in") { begin() }.buttonStyle(PrimaryButtonStyle())
                        .disabled(name.isEmpty || (runner.step > .idle && runner.step != .failed))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.window)
        .motion(Motion.quick, value: runner.step)
    }

    private func begin() {
        guard !name.isEmpty else { return }
        runner.start(name: name.trimmingCharacters(in: .whitespaces))
    }

    private func stepRow(_ step: LoginRunner.Step, _ text: String) -> some View {
        let current = runner.step
        let doneHere = current > step || current == .done
        let active = current == step && current != .done
        return HStack(spacing: 10) {
            ZStack {
                if doneHere {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 16)
            Text(LocalizedStringKey(text)).font(.bodyV).foregroundStyle(doneHere || active ? Theme.text : Theme.textTertiary)
        }
    }
}
