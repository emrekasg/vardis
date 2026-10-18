import AppKit
import SwiftUI
import VardisClaude
import VardisCore

struct ClaudeAccountsView: View {
    @Environment(ClaudeModel.self) private var claude
    @State private var adding = false
    @State private var confirmShell = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    accountTable
                    if claude.supportsSwitching {
                        Button("Add account\u{2026}") { adding = true }.buttonStyle(SecondaryButtonStyle())
                        shellSetup
                        history
                    } else {
                        storeNote
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 30)
            }
            .frame(maxWidth: .infinity)
            if claude.supportsSwitching {
                Rectangle().fill(Theme.separator).frame(width: 1)
                RulesPanel().frame(width: 380)
            }
        }
        .background(Theme.window)
        .claudePresence("claude.accounts")
        .onAppear { claude.reloadAccounts() }
        .sheet(isPresented: $adding) { AddAccountSheet { adding = false } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(claude.activeAccount.map { "\($0.name) is active" } ?? "Accounts").font(.largeTitleV).foregroundStyle(Theme.text)
            Text(explanation).font(.bodyV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        guard claude.supportsSwitching else {
            return "Usage for each Claude Code folder Vardis can read. Plan limits and switching need the direct download from vardis.app."
        }
        let rules = ClaudeModel.Rules.current
        guard rules.enabled, let active = claude.activeAccount else {
            return "New sessions start on the active account. Sessions already running finish on the account they started with."
        }
        let next = claude.nextAccount(rules: rules)?.name ?? "the next account with room"
        return "When it reaches \(Int(rules.fiveHour))% of its 5-hour window, Vardis moves new sessions to \(next). Sessions already running finish on the account they started with."
            .replacingOccurrences(of: "When it", with: "When \(active.name)")
    }

    private var accountTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Order").frame(maxWidth: .infinity, alignment: .leading)
                if claude.supportsQuota {
                    Text("5-hour window").frame(width: 190, alignment: .leading)
                    Text("Weekly").frame(width: 190, alignment: .leading)
                } else {
                    Text("This month").frame(width: 190, alignment: .trailing)
                }
            }
            .font(.captionStrongV).foregroundStyle(Theme.textTertiary).padding(.leading, 36).padding(.bottom, 8)
            Hairline()
            if claude.accounts.isEmpty {
                Text("No Claude Code folders found yet.").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 14)
            }
            ForEach(Array(claude.accounts.enumerated()), id: \.element.id) { i, a in
                AccountRow(account: a, isFirst: i == 0, isLast: i == claude.accounts.count - 1)
                Hairline()
            }
        }
    }

    private var storeNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.accent)
            Text("This edition reads usage from your session files only. Plan limits, adding accounts and switching between them need the direct download from vardis.app.")
                .font(.calloutV).foregroundStyle(Theme.text)
        }
        .padding(14)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var shellSetup: some View {
        let kind = claude.shellKind
        let file = ClaudeAccounts.startupFile(kind)
        let line = ClaudeAccounts.pathLine(kind)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Set up switching")
                Spacer()
                switch claude.shellState {
                case .active: Badge("Working", tone: .green)
                case .lineAddedNotFirst: Badge("Another claude comes first", tone: .orange)
                case .claudeMissing: Badge("Claude Code not found", tone: .orange)
                case .notSetUp: Badge("Not set up")
                case .unknown: EmptyView()
                }
            }
            switch claude.shellState {
            case .active:
                Text("New `claude` commands in any \(kind.rawValue) window start on the active account. Running sessions keep theirs.")
                    .font(.calloutV).foregroundStyle(Theme.textSecondary)
            case .claudeMissing:
                Text("Vardis could not find the Claude Code command for this user. Install Claude Code, then come back here.")
                    .font(.calloutV).foregroundStyle(Theme.textSecondary)
            default:
                Text(claude.shellState == .lineAddedNotFirst
                     ? "\(ClaudeModel.tildePath(file.path)) has the line, but a new \(kind.rawValue) still finds another `claude` first. Move the line to the end of the file."
                     : "Vardis puts a small `claude` launcher in ~/.vardis/bin that starts Claude Code with the active account. Put it first on your PATH once:")
                    .font(.calloutV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if claude.shellState == .notSetUp {
                        Button("Add to \(ClaudeModel.tildePath(file.path))\u{2026}") { confirmShell = true }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.separator))
                Text("Open terminals pick it up after a restart.").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
        }
        .task { await claude.checkShell() }
        .confirmationDialog("Add one line to \(file.path)?", isPresented: $confirmShell) {
            Button("Add line") { Task { await claude.appendShellSetup() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Vardis appends \(line) to the end of \(file.path). Nothing else in the file changes.")
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Switch history", trailing: "\(claude.switchLog.count) \(claude.switchLog.count == 1 ? "switch" : "switches")").padding(.bottom, 8)
            Hairline()
            if claude.switchLog.isEmpty {
                Text("No switches yet").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 12)
            }
            ForEach(claude.switchLog.prefix(12)) { e in
                HStack(spacing: 12) {
                    Text(ClaudeFmt.when(e.time)).font(.calloutV).foregroundStyle(Theme.textTertiary).frame(width: 110, alignment: .leading)
                    Text(e.from).font(.headlineV).foregroundStyle(Theme.text)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    Text(e.to).font(.headlineV).foregroundStyle(Theme.text)
                    Text(e.reason).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 10)
                Hairline()
            }
        }
    }
}

