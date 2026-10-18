import Darwin
import Foundation
import Testing
@testable import VardisSampling

struct PortScannerTests {
    @Test func portIsReadFromNetworkOrder() {
        // 3000 = 0x0BB8, stored big-endian in the low 16 bits of insi_lport.
        let raw = Int32(UInt16(3000).bigEndian)
        #expect(PortScanner.port(networkOrder: raw) == 3000)
        #expect(PortScanner.port(networkOrder: 0) == 0)
        #expect(PortScanner.port(networkOrder: Int32(UInt16(65535).bigEndian)) == 65535)
    }

    @Test func tcpListenAndEstablishedAreClassified() {
        let tcp = Int32(SOCKINFO_TCP)
        #expect(PortScanner.classify(kind: tcp, protocol: IPPROTO_TCP, tcpState: Int32(TSI_S_LISTEN), localPort: 5173, foreignPort: 0) == .listening(.tcp))
        #expect(PortScanner.classify(kind: tcp, protocol: IPPROTO_TCP, tcpState: Int32(TSI_S_ESTABLISHED), localPort: 5173, foreignPort: 51000) == .established)
        #expect(PortScanner.classify(kind: tcp, protocol: IPPROTO_TCP, tcpState: Int32(TSI_S_TIME_WAIT), localPort: 5173, foreignPort: 51000) == .ignored)
        #expect(PortScanner.classify(kind: tcp, protocol: IPPROTO_TCP, tcpState: Int32(TSI_S_LISTEN), localPort: 0, foreignPort: 0) == .ignored)
    }

    @Test func udpCountsOnlyWhenBoundUnconnectedAndNotDiscovery() {
        let inet = Int32(SOCKINFO_IN)
        #expect(PortScanner.classify(kind: inet, protocol: IPPROTO_UDP, tcpState: nil, localPort: 8125, foreignPort: 0) == .listening(.udp))
        #expect(PortScanner.classify(kind: inet, protocol: IPPROTO_UDP, tcpState: nil, localPort: 5353, foreignPort: 0) == .ignored)
        #expect(PortScanner.classify(kind: inet, protocol: IPPROTO_UDP, tcpState: nil, localPort: 8125, foreignPort: 443) == .ignored)
        #expect(PortScanner.classify(kind: inet, protocol: IPPROTO_UDP, tcpState: nil, localPort: 61507, foreignPort: 0) == .ignored)
        #expect(PortScanner.classify(kind: Int32(SOCKINFO_UN), protocol: 0, tcpState: nil, localPort: 0, foreignPort: 0) == .ignored)
    }

