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

    public init() {
        host = mach_host_self()
        cpu = CPUCollector(host: host)
        memory = MemoryCollector(host: host)
        processes = ProcessCollector(cores: SystemInfo.logicalCores)
    }

    /// Collects one Snapshot. The first call primes delta counters; rates/CPU may be 0 on that call.
    public func sample() -> Snapshot {
        let now = SystemInfo.uptimeNanos()
        let cpuSample = cpu.sample()
        let memorySample = memory.sample()
        processes.sample(now: now)
        grouper.group(processes.active, byPID: processes.byPID)

        var apps = [AppSample]()
        apps.reserveCapacity(grouper.activeGroups.count)
        for g in grouper.activeGroups { apps.append(g.makeSample()) }

        let date = Date()
        return Snapshot(
            timestamp: date,
            cpu: cpuSample,
            memory: memorySample,
            disk: disk.sample(now: now),
            network: network.sample(now: now),
            battery: battery.sample(now: now),
            gpu: gpu.sample(),
            apps: apps,
            processCount: processes.listedCount,
            uptime: max(0, date.timeIntervalSince1970 - bootTime)
        )
    }

    /// Details for one app (processes in it), from the last sample. Sorted by memory, descending.
    public func processes(inApp appID: String) -> [ProcessSample] {
        guard let group = grouper.group(id: appID) else { return [] }
        return group.members.map(\.sample).sorted { $0.memory > $1.memory }
    }
}
