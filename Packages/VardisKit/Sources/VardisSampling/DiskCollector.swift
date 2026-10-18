import Foundation
import IOKit
import VardisCore

/// Startup volume capacity and summed block-device throughput.
final class DiskCollector {
    private var lastRead: UInt64 = 0
    private var lastWritten: UInt64 = 0
    private var lastNanos: UInt64 = 0
    private var capacity: (total: UInt64, free: UInt64) = (0, 0)
    private var capacityReadAt: UInt64 = 0
    /// Free space changes slowly and the "important usage" query is the most expensive call in a sample
    /// (it asks the cache-delete service), so refresh it at most once a minute.
    private let capacityInterval: UInt64 = 60_000_000_000
    private let readKey = "Bytes (Read)" as CFString
    private let writeKey = "Bytes (Write)" as CFString
    private let statisticsKey = "Statistics" as CFString

    /// `capacityMaxAge` overrides the refresh interval (nanoseconds); background samples pass a long one.
    func sample(now: UInt64, capacityMaxAge: UInt64? = nil) -> DiskSample {
        if capacityReadAt == 0 || now &- capacityReadAt >= (capacityMaxAge ?? capacityInterval) {
            capacity = Self.readCapacity()
            capacityReadAt = now
        }
        let (read, written) = readCounters()
        var readRate = 0.0, writeRate = 0.0
        if lastNanos != 0, now > lastNanos {
            let seconds = Double(now - lastNanos) / 1e9
            readRate = Double(read >= lastRead ? read - lastRead : 0) / seconds
            writeRate = Double(written >= lastWritten ? written - lastWritten : 0) / seconds
        }
        lastRead = read
        lastWritten = written
        lastNanos = now
        return DiskSample(totalBytes: capacity.total, freeBytes: capacity.free, readBytesPerSecond: readRate, writeBytesPerSecond: writeRate)
    }

    private static func readCapacity() -> (UInt64, UInt64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else {
            return (0, 0)
        }
        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let free = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        return (total, free)
    }

    private func readCounters() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (lastRead, lastWritten)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, statisticsKey, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  CFGetTypeID(stats) == CFDictionaryGetTypeID() else { continue }
            let dict = stats as! CFDictionary
            read &+= Self.uint64(dict, readKey)
            written &+= Self.uint64(dict, writeKey)
        }
        return (read, written)
    }

    static func uint64(_ dict: CFDictionary, _ key: CFString) -> UInt64 {
        guard let raw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return 0 }
        var out: Int64 = 0
        CFNumberGetValue((value as! CFNumber), .sInt64Type, &out)
        return UInt64(bitPattern: out)
    }

    static func int64(_ dict: CFDictionary, _ key: CFString) -> Int64? {
        guard let raw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var out: Int64 = 0
        CFNumberGetValue((value as! CFNumber), .sInt64Type, &out)
        return out
    }
}
