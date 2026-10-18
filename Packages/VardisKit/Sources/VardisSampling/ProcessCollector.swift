import Darwin
import VardisCore

/// Identity of one process instance. The start time keeps a reused pid from inheriting old counters.
struct ProcessKey: Hashable {
    let pid: Int32
    let start: UInt64
}

/// Everything known about one live process. Created once per process instance and updated in place.
final class ProcessRecord {
    let pid: Int32
    let start: UInt64
    var parentPID: Int32
    let name: String
    let path: String

    // Raw counters from the previous sample.
    fileprivate var lastCPUTicks: UInt64 = 0
    fileprivate var lastRead: UInt64 = 0
    fileprivate var lastWritten: UInt64 = 0
    fileprivate var lastEnergy: UInt64 = 0
    fileprivate var hasPrevious = false
    fileprivate(set) var generation: UInt64 = 0

    // Values for the current interval.
    var cpu: Double = 0
    var memory: UInt64 = 0
    var energyWatts: Double = 0
    var readPerSecond: Double = 0
    var writePerSecond: Double = 0

    /// Owning app, resolved once per process instance by `AppGrouper`.
    var group: AppGroup?

    init(pid: Int32, start: UInt64, parentPID: Int32, name: String, path: String) {
        self.pid = pid
        self.start = start
        self.parentPID = parentPID
        self.name = name
        self.path = path
    }

    var sample: ProcessSample {
        ProcessSample(pid: pid, parentPID: parentPID, name: name, executablePath: path, cpu: cpu, memory: memory,
                      energyWatts: energyWatts, diskReadBytesPerSecond: readPerSecond, diskWriteBytesPerSecond: writePerSecond)
    }
}

/// Per-process counters via libproc. Processes we cannot read (other users without privileges) are skipped.
final class ProcessCollector {
    private let timebase = MachTimebase()
    private let cores: Double
    private var pids: [Int32] = Array(repeating: 0, count: 4096)
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    private var records: [ProcessKey: ProcessRecord] = [:]
    private(set) var byPID: [Int32: ProcessRecord] = [:]
    /// Processes read in the last sample. Reused across samples.
    private(set) var active: [ProcessRecord] = []
    /// Every pid the kernel listed, readable or not.
    private(set) var listedCount = 0
    private var generation: UInt64 = 0
    /// Pids rusage refused last time (other users' processes). Retried every `unreadableRetry` samples
    /// so a readable process that reuses such a pid shows up after a short delay.
    private var unreadable = Set<Int32>()
    private var unreadableNext = Set<Int32>()
    private let unreadableRetry: UInt64 = 8
    private var lastSampleNanos: UInt64 = 0

    init(cores: Int) {
        self.cores = Double(max(1, cores))
        active.reserveCapacity(2048)
    }

    func sample(now: UInt64) {
        generation &+= 1
        let wallNanos = lastSampleNanos == 0 ? 0 : Double(now &- lastSampleNanos)
        lastSampleNanos = now
        active.removeAll(keepingCapacity: true)

        let count = listPIDs()
        listedCount = count
        var info = rusage_info_v6()
        let retryAll = generation % unreadableRetry == 1
        unreadableNext.removeAll(keepingCapacity: true)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            if !retryAll, unreadable.contains(pid) {
                unreadableNext.insert(pid)
                continue
            }
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                }
            }
            guard ok else {
                unreadableNext.insert(pid)
                continue
            }
            let key = ProcessKey(pid: pid, start: info.ri_proc_start_abstime)
            let record: ProcessRecord
            if let existing = records[key] {
                record = existing
            } else {
                record = makeRecord(pid: pid, start: info.ri_proc_start_abstime)
                records[key] = record
                byPID[pid] = record
            }
            update(record, with: info, wallNanos: wallNanos)
            active.append(record)
        }
        swap(&unreadable, &unreadableNext)
        prune()
    }

    private func update(_ r: ProcessRecord, with info: rusage_info_v6, wallNanos: Double) {
        let cpuTicks = info.ri_user_time &+ info.ri_system_time
        r.memory = info.ri_phys_footprint
        if r.hasPrevious, wallNanos > 0 {
            let seconds = wallNanos / 1e9
            r.cpu = Self.cpuFraction(cpuNanos: timebase.nanos(Self.delta(r.lastCPUTicks, cpuTicks)), wallNanos: wallNanos, cores: cores)
            r.readPerSecond = Double(Self.delta(r.lastRead, info.ri_diskio_bytesread)) / seconds
            r.writePerSecond = Double(Self.delta(r.lastWritten, info.ri_diskio_byteswritten)) / seconds
            r.energyWatts = Double(Self.delta(r.lastEnergy, info.ri_energy_nj)) / 1e9 / seconds
        } else {
            r.cpu = 0; r.readPerSecond = 0; r.writePerSecond = 0; r.energyWatts = 0
        }
        r.lastCPUTicks = cpuTicks
        r.lastRead = info.ri_diskio_bytesread
        r.lastWritten = info.ri_diskio_byteswritten
        r.lastEnergy = info.ri_energy_nj
        r.hasPrevious = true
        r.generation = generation
    }

    /// Counters only grow for one process instance; treat a decrease as zero.
    @inline(__always) static func delta(_ old: UInt64, _ new: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    /// CPU as a fraction of the whole Mac.
    static func cpuFraction(cpuNanos: Double, wallNanos: Double, cores: Double) -> Double {
        guard wallNanos > 0, cores > 0 else { return 0 }
        return min(1, max(0, cpuNanos / (wallNanos * cores)))
    }

    private func listPIDs() -> Int {
        while true {
            let capacity = pids.count
            let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard n > 0 else { return 0 }
            if Int(n) < capacity { return Int(n) }
            pids = Array(repeating: 0, count: capacity * 2)
        }
    }

    private func makeRecord(pid: Int32, start: UInt64) -> ProcessRecord {
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        // A binary replaced by an update (Claude Code does this) has no path any more; argv[0] still has it.
        let path = pathLength > 0 ? String(decoding: pathBuffer[0..<Int(pathLength)].lazy.map { UInt8(bitPattern: $0) }, as: UTF8.self) : Self.executablePathFromArguments(pid) ?? ""

        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let gotBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size
        var name = ""
        if let slash = path.lastIndex(of: "/") {
            name = String(path[path.index(after: slash)...])
        }
        if name.isEmpty, gotBSD {
            name = Self.string(from: bsd.pbi_name)
            if name.isEmpty { name = Self.string(from: bsd.pbi_comm) }
        }
        if name.isEmpty { name = "pid \(pid)" }
        return ProcessRecord(pid: pid, start: start, parentPID: gotBSD ? Int32(bitPattern: bsd.pbi_ppid) : 0, name: name, path: path)
    }

    /// The exec path stored at the start of KERN_PROCARGS2 (after argc). Runs once per new process.
    static func executablePathFromArguments(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let start = MemoryLayout<Int32>.size
        guard let end = buffer[start..<size].firstIndex(of: 0), end > start else { return nil }
        let path = String(decoding: buffer[start..<end], as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private var staleKeys: [ProcessKey] = []

    /// Drops records for processes that were not seen in this sample, without rebuilding the tables.
    private func prune() {
        guard records.count != active.count else { return }
        let gen = generation
        staleKeys.removeAll(keepingCapacity: true)
        for (key, record) in records where record.generation != gen { staleKeys.append(key) }
        for key in staleKeys {
            records.removeValue(forKey: key)
            if let current = byPID[key.pid], current.generation != gen { byPID.removeValue(forKey: key.pid) }
        }
    }
}
