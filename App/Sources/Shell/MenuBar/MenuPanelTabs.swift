import SwiftUI
import VardisCore
import VardisSampling

// The panel's tabs. Every number comes from LiveModel (sampled while the panel is open),
// CleanupModel and ClaudeModel, read-only.

// MARK: - Overview

struct OverviewTab: View {
    let open: (Screen?) -> Void
    @Environment(LiveModel.self) private var live
    @Environment(ClaudeModel.self) private var claude
    private var prefs: MenuBarPrefs { .shared }

    private var tiles: [MenuTile] {
        let s = live.snapshot
        return prefs.enabledTiles.filter { t in
            switch t {
            case .gpu: s?.gpu != nil
            case .battery: s?.battery != nil
            case .claude: claude.supportsQuota && claude.quota(claude.activeAccount) != nil
            default: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Overview").font(.captionStrongV).foregroundStyle(Theme.textSecondary)
                Spacer()
                if let up = live.snapshot?.uptime {
                    Label("Up \(Self.uptime(up))", systemImage: "clock").font(.captionV).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 4)
            if !tiles.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(tiles) { t in OverviewTile(tile: t) }
                }
            }
            BusiestApps(open: open)
        }
    }

    /// "3d 4h", "5h 12m", "18m".
    static func uptime(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m >= 1440 { return "\(m / 1440)d \((m % 1440) / 60)h" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

private struct OverviewTile: View {
    let tile: MenuTile
    @Environment(LiveModel.self) private var live
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        let s = live.snapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: symbol(s)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                Text(tile.title).font(.captionStrongV).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                value(s)
                Spacer(minLength: 0)
                Text(caption(s)).font(.captionV).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize().layoutPriority(1)
            }
            Spacer(minLength: 6)
            footer(s).frame(height: 24)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(height: 100)
        .panelTile()
    }

    private var color: Color {
        switch tile {
        case .cpu: Theme.Metric.cpu
        case .memory: Theme.Metric.memory
        case .network: Theme.Metric.network
        case .disk: Theme.Metric.disk
        case .gpu: Theme.Metric.gpu
        case .battery: Theme.Metric.battery
        case .claude: Theme.claude
        }
    }

    private func symbol(_ s: Snapshot?) -> String {
        if tile == .battery, let b = s?.battery { return MenuBarFormat.batterySymbol(b) }
        return tile.symbol
    }

    @ViewBuilder private func value(_ s: Snapshot?) -> some View {
        switch tile {
        case .cpu: BigValue(s.map { Fmt.percent($0.cpu.total) } ?? "–")
        case .memory: BigValue(s.map { Fmt.bytes($0.memory.used) } ?? "–")
        case .network: BigValue(s.map { Fmt.rate($0.network.receivedBytesPerSecond) } ?? "–", prefix: "↓")
        case .disk: BigValue(s.map { Fmt.bytes($0.disk.freeBytes) } ?? "–")
        case .gpu: BigValue(s?.gpu.map { Fmt.percent($0.utilization) } ?? "–")
        case .battery: BigValue(s?.battery.map { Fmt.percent($0.charge) } ?? "–")
        case .claude: BigValue(ClaudeFmt.percent(claude.quota(claude.activeAccount)?.fiveHour?.utilization))
        }
    }

    private func caption(_ s: Snapshot?) -> String {
        guard let s else { return " " }
        switch tile {
        case .cpu:
            let l = NowFacts.load()
            return String(format: "load %.2f", l.one)
        case .memory: return "of \(Fmt.bytes(s.memory.total))"
        case .network: return "↑ " + Fmt.rate(s.network.sentBytesPerSecond)
        case .disk: return "free"
        case .gpu: return ""
        case .battery: return BatteryText.status(s.battery)
        case .claude:
            let w = claude.quota(claude.activeAccount)?.fiveHour
            let reset = ClaudeFmt.reset(w?.resetsAt)
            return reset.isEmpty ? "5-hour" : "resets \(reset)"
        }
    }

    @ViewBuilder private func footer(_ s: Snapshot?) -> some View {
        switch tile {
        case .cpu: AreaSparkline(values: live.cpu.elements, color: color, maxValue: 1)
        case .memory: AreaSparkline(values: live.memory.elements, color: color, maxValue: 1)
        case .network: AreaSparkline(values: live.networkIn.elements, color: color, secondary: live.networkOut.elements, secondaryColor: Theme.textTertiary)
        case .gpu: AreaSparkline(values: live.gpu.elements, color: color, maxValue: 1)
        case .disk:
            let used = s.map { 1 - Double($0.disk.freeBytes) / Double(max(1, $0.disk.totalBytes)) } ?? 0
            VStack { Spacer(); Meter(value: used, color: color) }
        case .battery: VStack { Spacer(); Meter(value: s?.battery?.charge ?? 0, color: color) }
        case .claude: VStack { Spacer(); Meter(value: (claude.quota(claude.activeAccount)?.fiveHour?.utilization ?? 0) / 100, color: color) }
        }
    }
}

