import SwiftUI
import VardisClaude
import VardisCore
import VardisSampling

// MARK: CPU

struct CPUTile: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let onOpen: (() -> Void)?
    let openApp: (AppSample) -> Void

    var body: some View {
        let s = snapshot
        let load = NowFacts.load()
        NowCard(title: "CPU", symbol: "cpu", color: Theme.Metric.cpu, onOpen: onOpen) {
            CoreStrip(perCore: s.cpu.perCore, color: Theme.Metric.cpu)
                .frame(height: 64)
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Load, 1 min", value: String(format: "%.2f", load.one))
                Stat(label: "5 min", value: String(format: "%.2f", load.five))
                Stat(label: "15 min", value: String(format: "%.2f", load.fifteen))
            }
            if let top = s.apps.max(by: { $0.cpu < $1.cpu }) {
                AppValueRow(app: top, value: Fmt.percent(top.cpu), open: openApp).padding(.horizontal, -6)
            }
        }
    }
}

/// One thin bar per logical core, efficiency and performance cores labelled as separate groups.
struct CoreStrip: View {
    let perCore: [Double]
    let color: Color
    @State private var hover: Int?

    var body: some View {
        let layout = NowFacts.cores
        let groups: [(String, Range<Int>)] = layout.efficiency > 0 && perCore.count == layout.total
            ? [("Efficiency", 0..<layout.efficiency), ("Performance", layout.efficiency..<perCore.count)]
            : [("Cores", 0..<perCore.count)]
        HStack(alignment: .bottom, spacing: 18) {
            ForEach(groups, id: \.0) { name, range in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(range), id: \.self) { i in
                            bar(i, perCore[i], tint: name == "Efficiency" ? color.opacity(0.6) : color)
                        }
                    }
                    let hovered = hover.flatMap { range.contains($0) ? $0 : nil }
                    Text(hovered.map { "Core \($0 + 1): \(Fmt.percent(perCore[$0]))" } ?? "\(name), \(range.count) cores")
                        .font(.captionV).foregroundStyle(Theme.textTertiary).monospacedDigit().lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func bar(_ i: Int, _ v: Double, tint: Color) -> some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint)
                    .frame(height: max(2, g.size.height * min(1, max(0, v))))
            }
            .frame(maxWidth: .infinity)
            .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 2, style: .continuous))
            .motion(Motion.value, value: v)
        }
        .frame(width: perCore.count > 16 ? 6 : 12)
        .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
        .help("Core \(i + 1): \(Fmt.percent(v))")
        .accessibilityElement()
        .accessibilityLabel("Core \(i + 1)")
        .accessibilityValue(Fmt.percent(v))
    }
}

// MARK: Memory

struct MemoryTile: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let onOpen: (() -> Void)?
    let openApp: (AppSample) -> Void

    var body: some View {
        let m = snapshot.memory
        NowCard(title: "Memory", symbol: "memorychip", color: Theme.Metric.memory, onOpen: onOpen) {
            PressureGauge(pressure: m.pressure)
            MemoryBar(memory: m).frame(height: 10)
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "App", value: Fmt.bytes(m.app), swatch: Theme.Metric.memory)
                Stat(label: "Wired", value: Fmt.bytes(m.wired), swatch: Theme.Metric.memory.opacity(0.72))
                Stat(label: "Compressed", value: Fmt.bytes(m.compressed), swatch: Theme.Metric.memory.opacity(0.5))
            }
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Cached", value: Fmt.bytes(m.cached), swatch: Theme.Metric.memory.opacity(0.28))
                Stat(label: "Free", value: Fmt.bytes(m.free), swatch: Theme.raised)
                Stat(label: "Swap", value: Fmt.bytes(m.swapUsed) + swapTrend,
                     tint: (NowFacts.trend(live.swap.elements) ?? 0) > 0 ? Theme.orange : Theme.text)
            }
            if let top = snapshot.apps.first {
                AppValueRow(app: top, value: Fmt.bytes(top.memory), open: openApp).padding(.horizontal, -6)
            }
        }
    }

    private var swapTrend: String {
        guard let d = NowFacts.trend(live.swap.elements) else { return "" }
        return d > 0 ? " \u{2191}" : " \u{2193}"
    }
}

