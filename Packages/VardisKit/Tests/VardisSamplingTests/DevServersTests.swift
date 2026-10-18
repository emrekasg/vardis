import Darwin
import Foundation
import Testing
@testable import VardisSampling

struct DevServersTests {
    @Test func ownershipClassification() {
        let me: UInt32 = 501
        #expect(ServerOwnership.classify(pid: 4321, uid: me, currentUID: me, name: "node", path: "/opt/homebrew/bin/node") == .yours)
        #expect(ServerOwnership.classify(pid: 4321, uid: me, currentUID: me, name: "ruby", path: "/usr/bin/ruby") == .yours)
        #expect(ServerOwnership.classify(pid: 4321, uid: me, currentUID: me, name: "ControlCenter",
                                         path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter") == .system)
        #expect(ServerOwnership.classify(pid: 4321, uid: me, currentUID: me, name: "rapportd", path: "/usr/libexec/rapportd") == .system)
        #expect(ServerOwnership.classify(pid: 300, uid: me, currentUID: me, name: "x", path: "/opt/x") == .system)
        #expect(ServerOwnership.classify(pid: 4321, uid: 0, currentUID: me, name: "x", path: "/opt/x") == .system)
        #expect(ServerOwnership.classify(pid: 4321, uid: me, currentUID: me, name: "com.docker.backend",
                                         path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == .container)
        #expect(ServerOwnership.classify(pid: 4321, uid: me, currentUID: me, name: "OrbStack Helper",
                                         path: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper") == .container)
    }

    @Test func portQueryParsing() {
        #expect(PortQuery.parse("3000") == 3000)
        #expect(PortQuery.parse(" :3000 ") == 3000)
        #expect(PortQuery.parse("localhost:5173") == 5173)
        #expect(PortQuery.parse("http://127.0.0.1:8080/app") == 8080)
        #expect(PortQuery.parse("65535") == 65535)
        #expect(PortQuery.parse("65536") == nil)
        #expect(PortQuery.parse("0") == nil)
        #expect(PortQuery.parse("node") == nil)
        #expect(PortQuery.parse("") == nil)
        #expect(PortQuery.parse("example.com:80") == nil)
        #expect(PortQuery.parse("٣٠٠٠") == nil)
    }

    @Test func configuredPortsFromProjectFiles() {
        let pkg = #"{"name":"web","scripts":{"dev":"vite --port 5174 --host","build":"vite build"}}"#
        #expect(DevPortConfig.ports(files: ["package.json": pkg]) == [5174])
        #expect(DevPortConfig.ports(files: ["package.json": #"{"scripts":{"dev":"next dev -p 3001"}}"#]) == [3001])
        #expect(DevPortConfig.ports(files: ["package.json": #"{"scripts":{"dev":"PORT=4000 node server.js"}}"#]) == [4000])
        #expect(DevPortConfig.ports(files: ["package.json": #"{"scripts":{"dev":"vite"}}"#]).isEmpty)
        #expect(DevPortConfig.ports(files: ["package.json": "not json"]).isEmpty)
        let vite = "export default defineConfig({ server: { port: 5180, strictPort: true } })"
        #expect(DevPortConfig.ports(files: ["vite.config.ts": vite]) == [5180])
        #expect(DevPortConfig.ports(files: [".env": "# x\nexport PORT=\"8081\"\nHOST=0.0.0.0"]) == [8081])
        #expect(DevPortConfig.ports(files: [".env": "API_PORT=9\nPORTAL=1"]).isEmpty)
        // Duplicates collapse.
        #expect(DevPortConfig.ports(files: [".env": "PORT=5174", "package.json": pkg]) == [5174])
    }

    @Test func configuredPortsReadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "PORT=3005\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(DevPortConfig.read(folder: dir.path) == [3005])
    }

    @Test func htmlTitle() {
        #expect(HTMLTitle.extract(from: Data("<html><head><TITLE lang=en>\n  Vite &amp; React\n</TITLE>".utf8)) == "Vite & React")
        #expect(HTMLTitle.extract(from: Data("<html><body>no title</body>".utf8)) == nil)
        #expect(HTMLTitle.extract(from: Data("<title></title>".utf8)) == nil)
    }

    @Test func establishedConnectionsKeepAServerBusy() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var t = IdleTracker(since: t0)
        t.observe(cpuNanos: 1e9, at: t0)
        t.observe(cpuNanos: 1e9, busy: true, at: t0 + 1700)
        #expect(!t.isIdle(at: t0 + 1800, after: 1800))
        t.observe(cpuNanos: 1e9, at: t0 + 1800)
        #expect(t.since == t0 + 1700)
        #expect(t.isIdle(at: t0 + 3500, after: 1800))
    }

    @Test func stopperRefusesWhatIsNotTheUsers() {
        #expect(!ProcessStopper.mayStop(.init(pid: 1, started: .now)))
        #expect(!ProcessStopper.mayStop(.init(pid: getpid(), started: .now)))
        #expect(!ProcessStopper.send(SIGHUP, to: .init(pid: 999_999, started: .now)))
        #expect(!ProcessStopper.send(SIGTERM, to: .init(pid: 999_999, started: .now)))
    }
}