/// "21.4 GB" with the unit smaller and secondary.
private struct BigValue: View {
    let text: String
    var prefix: String?
    var suffix: String?

    init(_ text: String, prefix: String? = nil, suffix: String? = nil) {
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
    }

    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if let prefix { Text(prefix).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textSecondary) }
            Text(parts.first ?? text).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            if parts.count > 1 { Text(parts[1]).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary) }
            if let suffix { Text(suffix).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textTertiary).padding(.leading, 2) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
}

enum BatteryText {
    static func status(_ b: BatterySample?) -> String {
        guard let b else { return " " }
        if b.isCharging {
            if let t = b.timeRemaining, t > 0 { return "Full in \(Fmt.duration(t).replacingOccurrences(of: " s", with: ""))" }
            return "Charging"
        }
        if b.onBattery {
            if let t = b.timeRemaining, t > 0 { return "\(shortDuration(t)) left" }
            return "On battery"
        }
        return b.charge >= 0.99 ? "Charged" : "On power adapter"
    }

    static func shortDuration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) m"
    }
}

/// Top three apps by CPU, with a bar each.
private struct BusiestApps: View {
    let open: (Screen?) -> Void
    @Environment(LiveModel.self) private var live

    var body: some View {
        let apps = (live.snapshot?.apps ?? []).sorted { $0.cpu > $1.cpu }.prefix(3)
        // Bars compare apps with each other; a floor keeps a quiet Mac's bars short.
        let scale = max(apps.first?.cpu ?? 0, 0.1)
        VStack(alignment: .leading, spacing: 2) {
            Text("Busiest right now").font(.calloutV).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6).padding(.bottom, 4)
            if apps.isEmpty {
                Text("Measuring…").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.horizontal, 6).padding(.vertical, 6)
            }
            ForEach(Array(apps)) { app in
                AppMeterRow(app: app, fraction: app.cpu / scale, value: Fmt.percent(app.cpu), color: Theme.Metric.cpu) { open(.apps) }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelTile()
    }
}

/// App icon, name, a bar and its value. Click opens the matching screen.
struct AppMeterRow: View {
    let app: AppSample
    let fraction: Double
    let value: String
    let color: Color
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 9) {
                AppIconView(bundleURL: app.bundleURL, name: app.name, size: 20)
                Text(app.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Meter(value: fraction, color: color).frame(width: 64)
                Text(value).font(.numeric).foregroundStyle(Theme.text).lineLimit(1).frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 6).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight(cornerRadius: 8))
    }
}

/// Big number with a label, for tab headers.
private struct TabHeader<Trailing: View>: View {
    let label: String
    let value: String
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.captionStrongV).foregroundStyle(Theme.textSecondary)
                Text(value).font(.numericL).foregroundStyle(Theme.text).contentTransition(.numericText())
                if let caption { Text(caption).font(.captionV).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            trailing
        }
    }
}

extension TabHeader where Trailing == EmptyView {
    init(label: String, value: String, caption: String? = nil) {
        self.init(label: label, value: value, caption: caption) { EmptyView() }
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 8, height: 8) }
            Text(key).font(.calloutV).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.numeric).foregroundStyle(Theme.text)
        }
        .frame(height: 20)
    }
}

// MARK: - CPU

