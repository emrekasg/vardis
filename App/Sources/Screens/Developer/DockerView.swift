import AppKit
import SwiftUI
import VardisCore

struct DockerView: View {
    var body: some View {
        // `Edition.current` is compiled inside VardisKit, which never sees the app target's APPSTORE flag,
        // so the edition is also checked here where the flag is set.
        if Self.isAppStore || !Edition.current.supports(.unrestrictedFileAccess) {
            EmptyDeveloperState(symbol: "shippingbox", title: "Docker is in the direct download.",
                                message: "The App Store edition runs in a sandbox that cannot talk to the Docker engine. The free direct download from \(Brand.domain) shows your containers here.")
        } else {
            DockerContent()
        }
    }

    private static var isAppStore: Bool {
        #if APPSTORE
        true
        #else
        false
        #endif
    }
}

private struct DockerContent: View {
    private let model = DockerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.availability {
            case .checking:
                Color.clear
            case .notInstalled:
                EmptyDeveloperState(symbol: "shippingbox", title: "Docker is not installed.",
                                    message: "Install Docker Desktop, OrbStack or Colima and your containers show up here with their CPU and memory.")
            case .daemonDown(let message):
                EmptyDeveloperState(symbol: "shippingbox", title: "Docker is not running.", message: message)
            case .ready:
                header
                Hairline()
                if model.containers.isEmpty {
                    EmptyDeveloperState(symbol: "shippingbox", title: "No containers yet.", message: "Containers you run or create show up here.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ContainerHeaderRow()
                            ForEach(model.containers) { c in
                                ContainerRow(container: c, model: model)
                                Hairline().padding(.leading, 28)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var header: some View {
        let running = model.containers.filter(\.isRunning).count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.containers.count == 1 ? "1 container" : "\(model.containers.count) containers").font(.titleV).foregroundStyle(Theme.text)
                Text("\(running) running").font(.calloutV).foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            if !model.disk.isEmpty {
                HStack(spacing: 28) {
                    ForEach(model.disk) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.type).font(.captionV).foregroundStyle(Theme.textSecondary)
                            Text(d.size).font(.numeric).foregroundStyle(Theme.text)
                            Text(d.reclaimable.isEmpty ? "\(d.total) total" : "\(d.total) total · \(d.reclaimable) reclaimable")
                                .font(.captionV).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 14)
    }
}

private enum DockerColumns {
    static let image: CGFloat = 220
    static let status: CGFloat = 150
    static let ports: CGFloat = 150
    static let cpu: CGFloat = 60
    static let memory: CGFloat = 90
    static let actions: CGFloat = 70
}

private struct ContainerHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Image").frame(width: DockerColumns.image, alignment: .leading)
            Text("Status").frame(width: DockerColumns.status, alignment: .leading)
            Text("Ports").frame(width: DockerColumns.ports, alignment: .leading)
            Text("CPU").frame(width: DockerColumns.cpu, alignment: .trailing)
            Text("Memory").frame(width: DockerColumns.memory, alignment: .trailing)
            Color.clear.frame(width: DockerColumns.actions)
        }
        .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 28).padding(.vertical, 8)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let model: DockerModel
    @State private var hovering = false

    var body: some View {
        let c = container
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(c.isRunning ? Theme.green : Theme.textTertiary.opacity(0.5)).frame(width: 7, height: 7)
                Text(c.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(c.image).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                .frame(width: DockerColumns.image, alignment: .leading)
            Text(c.status).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(width: DockerColumns.status, alignment: .leading)
            Text(c.ports).font(.calloutV).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                .frame(width: DockerColumns.ports, alignment: .leading).help(c.ports)
            Text(c.isRunning ? c.cpu.map(Fmt.percent) ?? "–" : "").font(.numeric).foregroundStyle(Theme.textSecondary)
                .frame(width: DockerColumns.cpu, alignment: .trailing)
            Text(c.isRunning ? c.memory ?? "–" : "").font(.numeric).foregroundStyle(Theme.text)
                .frame(width: DockerColumns.memory, alignment: .trailing)
            HStack(spacing: 2) {
                if model.busy.contains(c.id) {
                    Text(c.isRunning ? "Stopping" : "Starting").font(.captionV).foregroundStyle(Theme.textTertiary)
                } else if c.isRunning {
                    RowAction(symbol: "stop.circle", help: "Stop \(c.name)…") { confirm("stop") }
                } else {
                    RowAction(symbol: "play.circle", help: "Start \(c.name)…") { confirm("start") }
                }
            }
            .frame(width: DockerColumns.actions, alignment: .trailing)
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 28).padding(.vertical, 8)
        .background(hovering ? Theme.selected.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
    }

    private func confirm(_ verb: String) {
        let c = container
        let alert = NSAlert()
        alert.messageText = verb == "stop" ? "Stop \(c.name)?" : "Start \(c.name)?"
        alert.informativeText = verb == "stop"
            ? "Docker sends the container a stop signal and ends it after 10 seconds if it has not quit. Its data stays."
            : "Docker starts the container from \(c.image) with its existing settings."
        alert.addButton(withTitle: verb == "stop" ? "Stop" : "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            if let error = await model.perform(verb, on: c) {
                let failed = NSAlert()
                failed.messageText = "Could not \(verb) \(c.name)."
                failed.informativeText = error
                failed.runModal()
            }
        }
    }
}
