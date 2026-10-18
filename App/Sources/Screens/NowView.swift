import SwiftUI
import UniformTypeIdentifiers
import VardisCore

/// Now: four vitals people check most, large and calm, then detail tiles the person can hide and reorder.
/// Every tile and vital opens a drawer with the last minute, the last hour or day from history, top apps and facts.
struct NowView: View {
    @Environment(LiveModel.self) private var live
    @Environment(Navigation.self) private var nav
    @Environment(ClaudeModel.self) private var claude
    @State private var prefs = NowPrefs.shared
    @State private var open: NowMetric?
    @State private var editing = false
    @State private var dragging: NowTile?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NowHeader(editing: $editing)
                if let s = live.snapshot {
                    VitalsStrip(snapshot: s, open: { open = $0 })
                        .staggeredAppear(0)
                    tiles(s)
                    if editing { hiddenTray }
                }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
        }
        .background(Theme.surface)
        #if DEBUG
        // Visual checks: `VARDIS_NOW_DRAWER=<metric>` opens a drawer on launch (with --snapshot).
        .onAppear { if let m = ProcessInfo.processInfo.environment["VARDIS_NOW_DRAWER"].flatMap(NowMetric.init(rawValue:)) { open = m } }
        #endif
        .detailDrawer(item: $open, width: 460) { metric in
            NowDetailPanel(metric: metric, openApp: openApp)
        }
    }

    private func tiles(_ s: Snapshot) -> some View {
        let shown = prefs.visible.filter { available($0, s) }
        return VStack(spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(Array(shown.filter { !$0.isWide }.enumerated()), id: \.element) { i, tile in
                    editable(tile) { tileView(tile, s) }
                        .staggeredAppear(i + 1)
                }
            }
            ForEach(shown.filter(\.isWide)) { tile in
                editable(tile) { tileView(tile, s) }
                    .staggeredAppear(shown.count)
            }
        }
        .motion(Motion.travel, value: prefs.order)
        .motion(Motion.screen, value: prefs.hidden)
    }

    /// Claude hides itself without data; everything else is always available.
    private func available(_ tile: NowTile, _ s: Snapshot) -> Bool {
        switch tile {
        case .gpu: s.gpu != nil
        case .claude: ClaudeTile.hasData(claude)
        default: true
        }
    }

    @ViewBuilder
    private func tileView(_ tile: NowTile, _ s: Snapshot) -> some View {
        let opener: (NowMetric) -> (() -> Void)? = { m in editing ? nil : { open = m } }
        switch tile {
        case .cpu: CPUTile(snapshot: s, onOpen: opener(.cpu), openApp: openApp)
        case .memory: MemoryTile(snapshot: s, onOpen: opener(.memory), openApp: openApp)
        case .network: NetworkTile(snapshot: s, onOpen: opener(.network))
        case .disk: DiskTile(snapshot: s, onOpen: opener(.disk), openApp: openApp)
        case .gpu: GPUTile(snapshot: s, onOpen: opener(.gpu))
        case .power: PowerTile(snapshot: s, onOpen: opener(.power), openApp: openApp)
        case .claude: ClaudeTile(onOpen: editing ? nil : { nav.screen = .claudeUsage })
        case .watchlist: WatchListTile(snapshot: s, openApp: openApp)
        }
    }

    private func editable<C: View>(_ tile: NowTile, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .allowsHitTesting(!editing)
            .overlay(alignment: .topTrailing) {
                if editing {
                    HStack(spacing: 4) {
                        Button { prefs.move(tile, by: -1) } label: { Image(systemName: "chevron.left") }
                            .help("Move earlier")
                        Button { prefs.move(tile, by: 1) } label: { Image(systemName: "chevron.right") }
                            .help("Move later")
                        Button { prefs.setHidden(tile, true) } label: { Image(systemName: "eye.slash") }
                            .help("Hide \(tile.title)")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.separator))
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(dragging == tile ? Theme.accent : Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
            }
            .opacity(dragging == tile ? 0.55 : 1)
            .onDrag {
                dragging = tile
                return NSItemProvider(object: tile.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: TileDrop(target: tile, dragging: $dragging, prefs: prefs, enabled: editing))
    }

    private var hiddenTray: some View {
        let hidden = prefs.order.filter { prefs.hidden.contains($0) }
        return HStack(spacing: 8) {
            Text(hidden.isEmpty ? "Drag tiles to reorder. Hidden tiles appear here." : "Hidden")
                .font(.calloutV).foregroundStyle(Theme.textTertiary)
            ForEach(hidden) { tile in
                Button { prefs.setHidden(tile, false) } label: {
                    Label(tile.title, systemImage: "plus").font(.calloutV)
                }
                .buttonStyle(.bordered)
                .transition(.opacity)
            }
            Spacer()
            Button("Reset layout") { prefs.resetLayout() }.buttonStyle(.borderless).font(.calloutV)
        }
        .padding(.horizontal, 4)
        .transition(.opacity)
    }

    private func openApp(_ app: AppSample) {
        open = nil
        nav.open(.apps, appID: app.id)
    }
}

/// Reorders while a tile is dragged over another, so the grid makes room as the pointer moves.
private struct TileDrop: DropDelegate {
    let target: NowTile
    @Binding var dragging: NowTile?
    let prefs: NowPrefs
    let enabled: Bool

    func validateDrop(info: DropInfo) -> Bool { enabled && dragging != nil }

    func dropEntered(info: DropInfo) {
        guard enabled, let d = dragging, d != target else { return }
        MainActor.assumeIsolated { prefs.move(d, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: Header

private struct NowHeader: View {
    @Environment(LiveModel.self) private var live
    @Binding var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(live.isPaused ? Theme.textTertiary : Theme.green).frame(width: 7, height: 7)
            Text(live.isPaused ? "Paused" : "Live").font(.headlineV).foregroundStyle(Theme.text)
            Text(live.isPaused ? "numbers are frozen" : "updates every \(live.isFast ? "second" : "5 seconds")")
                .font(.calloutV).foregroundStyle(Theme.textTertiary)
            if let t = NowFacts.thermal() {
                Label(t.label, systemImage: "thermometer.medium")
                    .font(.captionStrongV)
                    .foregroundStyle(t.severe ? Theme.red : Theme.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((t.severe ? Theme.red : Theme.orange).opacity(0.12), in: Capsule())
                    .help(t.detail)
            }
            Spacer()
            if let s = live.snapshot {
                Text("Up \(Fmt.duration(s.uptime))").font(.calloutV).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            Button(editing ? "Done" : "Edit") { editing.toggle() }
                .keyboardShortcut(editing ? .defaultAction : nil)
                .help(editing ? "Finish editing" : "Hide or reorder tiles")
            Button {
                live.isPaused.toggle()
            } label: {
                Label(live.isPaused ? "Resume" : "Pause", systemImage: live.isPaused ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut(.space, modifiers: .option)
            .help(live.isPaused ? "Resume (⌥Space)" : "Pause (⌥Space)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 4)
    }
}

// MARK: Vitals

/// The four numbers people check most, side by side in one quiet panel.
private struct VitalsStrip: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let open: (NowMetric) -> Void

    var body: some View {
        let s = snapshot
        HStack(spacing: 0) {
            VitalCell(metric: .cpu, title: "CPU", symbol: "cpu", color: Theme.Metric.cpu,
                      value: (Fmt.percent(s.cpu.total).dropLast().description, "%"),
                      detail: "\(Fmt.percent(s.cpu.user)) user, \(Fmt.percent(s.cpu.system)) system",
                      bars: live.cpu.elements, top: 1, format: Fmt.percent, open: open)
            divider
            VitalCell(metric: .memory, title: "Memory", symbol: "memorychip", color: Theme.Metric.memory,
                      value: splitUnit(Fmt.bytes(s.memory.used)),
                      detail: "of \(Fmt.bytes(s.memory.total))" + (s.memory.swapUsed > 0 ? ", \(Fmt.bytes(s.memory.swapUsed)) swap" : ""),
                      badge: AnyView(PressureLabel(pressure: s.memory.pressure)),
                      bars: live.memory.elements, top: 1, format: Fmt.percent, label: "In use", open: open)
            divider
            VitalCell(metric: .network, title: "Network", symbol: "arrow.down.circle", color: Theme.Metric.network,
                      value: splitUnit(Fmt.rate(s.network.receivedBytesPerSecond)),
                      detail: "\(Fmt.rate(s.network.sentBytesPerSecond)) up",
                      bars: live.networkIn.elements, top: nil, format: Fmt.rate, label: "Download", open: open)
            divider
            powerCell(s)
        }
        .padding(.vertical, 4)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator))
    }

    @ViewBuilder
    private func powerCell(_ s: Snapshot) -> some View {
        if let b = s.battery {
            let state = b.isCharging ? "Charging" : b.onBattery ? (b.timeRemaining.map { "\(Fmt.duration($0)) left" } ?? "On battery") : "On power adapter"
            VitalCell(metric: .power, title: "Battery", symbol: b.isCharging ? "battery.100percent.bolt" : "battery.75percent", color: Theme.Metric.battery,
                      value: (String(Int((b.charge * 100).rounded())), "%"),
                      detail: state + (b.onBattery ? b.watts.map { ", \(Fmt.watts($0))" } ?? "" : ""),
                      bars: live.power.elements, top: nil, format: Fmt.watts, label: "Power", open: open)
        } else {
            VitalCell(metric: .power, title: "Power", symbol: "bolt", color: Theme.Metric.battery,
                      value: splitUnit(Fmt.watts(live.power.last ?? 0)),
                      detail: "used by apps",
                      bars: live.power.elements, top: nil, format: Fmt.watts, label: "Power", open: open)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(width: 1).padding(.vertical, 14)
    }
}

private struct VitalCell: View {
    @Environment(LiveModel.self) private var live
    let metric: NowMetric
    let title: String
    let symbol: String
    let color: Color
    let value: (String, String)
    let detail: String
    var badge: AnyView? = nil
    let bars: [Double]
    let top: Double?
    let format: (Double) -> String
    var label = "Value"
    let open: (NowMetric) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.calloutV).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                if let badge { badge }
            }
            BigNumber(value: value.0, unit: value.1)
            Text(detail).font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1).monospacedDigit()
            LiveBars(values: bars, color: color, tick: live.tick, top: top, interval: live.isFast ? 1 : 5, format: format, label: label)
                .frame(height: 30)
                .padding(.top, 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.selected.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .onTapGesture { open(metric) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(metric) }
        .help("Show \(title) details")
    }
}
