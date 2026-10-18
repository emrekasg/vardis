import SwiftUI
import VardisCore

struct NowView: View {
    @Environment(LiveModel.self) private var live

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LiveStrip()
                if let s = live.snapshot {
                    LazyVGrid(columns: columns, spacing: 12) {
                        cpuTile(s)
                        memoryTile(s)
                        gpuTile(s)
                        diskTile(s)
                        networkTile(s)
                        batteryTile(s)
                        processesTile(s)
                        energyTile(s)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        MemoryByTypePanel(memory: s.memory)
                        MemoryByAppPanel(apps: s.apps, memory: s.memory)
                        PowerByAppPanel(apps: s.apps)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.surface)
    }

    // MARK: Tiles

    private func cpuTile(_ s: Snapshot) -> some View {
        MetricTile(title: "CPU", symbol: "cpu", color: Theme.Metric.cpu,
                   context: "Now · \(s.cpu.perCore.count) cores",
                   value: "\(Int((s.cpu.total * 100).rounded()))", unit: "%",
                   stats: [("User", Fmt.percent(s.cpu.user)), ("System", Fmt.percent(s.cpu.system)), ("Avg", Fmt.percent(live.cpuAverage))],
                   history: live.cpu.elements, top: top(s.apps, by: \.cpu).map { ($0, Fmt.percent($0.cpu)) })
    }

    private func memoryTile(_ s: Snapshot) -> some View {
        let m = s.memory
        let parts = Fmt.bytes(m.used).split(separator: " ")
        return MetricTile(title: "Memory", symbol: "memorychip", color: Theme.Metric.memory,
                          context: "In use of \(Fmt.bytes(m.total))",
                          value: String(parts.first ?? ""), unit: String(parts.last ?? ""),
                          badge: pressureBadge(m.pressure),
                          stats: [("App", Fmt.bytes(m.app)), ("Wired", Fmt.bytes(m.wired)), ("Compressed", Fmt.bytes(m.compressed))],
                          history: live.memory.elements, top: s.apps.first.map { ($0, Fmt.bytes($0.memory)) })
    }

    private func gpuTile(_ s: Snapshot) -> some View {
        MetricTile(title: "GPU", symbol: "square.stack.3d.up", color: Theme.Metric.gpu,
                   context: s.gpu?.name ?? "Graphics",
                   value: s.gpu.map { "\(Int(($0.utilization * 100).rounded()))" } ?? "–", unit: "%",
                   stats: [("Memory", s.gpu?.memoryBytes.map(Fmt.bytes) ?? "–"), ("Peak", Fmt.percent(live.gpuPeak)), ("", "")],
                   history: live.gpu.elements, top: nil)
    }

    private func diskTile(_ s: Snapshot) -> some View {
        let parts = Fmt.bytes(s.disk.freeBytes).split(separator: " ")
        return MetricTile(title: "Disk", symbol: "internaldrive", color: Theme.Metric.disk,
                          context: "Free of \(Fmt.bytes(s.disk.totalBytes))",
                          value: String(parts.first ?? ""), unit: String(parts.last ?? ""),
                          stats: [("Read", Fmt.rate(s.disk.readBytesPerSecond)), ("Write", Fmt.rate(s.disk.writeBytesPerSecond)), ("", "")],
                          history: live.diskWrite.normalized, top: top(s.apps, by: \.diskWriteBytesPerSecond).map { ($0, Fmt.rate($0.diskWriteBytesPerSecond)) })
    }

    private func networkTile(_ s: Snapshot) -> some View {
        let parts = Fmt.rate(s.network.receivedBytesPerSecond).split(separator: " ")
        return MetricTile(title: "Network", symbol: "globe", color: Theme.Metric.network,
                          context: "Downloading",
                          value: String(parts.first ?? ""), unit: String(parts.last ?? ""),
                          stats: [("Uploading", Fmt.rate(s.network.sentBytesPerSecond)), ("Received", Fmt.bytes(s.network.receivedTotal)), ("Sent", Fmt.bytes(s.network.sentTotal))],
                          history: live.networkIn.normalized, top: nil)
    }

