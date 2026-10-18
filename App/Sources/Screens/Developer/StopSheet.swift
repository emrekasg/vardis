import SwiftUI
import VardisCore
import VardisSampling

/// What the user is about to stop. Nothing is stopped until they press the sheet's Stop button.
struct StopRequest: Identifiable {
    let id = UUID()
    var title: String
    var intro: String?
    var targets: [StopTarget]
    /// Ticked when the sheet opens. With `selectable` false every target is stopped.
    var preselected: Set<String>
    var selectable: Bool

    static func single(_ t: StopTarget) -> StopRequest {
        let place = t.projectName.map { " in \($0)" } ?? ""
        let ports = t.ports.isEmpty ? "" : "It is listening on \(t.portsText)\(place). "
        return StopRequest(title: "Stop \(t.name)?", intro: ports + StopSheet.consequence(container: t.isContainer),
                           targets: [t], preselected: [t.id], selectable: false)
    }

    static func project(_ p: DevProject) -> StopRequest {
        let t = p.stopTargets
        return StopRequest(title: "Quit \(p.title)?", intro: "Stops every server started from this folder. " + StopSheet.consequence(container: t.allSatisfy(\.isContainer)),
                           targets: t, preselected: Set(t.map(\.id)), selectable: t.count > 1)
    }

    @MainActor static func cleanup(_ model: PortsModel) -> StopRequest {
        let all = model.stoppable
        let idle = Set(all.filter { $0.idleSince != nil }.map(\.id))
        let title = idle.isEmpty ? "Clean up servers" : "Clean up \(idle.count == 1 ? "1 idle server" : "\(idle.count) idle servers")?"
        let intro = idle.isEmpty
            ? "None of your servers has been idle for 30 minutes yet. Tick any you want to stop."
            : "Idle means no CPU and no connections for at least 30 minutes. They are ticked; tick others to stop them too."
        return StopRequest(title: title, intro: intro, targets: all, preselected: idle, selectable: true)
    }
}

struct StopSheet: View {
    let request: StopRequest
    let model: PortsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var phase: Phase = .confirm
    @State private var stopped: [StopTarget] = []
    @State private var stillRunning: [StopTarget] = []
    @State private var failed: [(target: StopTarget, message: String)] = []

    enum Phase: Equatable { case confirm, working(String), result }

    init(request: StopRequest, model: PortsModel) {
        self.request = request
        self.model = model
        _selected = State(initialValue: request.preselected)
    }

    nonisolated static func consequence(container: Bool) -> String {
        container ? "Docker stops the container and keeps it, so it can start again."
            : "Vardis asks it to quit, like pressing Control-C. Unsaved work in it may be lost."
    }

    private var chosen: [StopTarget] { request.targets.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .confirm: confirm
            case .working(let text):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.bodyV).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .result: result
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Theme.window)
        .motion(Motion.quick, value: phase)
    }

    // MARK: Confirm

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.titleV).foregroundStyle(Theme.text)
            if let intro = request.intro {
                Text(intro).font(.bodyV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if request.targets.isEmpty {
                Text("Nothing here can be stopped from Vardis.").font(.bodyV).foregroundStyle(Theme.textTertiary)
            } else if request.selectable || request.targets.count > 1 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(request.targets) { t in
                            TargetRow(target: t, selectable: request.selectable, isOn: binding(t.id))
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(freesText(chosen)).font(.calloutV).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Stop \(chosen.count)" : "Stop") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { on in if on { selected.insert(id) } else { selected.remove(id) } })
    }

    private func freesText(_ targets: [StopTarget]) -> String {
        guard !targets.isEmpty else { return "Nothing selected." }
        let bytes = IdleFmt.frees(targets)
        let containers = targets.filter(\.isContainer).count
        var s = bytes > 0 ? "Stopping \(targets.count == 1 ? "it" : "these") frees \(Fmt.bytes(bytes))" : "Stopping \(targets.count == 1 ? "it" : "these")"
        if containers > 0 { s += bytes > 0 ? ", plus what \(containers == 1 ? "the container uses" : "the containers use")" : " frees what \(containers == 1 ? "the container uses" : "the containers use")" }
        return s + "."
    }

    private func run() {
        let targets = chosen
        phase = .working(targets.count == 1 ? "Asking \(targets[0].name) to quit…" : "Asking \(targets.count) servers to quit…")
        Task {
            let o = await model.stop(targets)
            stopped = o.stopped
            stillRunning = o.stillRunning
            failed = o.failed
            phase = .result
        }
    }

    private func forceQuit() {
        let targets = stillRunning
        phase = .working("Force quitting…")
        Task {
            let o = await model.forceQuit(targets)
            stopped += o.stopped
            stillRunning = []
            failed += o.failed
            phase = .result
        }
    }

    // MARK: Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(resultTitle).font(.titleV).foregroundStyle(Theme.text)
            if !stillRunning.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stillRunning.count == 1 ? "\(stillRunning[0].name) did not quit within 3 seconds." : "\(stillRunning.count) did not quit within 3 seconds.")
                        .font(.headlineV).foregroundStyle(Theme.orange)
                    Text("Force Quit ends them at once, without letting them save or clean up.")
                        .font(.calloutV).foregroundStyle(Theme.textSecondary)
                    VStack(spacing: 0) { ForEach(stillRunning) { TargetRow(target: $0, selectable: false, isOn: .constant(true)) } }
                }
            }
            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(failed, id: \.target.id) { f in
                        Text("\(f.target.name): \(f.message)").font(.calloutV).foregroundStyle(Theme.red).lineLimit(2)
                    }
                }
            }
            HStack {
                Spacer()
                if stillRunning.isEmpty {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Leave Running") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(stillRunning.count == 1 ? "Force Quit" : "Force Quit \(stillRunning.count)") { forceQuit() }
                        .buttonStyle(.borderedProminent).tint(Theme.red)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var resultTitle: String {
        if stopped.isEmpty { return stillRunning.isEmpty ? "Nothing was stopped." : "Still running" }
        let freed = IdleFmt.frees(stopped)
        let what = stopped.count == 1 ? "Stopped \(stopped[0].name)" : "Stopped \(stopped.count) servers"
        return freed > 0 ? "\(what), freed \(Fmt.bytes(freed))." : "\(what)."
    }
}

private struct TargetRow: View {
    let target: StopTarget
    let selectable: Bool
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if selectable {
                    Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(target.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                        if target.isContainer { Badge("container", tone: .blue) }
                    }
                    Text([target.projectName, target.portsText.isEmpty ? nil : target.portsText].compactMap { $0 }.joined(separator: "  "))
                        .font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                if let since = target.idleSince {
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in Badge(IdleFmt.text(since: since, now: ctx.date)) }
                }
                Text(target.memory.map { Fmt.bytes($0) } ?? "–").font(.numeric).foregroundStyle(Theme.text).frame(width: 80, alignment: .trailing)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { if selectable { isOn.toggle() } }
            Hairline()
        }
    }
}