struct CPUTab: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let s = live.snapshot
        let l = NowFacts.load()
        VStack(alignment: .leading, spacing: 12) {
            TabHeader(label: "CPU", value: s.map { Fmt.percent($0.cpu.total) } ?? "–",
                      caption: s.map { "User \(Fmt.percent($0.cpu.user)) · System \(Fmt.percent($0.cpu.system))" }) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Load average").font(.captionV).foregroundStyle(Theme.textTertiary)
                    Text(String(format: "%.2f  %.2f  %.2f", l.one, l.five, l.fifteen)).font(.numeric).foregroundStyle(Theme.textSecondary)
                }
            }
            AreaSparkline(values: live.cpu.elements, color: Theme.Metric.cpu, maxValue: 1)
                .frame(height: 44).padding(8).panelTile()
            if let s { CoreBars(perCore: s.cpu.perCore) }
            TopApps(title: "Top apps by CPU", apps: Array((s?.apps ?? []).sorted { $0.cpu > $1.cpu }.prefix(5)),
                    fraction: { $0.cpu }, value: { Fmt.percent($0.cpu) }, color: Theme.Metric.cpu, floor: 0.1)
        }
    }
}

/// Per-core load, efficiency and performance cores apart.
private struct CoreBars: View {
    let perCore: [Double]

    var body: some View {
        let layout = NowFacts.cores
        let e = layout.efficiency > 0 ? Array(perCore.prefix(layout.efficiency)) : []
        let p = layout.efficiency > 0 ? Array(perCore.dropFirst(layout.efficiency)) : perCore
        HStack(alignment: .top, spacing: 10) {
            if !e.isEmpty { group("Efficiency", e).frame(maxWidth: .infinity) }
            group(e.isEmpty ? "Cores" : "Performance", p).frame(maxWidth: .infinity)
        }
        .padding(10)
        .panelTile()
    }

    private func group(_ title: String, _ values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading(title, trailing: values.isEmpty ? nil : Fmt.percent(values.reduce(0, +) / Double(values.count)))
            Canvas(rendersAsynchronously: false) { ctx, size in
                guard !values.isEmpty else { return }
                let gap: CGFloat = 3
                let w = max(2, (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * (w + gap)
                    let track = CGRect(x: x, y: 0, width: w, height: size.height)
                    ctx.fill(Path(roundedRect: track, cornerRadius: min(2.5, w / 2)), with: .color(Theme.raised))
                    let h = max(2, size.height * CGFloat(min(1, max(0, v))))
                    let bar = CGRect(x: x, y: size.height - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: min(2.5, w / 2)), with: .color(Theme.Metric.cpu.opacity(title == "Efficiency" ? 0.7 : 1)))
                }
            }
            .frame(height: 38)
        }
    }
}

private struct TopApps: View {
    let title: String
    let apps: [AppSample]
    let fraction: (AppSample) -> Double
    let value: (AppSample) -> String
    let color: Color
    var empty = "Measuring…"
    /// Bars are relative to the list's top value, but never to less than this.
    var floor: Double = 0

    var body: some View {
        let scale = max(apps.map(fraction).max() ?? 0, floor, 0.000_001)
        VStack(alignment: .leading, spacing: 2) {
            PanelHeading(title).padding(.horizontal, 2).padding(.bottom, 2)
            if apps.isEmpty { Text(empty).font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.horizontal, 2).padding(.vertical, 6) }
            ForEach(apps) { a in AppMeterRow(app: a, fraction: fraction(a) / scale, value: value(a), color: color) }
        }
    }
}

// MARK: - Memory

struct MemoryTab: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let s = live.snapshot
        VStack(alignment: .leading, spacing: 12) {
            TabHeader(label: "Memory", value: s.map { Fmt.bytes($0.memory.used) } ?? "–", caption: s.map { "of \(Fmt.bytes($0.memory.total))" }) {
                if let s { pressure(s.memory.pressure) }
            }
            if let m = s?.memory {
                VStack(alignment: .leading, spacing: 8) {
                    SegmentBar(segments: [
                        .init(id: "app", value: Double(m.app), color: Theme.Metric.memory),
                        .init(id: "wired", value: Double(m.wired), color: Theme.Metric.memory.opacity(0.65)),
                        .init(id: "compressed", value: Double(m.compressed), color: Theme.Metric.memory.opacity(0.38)),
                        .init(id: "rest", value: Double(m.total > m.used ? m.total - m.used : 0), color: .clear),
                    ], height: 8)
                    Grid(horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            KeyValueRow(key: "App", value: Fmt.bytes(m.app), dot: Theme.Metric.memory)
                            KeyValueRow(key: "Wired", value: Fmt.bytes(m.wired), dot: Theme.Metric.memory.opacity(0.65))
                        }
                        GridRow {
                            KeyValueRow(key: "Compressed", value: Fmt.bytes(m.compressed), dot: Theme.Metric.memory.opacity(0.38))
                            KeyValueRow(key: "Swap", value: Fmt.bytes(m.swapUsed), dot: Theme.textTertiary)
                        }
                    }
                    AreaSparkline(values: live.memory.elements, color: Theme.Metric.memory, maxValue: 1).frame(height: 30)
                }
                .padding(10)
                .panelTile()
            }
            TopApps(title: "Top apps by memory", apps: Array((s?.apps ?? []).sorted { $0.memory > $1.memory }.prefix(5)),
                    fraction: { Double($0.memory) }, value: { Fmt.bytes($0.memory) }, color: Theme.Metric.memory)
        }
    }

    private func pressure(_ p: MemoryPressure) -> some View {
        switch p {
        case .normal: Badge("Pressure normal", tone: .green)
        case .warning: Badge("Pressure high", tone: .orange)
        case .critical: Badge("Pressure critical", tone: .red)
        }
    }
}

