import AppKit
import SwiftUI
import VardisCore
import VardisSampling

/// Compact dev servers list for the menu bar panel (~360 pt wide): projects with their ports and memory,
/// a per-project Stop, "Clean up idle", and a way into the full screen. Scans every 2 s only while shown.
/// `open` shows a screen in the main window; pass the panel's opener to get an "Open Ports & Servers" link.
struct PortsMenuSection: View {
    var open: ((Screen?) -> Void)?
    @Environment(LiveModel.self) private var live
    private let model = PortsModel.shared

    init(open: ((Screen?) -> Void)? = nil) { self.open = open }

    private static let maxRows = 6

    var body: some View {
        let projects = model.projects.filter { $0.place != .system }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Dev servers").font(.captionStrongV).foregroundStyle(Theme.textSecondary)
                if model.devServerCount > 0 {
                    Text("\(model.devServerCount)").font(.captionV).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                let idle = model.idleTargets
                if !idle.isEmpty {
                    Button("Clean up idle (\(idle.count))") { StopAlerts.confirm(title: "Stop \(idle.count == 1 ? "1 idle server" : "\(idle.count) idle servers")?", targets: idle, model: model) }
                        .buttonStyle(.link).font(.captionV)
                        .help("Servers with no CPU and no connections for 30 minutes or more")
                }
            }
            if model.hasScanned && projects.isEmpty {
                Text("No dev servers are listening.").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(projects.prefix(Self.maxRows)) { p in MenuProjectRow(project: p, model: model) }
                }
                if projects.count > Self.maxRows {
                    Text("\(projects.count - Self.maxRows) more").font(.captionV).foregroundStyle(Theme.textTertiary)
                }
            }
            if let open {
                Button("Open Ports & Servers") { open(.ports) }
                    .buttonStyle(.link).font(.calloutV)
                    .padding(.top, 2)
            }
        }
        .onAppear { model.appear(live: live) }
        .onDisappear { model.disappear() }
    }
}

private struct MenuProjectRow: View {
    let project: DevProject
    let model: PortsModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.path == nil ? "tray" : "folder").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(project.title).font(.calloutV).foregroundStyle(Theme.text).lineLimit(1)
                    if project.servers.contains(where: \.isIdle) {
                        Text("idle").font(.captionV).foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(project.ports.prefix(4).map { ":\($0.port)" }.joined(separator: " ") + (project.ports.count > 4 ? " +\(project.ports.count - 4)" : ""))
                    .font(.captionV).monospacedDigit().foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(project.memory > 0 ? Fmt.bytes(project.memory) : "").font(.captionV).monospacedDigit().foregroundStyle(Theme.textSecondary)
            let targets = project.stopTargets
            Button {
                StopAlerts.confirm(title: project.path == nil ? "Stop \(targets.count == 1 ? targets[0].name : "\(targets.count) servers")?" : "Quit \(project.title)?",
                                   targets: targets, model: model)
            } label: {
                Image(systemName: "stop.circle").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(targets.isEmpty ? 0 : (hovering ? 1 : 0.6))
            .disabled(targets.isEmpty)
            .help(project.path == nil ? "Stop…" : "Quit \(project.title)…")
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .background(hovering ? Theme.selected.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
    }
}

/// Small NSAlert confirmations for places without room for a sheet (the menu bar panel).
@MainActor
enum StopAlerts {
    static func confirm(title: String, targets: [StopTarget], model: PortsModel) {
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = title
        let list = targets.prefix(8).map { t in
            [t.name, t.projectName, t.portsText, t.idleSince.map { IdleFmt.text(since: $0) }].compactMap { $0 }.joined(separator: "  ")
        }.joined(separator: "\n") + (targets.count > 8 ? "\n\(targets.count - 8) more" : "")
        let freed = IdleFmt.frees(targets)
        let frees = freed > 0 ? "\n\nStopping \(targets.count == 1 ? "it" : "them") frees \(Fmt.bytes(freed))." : ""
        alert.informativeText = list + frees + "\n" + StopSheet.consequence(container: targets.allSatisfy(\.isContainer))
        alert.addButton(withTitle: targets.count == 1 ? "Stop" : "Stop \(targets.count)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let outcome = await model.stop(targets)
            guard !outcome.stillRunning.isEmpty else { return }
            let again = NSAlert()
            let names = outcome.stillRunning.map(\.name).joined(separator: ", ")
            again.messageText = outcome.stillRunning.count == 1 ? "\(names) is still running." : "\(outcome.stillRunning.count) servers are still running."
            again.informativeText = (outcome.stillRunning.count == 1 ? "" : names + "\n\n")
                + "They did not quit within 3 seconds. Force Quit ends them at once, without letting them clean up."
            again.addButton(withTitle: "Force Quit")
            again.addButton(withTitle: "Leave Running")
            if again.runModal() == .alertFirstButtonReturn { _ = await model.forceQuit(outcome.stillRunning) }
        }
    }
}
