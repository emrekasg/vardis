import AppKit
import SwiftUI
import VardisCore
import VardisSampling

struct PortsView: View {
    @Environment(LiveModel.self) private var live
    private let model = PortsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.serverCount == 1 ? "1 server" : "\(model.serverCount) servers").font(.titleV).foregroundStyle(Theme.text)
                Text("listening on \(model.portCount == 1 ? "1 port" : "\(model.portCount) ports"), grouped by project folder")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 12)
            Hairline()

            if model.hasScanned && model.groups.isEmpty {
                EmptyDeveloperState(symbol: "powerplug", title: "No servers are listening.",
                                    message: Self.emptyMessage)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        PortsHeaderRow()
                        ForEach(model.groups) { group in
                            ProjectHeader(group: group)
                            ForEach(group.servers) { row in
                                ServerRowView(row: row, model: model)
                                Hairline().padding(.leading, 28)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear { model.appear(live: live) }
        .onDisappear { model.disappear() }
    }

    private static var emptyMessage: String {
        #if APPSTORE
        "The App Store edition's sandbox cannot see other apps' sockets. The free direct download from \(Brand.domain) lists every server you start."
        #else
        "Dev servers, databases and other tools you start show up here with their ports."
        #endif
    }
}

private enum PortsColumns {
    static let port: CGFloat = 150
    static let app: CGFloat = 170
    static let uptime: CGFloat = 90
    static let cpu: CGFloat = 60
    static let memory: CGFloat = 80
    static let actions: CGFloat = 96
}

private struct PortsHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Port").frame(width: PortsColumns.port, alignment: .leading)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("App").frame(width: PortsColumns.app, alignment: .leading)
            Text("Uptime").frame(width: PortsColumns.uptime, alignment: .trailing)
            Text("CPU").frame(width: PortsColumns.cpu, alignment: .trailing)
            Text("Memory").frame(width: PortsColumns.memory, alignment: .trailing)
            Color.clear.frame(width: PortsColumns.actions)
        }
        .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 28).padding(.vertical, 8)
    }
}

private struct ProjectHeader: View {
    let group: ProjectGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: group.path == nil ? "tray" : "folder").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text(group.title).font(.headlineV).foregroundStyle(Theme.text)
            Text(group.subtitle).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let path = group.path {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
                    .buttonStyle(.link).font(.captionV)
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 6)
    }
}

private struct ServerRowView: View {
    let row: ServerRow
    let model: PortsModel
    @State private var hovering = false

    private var p: ServerProcess { row.process }
    private var httpPort: UInt16? { p.ports.first(where: \.looksLikeHTTP)?.port }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(p.ports.prefix(3), id: \.self) { port in
                    Text(verbatim: "\(port.port)").font(.numeric).foregroundStyle(Theme.text)
                    + Text(port.transport == .udp ? " udp" : "").font(.captionV).foregroundStyle(Theme.textTertiary)
                }
                if p.ports.count > 3 { Text("+\(p.ports.count - 3)").font(.captionV).foregroundStyle(Theme.textTertiary) }
            }
            .frame(width: PortsColumns.port, alignment: .leading)
            .help(p.ports.map { "\($0.port)/\($0.transport.rawValue)\($0.localOnly ? " (this Mac only)" : " (reachable from your network)")" }.joined(separator: "\n"))

            HStack(spacing: 8) {
                Text(p.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                Text(verbatim: "\(p.pid)").font(.captionV).foregroundStyle(Theme.textTertiary)
                if p.isIdle { Badge("idle") }
                if p.ports.contains(where: { !$0.localOnly }) { Badge("network", tone: .orange).help("Reachable from other devices on your network") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                // Only a real app is worth naming; a bare tool's group is just the process again.
                if let app = row.app, app.bundleURL != nil {
                    AppIconView(bundleURL: app.bundleURL, name: app.name, size: 16)
                    Text(app.name).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(width: PortsColumns.app, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.uptime(since: p.started, now: context.date)).font(.numeric).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: PortsColumns.uptime, alignment: .trailing)
            Text(Fmt.percent(p.cpu)).font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: PortsColumns.cpu, alignment: .trailing)
            Text(Fmt.bytes(p.memory)).font(.numeric).foregroundStyle(Theme.text).frame(width: PortsColumns.memory, alignment: .trailing)

            HStack(spacing: 2) {
                if let port = httpPort {
                    RowAction(symbol: "safari", help: "Open localhost:\(port) in your browser") {
                        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                    }
                }
                if let path = p.projectPath ?? p.workingDirectory {
                    RowAction(symbol: "folder", help: "Reveal project in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                }
                RowAction(symbol: "stop.circle", help: "Stop \(p.name)…") { confirmStop() }
            }
            .frame(width: PortsColumns.actions, alignment: .trailing)
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 28).padding(.vertical, 8)
        .background(hovering ? Theme.selected.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .contextMenu {
            if let port = httpPort { Button("Open localhost:\(port) in Browser") { if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) } } }
            if let path = p.projectPath ?? p.workingDirectory { Button("Reveal Project in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } }
            Divider()
            Button("Stop \(p.name)…") { confirmStop() }
        }
    }

    static func uptime(since start: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(start))
        if s < 60 { return "just now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m) min" }
        if m < 24 * 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(m / 1440) d \((m % 1440) / 60) h"
    }

    /// Vardis never stops anything without this confirmation. SIGTERM first; SIGKILL only if the user asks again.
    private func confirmStop() {
        let p = self.p
        let alert = NSAlert()
        alert.messageText = "Stop \(p.name) (pid \(p.pid))?"
        let ports = p.ports.map { String($0.port) }.joined(separator: ", ")
        let place = (p.projectPath ?? p.workingDirectory).map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        alert.informativeText = "It is listening on \(p.ports.count == 1 ? "port" : "ports") \(ports)\(place). Vardis asks it to quit, like pressing Control-C; unsaved work in it may be lost."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard model.send(SIGTERM, to: p) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard model.isAlive(p) else { return }
            let again = NSAlert()
            again.messageText = "\(p.name) is still running."
            again.informativeText = "It did not quit within 3 seconds. Force stop ends it at once, without letting it clean up."
            again.addButton(withTitle: "Force Stop")
            again.addButton(withTitle: "Keep Running")
            if again.runModal() == .alertFirstButtonReturn { _ = model.send(SIGKILL, to: p) }
        }
    }
}

struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct EmptyDeveloperState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
            Text(title).font(.headlineV).foregroundStyle(Theme.text)
            Text(message).font(.calloutV).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
