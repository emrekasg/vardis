import Foundation
import Observation
import VardisCore
import VardisSampling

let liveHistoryLength = 60

/// Everything a screen can show, as one value. Copied to the UI only while something is on screen.
struct LiveState {
    var snapshot: Snapshot?
    var cpu = RingBuffer<Double>(capacity: liveHistoryLength, filler: 0)
    var memory = RingBuffer<Double>(capacity: liveHistoryLength, filler: 0)
    var gpu = RingBuffer<Double>(capacity: liveHistoryLength, filler: 0)
    var diskWrite = RingBuffer<Double>(capacity: liveHistoryLength, filler: 0)
    var networkIn = RingBuffer<Double>(capacity: liveHistoryLength, filler: 0)
    var battery = RingBuffer<Double>(capacity: liveHistoryLength, filler: 0)
    /// Memory per app id, for row sparklines.
    var appMemory: [String: RingBuffer<Double>] = [:]
    /// CPU average since launch, shown as "Avg" until history lands.
    var cpuAverage: Double = 0
    var gpuPeak: Double = 0
    var cpuSamples = 0
    /// Vardis measuring itself, shown in Settings › Performance.
    var lastSampleDuration: Duration = .zero
    var ownFootprint: UInt64 = 0
}

/// Owns the sampling loop and the in-memory history every screen reads from.
/// Screens never touch the disk. While nothing is visible the UI is not told about new
/// samples at all, so a hidden window costs no layout or rendering.
@MainActor
@Observable
final class LiveModel {
    static let historyLength = liveHistoryLength

    /// What views read. Updated only while a presenter is visible.
    private(set) var state = LiveState()
    @ObservationIgnored private var working = LiveState()
    @ObservationIgnored private var presenters = Set<String>()

    var snapshot: Snapshot? { state.snapshot }
    var cpu: RingBuffer<Double> { state.cpu }
    var memory: RingBuffer<Double> { state.memory }
    var gpu: RingBuffer<Double> { state.gpu }
    var diskWrite: RingBuffer<Double> { state.diskWrite }
    var networkIn: RingBuffer<Double> { state.networkIn }
    var battery: RingBuffer<Double> { state.battery }
    var appMemory: [String: RingBuffer<Double>] { state.appMemory }
    var cpuAverage: Double { state.cpuAverage }
    var gpuPeak: Double { state.gpuPeak }
    var lastSampleDuration: Duration { state.lastSampleDuration }
    var ownFootprint: UInt64 { state.ownFootprint }

    /// Fast mode (1 s) while a screen with live data is visible; otherwise 5 s.
    var isFast = false {
        didSet { if isFast != oldValue { restart() } }
    }
    var isPaused = false

    /// Called on every sample, visible or not (menu bar titles, history writer, alerts).
    @ObservationIgnored private var tickObservers: [@MainActor (Snapshot) -> Void] = []

    func onEveryTick(_ observer: @escaping @MainActor (Snapshot) -> Void) { tickObservers.append(observer) }

    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused {
                    let clock = ContinuousClock()
                    let started = clock.now
                    let s = await self.sampler.sample()
                    self.working.lastSampleDuration = clock.now - started
                    self.apply(s)
                }
                let fast = self.isFast
                try? await Task.sleep(for: fast ? .seconds(1) : .seconds(5), tolerance: fast ? .milliseconds(100) : .seconds(1))
            }
        }
    }

    /// A window or popover announces it is on screen. The first presenter gets the latest state at once.
    func setPresenting(_ id: String, _ visible: Bool) {
        let wasEmpty = presenters.isEmpty
        if visible { presenters.insert(id) } else { presenters.remove(id) }
        if wasEmpty && !presenters.isEmpty { state = working }
    }

    func processes(inApp id: String) async -> [ProcessSample] {
        await sampler.processes(inApp: id)
    }

    private func restart() {
        loop?.cancel()
        loop = nil
        start()
    }

    private func apply(_ s: Snapshot) {
        working.snapshot = s
        working.cpu.append(s.cpu.total)
        working.memory.append(s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0)
        working.gpu.append(s.gpu?.utilization ?? 0)
        working.diskWrite.append(s.disk.writeBytesPerSecond)
        working.networkIn.append(s.network.receivedBytesPerSecond)
        working.battery.append(s.battery?.charge ?? 0)
        working.cpuSamples += 1
        working.cpuAverage += (s.cpu.total - working.cpuAverage) / Double(working.cpuSamples)
        working.gpuPeak = max(working.gpuPeak, s.gpu?.utilization ?? 0)

        var seen = Set<String>()
        for app in s.apps.prefix(80) {
            seen.insert(app.id)
            working.appMemory[app.id, default: RingBuffer(capacity: Self.historyLength, filler: 0)].append(Double(app.memory))
        }
        if working.appMemory.count > 200 { working.appMemory = working.appMemory.filter { seen.contains($0.key) } }
        working.ownFootprint = Self.currentFootprint()
        if !presenters.isEmpty { state = working }
        for o in tickObservers { o(s) }
    }

    private static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

extension RingBuffer where Element == Double {
    /// Values scaled to 0...1 against the largest value in the buffer.
    var normalized: [Double] {
        let e = elements
        guard let m = e.max(), m > 0 else { return e.map { _ in 0 } }
        return e.map { $0 / m }
    }
}
