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
        case .claudeLive, .claudeSessions, .claudeUsage, .claudeAccounts: "Claude Code"
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

extension Screen {
    /// Sidebar order, top to bottom. Screen changes slide in the direction of travel through this list.
    static let sidebarGroups: [(title: String, screens: [Screen])] = [
        ("Mac", [.now, .today, .apps, .timeMachine, .diskCleanup]),
        ("Claude Code", [.claudeLive, .claudeSessions, .claudeUsage, .claudeAccounts]),
        ("Developer", [.ports, .docker]),
    ]
    static let sidebarOrder: [Screen] = sidebarGroups.flatMap(\.screens)
    var sidebarIndex: Int { Self.sidebarOrder.firstIndex(of: self) ?? 0 }
}

/// Shared navigation state for the main window.
///
/// Cross-screen hand-off (read by the screen that owns the selection):
/// - `selectedAppID`: an `AppSample.id` to select when the Apps screen shows. Set by the command palette
///   together with `screen = .apps`. The Apps screen should read it on appear and on change, select that
///   app, then set it back to `nil`.
/// - `selectedSessionID`: a `ClaudeSession.id`, same contract for the Sessions screen.
/// - `searchFocusRequest`: bumped by ⌘F. A screen with a search field attaches
///   `.screenSearchFocus($focused)` (Design/Shell.swift) and the field takes focus.
@MainActor
@Observable
final class Navigation {
    var screen: Screen = .now {
        didSet { if screen != oldValue { travel = screen.sidebarIndex >= oldValue.sidebarIndex ? .down : .up } }
    }
    /// Direction of the last screen change in sidebar order.
    private(set) var travel: Travel = .down
    enum Travel { case up, down }

    var selectedAppID: String?
    var selectedSessionID: String?
    var paletteOpen = false
    /// False while the main window is closed. The view tree is dropped then, so a hidden window
    /// costs no layout, no rendering and no memory for screen state.
    var windowOpen = false
    var searchFocusRequest = 0

    /// Shows a screen and asks it to select an item, in one step.
    func open(_ screen: Screen, appID: String? = nil, sessionID: String? = nil) {
        if let appID { selectedAppID = appID }
        if let sessionID { selectedSessionID = sessionID }
        self.screen = screen
    }
}
