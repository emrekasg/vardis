import SwiftUI
import VardisCore
import VardisStore

/// How an event looks and reads wherever it is listed.
enum EventStyle {
    static func color(_ e: HistoryEvent) -> Color {
        switch e.kind {
        case .memoryPressure: e.detail == MemoryPressure.critical.rawValue ? Theme.red : (e.detail == MemoryPressure.warning.rawValue ? Theme.orange : Theme.green)
        case .swapGrew, .memoryGrowth: Theme.red
        case .cpuHog, .cpuHogEnded: Theme.Metric.cpu
        case .keptAwakeStarted, .keptAwakeEnded: Theme.orange
        case .sleep, .wake: Theme.textTertiary
        case .appLaunched, .appQuit: Theme.textSecondary
        }
    }

    static func symbol(_ e: HistoryEvent) -> String {
        switch e.kind {
        case .memoryPressure, .swapGrew: "memorychip"
        case .memoryGrowth: "chart.line.uptrend.xyaxis"
        case .cpuHog, .cpuHogEnded: "cpu"
        case .keptAwakeStarted, .keptAwakeEnded: "moon"
        case .sleep: "moon.zzz"
        case .wake: "sunrise"
        case .appLaunched: "arrow.up.forward.app"
        case .appQuit: "xmark.app"
        }
    }

    static func text(_ e: HistoryEvent) -> String {
        let app = e.app ?? "An app"
        switch e.kind {
        case .appLaunched: return "\(app) opened"
        case .appQuit: return "\(app) quit"
        case .memoryPressure:
            switch e.detail {
            case MemoryPressure.critical.rawValue: return "Memory pressure turned critical"
            case MemoryPressure.warning.rawValue: return "Memory pressure rose to warning"
            default: return "Memory pressure back to normal"
            }
        case .swapGrew: return e.detail
        case .cpuHog: return "\(app) went above 80% CPU"
        case .cpuHogEnded: return "\(app) calmed down after \(Fmt.duration(e.value ?? 0))"
        case .memoryGrowth: return "\(app) memory keeps growing: \(e.detail)"
        case .sleep: return "Mac went to sleep"
        case .wake: return "Mac woke up"
        case .keptAwakeStarted: return "\(app) started keeping the Mac awake"
        case .keptAwakeEnded: return "\(app) let the Mac sleep again after \(Fmt.duration(e.value ?? 0))"
        }
    }

    /// Kinds worth a dot on a chart; launches and quits would drown everything else.
    static func isNotable(_ e: HistoryEvent) -> Bool {
        switch e.kind {
        case .appLaunched, .appQuit, .cpuHogEnded, .keptAwakeEnded: false
        default: true
        }
    }
}

extension Standout.Tone {
    var color: Color {
        switch self {
        case .orange: Theme.orange
        case .red: Theme.red
        case .blue: Theme.accent
        case .green: Theme.green
        case .neutral: Theme.textSecondary
        }
    }
}
