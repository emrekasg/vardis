import Darwin
import VardisCore

/// Memory breakdown using Activity Monitor's definitions.
final class MemoryCollector {
    private let host: mach_port_t
    private let total: UInt64
    private let pageSize: UInt64

    init(host: mach_port_t) {
        self.host = host
        total = SystemInfo.memorySize
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : 16384
    }

    func sample() -> MemorySample {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count) == KERN_SUCCESS
            }
        }
        let swapUsed = SystemInfo.sysctl("vm.swapusage", as: xsw_usage.self)?.xsu_used ?? 0
        let pressure = Self.pressure(SystemInfo.sysctl("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1)
        guard ok else {
            return MemorySample(total: total, app: 0, wired: 0, compressed: 0, cached: 0, free: 0, swapUsed: swapUsed, pressure: pressure)
        }
        let page = pageSize
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemorySample(
            total: total,
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            free: UInt64(stats.free_count) * page,
            swapUsed: swapUsed,
            pressure: pressure
        )
    }

    static func pressure(_ level: Int32) -> MemoryPressure {
        switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}