/// Three-step gauge with the current level marked and named.
struct PressureGauge: View {
    let pressure: MemoryPressure

    var body: some View {
        let level = pressure == .normal ? 0 : pressure == .warning ? 1 : 2
        let colors = [Theme.green, Theme.orange, Theme.red]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pressure").font(.captionV).foregroundStyle(Theme.textTertiary)
                Spacer()
                PressureLabel(pressure: pressure)
            }
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(i <= level ? colors[level] : Theme.raised).frame(height: 5)
                }
            }
            .motion(Motion.value, value: level)
        }
        .help(NowFacts.pressureExplanation(pressure))
    }
}

/// App / wired / compressed / cached / free as one stacked bar.
struct MemoryBar: View {
    let memory: MemorySample

    static func parts(_ m: MemorySample) -> [(String, UInt64, Double)] {
        [("App", m.app, 1), ("Wired", m.wired, 0.72), ("Compressed", m.compressed, 0.5), ("Cached", m.cached, 0.28), ("Free", m.free, 0)]
    }

    var body: some View {
        let parts = Self.parts(memory)
        let total = max(1, parts.reduce(0) { $0 + Double($1.1) })
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(parts, id: \.0) { p in
                    Rectangle()
                        .fill(p.2 == 0 ? Theme.raised : Theme.Metric.memory.opacity(p.2))
                        .frame(width: max(0, (g.size.width - 8) * Double(p.1) / total))
                        .help("\(p.0): \(Fmt.bytes(p.1))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .motion(Motion.value, value: memory.used)
        }
    }
}

// MARK: Network

struct NetworkTile: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let onOpen: (() -> Void)?

    var body: some View {
        let n = snapshot.network
        NowCard(title: "Network", symbol: "network", color: Theme.Metric.network, onOpen: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Download", value: Fmt.rate(n.receivedBytesPerSecond))
                Stat(label: "Upload", value: Fmt.rate(n.sentBytesPerSecond))
            }
            LivePairChart(first: ("Download", Theme.Metric.network, live.networkIn.elements),
                          second: ("Upload", Theme.Metric.cpu, live.networkOut.elements),
                          interval: live.isFast ? 1 : 5, format: Fmt.rate)
                .frame(height: 64)
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Received since boot", value: Fmt.bytes(n.receivedTotal))
                Stat(label: "Sent since boot", value: Fmt.bytes(n.sentTotal))
            }
        }
    }
}

// MARK: Disk

struct DiskTile: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let onOpen: (() -> Void)?
    let openApp: (AppSample) -> Void

    var body: some View {
        let d = snapshot.disk
        let used = d.totalBytes > d.freeBytes ? Double(d.totalBytes - d.freeBytes) / Double(max(1, d.totalBytes)) : 0
        NowCard(title: "Disk", symbol: "internaldrive", color: Theme.Metric.disk, onOpen: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(value: splitUnit(Fmt.bytes(d.freeBytes)).0, unit: splitUnit(Fmt.bytes(d.freeBytes)).1, font: .numericL)
                    Text("free of \(Fmt.bytes(d.totalBytes))").font(.calloutV).foregroundStyle(Theme.textTertiary)
                }
                Meter(value: used, color: used > 0.9 ? Theme.orange : Theme.Metric.disk)
            }
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Read", value: Fmt.rate(d.readBytesPerSecond))
                Stat(label: "Write", value: Fmt.rate(d.writeBytesPerSecond))
            }
            LiveBars(values: live.diskWrite.elements, color: Theme.Metric.disk, tick: live.tick,
                     interval: live.isFast ? 1 : 5, format: Fmt.rate, label: "Write")
                .frame(height: 30)
            if let top = snapshot.apps.max(by: { $0.diskWriteBytesPerSecond < $1.diskWriteBytesPerSecond }), top.diskWriteBytesPerSecond > 0 {
                AppValueRow(app: top, value: Fmt.rate(top.diskWriteBytesPerSecond), open: openApp).padding(.horizontal, -6)
            }
        }
    }
}

