import Darwin

/// Performance and efficiency core counts (`hw.perflevel0/1.logicalcpu`). Intel Macs report one level.
public struct CoreLayout: Sendable, Equatable {
    public var performance: Int
    public var efficiency: Int
    public var total: Int { performance + efficiency }

    public init(performance: Int, efficiency: Int) {
        self.performance = performance
        self.efficiency = efficiency
    }

    /// Read once; it never changes while the Mac is on.
    public static let current: CoreLayout = {
        let levels = Int(SystemInfo.sysctl("hw.nperflevels", as: Int32.self) ?? 1)
        let p = Int(SystemInfo.sysctl("hw.perflevel0.logicalcpu", as: Int32.self) ?? Int32(SystemInfo.logicalCores))
        let e = levels > 1 ? Int(SystemInfo.sysctl("hw.perflevel1.logicalcpu", as: Int32.self) ?? 0) : 0
        return CoreLayout(performance: p, efficiency: e)
    }()

    /// Kind of each `host_processor_info` slot. Apple silicon lists the efficiency cluster first.
    public func isEfficiency(core index: Int) -> Bool { index < efficiency }
}

/// 1, 5 and 15 minute load averages (`getloadavg`).
public func loadAverages() -> (one: Double, five: Double, fifteen: Double) {
    var l = [Double](repeating: 0, count: 3)
    guard getloadavg(&l, 3) == 3 else { return (0, 0, 0) }
    return (l[0], l[1], l[2])
}

/// Small wrappers around sysctl and mach time. Everything here is read once or is allocation-free.
enum SystemInfo {
    /// Reads a fixed-size sysctl value into stack memory.
    static func sysctl<T: BitwiseCopyable>(_ name: String, as _: T.Type) -> T? {
        withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buf -> T? in
            var len = MemoryLayout<T>.size
            guard sysctlbyname(name, buf.baseAddress, &len, nil, 0) == 0, len == MemoryLayout<T>.size else { return nil }
            return buf.baseAddress!.pointee
        }
    }

    static var memorySize: UInt64 { sysctl("hw.memsize", as: UInt64.self) ?? 0 }
    static var logicalCores: Int { Int(sysctl("hw.logicalcpu", as: Int32.self) ?? 1) }

    /// Boot time as seconds since 1970.
    static var bootTime: Double {
        guard let tv = sysctl("kern.boottime", as: timeval.self) else { return 0 }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    /// Nanoseconds while awake. Process CPU time only advances while awake, so rates use this clock.
    @inline(__always) static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Converts mach absolute time units (what rusage reports on Apple silicon) to nanoseconds.
struct MachTimebase: Sendable {
    let factor: Double

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        factor = info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }

    @inline(__always) func nanos(_ ticks: UInt64) -> Double { Double(ticks) * factor }
}
