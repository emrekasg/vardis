import Testing
@testable import VardisSampling

struct DeltaTests {
    @Test func cpuUsageAcrossCounterWrap() {
        let prev = [CoreTicks(user: UInt32.max - 9, system: 100, idle: 1000, nice: 0),
                    CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let cur = [CoreTicks(user: 10, system: 120, idle: 1060, nice: 0),   // user +20, system +20, idle +60
                   CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]      // fully idle
        let s = CPUCollector.usage(previous: prev, current: cur)
        #expect(abs(s.perCore[0] - 0.4) < 1e-9)
        #expect(s.perCore[1] == 0)
        #expect(abs(s.user - 0.1) < 1e-9)
        #expect(abs(s.system - 0.1) < 1e-9)
        #expect(abs(s.total - 0.2) < 1e-9)
    }

    @Test func cpuUsageWithNoTicksIsZero() {
        let t = [CoreTicks(user: 5, system: 5, idle: 5, nice: 5)]
        #expect(CPUCollector.usage(previous: t, current: t).total == 0)
    }

    @Test func processCPUIsFractionOfWholeMac() {
        // 1 s of CPU in 1 s of wall time on 10 cores = 10 % of the Mac.
        #expect(abs(ProcessCollector.cpuFraction(cpuNanos: 1e9, wallNanos: 1e9, cores: 10) - 0.1) < 1e-12)
        #expect(ProcessCollector.cpuFraction(cpuNanos: 50e9, wallNanos: 1e9, cores: 10) == 1)
        #expect(ProcessCollector.cpuFraction(cpuNanos: 1e9, wallNanos: 0, cores: 10) == 0)
        #expect(ProcessCollector.delta(10, 5) == 0)
    }

    @Test func networkCounterWrap() {
        #expect(NetworkCollector.counterDelta(previous: 100, current: 250) == 150)
        #expect(NetworkCollector.counterDelta(previous: UInt32.max - 99, current: 50) == 150)
        #expect(NetworkCollector.counterDelta(previous: 7, current: 7) == 0)
    }

    @Test func pressureLevels() {
        #expect(MemoryCollector.pressure(1) == .normal)
        #expect(MemoryCollector.pressure(2) == .warning)
        #expect(MemoryCollector.pressure(4) == .critical)
    }
}
