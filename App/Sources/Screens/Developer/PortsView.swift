import AppKit
import SwiftUI
import VardisCore
import VardisSampling

/// Dev servers and ports, grouped by the project folder they were started from.
/// ⌘F takes a port ("3000" or ":3000") and shows what holds it, or a name to filter by.
struct PortsView: View {
    @Environment(LiveModel.self) private var live
    private let model = PortsModel.shared
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var request: StopRequest?

    private var portQuery: UInt16? { PortQuery.parse(query) }

    private var visibleProjects: [DevProject] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let port = portQuery {
            return model.projects.compactMap { p in
                var p = p
                p.servers = p.servers.filter { $0.ports.contains { $0.port == port } }
                return p.servers.isEmpty ? nil : p
            }
        }
        guard !q.isEmpty else { return model.projects }
        return model.projects.compactMap { p in
            if p.title.localizedCaseInsensitiveContains(q) || (p.path ?? "").localizedCaseInsensitiveContains(q) { return p }
            var p = p
            p.servers = p.servers.filter { $0.name.localizedCaseInsensitiveContains(q) || (model.http[$0.ports.first?.port ?? 0]?.title ?? "").localizedCaseInsensitiveContains(q) }
            return p.servers.isEmpty ? nil : p
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            if let port = portQuery {
                FreePortCard(port: port, model: model) { request = .single($0) }
                Hairline()
            }
            content
        }
        .background(Theme.window)
        .onAppear { model.appear(live: live) }
        .onDisappear { model.disappear() }
        .sheet(item: $request) { StopSheet(request: $0, model: model) }
    }

    @ViewBuilder private var content: some View {
        let projects = visibleProjects
        if model.hasScanned && model.projects.isEmpty {
            EmptyDeveloperState(symbol: "powerplug", title: "No servers are listening.", message: Self.emptyMessage)
        } else if model.hasScanned && projects.isEmpty && portQuery == nil {
            EmptyDeveloperState(symbol: "magnifyingglass", title: "Nothing matches “\(query)”.", message: "Type a port number, a project or a process name.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !projects.isEmpty { PortsHeaderRow() }
                    ForEach(projects) { project in
                        ProjectHeader(project: project) { request = .project(project) }
                        ForEach(project.servers) { server in
                            VStack(spacing: 0) {
                                ServerRowView(server: server, http: model.http) { request = .single($0) }
                                Hairline().padding(.leading, 28)
                            }
                            .transition(.row)
                        }
                    }
                }
                .padding(.bottom, 20)
                .animatesRows(projects.flatMap { $0.servers.map(\.id) })
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.serverCount == 1 ? "1 server" : "\(model.serverCount) servers").font(.titleV).foregroundStyle(Theme.text)
                    .contentTransition(.numericText()).motion(Motion.quick, value: model.serverCount)
                Text(subtitle).font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 12)
            searchField
            if model.systemServerCount > 0 {
                Toggle("Show system (\(model.systemServerCount))", isOn: Binding(get: { model.showSystem }, set: { model.showSystem = $0 }))
                    .toggleStyle(.checkbox).font(.calloutV).foregroundStyle(Theme.textSecondary)
                    .help("Servers that belong to macOS or another account. Vardis never stops them.")
            }
            Button {
                request = .cleanup(model)
            } label: {
                Label(model.idleTargets.isEmpty ? "Clean Up…" : "Clean Up \(model.idleTargets.count) Idle…", systemImage: "sparkles")
            }
            .disabled(model.stoppable.isEmpty)
            .help("Stop idle servers in one go. You confirm the list first.")
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 14)
    }

    private var subtitle: String {
        let ports = model.portCount == 1 ? "1 port" : "\(model.portCount) ports"
        let idle = model.idleTargets.count
        return "listening on \(ports), grouped by project folder" + (idle > 0 ? ", \(idle) idle" : "")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField("Port or name", text: $query)
                .textFieldStyle(.plain)
                .focused($searching)
                .screenSearchFocus($searching)
                .onExitCommand { query = ""; searching = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Clear search")
            }
        }
        .font(.bodyV)
        .padding(.horizontal, 8).frame(width: 190, height: 26)
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("Find a port or a server (⌘F)")
    }

    private static var emptyMessage: String {
        #if APPSTORE
        "The App Store edition's sandbox cannot see other apps' sockets. The free direct download from \(Brand.domain) lists every server you start."
        #else
        "Dev servers, databases and other tools you start show up here with their ports."
        #endif
    }
}

// MARK: Free a port

/// What holds a typed port, with a way to stop it. Says so when the holder is outside what Vardis can see.
private struct FreePortCard: View {
    let port: UInt16
    let model: PortsModel
    let stop: (StopTarget) -> Void
    @State private var externallyHeld: Bool?

