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
        popover.contentViewController = NSHostingController(rootView: MenuBarDropdown(open: { [weak self] screen in
            self?.popover.performClose(nil)
            self?.openWindow(screen)
        }).environment(live))
        update(nil)
    }

    func update(_ s: Snapshot?) {
        let cpu = s.map { Fmt.percent($0.cpu.total) } ?? "–"
        let mem = s.map { Fmt.bytes($0.memory.used).replacingOccurrences(of: " ", with: "") } ?? "–"
        cpuItem.button?.attributedTitle = NSAttributedString(string: " " + cpu, attributes: Self.numberAttributes)
        memoryItem.button?.attributedTitle = NSAttributedString(string: mem, attributes: Self.numberAttributes)
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
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