/// Spawns its own throwaway listeners and stops them through `ProcessStopper`. Never touches any other process.
@Suite(.serialized)
struct ThrowawayListenerStopTests {
    static func python() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Launches `python3 args` in a fresh temp folder and waits until the scanner sees it listening.
    static func spawn(_ args: [String]) async throws -> (Process, ServerProcess, URL) {
        let interpreter = try #require(Self.python())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vardis-listener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: interpreter)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let scanner = PortScanner()
        for _ in 0..<100 {
            if let s = await scanner.scan(pids: [p.processIdentifier]).first, !s.ports.isEmpty { return (p, s, dir) }
            try await Task.sleep(for: .milliseconds(100))
        }
        p.terminate()
        throw CancellationError()
    }

    @Test func httpServerStopsOnSIGTERM() async throws {
        let (p, server, dir) = try await Self.spawn(["-m", "http.server", "0", "--bind", "127.0.0.1"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(server.pid == p.processIdentifier)
        #expect(server.ownership == .yours)
        #expect(server.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == dir.resolvingSymlinksInPath().path)
        let port = try #require(server.ports.first?.port)
        #expect(PortProbe.isListening(port: port))

        let target = ProcessStopper.Target(pid: server.pid, started: server.started)
        #expect(ProcessStopper.mayStop(target))
        #expect(ProcessStopper.send(SIGTERM, to: target))
        let survivors = await ProcessStopper.waitForExit([target], timeout: .seconds(3))
        #expect(survivors.isEmpty)
        #expect(!ProcessStopper.isAlive(target))
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
        #expect(!PortProbe.isListening(port: port))
        // The same pid and start can never be signalled again.
        #expect(!ProcessStopper.send(SIGKILL, to: target))
    }

    @Test func listenerIgnoringSIGTERMNeedsForceQuit() async throws {
        let script = "import signal,socket,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ns=socket.socket()\ns.bind(('127.0.0.1',0))\ns.listen()\ntime.sleep(120)"
        let (p, server, dir) = try await Self.spawn(["-c", script])
        defer { try? FileManager.default.removeItem(at: dir); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let target = ProcessStopper.Target(pid: server.pid, started: server.started)
        #expect(ProcessStopper.send(SIGTERM, to: target))
        let survivors = await ProcessStopper.waitForExit([target], timeout: .seconds(1))
        #expect(survivors == [target])
        #expect(ProcessStopper.send(SIGKILL, to: target))
        #expect(await ProcessStopper.waitForExit([target], timeout: .seconds(3)).isEmpty)
    }
}

struct ContainerListTests {
    @Test func publishedPortsParse() {
        let ports = ContainerList.hostPorts("0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:8000-8001->8000-8001/tcp, 9000/tcp, 0.0.0.0:53->53/udp")
        #expect(ports == [
            ListeningPort(port: 53, transport: .udp, localOnly: false),
            ListeningPort(port: 5432, transport: .tcp, localOnly: false),
            ListeningPort(port: 8000, transport: .tcp, localOnly: true),
            ListeningPort(port: 8001, transport: .tcp, localOnly: true),
        ])
        #expect(ContainerList.hostPorts("9000/tcp").isEmpty)
    }

    @Test func linesParse() {
        let out = "abc123\tshop-db-1\tpostgres:16\tshop\t/Users/a/code/shop\t0.0.0.0:5432->5432/tcp\n"
            + "def456\tlonely\tredis\t\t\t6379/tcp\n"
            + "ghi789\tweb\tnginx\t\t\t127.0.0.1:8080->80/tcp\n"
        let list = ContainerList.parse(out)
        #expect(list.count == 2)
        #expect(list[0].workingDirectory == "/Users/a/code/shop" && list[0].composeProject == "shop" && list[0].ports.map(\.port) == [5432])
        #expect(list[1].name == "web" && list[1].workingDirectory == nil && list[1].ports.first?.localOnly == true)
    }
}
