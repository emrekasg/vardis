import Darwin
import Foundation
import VardisCore

/// Owns every collector. The app calls `sample()` on its own timer (1–5 s).
public actor Sampler {
    private let host: mach_port_t
    private let cpu: CPUCollector
    private let memory: MemoryCollector
    private let processes: ProcessCollector
    private let grouper = AppGrouper()
    private let disk = DiskCollector()
    private let network = NetworkCollector()
    private let battery = BatteryCollector()
    private let gpu = GPUCollector()
    private let bootTime = SystemInfo.bootTime
    private var last: Snapshot?

    public init() {
        host = mach_host_self()
        cpu = CPUCollector(host: host)
        memory = MemoryCollector(host: host)
        processes = ProcessCollector(cores: SystemInfo.logicalCores)
    }

    /// Collects one Snapshot. The first call primes delta counters; rates/CPU may be 0 on that call.
    /// `background`: nobody is looking, so slow-changing, costly readings (free disk space asks the
    /// cache-delete service and costs more than the whole process walk) refresh only every 10 minutes.
    public func sample(background: Bool = false) -> Snapshot {
        let now = SystemInfo.uptimeNanos()
        let cpuSample = cpu.sample()
        let memorySample = memory.sample()
        processes.sample(now: now)
        grouper.group(processes.active, byPID: processes.byPID)

        var apps = [AppSample]()
        apps.reserveCapacity(grouper.activeGroups.count)
        for g in grouper.activeGroups { apps.append(g.makeSample()) }

        let date = Date()
        let snapshot = Snapshot(
            timestamp: date,
            cpu: cpuSample,
            memory: memorySample,
            disk: disk.sample(now: now, capacityMaxAge: background ? 600_000_000_000 : nil),
            network: network.sample(now: now),
            battery: battery.sample(now: now),
            gpu: gpu.sample(),
            apps: apps,
            processCount: processes.listedCount,
            uptime: max(0, date.timeIntervalSince1970 - bootTime)
        )
        last = snapshot
        return snapshot
    }

    /// A cheap Snapshot for menu bar ticks while no window is open: CPU, memory and network are fresh;
    /// apps, disk, battery and GPU are carried over from the last full `sample()`. No per-process walk.
    public func sampleSystem() -> Snapshot {
        let now = SystemInfo.uptimeNanos()
        let cpuSample = cpu.sample()
        let memorySample = memory.sample()
        let networkSample = network.sample(now: now)
        let date = Date()
        guard var s = last else {
            return Snapshot(timestamp: date, cpu: cpuSample, memory: memorySample,
                            disk: DiskSample(totalBytes: 0, freeBytes: 0, readBytesPerSecond: 0, writeBytesPerSecond: 0),
                            network: networkSample, battery: nil, gpu: nil, apps: [], processCount: 0,
                            uptime: max(0, date.timeIntervalSince1970 - bootTime))
        }
        s.timestamp = date
        s.cpu = cpuSample
        s.memory = memorySample
        s.network = networkSample
        s.uptime = max(0, date.timeIntervalSince1970 - bootTime)
        return s
    }

    /// The app (as `AppGrouper` sees it) each pid belonged to in the last full sample.
    public func apps(forPIDs pids: [Int32]) -> [Int32: AppIdentity] {
        var out = [Int32: AppIdentity]()
        for pid in pids {
            guard let g = processes.byPID[pid]?.group else { continue }
            out[pid] = AppIdentity(id: g.id, name: g.name, bundleURL: g.bundleURL)
        }
        return out
    }

    /// When each app's oldest live process started, from the last full sample. Read once per new process,
    /// so this is a walk over records already in memory.
    public func appStartDates() -> [String: Date] {
        var out = [String: Date]()
        out.reserveCapacity(grouper.activeGroups.count)
        for g in grouper.activeGroups {
            var oldest: Date?
            for p in g.members { if let s = p.started, oldest == nil || s < oldest! { oldest = s } }
            if let oldest { out[g.id] = oldest }
        }
        return out
    }

    /// Details for one app (processes in it), from the last sample. Sorted by memory, descending.
    public func processes(inApp appID: String) -> [ProcessSample] {
        guard let group = grouper.group(id: appID) else { return [] }
        return group.members.map(\.sample).sorted { $0.memory > $1.memory }
    }
}

/// Who owns a process, in the same terms as `AppSample`.
public struct AppIdentity: Sendable, Equatable {
    public var id: String
    public var name: String
    public var bundleURL: URL?
}
