import Darwin
import Foundation
import Testing
import VardisCore
@testable import VardisSampling

@Suite(.serialized)
struct SamplerTests {
    @Test func plausibleValuesOnThisMac() async throws {
        let sampler = Sampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(300))
        let s = await sampler.sample()

        #expect(s.memory.total == SystemInfo.memorySize)
        #expect(s.memory.total > 0)
        #expect(s.memory.used <= s.memory.total)
        #expect((0...1).contains(s.cpu.total))
        #expect(s.cpu.perCore.count == SystemInfo.logicalCores)
        #expect(s.cpu.perCore.allSatisfy { (0...1).contains($0) })
        #expect(!s.apps.isEmpty)
        #expect(s.processCount > 0)
        #expect(zip(s.apps, s.apps.dropFirst()).allSatisfy { $0.memory >= $1.memory })
        #expect(s.apps.allSatisfy { (0...1).contains($0.cpu) })
        #expect(s.disk.totalBytes > 0 && s.disk.freeBytes <= s.disk.totalBytes)
        #expect(s.uptime > 0)

        let me = getpid()
        let mine = try #require(s.apps.first { $0.processIDs.contains(me) })
        let details = await sampler.processes(inApp: mine.id)
        let ownProcess = try #require(details.first { $0.pid == me })
        #expect(ownProcess.memory > 0)
        #expect((0...1).contains(ownProcess.cpu))

        // Per-process CPU uses the same "whole Mac" scale as cpu.total; a timebase mistake would inflate it ~40x.
        let appCPU = s.apps.reduce(0) { $0 + $1.cpu }
        #expect(appCPU <= s.cpu.total + 0.15, "apps \(appCPU) vs total \(s.cpu.total)")

        let processesInApps = s.apps.reduce(0) { $0 + $1.processCount }
        print("vardis-sampling: listed=\(s.processCount) readable=\(processesInApps) apps=\(s.apps.count) cpu=\(s.cpu.total) appCPU=\(appCPU) own-app=\(mine.name) gpu=\(s.gpu.map { "\($0.name) \($0.utilization)" } ?? "nil") battery=\(s.battery.map { "\($0.charge) \($0.watts ?? -1)W cycles=\($0.cycleCount ?? -1) health=\($0.health ?? -1)" } ?? "nil")")
        print("vardis-sampling: top apps \(s.apps.prefix(5).map { "\($0.name)=\($0.memory >> 20)MB/\($0.processCount)" })")
    }

    /// Budget: < 5 ms per sample for a Mac with ~700 processes. Almost all of the time is one
    /// `proc_pid_rusage` syscall per pid, so the budget scales with the process count on busier Macs.
    @Test func sampleIsFast() async throws {
        let sampler = Sampler()
        var processCount = await sampler.sample().processCount
        var timings: [Double] = []
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            let start = SystemInfo.uptimeNanos()
            processCount = await sampler.sample().processCount
            timings.append(Double(SystemInfo.uptimeNanos() - start) / 1e6)
        }
        timings.sort()
        let median = timings[timings.count / 2]
        let budget = 5.0 * max(1, Double(processCount) / 700)
        print("vardis-sampling: sample() median \(String(format: "%.2f", median)) ms, min \(String(format: "%.2f", timings[0])), max \(String(format: "%.2f", timings.last!)), processes \(processCount), budget \(String(format: "%.1f", budget)) ms")
        #expect(median < budget)
    }
}
