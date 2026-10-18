import Darwin

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