// MARK: - Disk

struct DiskTab: View {
    let open: (Screen?) -> Void
    @Environment(LiveModel.self) private var live
    @Environment(CleanupModel.self) private var cleanup

    var body: some View {
        let s = live.snapshot
        let writers = (s?.apps ?? []).filter { $0.diskWriteBytesPerSecond >= 1000 }.sorted { $0.diskWriteBytesPerSecond > $1.diskWriteBytesPerSecond }.prefix(5)
        VStack(alignment: .leading, spacing: 12) {
            TabHeader(label: "Disk", value: s.map { Fmt.bytes($0.disk.freeBytes) + " free" } ?? "–", caption: s.map { "of \(Fmt.bytes($0.disk.totalBytes))" })
            if let d = s?.disk {
                Meter(value: 1 - Double(d.freeBytes) / Double(max(1, d.totalBytes)), color: Theme.Metric.disk)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        KeyValueRow(key: "Write", value: Fmt.rate(d.writeBytesPerSecond), dot: Theme.Metric.disk)
                        Spacer(minLength: 16)
                        KeyValueRow(key: "Read", value: Fmt.rate(d.readBytesPerSecond), dot: Theme.textTertiary)
                    }
                    AreaSparkline(values: live.diskWrite.elements, color: Theme.Metric.disk, secondary: live.diskRead.elements, secondaryColor: Theme.textTertiary)
                        .frame(height: 34)
                }
                .padding(10)
                .panelTile()
            }
            TopApps(title: "Writing the most", apps: Array(writers), fraction: { $0.diskWriteBytesPerSecond },
                    value: { Fmt.rate($0.diskWriteBytesPerSecond) }, color: Theme.Metric.disk, empty: "Nothing is writing much right now.")
            let ready = cleanup.defaultReclaimable
            if ready > 0 {
                Button { open(.diskCleanup) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.Metric.disk)
                        Text("\(Fmt.bytes(ready)) ready in Disk Cleanup").font(.bodyV).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                }
                .buttonStyle(PanelButtonStyle())
            }
        }
    }
}

// MARK: - Network

struct NetworkTab: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let n = live.snapshot?.network
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                rate("Download", "arrow.down", n?.receivedBytesPerSecond, Theme.Metric.network)
                Spacer()
                rate("Upload", "arrow.up", n?.sentBytesPerSecond, Theme.textSecondary)
            }
            AreaSparkline(values: live.networkIn.elements, color: Theme.Metric.network, secondary: live.networkOut.elements, secondaryColor: Theme.textTertiary)
                .frame(height: 64).padding(8).panelTile()
            if let n {
                VStack(spacing: 0) {
                    PanelHeading("Since the Mac started").padding(.bottom, 4)
                    KeyValueRow(key: "Downloaded", value: Fmt.bytes(n.receivedTotal), dot: Theme.Metric.network)
                    KeyValueRow(key: "Uploaded", value: Fmt.bytes(n.sentTotal), dot: Theme.textTertiary)
                }
                .padding(10)
                .panelTile()
            }
        }
    }

    private func rate(_ label: String, _ symbol: String, _ v: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(label, systemImage: symbol).font(.captionStrongV).foregroundStyle(color)
            Text(v.map(Fmt.rate) ?? "–").font(.numericL).foregroundStyle(Theme.text).contentTransition(.numericText())
        }
    }
}

