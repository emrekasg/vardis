import Darwin
import VardisCore

/// Tick counters for one logical core, as reported by `host_processor_info`.
struct CoreTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Whole-Mac and per-core CPU busy fractions from `host_processor_info` deltas.
final class CPUCollector {
    private let host: mach_port_t
    private var previous: [CoreTicks] = []
    private var current: [CoreTicks] = []

    init(host: mach_port_t) {
        self.host = host
    }

    func sample() -> CPUSample {
        guard read(into: &current) else { return CPUSample(user: 0, system: 0, perCore: []) }
        defer { swap(&previous, &current) }
        if previous.count != current.count {
            return CPUSample(user: 0, system: 0, perCore: Array(repeating: 0, count: current.count))
        }
        return Self.usage(previous: previous, current: current)
    }

    /// Pure delta math. Counters are 32-bit and wrap, so subtraction wraps too.
    static func usage(previous: [CoreTicks], current: [CoreTicks]) -> CPUSample {
        var user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        var perCore = [Double](repeating: 0, count: current.count)
        for i in 0..<min(previous.count, current.count) {
            let p = previous[i], c = current[i]
            let u = UInt64(c.user &- p.user) + UInt64(c.nice &- p.nice)
            let s = UInt64(c.system &- p.system)
            let t = u + s + UInt64(c.idle &- p.idle)
            user += u
            system += s
            total += t
            perCore[i] = t == 0 ? 0 : min(1, Double(u + s) / Double(t))
        }
        guard total > 0 else { return CPUSample(user: 0, system: 0, perCore: perCore) }
        return CPUSample(user: Double(user) / Double(total), system: Double(system) / Double(total), perCore: perCore)
    }

    private func read(into out: inout [CoreTicks]) -> Bool {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return false }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let n = Int(cpuCount)
        if out.count != n { out = Array(repeating: CoreTicks(user: 0, system: 0, idle: 0, nice: 0), count: n) }
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<n {
            let base = i * stride
            out[i] = CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
        return true
    }
}