    @ViewBuilder
    private func batteryTile(_ s: Snapshot) -> some View {
        if let b = s.battery {
            MetricTile(title: "Battery", symbol: "battery.75percent", color: Theme.Metric.battery,
                       context: b.isCharging ? "Charging" : (b.onBattery ? "On battery" : "On power adapter"),
                       value: "\(Int((b.charge * 100).rounded()))", unit: "%",
                       stats: [("Remaining", b.timeRemaining.map(Fmt.duration) ?? "–"), ("Draw", b.watts.map(Fmt.watts) ?? "–"), ("Health", b.health.map(Fmt.percent) ?? "–")],
                       history: live.battery.elements, top: top(s.apps, by: \.energyWatts).map { ($0, Fmt.watts($0.energyWatts)) })
        } else {
            MetricTile(title: "Power", symbol: "bolt", color: Theme.Metric.battery,
                       context: "All apps", value: String(format: "%.1f", s.apps.reduce(0) { $0 + $1.energyWatts }), unit: "W",
                       stats: [("", ""), ("", ""), ("", "")], history: nil,
                       top: top(s.apps, by: \.energyWatts).map { ($0, Fmt.watts($0.energyWatts)) })
        }
    }

    private func processesTile(_ s: Snapshot) -> some View {
        MetricTile(title: "Processes", symbol: "square.grid.2x2", color: Theme.Metric.ane,
                   context: "Grouped into apps", value: "\(s.apps.count)", unit: "apps",
                   stats: [("Processes", "\(s.processCount)"), ("Swap", Fmt.bytes(s.memory.swapUsed)), ("Uptime", Fmt.duration(s.uptime))],
                   history: nil, top: nil)
    }

    private func energyTile(_ s: Snapshot) -> some View {
        MetricTile(title: "Vardis", symbol: "gauge.with.needle", color: Theme.Metric.agents,
                   context: "Measuring itself", value: Fmt.bytes(live.ownFootprint).split(separator: " ").first.map(String.init) ?? "", unit: "MB",
                   stats: [("Last sample", String(format: "%.1f ms", live.lastSampleDuration.milliseconds)), ("Interval", live.isFast ? "1 s" : "5 s"), ("", "")],
                   history: nil, top: nil)
    }

    private func top(_ apps: [AppSample], by key: KeyPath<AppSample, Double>) -> AppSample? {
        apps.max { $0[keyPath: key] < $1[keyPath: key] }
    }

    private func pressureBadge(_ p: MemoryPressure) -> (String, BadgeTone) {
        switch p {
        case .normal: ("Normal", .green)
        case .warning: ("Warning", .orange)
        case .critical: ("Critical", .red)
        }
    }
}

private struct LiveStrip: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(live.isPaused ? Theme.textTertiary : Theme.green).frame(width: 8, height: 8)
            Text(live.isPaused ? "Paused" : "Live").font(.headlineV).foregroundStyle(Theme.text)
            Text("updates every \(live.isFast ? "second" : "5 seconds")").font(.calloutV).foregroundStyle(Theme.textTertiary)
            Spacer()
            if let s = live.snapshot {
                Text("Uptime \(Fmt.duration(s.uptime))").font(.calloutV).foregroundStyle(Theme.textSecondary)
            }
            Button(live.isPaused ? "Resume" : "Pause") { live.isPaused.toggle() }
                .keyboardShortcut(.space, modifiers: .option)
        }
        .padding(.horizontal, 4)
    }
}