// MARK: - GPU

struct GPUTab: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let g = live.snapshot?.gpu
        VStack(alignment: .leading, spacing: 12) {
            TabHeader(label: "GPU", value: g.map { Fmt.percent($0.utilization) } ?? "–", caption: g?.name) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Peak since launch").font(.captionV).foregroundStyle(Theme.textTertiary)
                    Text(Fmt.percent(live.gpuPeak)).font(.numeric).foregroundStyle(Theme.textSecondary)
                }
            }
            AreaSparkline(values: live.gpu.elements, color: Theme.Metric.gpu, maxValue: 1)
                .frame(height: 64).padding(8).panelTile()
            if let m = g?.memoryBytes, m > 0 {
                KeyValueRow(key: "GPU memory in use", value: Fmt.bytes(m)).padding(.horizontal, 10).padding(.vertical, 6).panelTile()
            }
        }
    }
}

// MARK: - Battery & power

struct BatteryTab: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let s = live.snapshot
        let b = s?.battery
        let apps = (s?.apps ?? []).filter { $0.energyWatts > 0.05 }.sorted { $0.energyWatts > $1.energyWatts }.prefix(5)
        VStack(alignment: .leading, spacing: 12) {
            TabHeader(label: "Battery", value: b.map { Fmt.percent($0.charge) } ?? "–", caption: BatteryText.status(b)) {
                if let b { Image(systemName: MenuBarFormat.batterySymbol(b)).font(.system(size: 26, weight: .regular)).foregroundStyle(Theme.Metric.battery) }
            }
            if let b {
                Meter(value: b.charge, color: Theme.Metric.battery)
                VStack(spacing: 0) {
                    if let w = b.watts, b.onBattery { KeyValueRow(key: "Drawing", value: Fmt.watts(w)) }
                    if let c = b.cycleCount { KeyValueRow(key: "Cycle count", value: "\(c)") }
                    if let h = b.health { KeyValueRow(key: "Health", value: Fmt.percent(h)) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .panelTile()
            }
            TopApps(title: "Power by app", apps: Array(apps), fraction: { $0.energyWatts }, value: { Fmt.watts($0.energyWatts) },
                    color: Theme.Metric.battery, empty: "No app is using much power.")
        }
    }
}

// MARK: - Claude Code

struct ClaudeTab: View {
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        let active = claude.activeAccount
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Theme.claude)
                Text(active?.name ?? "Claude Code").font(.headlineV).foregroundStyle(Theme.text)
                if let plan = active?.plan { Badge(plan, tone: .claude) }
                Spacer()
                Text("\(claude.live.count) running").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 10) {
                if claude.supportsQuota {
                    if let q = claude.quota(active) {
                        QuotaMeterView(window: q.fiveHour, color: Theme.claude, label: "5-hour")
                        QuotaMeterView(window: q.sevenDay, color: Theme.textSecondary, label: "Weekly")
                    } else {
                        Text(claude.quotas[active?.id ?? ""]?.problem ?? "Checking plan limits…").font(.captionV).foregroundStyle(Theme.textTertiary)
                    }
                    let rules = ClaudeModel.Rules.current
                    if let next = claude.nextAccount(rules: rules) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                            Text("Next: \(next.name), at \(ClaudeFmt.percent(claude.quota(next)?.fiveHour?.utilization))")
                            if rules.enabled { Text("· switches at \(Int(rules.fiveHour))%") }
                        }
                        .font(.captionV).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("Plan limits need the direct download from vardis.app.").font(.captionV).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .panelTile()
            VStack(alignment: .leading, spacing: 2) {
                PanelHeading("Sessions").padding(.horizontal, 2).padding(.bottom, 2)
                if claude.live.isEmpty {
                    Text("None running").font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.horizontal, 2).padding(.vertical, 6)
                }
                ForEach(claude.live.prefix(5)) { s in
                    let status = LiveStatusText(s)
                    HStack(spacing: 8) {
                        Circle().fill(status.dot).frame(width: 7, height: 7)
                        Text(s.projectName).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(status.text).font(.captionV).foregroundStyle(status.color).lineLimit(1)
                        Text(Fmt.percent(s.activity.contextFraction)).font(.numeric).foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 6).frame(height: 28)
                }
            }
        }
    }
}
