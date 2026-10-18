import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable, Sendable {
    case now, today, apps, timeMachine, diskCleanup
    case claudeLive, claudeSessions, claudeUsage, claudeAccounts
    case ports, docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Now"
        case .today: "Today"
        case .apps: "Apps"
        case .timeMachine: "Time Machine"
        case .diskCleanup: "Disk Cleanup"
        case .claudeLive: "Live"
        case .claudeSessions: "Sessions"
        case .claudeUsage: "Usage"
        case .claudeAccounts: "Accounts"
        case .ports: "Ports & Servers"
        case .docker: "Docker"
        }
    }

    /// Title shown in the toolbar (Claude screens share one).
    var toolbarTitle: String {
        switch self {
        case .claudeLive: "Claude Code"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .now: "bolt"
        case .today: "gauge.with.needle"
        case .apps: "square.grid.2x2"
        case .timeMachine: "clock"
        case .diskCleanup: "internaldrive"
        case .claudeLive: "waveform.path.ecg"
        case .claudeSessions: "bubble.left"
        case .claudeUsage: "chart.bar.xaxis"
        case .claudeAccounts: "person.2"
        case .ports: "powerplug"
        case .docker: "shippingbox"
        }
    }

    var group: String {
        switch self {
        case .now, .today, .apps, .timeMachine, .diskCleanup: "Mac"
        case .claudeLive, .claudeSessions, .claudeUsage, .claudeAccounts: "Claude Code"
        case .ports, .docker: "Developer"
        }
    }

    /// Screens that show per-second data switch sampling to fast mode.
    var wantsFastSampling: Bool { self == .now || self == .apps || self == .claudeLive }
}

@MainActor
@Observable
final class Navigation {
    var screen: Screen = .now
}
