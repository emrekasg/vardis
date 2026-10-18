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
        didSet { if isFast != oldValue { wake() } }
    }
    var isPaused = false

    /// While nothing is on screen, ticks only read CPU, memory and network (what the menu bar shows);
    /// the per-process walk runs this often. History can lower it to 5 s if it needs per-app rows that often.
    @ObservationIgnored var backgroundFullSampleInterval: Duration = .seconds(30)

    /// Called on every sample, visible or not (menu bar titles, alerts). Apps may be carried over from
    /// the last full sample on cheap ticks.
    @ObservationIgnored private var tickObservers: [@MainActor (Snapshot) -> Void] = []
    /// Called only after a full per-process sample (history writer).
    @ObservationIgnored private var fullSampleObservers: [@MainActor (Snapshot) -> Void] = []

    func onEveryTick(_ observer: @escaping @MainActor (Snapshot) -> Void) { tickObservers.append(observer) }
    func onEveryFullSample(_ observer: @escaping @MainActor (Snapshot) -> Void) { fullSampleObservers.append(observer) }

    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var lastFull: ContinuousClock.Instant?
    @ObservationIgnored private var wantsFull = true
    /// A wake that arrived while a sample was running; the loop skips its next wait.
    @ObservationIgnored private var wakePending = false

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused {
                    let started = clock.now
                    let full = self.wantsFull || !self.presenters.isEmpty
                        || self.lastFull.map { started - $0 >= self.backgroundFullSampleInterval } ?? true
                    self.wantsFull = false
                    let background = self.presenters.isEmpty
                    let s = full ? await self.sampler.sample(background: background) : await self.sampler.sampleSystem()
                    if full { self.lastFull = started }
                    self.working.lastSampleDuration = clock.now - started
                    self.apply(s, full: full)
                }
                // Generous leeway while idle lets the kernel coalesce our wake-ups with others (App Nap does the rest).
                let interval: Duration = self.isFast ? .seconds(1) : .seconds(5)
                let tolerance: Duration = self.isFast ? .milliseconds(100) : self.presenters.isEmpty ? .seconds(2) : .milliseconds(500)
                if self.wakePending { self.wakePending = false; continue }
                let nap = Task { _ = try? await Task.sleep(for: interval, tolerance: tolerance) }
                self.sleeper = nap
                await nap.value
                self.sleeper = nil
                self.wakePending = false
            }
        }
    }

    /// Ends the current wait so the next sample is taken now.
    private func wake() {
        if let sleeper { sleeper.cancel() } else { wakePending = true }
    }

    /// A window or popover announces it is on screen. The first presenter gets the latest state at once,
    /// and a full sample follows immediately so per-app numbers are fresh within milliseconds.
    func setPresenting(_ id: String, _ visible: Bool) {
        let wasEmpty = presenters.isEmpty
        if visible { presenters.insert(id) } else { presenters.remove(id) }
        if wasEmpty && !presenters.isEmpty {
            state = working
            wantsFull = true
            wake()
        }
    }

    func processes(inApp id: String) async -> [ProcessSample] {
        await sampler.processes(inApp: id)
    }

    /// Owning app per pid, from the last full sample.
    func apps(forPIDs pids: [Int32]) async -> [Int32: AppIdentity] {
        await sampler.apps(forPIDs: pids)
    }

    private func apply(_ s: Snapshot, full: Bool) {
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

        if full {
            var seen = Set<String>()
            for app in s.apps.prefix(80) {
                seen.insert(app.id)
                working.appMemory[app.id, default: RingBuffer(capacity: Self.historyLength, filler: 0)].append(Double(app.memory))
            }
            if working.appMemory.count > 200 { working.appMemory = working.appMemory.filter { seen.contains($0.key) } }
        }
        working.ownFootprint = Self.currentFootprint()
        if !presenters.isEmpty { state = working }
        for o in tickObservers { o(s) }
        if full { for o in fullSampleObservers { o(s) } }
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
