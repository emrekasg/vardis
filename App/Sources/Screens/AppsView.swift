import SwiftUI
import VardisCore

struct AppsView: View {
    @Environment(LiveModel.self) private var live
    @State private var selection: AppSample.ID?
    @State private var sortOrder = [KeyPathComparator(\AppSample.memory, order: .reverse)]
    @State private var processes: [ProcessSample] = []
    @State private var showSystem = true

    private var apps: [AppSample] {
        let all = live.snapshot?.apps ?? []
        return (showSystem ? all : all.filter { !$0.isSystem }).sorted(using: sortOrder)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(apps.count) apps").font(.titleV).foregroundStyle(Theme.text)
                    Text("\(live.snapshot?.processCount ?? 0) processes, grouped by the app that launched them")
                        .font(.calloutV).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Toggle("System", isOn: $showSystem).toggleStyle(.checkbox).font(.calloutV)
                }
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 12)

                Table(apps, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("App", value: \.name) { app in
                        HStack(spacing: 8) {
                            AppIconView(bundleURL: app.bundleURL, name: app.name)
                            Text(app.name).font(.bodyV)
                            Text(app.isSystem ? "system" : app.processCount == 1 ? "1 process" : "\(app.processCount) processes")
                                .font(.captionV).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .width(min: 220, ideal: 300)
                    TableColumn("CPU", value: \.cpu) { Text(Fmt.percent($0.cpu)).font(.numeric).frame(maxWidth: .infinity, alignment: .trailing) }
                        .width(70)
                    TableColumn("Memory", value: \.memory) { Text(Fmt.bytes($0.memory)).font(.numeric).frame(maxWidth: .infinity, alignment: .trailing) }
                        .width(84)
                    TableColumn("Energy", value: \.energyWatts) { Text(Fmt.watts($0.energyWatts)).font(.numeric).frame(maxWidth: .infinity, alignment: .trailing) }
                        .width(76)
                    TableColumn("Disk write", value: \.diskWriteBytesPerSecond) { Text(Fmt.rate($0.diskWriteBytesPerSecond)).font(.numeric).frame(maxWidth: .infinity, alignment: .trailing) }
                        .width(90)
                    TableColumn("Memory, last minute") { app in
                        Sparkline(values: live.appMemory[app.id]?.elements ?? [], color: Theme.textTertiary)
                            .frame(height: 18)
                    }
                    .width(120)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
            }
            if let id = selection, let app = live.snapshot?.apps.first(where: { $0.id == id }) {
                Rectangle().fill(Theme.separator).frame(width: 1)
                AppInspector(app: app, processes: processes)
                    .frame(width: 360)
                    .task(id: "\(id)-\(live.snapshot?.timestamp.timeIntervalSince1970 ?? 0)") {
                        processes = await live.processes(inApp: id)
                    }
            }
        }
    }
}

private struct AppInspector: View {
    let app: AppSample
    let processes: [ProcessSample]
    @Environment(LiveModel.self) private var live

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    AppIconView(bundleURL: app.bundleURL, name: app.name, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.titleV).foregroundStyle(Theme.text)
                        Text(app.processCount == 1 ? "1 process" : "\(app.processCount) processes").font(.calloutV).foregroundStyle(Theme.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Memory, last minute").font(.calloutV).foregroundStyle(Theme.textSecondary)
                    Text(Fmt.bytes(app.memory)).font(.numericXL).foregroundStyle(Theme.text)
                    Sparkline(values: live.appMemory[app.id]?.elements ?? [], color: Theme.Metric.memory).frame(height: 56)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Processes").font(.headlineV).foregroundStyle(Theme.text).padding(.bottom, 6)
                    Hairline()
                    ForEach(processes.sorted { $0.memory > $1.memory }) { p in
                        HStack {
                            Text(p.name).font(.calloutV).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(Fmt.percent(p.cpu)).font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: 52, alignment: .trailing)
                            Text(Fmt.bytes(p.memory)).font(.numeric).foregroundStyle(Theme.text).frame(width: 72, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        Hairline()
                    }
                }
                HStack {
                    Button("Quit \(app.name)") { quit(force: false) }
                    Button("Force Quit") { quit(force: true) }
                }
            }
            .padding(24)
        }
        .background(Theme.surface)
    }

    /// Quitting always asks first; Vardis never ends a process on its own.
    private func quit(force: Bool) {
        let alert = NSAlert()
        alert.messageText = force ? "Force quit \(app.name)?" : "Quit \(app.name)?"
        alert.informativeText = force ? "Unsaved changes in \(app.name) will be lost." : "\(app.name) may ask you to save changes."
        alert.addButton(withTitle: force ? "Force Quit" : "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for pid in app.processIDs {
            if let running = NSRunningApplication(processIdentifier: pid) {
                _ = force ? running.forceTerminate() : running.terminate()
            }
        }
    }
}