    var body: some View {
        let holders = model.holders(of: port)
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemName: holders.isEmpty && externallyHeld != true ? "checkmark" : "powerplug", color: holders.isEmpty && externallyHeld != true ? Theme.green : Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                if holders.isEmpty {
                    Text(externallyHeld == true ? "Something Vardis cannot see holds port \(String(port))." : externallyHeld == false ? "Port \(String(port)) is free." : "Looking at port \(String(port))…")
                        .font(.headlineV).foregroundStyle(Theme.text)
                    if externallyHeld == true {
                        Text("It belongs to another account or to macOS, so it is not listed and cannot be stopped from here.")
                            .font(.calloutV).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    ForEach(holders, id: \.server.id) { h in
                        HStack(spacing: 8) {
                            Text("Port \(String(port)) is held by \(h.server.name)").font(.headlineV).foregroundStyle(Theme.text)
                            Text(h.project.path == nil ? h.project.title : "in \(h.project.title)").font(.calloutV).foregroundStyle(Theme.textSecondary)
                            OwnerBadge(ownership: h.server.ownership)
                            if let m = h.server.memory { Text(Fmt.bytes(m)).font(.numeric).foregroundStyle(Theme.textSecondary) }
                            Spacer(minLength: 8)
                            if let t = h.server.stopTarget {
                                Button("Stop It…") { stop(t) }
                            } else {
                                Text(h.server.ownership == .container ? "Stop its container in Docker" : "Vardis never stops it")
                                    .font(.captionV).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(Theme.surface)
        .task(id: "\(port)-\(holders.isEmpty)") {
            guard holders.isEmpty else { externallyHeld = nil; return }
            let p = port
            externallyHeld = await Task.detached(priority: .userInitiated) { PortProbe.isListening(port: p) }.value
        }
    }
}

// MARK: Rows

private enum PortsColumns {
    static let port: CGFloat = 150
    static let owner: CGFloat = 150
    static let uptime: CGFloat = 80
    static let cpu: CGFloat = 56
    static let memory: CGFloat = 76
    static let actions: CGFloat = 110
}

private struct PortsHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Port").frame(width: PortsColumns.port, alignment: .leading)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("Owner").frame(width: PortsColumns.owner, alignment: .leading)
            Text("Uptime").frame(width: PortsColumns.uptime, alignment: .trailing)
            Text("CPU").frame(width: PortsColumns.cpu, alignment: .trailing)
            Text("Memory").frame(width: PortsColumns.memory, alignment: .trailing)
            Color.clear.frame(width: PortsColumns.actions)
        }
        .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 28).padding(.vertical, 8)
    }
}

struct OwnerBadge: View {
    let ownership: ServerOwnership
    var body: some View {
        switch ownership {
        case .yours: Text(ownership.label).font(.captionV).foregroundStyle(Theme.textTertiary)
        case .container: Badge(ownership.label, tone: .blue)
        case .system: Badge(ownership.label)
        }
    }
}

private struct ProjectHeader: View {
    let project: DevProject
    let quit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(project.title).font(.headlineV).foregroundStyle(Theme.text).lineLimit(1)
                Text(project.subtitle).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
                ForEach(project.conflicts, id: \.self) { c in
                    Badge("wants :\(String(c.port)), held by \(c.holder)", tone: .orange)
                        .help("This project's config asks for port \(c.port), but \(c.holder) is already using it.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.percent(project.cpu)).font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: PortsColumns.cpu, alignment: .trailing)
                .contentTransition(.numericText()).motion(Motion.value, value: project.cpu)
            Text(project.memory > 0 ? Fmt.bytes(project.memory) : "–").font(.numeric).foregroundStyle(Theme.text)
                .frame(width: PortsColumns.memory, alignment: .trailing)
                .contentTransition(.numericText()).motion(Motion.value, value: project.memory)
            HStack(spacing: 2) {
                if let path = project.path {
                    if let t = ProjectOpeners.terminal {
                        RowAction(symbol: "terminal", help: "Open in Terminal") { ProjectOpeners.open(path, with: t) }
                    }
                    if let e = ProjectOpeners.editors.first {
                        RowAction(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in \(e.name)") { ProjectOpeners.open(path, with: e) }
                    }
                    RowAction(symbol: "folder", help: "Reveal in Finder") { ProjectOpeners.reveal(path) }
                }
                if project.place != .system, !project.stopTargets.isEmpty {
                    RowAction(symbol: "stop.circle", help: project.path == nil ? "Stop all of these…" : "Quit \(project.title)…", action: quit)
                }
            }
            .frame(width: PortsColumns.actions, alignment: .trailing)
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .contextMenu {
            if let path = project.path {
                if let t = ProjectOpeners.terminal { Button("Open in Terminal") { ProjectOpeners.open(path, with: t) } }
                ForEach(ProjectOpeners.editors) { e in Button("Open in \(e.name)") { ProjectOpeners.open(path, with: e) } }
                Button("Reveal in Finder") { ProjectOpeners.reveal(path) }
            }
            if project.place != .system, !project.stopTargets.isEmpty {
                Divider()
                Button(project.path == nil ? "Stop All…" : "Quit \(project.title)…", action: quit)
            }
        }
    }

    private var symbol: String {
        switch project.place {
        case .folder: "folder"
        case .elsewhere: "tray"
        case .system: "gearshape"
        }
    }
}

private struct ServerRowView: View {
    let server: DevServer
    let http: [UInt16: HTTPInfo]
    let stop: (StopTarget) -> Void
    @State private var hovering = false

    /// First port that answered HTTP, else the first that looks like it (before the probe lands).
    private var browserPort: UInt16? {
        server.httpPorts.first { http[$0] != nil } ?? (server.ownership == .system ? nil : server.httpPorts.first)
    }
    private var pageTitle: String? { server.httpPorts.lazy.compactMap { http[$0]?.title }.first }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(server.ports.prefix(3), id: \.self) { port in
                    Text(verbatim: "\(port.port)").font(.numeric).foregroundStyle(Theme.text)
                        + Text(port.transport == .udp ? " udp" : "").font(.captionV).foregroundStyle(Theme.textTertiary)
                }
                if server.ports.count > 3 { Text("+\(server.ports.count - 3)").font(.captionV).foregroundStyle(Theme.textTertiary) }
            }
            .frame(width: PortsColumns.port, alignment: .leading)
            .help(server.ports.map { "\($0.port)/\($0.transport.rawValue)\($0.localOnly ? " (this Mac only)" : " (reachable from your network)")" }.joined(separator: "\n"))

            HStack(spacing: 8) {
                if let app = server.app, app.bundleURL != nil {
                    AppIconView(bundleURL: app.bundleURL, name: app.name, size: 16)
                } else if server.container != nil {
                    Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                }
                Text(server.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                Text(server.detail).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                if let since = server.idleSince {
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in Badge(IdleFmt.text(since: since, now: ctx.date)) }
                        .help("No CPU and no connections since \(since.formatted(date: .abbreviated, time: .shortened))")
                }
                if server.ports.contains(where: { !$0.localOnly }) { Badge("network", tone: .orange).help("Reachable from other devices on your network") }
                if let pageTitle {
                    Text(pageTitle).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                OwnerBadge(ownership: server.ownership)
                if let app = server.app, app.bundleURL != nil {
                    Text(app.name).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .frame(width: PortsColumns.owner, alignment: .leading)

            Group {
                if let started = server.started {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(DurationFmt.compact(context.date.timeIntervalSince(started))).font(.numeric).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("–").font(.numeric).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: PortsColumns.uptime, alignment: .trailing)
            Text(server.cpu.map(Fmt.percent) ?? "–").font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: PortsColumns.cpu, alignment: .trailing)
                .contentTransition(.numericText()).motion(Motion.value, value: server.cpu)
            Text(server.memory.map { Fmt.bytes($0) } ?? "–").font(.numeric).foregroundStyle(Theme.text).frame(width: PortsColumns.memory, alignment: .trailing)
                .contentTransition(.numericText()).motion(Motion.value, value: server.memory)

            HStack(spacing: 2) {
                if let port = browserPort {
                    RowAction(symbol: "safari", help: "Open localhost:\(port) in your browser") { ProjectOpeners.browse(port) }
                }
                if let t = server.stopTarget {
                    RowAction(symbol: "stop.circle", help: "Stop \(server.name)…") { stop(t) }
                }
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
            ForEach(server.httpPorts, id: \.self) { port in
                Button("Open localhost:\(String(port)) in Browser") { ProjectOpeners.browse(port) }
            }
            if let path = server.projectPath ?? server.process?.workingDirectory {
                Button("Reveal Folder in Finder") { ProjectOpeners.reveal(path) }
            }
            if let t = server.stopTarget {
                Divider()
                Button("Stop \(server.name)…") { stop(t) }
            }
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

    var body: some View { EmptyState(symbol: symbol, title: title, detail: message) }
}

/// Sidebar count of dev servers (the user's and containers). Keeps a scanner-only 60 s count running while shown.
struct PortsBadge: View {
    private let model = PortsModel.shared

    var body: some View {
        let n = model.devServerCount
        Text(n > 0 ? "\(n)" : "").font(.captionV).monospacedDigit().foregroundStyle(Theme.textTertiary)
            .contentTransition(.numericText())
            .motion(Motion.value, value: n)
            .onAppear { model.badgeAppear() }
            .onDisappear { model.badgeDisappear() }
            .help(n == 1 ? "1 dev server" : "\(n) dev servers")
    }
}
