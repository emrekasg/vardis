import Foundation
import VardisCore
import VardisSampling

/// What Now shows in its drawers, one case per metric.
enum NowMetric: String, Identifiable, Equatable, CaseIterable, Sendable {
    case cpu, memory, network, disk, gpu, power
    var id: String { rawValue }
}

/// Small readings Now needs that are not part of a Snapshot. All cheap enough to read per tick.
enum NowFacts {
    static var cores: CoreLayout { CoreLayout.current }

    static func load() -> (one: Double, five: Double, fifteen: Double) { loadAverages() }

    /// nil while nominal: Now shows thermal state only when macOS reports throttling.
    static func thermal(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> (label: String, detail: String, severe: Bool)? {
        switch state {
        case .nominal: nil
        case .fair: ("Thermal: fair", "The Mac is warm; macOS may slow background work.", false)
        case .serious: ("Thermal: serious", "macOS is slowing the CPU to cool down.", true)
        case .critical: ("Thermal: critical", "macOS is slowing the Mac heavily to cool down.", true)
        @unknown default: nil
        }
    }

    static func pressureLabel(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    static func pressureExplanation(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "Memory is used efficiently. Free and cached memory are available."
        case .warning: "macOS is compressing memory and may start using swap."
        case .critical: "The Mac is short of memory and relies on swap. Quitting a large app helps."
        }
    }

    /// Change of the oldest vs newest reading, nil when flat (under 1%).
    static func trend(_ values: [Double]) -> Double? {
        guard let first = values.first(where: { $0 > 0 }), let last = values.last, first > 0 else { return nil }
        let change = (last - first) / first
        return abs(change) < 0.01 ? nil : last - first
    }
}