    @Test func loopbackAddresses() {
        #expect(PortScanner.isLoopbackIPv4(networkOrder: UInt32(0x7F00_0001).bigEndian))
        #expect(!PortScanner.isLoopbackIPv4(networkOrder: 0))
        #expect(!PortScanner.isLoopbackIPv4(networkOrder: UInt32(0xC0A8_0001).bigEndian))
        var v6 = [UInt8](repeating: 0, count: 16)
        #expect(!PortScanner.isLoopbackIPv6(v6)) // ::
        v6[15] = 1
        #expect(PortScanner.isLoopbackIPv6(v6)) // ::1
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1]
        #expect(PortScanner.isLoopbackIPv6(mapped))
    }

    @Test func ipv4AndIPv6OnOnePortMerge() {
        let merged = PortScanner.merge([
            ListeningPort(port: 3000, transport: .tcp, localOnly: true),
            ListeningPort(port: 3000, transport: .tcp, localOnly: false),
            ListeningPort(port: 80, transport: .tcp, localOnly: true),
            ListeningPort(port: 3000, transport: .udp, localOnly: true),
        ])
        #expect(merged == [
            ListeningPort(port: 80, transport: .tcp, localOnly: true),
            ListeningPort(port: 3000, transport: .tcp, localOnly: false),
            ListeningPort(port: 3000, transport: .udp, localOnly: true),
        ])
    }

    @Test func httpGuess() {
        #expect(ListeningPort(port: 5173, transport: .tcp, localOnly: true).looksLikeHTTP)
        #expect(ListeningPort(port: 8080, transport: .tcp, localOnly: false).looksLikeHTTP)
        #expect(!ListeningPort(port: 5432, transport: .tcp, localOnly: true).looksLikeHTTP)
        #expect(!ListeningPort(port: 8080, transport: .udp, localOnly: true).looksLikeHTTP)
        #expect(!ListeningPort(port: 57621, transport: .tcp, localOnly: false).looksLikeHTTP)
    }

    @Test func projectRootFindsNearestMarkerBelowHome() {
        let files: Set<String> = ["/Users/a/code/web/package.json", "/Users/a/code/.git", "/Users/a/.git"]
        let exists: (String) -> Bool = { files.contains($0) }
        #expect(PortScanner.projectRoot(for: "/Users/a/code/web/src", home: "/Users/a", exists: exists) == "/Users/a/code/web")
        #expect(PortScanner.projectRoot(for: "/Users/a/code/api", home: "/Users/a", exists: exists) == "/Users/a/code")
        // No marker: the working directory itself; home and "/" are never projects.
        #expect(PortScanner.projectRoot(for: "/Users/a/notes", home: "/Users/a/", exists: exists) == "/Users/a/notes")
        #expect(PortScanner.projectRoot(for: "/Users/a", home: "/Users/a", exists: exists) == nil)
        #expect(PortScanner.projectRoot(for: "/", home: "/Users/a", exists: exists) == nil)
        #expect(PortScanner.projectRoot(for: "/tmp/demo/", home: "/Users/a", exists: exists) == "/tmp/demo")
    }

    @Test func idleNeedsQuietCPUForTheWholeWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var t = IdleTracker(since: t0)
        t.observe(cpuNanos: 5e9, at: t0)
        // 10 minutes later, 1 ms more CPU: noise, stays quiet.
        t.observe(cpuNanos: 5e9 + 1e6, at: t0 + 600)
        #expect(!t.isIdle(at: t0 + 600, after: 1800))
        #expect(t.isIdle(at: t0 + 1800, after: 1800))
        // A burst resets the clock.
        t.observe(cpuNanos: 9e9, at: t0 + 1900)
        #expect(!t.isIdle(at: t0 + 1900, after: 1800))
        #expect(t.isIdle(at: t0 + 3700, after: 1800))
    }

    @Test func scanFindsOwnListener() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: actual.sin_port)
        let results = await PortScanner().scan()
        let me = try #require(results.first { $0.pid == getpid() })
        #expect(me.ports.contains(ListeningPort(port: port, transport: .tcp, localOnly: true)))
        #expect(me.workingDirectory != nil)
        #expect(results.allSatisfy { !$0.ports.isEmpty })
        #expect(PortScanner.isRunning(pid: me.pid, started: me.started))
        #expect(!PortScanner.isRunning(pid: me.pid, started: me.started.addingTimeInterval(-5)))
    }
}

struct PortScannerPIDTests {
    /// A TCP socket listening on an ephemeral loopback port shows up when only this pid is scanned.
    @Test func scanLimitedToPIDsFindsOwnListener() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)

        let found = await PortScanner().scan(pids: [getpid()])
        let me = try #require(found.first { $0.pid == getpid() })
        #expect(me.ports.contains(ListeningPort(port: port, transport: .tcp, localOnly: true)))
        #expect(await PortScanner().scan(pids: []).isEmpty)
    }
}

struct CoreLayoutTests {
    @Test func coreCountsAddUp() {
        let l = CoreLayout.current
        #expect(l.performance > 0)
        #expect(l.total == SystemInfo.logicalCores)
        #expect(l.isEfficiency(core: 0) == (l.efficiency > 0))
        let load = loadAverages()
        #expect(load.one >= 0 && load.five >= 0 && load.fifteen >= 0)
    }
}