// MARK: GPU

struct GPUTile: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let onOpen: (() -> Void)?

    var body: some View {
        let g = snapshot.gpu
        NowCard(title: "GPU", symbol: "square.stack.3d.up", color: Theme.Metric.gpu, onOpen: onOpen) {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value: String(Int(((g?.utilization ?? 0) * 100).rounded())), unit: "%", font: .numericL)
                Text(g?.name ?? "Graphics").font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            LiveBars(values: live.gpu.elements, color: Theme.Metric.gpu, tick: live.tick, top: 1,
                     interval: live.isFast ? 1 : 5, format: Fmt.percent, label: "GPU")
                .frame(height: 30)
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Memory in use", value: g?.memoryBytes.map(Fmt.bytes) ?? "\u{2013}")
                Stat(label: "Peak since launch", value: Fmt.percent(live.gpuPeak))
            }
        }
    }
}

// MARK: Power

struct PowerTile: View {
    @Environment(LiveModel.self) private var live
    let snapshot: Snapshot
    let onOpen: (() -> Void)?
    let openApp: (AppSample) -> Void

    var body: some View {
        let s = snapshot
        let total = max(0.0001, s.apps.reduce(0) { $0 + $1.energyWatts })
        let top = s.apps.sorted { $0.energyWatts > $1.energyWatts }.prefix(3)
        NowCard(title: s.battery == nil ? "Power by app" : "Battery", symbol: s.battery == nil ? "bolt" : "battery.75percent",
                color: Theme.Metric.battery, onOpen: onOpen) {
            if let b = s.battery {
                HStack(alignment: .top, spacing: 8) {
                    Stat(label: b.onBattery ? "Time left" : "Source", value: b.onBattery ? b.timeRemaining.map(Fmt.duration) ?? "Estimating" : b.isCharging ? "Charging" : "Adapter")
                    Stat(label: "Health", value: b.health.map(Fmt.percent) ?? "\u{2013}")
                    Stat(label: "Cycles", value: b.cycleCount.map(String.init) ?? "\u{2013}")
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(value: splitUnit(Fmt.watts(total)).0, unit: splitUnit(Fmt.watts(total)).1, font: .numericL)
                    Text("all apps").font(.calloutV).foregroundStyle(Theme.textTertiary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(top)) { app in
                    AppValueRow(app: app, value: Fmt.watts(app.energyWatts), share: app.energyWatts / total,
                                color: Theme.Metric.battery, open: openApp)
                }
            }
            .padding(.horizontal, -6)
        }
    }
}

// MARK: Claude

struct ClaudeTile: View {
    @Environment(ClaudeModel.self) private var claude
    let onOpen: (() -> Void)?

    /// Shown only when there is something to say: a plan limit or a running session.
    static func hasData(_ claude: ClaudeModel) -> Bool {
        claude.quota(claude.activeAccount)?.fiveHour != nil || !claude.live.isEmpty
    }

    var body: some View {
        let five = claude.quota(claude.activeAccount)?.fiveHour
        NowCard(title: "Claude Code", symbol: "sparkle", color: Theme.claude, onOpen: onOpen) {
            if let five {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        BigNumber(value: String(Int(five.utilization.rounded())), unit: "%", font: .numericL)
                        Text("of the 5-hour window").font(.calloutV).foregroundStyle(Theme.textTertiary)
                    }
                    Meter(value: five.utilization / 100, color: five.utilization >= 90 ? Theme.red : Theme.claude)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Stat(label: "Account", value: claude.activeAccount?.name ?? "\u{2013}")
                Stat(label: "Resets", value: five?.resetsAt.map { $0.formatted(.dateTime.hour().minute()) } ?? "\u{2013}")
                Stat(label: "Running", value: "\(claude.live.count)")
            }
        }
    }
}
