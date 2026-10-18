import Foundation

// Shared value types. Samplers produce them, the app and the store consume them.
// Fractions are 0...1 of the whole Mac unless a property says otherwise.

public struct CPUSample: Sendable, Equatable {
    public var user: Double
    public var system: Double
    /// Busy fraction per logical core, 0...1.
    public var perCore: [Double]
    public var total: Double { min(1, user + system) }

    public init(user: Double, system: Double, perCore: [Double]) {
        self.user = user
        self.system = system
        self.perCore = perCore
    }
}

public enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical
}

public struct MemorySample: Sendable, Equatable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var pressure: MemoryPressure
    /// What Activity Monitor calls "Memory Used".
    public var used: UInt64 { app + wired + compressed }

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, free: UInt64, swapUsed: UInt64, pressure: MemoryPressure) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swapUsed = swapUsed
        self.pressure = pressure
    }
}

public struct DiskSample: Sendable, Equatable {
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double

    public init(totalBytes: UInt64, freeBytes: UInt64, readBytesPerSecond: Double, writeBytesPerSecond: Double) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct NetworkSample: Sendable, Equatable {
    public var receivedBytesPerSecond: Double
    public var sentBytesPerSecond: Double
    /// Interface counters since boot.
    public var receivedTotal: UInt64
    public var sentTotal: UInt64

    public init(receivedBytesPerSecond: Double, sentBytesPerSecond: Double, receivedTotal: UInt64, sentTotal: UInt64) {
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.receivedTotal = receivedTotal
        self.sentTotal = sentTotal
    }
}

public struct BatterySample: Sendable, Equatable {
    /// 0...1
    public var charge: Double
    public var isCharging: Bool
    public var onBattery: Bool
    public var timeRemaining: TimeInterval?
    /// Positive while discharging.
    public var watts: Double?
    public var cycleCount: Int?
    /// Max capacity / design capacity, 0...1.
    public var health: Double?

    public init(charge: Double, isCharging: Bool, onBattery: Bool, timeRemaining: TimeInterval?, watts: Double?, cycleCount: Int?, health: Double?) {
        self.charge = charge
        self.isCharging = isCharging
        self.onBattery = onBattery
        self.timeRemaining = timeRemaining
        self.watts = watts
        self.cycleCount = cycleCount
        self.health = health
    }
}

public struct GPUSample: Sendable, Equatable {
    public var name: String
    /// 0...1
    public var utilization: Double
    public var memoryBytes: UInt64?

    public init(name: String, utilization: Double, memoryBytes: UInt64?) {
        self.name = name
        self.utilization = utilization
        self.memoryBytes = memoryBytes
    }
}

public struct ProcessSample: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var executablePath: String
    /// Fraction of the whole Mac, 0...1.
    public var cpu: Double
    /// Physical footprint, the number Activity Monitor shows as Memory.
    public var memory: UInt64
    public var energyWatts: Double
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double

    public init(pid: Int32, parentPID: Int32, name: String, executablePath: String, cpu: Double, memory: UInt64, energyWatts: Double, diskReadBytesPerSecond: Double, diskWriteBytesPerSecond: Double) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.cpu = cpu
        self.memory = memory
        self.energyWatts = energyWatts
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    }
}

/// Processes rolled up into the app that owns them.
public struct AppSample: Sendable, Equatable, Identifiable {
    /// Bundle identifier when known, otherwise the bundle or executable path.
    public var id: String
    public var name: String
    public var bundleURL: URL?
    public var isSystem: Bool
    public var processIDs: [Int32]
    public var cpu: Double
    public var memory: UInt64
    public var energyWatts: Double
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    public var processCount: Int { processIDs.count }

    public init(id: String, name: String, bundleURL: URL?, isSystem: Bool, processIDs: [Int32], cpu: Double, memory: UInt64, energyWatts: Double, diskReadBytesPerSecond: Double, diskWriteBytesPerSecond: Double) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
        self.isSystem = isSystem
        self.processIDs = processIDs
        self.cpu = cpu
        self.memory = memory
        self.energyWatts = energyWatts
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    }
}

public struct Snapshot: Sendable {
    public var timestamp: Date
    public var cpu: CPUSample
    public var memory: MemorySample
    public var disk: DiskSample
    public var network: NetworkSample
    public var battery: BatterySample?
    public var gpu: GPUSample?
    /// Sorted by memory, descending.
    public var apps: [AppSample]
    public var processCount: Int
    public var uptime: TimeInterval

    public init(timestamp: Date, cpu: CPUSample, memory: MemorySample, disk: DiskSample, network: NetworkSample, battery: BatterySample?, gpu: GPUSample?, apps: [AppSample], processCount: Int, uptime: TimeInterval) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.gpu = gpu
        self.apps = apps
        self.processCount = processCount
        self.uptime = uptime
    }
}