struct MetricTile: View {
    let title: String
    let symbol: String
    let color: Color
    let context: String
    let value: String
    let unit: String
    var badge: (String, BadgeTone)? = nil
    let stats: [(String, String)]
    let history: [Double]?
    let top: (AppSample, String)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(systemName: symbol, color: color)
                Text(title).font(.headlineV).foregroundStyle(Theme.text)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(context).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.numericXL).foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                        .motion(Motion.value, value: value)
                    Text(unit).font(.headlineV).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let badge { Badge(badge.0, tone: badge.1) }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, st in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(st.0).font(.captionV).foregroundStyle(Theme.textTertiary)
                        Text(st.1).font(.numeric).foregroundStyle(Theme.text).lineLimit(1)
                            .contentTransition(.numericText())
                            .motion(Motion.value, value: st.1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let history {
                BarHistory(values: history, color: color)
                    .frame(height: 40)
                    .padding(6)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let top {
                HStack(spacing: 6) {
                    Text("Top").font(.captionV).foregroundStyle(Theme.textTertiary)
                    AppIconView(bundleURL: top.0.bundleURL, name: top.0.name, size: 14)
                    Text(top.0.name).font(.calloutV).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(top.1).font(.numeric).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Theme.textTertiary.opacity(0.35) : Theme.separator))
        .shadow(color: .black.opacity(hovering ? 0.06 : 0), radius: 10, y: 4)
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
    }
}

// MARK: Panels

private struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconTile(systemName: symbol, color: color)
                Text(title).font(.headlineV).foregroundStyle(Theme.text)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator))
    }
}

private struct DonutLegendPanel: View {
    let title: String
    let symbol: String
    let color: Color
    let center: String
    let caption: String
    let rows: [(String, Double, String)]

    var body: some View {
        Panel(title: title, symbol: symbol, color: color) {
            HStack(spacing: 20) {
                let opacities = [1.0, 0.72, 0.5, 0.32]
                let slices = rows.enumerated().map { i, r in
                    DonutSlice(id: r.0, value: r.1, color: i < rows.count - 1 ? color.opacity(opacities[min(i, 3)]) : Theme.raised)
                }
                ZStack {
                    Donut(slices: slices)
                    VStack(spacing: 0) {
                        Text(center).font(.numericL).foregroundStyle(Theme.text)
                        Text(caption).font(.captionV).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 120, height: 120)
                VStack(spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(slices[i].color).frame(width: 8, height: 8)
                            Text(r.0).font(.calloutV).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(r.2).font(.numeric).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

private struct MemoryByTypePanel: View {
    let memory: MemorySample
    var body: some View {
        let m = memory
        DonutLegendPanel(title: "Memory by type", symbol: "memorychip", color: Theme.Metric.memory,
                         center: Fmt.percent(m.total > 0 ? Double(m.used) / Double(m.total) : 0), caption: "in use",
                         rows: [("App", Double(m.app), Fmt.bytes(m.app)), ("Wired", Double(m.wired), Fmt.bytes(m.wired)),
                                ("Compressed", Double(m.compressed), Fmt.bytes(m.compressed)), ("Cached", Double(m.cached), Fmt.bytes(m.cached)),
                                ("Free", Double(m.free), Fmt.bytes(m.free))])
    }
}

private struct MemoryByAppPanel: View {
    let apps: [AppSample]
    let memory: MemorySample
    var body: some View {
        let top = Array(apps.prefix(4))
        let rest = apps.dropFirst(4).reduce(UInt64(0)) { $0 + $1.memory }
        let all = apps.reduce(UInt64(0)) { $0 + $1.memory }
        DonutLegendPanel(title: "Memory by app", symbol: "square.grid.2x2", color: Theme.Metric.memory,
                         center: Fmt.bytes(all), caption: "all apps",
                         rows: top.map { ($0.name, Double($0.memory), Fmt.bytes($0.memory)) } + [("Other", Double(rest), Fmt.bytes(rest))])
    }
}

private struct PowerByAppPanel: View {
    let apps: [AppSample]
    var body: some View {
        let sorted = apps.sorted { $0.energyWatts > $1.energyWatts }
        let top = Array(sorted.prefix(4))
        let rest = sorted.dropFirst(4).reduce(0) { $0 + $1.energyWatts }
        let all = sorted.reduce(0) { $0 + $1.energyWatts }
        DonutLegendPanel(title: "Power by app", symbol: "bolt", color: Theme.Metric.battery,
                         center: Fmt.watts(all), caption: "all apps",
                         rows: top.map { ($0.name, $0.energyWatts, Fmt.watts($0.energyWatts)) } + [("Other", rest, Fmt.watts(rest))])
    }
}
