import Foundation
import IOKit
import VardisCore

/// GPU utilization and memory from the first `IOAccelerator` that publishes performance statistics.
final class GPUCollector {
    private var accelerator: io_service_t = 0
    private var name = "GPU"
    private var looked = false
    private let statsKey = "PerformanceStatistics" as CFString
    private let utilizationKey = "Device Utilization %" as CFString
    private let memoryKey = "In use system memory" as CFString

    deinit {
        if accelerator != 0 { IOObjectRelease(accelerator) }
    }

    func sample() -> GPUSample? {
        if !looked {
            looked = true
            find()
        }
        guard accelerator != 0, let stats = statistics(of: accelerator) else { return nil }
        let utilization = DiskCollector.int64(stats, utilizationKey).map { min(1, max(0, Double($0) / 100)) } ?? 0
        let memory = DiskCollector.int64(stats, memoryKey).map { UInt64(max(0, $0)) }
        return GPUSample(name: name, utilization: utilization, memoryBytes: memory)
    }

    private func statistics(of entry: io_service_t) -> CFDictionary? {
        guard let value = IORegistryEntryCreateCFProperty(entry, statsKey, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        return (value as! CFDictionary)
    }

    private func find() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if accelerator == 0, statistics(of: entry) != nil {
                accelerator = entry
                name = Self.model(of: entry) ?? "GPU"
            } else {
                IOObjectRelease(entry)
            }
        }
    }

    /// "model" on the accelerator (Apple silicon) or on its parent PCI device (Intel / discrete).
    private static func model(of entry: io_service_t) -> String? {
        if let m = string(entry, "model") { return m }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return string(parent, "model")
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return (value as! String) }
        if CFGetTypeID(value) == CFDataGetTypeID() {
            let data = value as! Data
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }
}