private struct AccountRow: View {
    let account: ClaudeAccount
    let isFirst: Bool
    let isLast: Bool
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        let q = claude.quota(account)
        let problem = claude.quotas[account.id]?.problem
        HStack(spacing: 12) {
            if claude.supportsSwitching {
                VStack(spacing: 0) {
                    Button { claude.move(account, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(isFirst)
                    Button { claude.move(account, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(isLast)
                }
                .buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 14)
            }
            Circle().fill(color).frame(width: 30, height: 30)
                .overlay(Text(String(account.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.window))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name).font(.headlineV).foregroundStyle(Theme.text)
                    badge
                }
                Text(([account.plan, account.source] as [String?]).compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if claude.supportsSwitching, account.id != claude.activeHomeID, account.isSignedIn {
                Button("Use for new sessions") { claude.makeActive(account, reason: "Chosen by you") }
                    .buttonStyle(.plain).font(.captionV).foregroundStyle(Theme.accent)
            }
            if claude.supportsQuota {
                Group {
                    if let q {
                        QuotaMeterView(window: q.fiveHour)
                        QuotaMeterView(window: q.sevenDay, color: Theme.textSecondary)
                    } else {
                        Text(problem ?? (account.isSignedIn ? "Checking\u{2026}" : "Not signed in")).font(.captionV).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                    }
                }
                .frame(width: 190)
            } else {
                let usage = claude.monthHomes.first { $0.home == account.id }
                Text(usage.map { "\(ClaudeFmt.tokens($0.tokens.total)) tokens \u{00B7} \(ClaudeFmt.usd($0.costUSD))" } ?? "No usage")
                    .font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: 190, alignment: .trailing)
            }
        }
        .padding(.vertical, 12)
    }

    private var color: Color {
        let palette = [Theme.claude, Theme.accent, Theme.green, Theme.Metric.network, Theme.orange, Theme.Metric.disk]
        let i = abs(account.id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palette.count
        return account.home.isDefault ? Theme.claude : palette[i]
    }

    @ViewBuilder private var badge: some View {
        if account.id == claude.activeHomeID {
            Badge("Active", tone: .blue)
        } else if !account.isSignedIn {
            Badge("Signed out")
        } else if let u = claude.quota(account)?.fiveHour, u.utilization >= 100 {
            Badge("Paused until \(ClaudeFmt.reset(u.resetsAt))", tone: .orange)
        } else if claude.nextAccount()?.id == account.id {
            Badge("Next")
        }
    }
}

private struct RulesPanel: View {
    @Environment(ClaudeModel.self) private var claude
    @AppStorage(Pref.autoSwitch) private var enabled = false
    @AppStorage(Pref.autoSwitchFiveHour) private var fiveHour = 90
    @AppStorage(Pref.autoSwitchWeekly) private var weekly = 95
    @AppStorage(ClaudePref.skipAbove) private var skipAbove = 80
    @AppStorage(ClaudePref.cooldownMinutes) private var cooldown = 10
    @AppStorage(Pref.alertSwitched) private var notify = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("Switch automatically", "Uses each account\u{2019}s own sign-in", $enabled)
                slider("Switch when the 5-hour window reaches", value: $fiveHour, range: 50...100, unit: "%")
                slider("\u{2026}or the weekly limit reaches", value: $weekly, range: 50...100, unit: "%")
                slider("Skip accounts already above", value: $skipAbove, range: 20...100, unit: "%", footer: skippedText)
                slider("Wait between switches at least", value: $cooldown, range: 0...60, unit: " min", footer: "Stops back-and-forth when two accounts are both close.")
                toggleRow("Notify me when an account switches", nil, $notify)
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .disabled(claude.accounts.count < 2)
            if claude.accounts.count < 2 {
                Text("Add a second account to switch between them.").font(.captionV).foregroundStyle(Theme.textTertiary).padding(.horizontal, 24)
            }
        }
        .background(Theme.surface)
    }

    private var skippedText: String? {
        let skipped = claude.skippedAccounts()
        guard let first = skipped.first else { return nil }
        return "\(first.0.name) is skipped right now. It is at \(Int(first.1))%."
    }

    private func toggleRow(_ title: String, _ detail: String?, _ b: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.bodyV).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.captionV).foregroundStyle(Theme.textTertiary) }
                }
                Spacer()
                Toggle("", isOn: b).toggleStyle(.switch).labelsHidden()
            }
            .padding(.vertical, 14)
            Hairline()
        }
    }

    private func slider(_ title: String, value: Binding<Int>, range: ClosedRange<Double>, unit: String, footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.bodyV).foregroundStyle(Theme.text)
                Spacer()
                Text("\(value.wrappedValue)\(unit)").font(.numeric).foregroundStyle(Theme.accent)
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }), in: range)
                .controlSize(.small)
            if let footer { Text(footer).font(.captionV).foregroundStyle(Theme.textTertiary) }
            Hairline().padding(.top, 6)
        }
        .padding(.top, 14)
    }
}
