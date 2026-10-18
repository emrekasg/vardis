import AppKit
import SwiftUI
import VardisCore

/// Each readout is its own status item, like the system's own. Titles are patched in place on every tick.
@MainActor
final class StatusBarController {
    private let cpuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let memoryItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let live: LiveModel
    private let openWindow: (Screen?) -> Void
    private var popoverObserver: NSObjectProtocol?

    private static let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
    ]

    init(live: LiveModel, openWindow: @escaping (Screen?) -> Void) {
        self.live = live
        self.openWindow = openWindow
        for item in [cpuItem, memoryItem] {
            item.button?.target = self
            item.button?.action = #selector(toggle(_:))
            item.button?.imagePosition = .imageLeading
        }
        cpuItem.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")
        cpuItem.autosaveName = "vardis.cpu"
        memoryItem.autosaveName = "vardis.memory"
        popover.behavior = .transient
        popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak live] _ in
            MainActor.assumeIsolated { live?.setPresenting("popover", false) }
        }
        popover.animates = true
        update(nil)
        applyVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
    }

    private var lastCPU = "", lastMemory = ""
    private var defaultsObserver: NSObjectProtocol?

    /// Re-sets a title only when its text changed; redrawing the status bar is the main idle cost.
    func update(_ s: Snapshot?) {
        let cpu = " " + (s.map { Fmt.percent($0.cpu.total) } ?? "–")
        let mem = s.map { Fmt.bytes($0.memory.used).replacingOccurrences(of: " ", with: "") } ?? "–"
        if cpu != lastCPU { lastCPU = cpu; cpuItem.button?.attributedTitle = NSAttributedString(string: cpu, attributes: Self.numberAttributes) }
        if mem != lastMemory { lastMemory = mem; memoryItem.button?.attributedTitle = NSAttributedString(string: mem, attributes: Self.numberAttributes) }
    }

    private func applyVisibility() {
        let d = UserDefaults.standard
        if cpuItem.isVisible != d.bool(forKey: Pref.menuCPU) { cpuItem.isVisible = d.bool(forKey: Pref.menuCPU) }
        if memoryItem.isVisible != d.bool(forKey: Pref.menuMemory) { memoryItem.isVisible = d.bool(forKey: Pref.menuMemory) }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        // The popover's SwiftUI content is built on first use, not at launch.
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: MenuBarDropdown(open: { [weak self] screen in
                self?.popover.performClose(nil)
                self?.openWindow(screen)
            }).environment(live))
        }
        if popover.isShown { popover.performClose(nil) } else {
            live.setPresenting("popover", true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

struct MenuBarDropdown: View {
    let open: (Screen?) -> Void
    @Environment(LiveModel.self) private var live

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = live.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    row("CPU", Fmt.percent(s.cpu.total), s.cpu.total, Theme.Metric.cpu)
                    row("Memory", "\(Fmt.bytes(s.memory.used)) of \(Fmt.bytes(s.memory.total))", Double(s.memory.used) / Double(max(1, s.memory.total)), Theme.Metric.memory)
                    row("Disk", "\(Fmt.bytes(s.disk.freeBytes)) free", 1 - Double(s.disk.freeBytes) / Double(max(1, s.disk.totalBytes)), Theme.Metric.disk)
                }
                .padding(12)
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Using the most right now").font(.captionStrongV).foregroundStyle(Theme.textTertiary)
                    ForEach(s.apps.sorted { $0.cpu > $1.cpu }.prefix(3)) { app in
                        HStack(spacing: 8) {
                            AppIconView(bundleURL: app.bundleURL, name: app.name, size: 16)
                            Text(app.name).font(.bodyV).lineLimit(1)
                            Spacer()
                            Text("\(Fmt.percent(app.cpu)) · \(Fmt.bytes(app.memory))").font(.numeric).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(12)
                Hairline()
            }
            HStack {
                Button("Open Vardis") { open(nil) }.buttonStyle(.plain).font(.bodyV)
                Spacer()
                Text("⌥⌘V").font(.captionV).foregroundStyle(Theme.textTertiary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
        }
        .frame(width: 320)
    }

    private func row(_ label: String, _ value: String, _ fraction: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.captionV).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).font(.captionStrongV).foregroundStyle(Theme.text)
            }
            Meter(value: fraction, color: color)
        }
    }
}

