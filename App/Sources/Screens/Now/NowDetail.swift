import SwiftUI
import VardisCore
import VardisSampling
import VardisStore

/// The drawer behind every Now tile: live minute, last hour or day from history, top apps, facts.
struct NowDetailPanel: View {
    @Environment(LiveModel.self) private var live
    @Environment(HistoryModel.self) private var history
    let metric: NowMetric
    let openApp: (AppSample) -> Void

    @State private var range: HistoryRange = .hour
    @State private var past: [HistorySeries] = []
    @State private var swapPast = HistorySeries()

    enum HistoryRange: String, CaseIterable, Identifiable {
        case hour = "Last hour", day = "Last 24 hours"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .hour ? 3_600 : 86_400 }
        var timeFormat: Date.FormatStyle { .dateTime.hour().minute() }
    }

    var body: some View {
        ScrollView {
            if let s = live.snapshot {
                VStack(alignment: .leading, spacing: 22) {
                    header(s)
                    section("Last minute") { liveChart(s).frame(height: 110) }
                    if !historyMetrics(s).isEmpty { historySection(s) }
                    if metric == .memory, !swapPast.isEmpty {
                        section("Swap, \(range.rawValue.lowercased())") {
                            TimeChart(times: swapPast.times, series: [ChartSeries(id: "Swap", color: Theme.orange, values: swapPast.values)],
                                      format: { Fmt.bytes(double: $0) })
                                .frame(height: 70)
                        }
                    }
                    topApps(s)
                    section("Details") { VStack(spacing: 0) { facts(s) } }
                }
                .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 2)
            }
        }
        .task(id: "\(range.rawValue)-\(live.snapshot != nil)") { await loadHistory() }
    }

    // MARK: Header

    private var title: String {
        switch metric {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .power: live.snapshot?.battery == nil ? "Power" : "Battery"
        }
    }

    private var symbol: String {
        switch metric {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .gpu: "square.stack.3d.up"
        case .power: "bolt"
        }
    }

    private var color: Color {
        switch metric {
        case .cpu: Theme.Metric.cpu
        case .memory: Theme.Metric.memory
        case .network: Theme.Metric.network
        case .disk: Theme.Metric.disk
        case .gpu: Theme.Metric.gpu
        case .power: Theme.Metric.battery
        }
    }

    private func headline(_ s: Snapshot) -> (String, String, String) {
        switch metric {
        case .cpu: (Fmt.percent(s.cpu.total).replacingOccurrences(of: "%", with: ""), "%", "across \(s.cpu.perCore.count) cores")
        case .memory: (splitUnit(Fmt.bytes(s.memory.used)).0, splitUnit(Fmt.bytes(s.memory.used)).1, "in use of \(Fmt.bytes(s.memory.total))")
        case .network: (splitUnit(Fmt.rate(s.network.receivedBytesPerSecond)).0, splitUnit(Fmt.rate(s.network.receivedBytesPerSecond)).1,
                        "down, \(Fmt.rate(s.network.sentBytesPerSecond)) up")
        case .disk: (splitUnit(Fmt.bytes(s.disk.freeBytes)).0, splitUnit(Fmt.bytes(s.disk.freeBytes)).1, "free of \(Fmt.bytes(s.disk.totalBytes))")
        case .gpu: (String(Int(((s.gpu?.utilization ?? 0) * 100).rounded())), "%", s.gpu?.name ?? "Graphics")
        case .power:
            if let b = s.battery { (String(Int((b.charge * 100).rounded())), "%", b.isCharging ? "Charging" : b.onBattery ? "On battery" : "On power adapter") }
            else { (splitUnit(Fmt.watts(live.power.last ?? 0)).0, splitUnit(Fmt.watts(live.power.last ?? 0)).1, "used by apps") }
        }
    }

    private func header(_ s: Snapshot) -> some View {
        let h = headline(s)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconTile(systemName: symbol, color: color, size: 24)
                Text(title).font(.titleV).foregroundStyle(Theme.text)
                if metric == .memory { PressureLabel(pressure: s.memory.pressure) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BigNumber(value: h.0, unit: h.1)
                Text(h.2).font(.calloutV).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Charts

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headlineV).foregroundStyle(Theme.text)
            content()
        }
    }

    private var liveTimes: [Date] {
        let n = live.cpu.count
        let step: TimeInterval = live.isFast ? 1 : 5
        let end = live.snapshot?.timestamp ?? Date()
        return (0..<n).map { end.addingTimeInterval(-Double(n - 1 - $0) * step) }
    }

    @ViewBuilder
    private func liveChart(_ s: Snapshot) -> some View {
        let times = liveTimes
        let fmt: Date.FormatStyle = .dateTime.hour().minute().second()
        switch metric {
        case .cpu:
            TimeChart(times: times, series: [ChartSeries(id: "CPU", color: color, values: live.cpu.elements)], maxValue: 1, format: Fmt.percent, timeFormat: fmt)
        case .memory:
            TimeChart(times: times, series: [ChartSeries(id: "In use", color: color, values: live.memory.elements.map { $0 * Double(s.memory.total) })],
                      maxValue: Double(s.memory.total), format: { Fmt.bytes(double: $0) }, timeFormat: fmt)
        case .network:
            TimeChart(times: times, series: [ChartSeries(id: "Download", color: color, values: live.networkIn.elements),
                                             ChartSeries(id: "Upload", color: Theme.Metric.cpu, values: live.networkOut.elements)],
                      format: Fmt.rate, timeFormat: fmt)
        case .disk:
            TimeChart(times: times, series: [ChartSeries(id: "Read", color: Theme.Metric.cpu, values: live.diskRead.elements),
                                             ChartSeries(id: "Write", color: color, values: live.diskWrite.elements)],
                      format: Fmt.rate, timeFormat: fmt)
        case .gpu:
            TimeChart(times: times, series: [ChartSeries(id: "GPU", color: color, values: live.gpu.elements)], maxValue: 1, format: Fmt.percent, timeFormat: fmt)
        case .power:
            TimeChart(times: times, series: [ChartSeries(id: "Power", color: color, values: live.power.elements)], format: Fmt.watts, timeFormat: fmt)
        }
    }

    /// History metrics (and labels, colors) for this drawer; empty when history does not record it.
    private func historyMetrics(_ s: Snapshot) -> [(Metric, String, Color)] {
        switch metric {
        case .cpu: [(.cpu, "CPU", color)]
        case .memory: [(.memoryUsed, "In use", color)]
        case .network: [(.netIn, "Download", color), (.netOut, "Upload", Theme.Metric.cpu)]
        case .disk: [(.diskRead, "Read", Theme.Metric.cpu), (.diskWrite, "Write", color)]
        case .gpu: [(.gpu, "GPU", color)]
        case .power: s.battery == nil ? [] : [(.battery, "Charge", color)]
        }
    }

    private func historySection(_ s: Snapshot) -> some View {
        let metrics = historyMetrics(s)
        let format: (Double) -> String = switch metric {
        case .cpu, .gpu, .power: Fmt.percent
        case .memory: { Fmt.bytes(double: $0) }
        case .network, .disk: Fmt.rate
        }
        let maxValue: Double? = switch metric {
        case .cpu, .gpu, .power: 1
        case .memory: Double(s.memory.total)
        default: nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.headlineV).foregroundStyle(Theme.text)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0 == .hour ? "1 h" : "24 h").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let first = past.first, !first.isEmpty {
                TimeChart(times: first.times,
                          series: zip(metrics, past).map { m, series in ChartSeries(id: m.1, color: m.2, values: series.values) },
                          maxValue: maxValue, format: format, timeFormat: range.timeFormat)
                    .frame(height: 120)
                    .transition(.opacity)
            } else {
                Text("Vardis has not recorded this range yet. History fills in as the Mac runs.")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
        .motion(Motion.screen, value: past.first?.times.count ?? 0)
    }

    private func loadHistory() async {
        guard let s = live.snapshot else { return }
        var out: [HistorySeries] = []
        for m in historyMetrics(s) { out.append(await history.series(m.0, last: range.seconds)) }
        // Series of one drawer share a time axis; trim to the shortest so they line up.
        let n = out.map(\.times.count).min() ?? 0
        past = out.map { HistorySeries(times: Array($0.times.suffix(n)), values: Array($0.values.suffix(n))) }
        if metric == .memory { swapPast = await history.series(.swap, last: range.seconds) }
    }

    // MARK: Top apps

    @ViewBuilder
    private func topApps(_ s: Snapshot) -> some View {
        let ranked: [(AppSample, Double, String)]? = switch metric {
        case .cpu: s.apps.sorted { $0.cpu > $1.cpu }.prefix(5).map { ($0, $0.cpu, Fmt.percent($0.cpu)) }
        case .memory: s.apps.prefix(5).map { ($0, Double($0.memory), Fmt.bytes($0.memory)) }
        case .disk: s.apps.sorted { $0.diskWriteBytesPerSecond > $1.diskWriteBytesPerSecond }.prefix(5)
            .filter { $0.diskWriteBytesPerSecond > 0 }.map { ($0, $0.diskWriteBytesPerSecond, Fmt.rate($0.diskWriteBytesPerSecond)) }
        case .power: s.apps.sorted { $0.energyWatts > $1.energyWatts }.prefix(5).map { ($0, $0.energyWatts, Fmt.watts($0.energyWatts)) }
        case .network, .gpu: nil
        }
        section(metric == .disk ? "Top writers" : "Top apps") {
            if let ranked, !ranked.isEmpty {
                let top = max(0.0001, ranked.first?.1 ?? 1)
                VStack(spacing: 0) {
                    ForEach(ranked, id: \.0.id) { app, v, label in
                        AppValueRow(app: app, value: label, share: v / top, color: color, open: openApp)
                    }
                }
                .padding(.horizontal, -6)
            } else if ranked != nil {
                Text("Nothing is writing to disk right now.").font(.calloutV).foregroundStyle(Theme.textTertiary)
            } else {
                Text(metric == .network
                     ? "macOS does not report network use per app through public APIs, so Vardis shows the whole Mac."
                     : "macOS does not report GPU use per app through public APIs.")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Facts

    @ViewBuilder
    private func facts(_ s: Snapshot) -> some View {
        switch metric {
        case .cpu:
            let l = NowFacts.load()
            let cores = NowFacts.cores
            FactRow(label: "User", value: Fmt.percent(s.cpu.user))
            FactRow(label: "System", value: Fmt.percent(s.cpu.system))
            FactRow(label: "Average since Vardis started", value: Fmt.percent(live.cpuAverage))
            FactRow(label: "Load average", value: String(format: "%.2f, %.2f, %.2f", l.one, l.five, l.fifteen), detail: "1, 5 and 15 minutes")
            FactRow(label: "Cores", value: cores.efficiency > 0 ? "\(cores.performance) performance, \(cores.efficiency) efficiency" : "\(s.cpu.perCore.count)")
            FactRow(label: "Thermal state", value: NowFacts.thermal()?.label.replacingOccurrences(of: "Thermal: ", with: "").capitalized ?? "Nominal",
                    detail: NowFacts.thermal()?.detail)
            FactRow(label: "Processes", value: "\(s.processCount)")
        case .memory:
            let m = s.memory
            FactRow(label: "Pressure", value: NowFacts.pressureLabel(m.pressure), detail: NowFacts.pressureExplanation(m.pressure))
            ForEach(MemoryBar.parts(m), id: \.0) { FactRow(label: $0.0, value: Fmt.bytes($0.1)) }
            FactRow(label: "Swap used", value: Fmt.bytes(m.swapUsed), detail: swapDetail)
            FactRow(label: "Physical memory", value: Fmt.bytes(m.total))
        case .network:
            let n = s.network
            FactRow(label: "Download", value: Fmt.rate(n.receivedBytesPerSecond))
            FactRow(label: "Upload", value: Fmt.rate(n.sentBytesPerSecond))
            FactRow(label: "Peak download, last minute", value: Fmt.rate(live.networkIn.elements.max() ?? 0))
            FactRow(label: "Received since boot", value: Fmt.bytes(n.receivedTotal))
            FactRow(label: "Sent since boot", value: Fmt.bytes(n.sentTotal))
        case .disk:
            let d = s.disk
            FactRow(label: "Free", value: Fmt.bytes(d.freeBytes), detail: "Includes space macOS can purge")
            FactRow(label: "Used", value: Fmt.bytes(d.totalBytes > d.freeBytes ? d.totalBytes - d.freeBytes : 0))
            FactRow(label: "Capacity", value: Fmt.bytes(d.totalBytes))
            FactRow(label: "Read", value: Fmt.rate(d.readBytesPerSecond))
            FactRow(label: "Write", value: Fmt.rate(d.writeBytesPerSecond))
        case .gpu:
            FactRow(label: "Device", value: s.gpu?.name ?? "\u{2013}")
            FactRow(label: "Utilization", value: Fmt.percent(s.gpu?.utilization ?? 0))
            FactRow(label: "Memory in use", value: s.gpu?.memoryBytes.map(Fmt.bytes) ?? "\u{2013}")
            FactRow(label: "Peak since Vardis started", value: Fmt.percent(live.gpuPeak))
        case .power:
            if let b = s.battery {
                FactRow(label: "Charge", value: Fmt.percent(b.charge))
                FactRow(label: "Source", value: b.onBattery ? "Battery" : "Power adapter")
                FactRow(label: "Time left", value: b.timeRemaining.map(Fmt.duration) ?? "\u{2013}")
                FactRow(label: "Battery draw", value: b.watts.map(Fmt.watts) ?? "\u{2013}")
                FactRow(label: "Health", value: b.health.map(Fmt.percent) ?? "\u{2013}", detail: "Maximum capacity compared with new")
                FactRow(label: "Cycle count", value: b.cycleCount.map(String.init) ?? "\u{2013}")
            }
            FactRow(label: "Used by apps", value: Fmt.watts(s.apps.reduce(0) { $0 + $1.energyWatts }), detail: "Sum of each app's energy over the last sample")
        }
    }

    private var swapDetail: String? {
        guard let d = NowFacts.trend(live.swap.elements) else { return "Steady over the last minute" }
        return d > 0 ? "Grew \(Fmt.bytes(UInt64(d))) in the last minute" : "Shrank \(Fmt.bytes(UInt64(-d))) in the last minute"
    }
}
