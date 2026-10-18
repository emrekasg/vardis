import Foundation
import IOKit
import IOKit.ps
import VardisCore

/// Battery state from the power-source API plus `AppleSmartBattery` registry details. Nil on desktops.
final class BatteryCollector {
    private var battery: io_service_t = 0
    private var looked = false
    private var cycleCount: Int?
    private var health: Double?
    private var detailsReadAt: UInt64 = 0
    private let detailsInterval: UInt64 = 60_000_000_000

    private let voltageKey = "Voltage" as CFString
    private let amperageKey = "InstantAmperage" as CFString
    private let cycleKey = "CycleCount" as CFString
    private let rawMaxKey = "AppleRawMaxCapacity" as CFString
    private let designKey = "DesignCapacity" as CFString

    deinit {
        if battery != 0 { IOObjectRelease(battery) }
    }

    func sample(now: UInt64) -> BatterySample? {
        if !looked {
            looked = true
            battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard let source = Self.internalBattery() else { return nil }

        let current = (source[kIOPSCurrentCapacityKey] as? Int) ?? 0
        let max = (source[kIOPSMaxCapacityKey] as? Int) ?? 100
        let charging = (source[kIOPSIsChargingKey] as? Bool) ?? false
        let onBattery = (source[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        let minutes = charging ? source[kIOPSTimeToFullChargeKey] as? Int : source[kIOPSTimeToEmptyKey] as? Int
        let remaining = minutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil }

        var watts: Double?
        if battery != 0 {
            if detailsReadAt == 0 || now &- detailsReadAt >= detailsInterval {
                detailsReadAt = now
                cycleCount = int(cycleKey).map { Int($0) }
                if let raw = int(rawMaxKey), let design = int(designKey), design > 0 {
                    health = min(1, Swift.max(0, Double(raw) / Double(design)))
                }
            }
            if let mV = int(voltageKey), let mA = int(amperageKey) {
                watts = -Double(mV) * Double(mA) / 1e6
            }
        }
        return BatterySample(charge: max > 0 ? min(1, Double(current) / Double(max)) : 0, isCharging: charging, onBattery: onBattery,
                             timeRemaining: remaining, watts: watts, cycleCount: cycleCount, health: health)
    }

    private func int(_ key: CFString) -> Int64? {
        guard let value = IORegistryEntryCreateCFProperty(battery, key, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var out: Int64 = 0
        CFNumberGetValue((value as! CFNumber), .sInt64Type, &out)
        return out
    }

    private static func internalBattery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType { return desc }
        }
        return nil
    }
}