// MARK: - Claude Code status item

/// The Claude item: active account's 5-hour use (sparkle + number) and a popover with quota and running sessions.
/// Shown while `Pref.menuClaude` is on.
@MainActor
final class ClaudeStatusItem {
    private static var shared: ClaudeStatusItem?

    static func install(model: ClaudeModel) {
        guard shared == nil else { return }
        shared = ClaudeStatusItem(model: model)
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: ClaudeModel
    private var observers: [NSObjectProtocol] = []

    private init(model: ClaudeModel) {
        self.model = model
        item.autosaveName = "vardis.claude"
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.imagePosition = .imageLeading
        let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Code")
        image?.isTemplate = true
        item.button?.image = image
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ClaudeMenuView(open: {
            NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }).environment(model))
        observers.append(NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.setPresenting("claude.menu", false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        })
        applyVisibility()
        observe()
    }

    private func applyVisibility() {
        let visible = UserDefaults.standard.bool(forKey: Pref.menuClaude)
        if item.isVisible != visible { item.isVisible = visible }
    }

    /// Re-renders the title whenever the active account's quota changes.
    private func observe() {
        let text = withObservationTracking {
            ClaudeFmt.percent(model.quota(model.activeAccount)?.fiveHour?.utilization)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        item.button?.attributedTitle = NSAttributedString(string: " " + text, attributes: attrs)
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) } else {
            model.setPresenting("claude.menu", true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

struct ClaudeMenuView: View {
    let open: () -> Void
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            account.padding(12)
            Hairline()
            sessions.padding(12)
            Hairline()
            HStack {
                Button("Open Vardis", action: open).buttonStyle(.plain).font(.bodyV)
                Spacer()
                Text("\u{2325}\u{2318}V").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
        }
        .frame(width: 320)
    }

    private var account: some View {
        let active = claude.activeAccount
        let q = claude.quota(active)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Theme.claude)
                Text(active?.name ?? "Claude Code").font(.headlineV).foregroundStyle(Theme.text)
                if let plan = active?.plan { Text(plan).font(.captionV).foregroundStyle(Theme.textTertiary) }
                Spacer()
                Text("\(claude.live.count) \(claude.live.count == 1 ? "session" : "sessions") running").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            if claude.supportsQuota {
                if let q {
                    QuotaMeterView(window: q.fiveHour, label: "5-hour")
                    QuotaMeterView(window: q.sevenDay, color: Theme.textSecondary, label: "Weekly")
                } else {
                    Text(claude.quotas[active?.id ?? ""]?.problem ?? "Checking plan limits\u{2026}").font(.captionV).foregroundStyle(Theme.textTertiary)
                }
                let rules = ClaudeModel.Rules.current
                if rules.enabled, let next = claude.nextAccount(rules: rules) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                        Text("Next: \(next.name) at \(Int(rules.fiveHour))% \u{00B7} \(next.name) is at \(ClaudeFmt.percent(claude.quota(next)?.fiveHour?.utilization))")
                    }
                    .font(.captionV).foregroundStyle(Theme.textTertiary)
                }
            } else {
                Text("Plan limits need the direct download from vardis.app.").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Sessions").font(.captionStrongV).foregroundStyle(Theme.textTertiary)
            if claude.live.isEmpty {
                Text("None running").font(.calloutV).foregroundStyle(Theme.textTertiary)
            }
            ForEach(claude.live.prefix(6)) { s in
                let status = LiveStatusText(s)
                HStack(spacing: 8) {
                    Circle().fill(status.dot).frame(width: 7, height: 7)
                    Text(s.projectName).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(status.text).font(.captionV).foregroundStyle(status.color).lineLimit(1)
                    Text(Fmt.percent(s.activity.contextFraction)).font(.captionStrongV).foregroundStyle(Theme.textSecondary).frame(width: 34, alignment: .trailing)
                }
            }
        }
    }
}
