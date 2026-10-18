import Foundation
import Observation

extension Notification.Name {
    /// Asks the app to show Time Machine at `userInfo["date"]` (a `Date`).
    static let vardisOpenTimeMachine = Notification.Name("vardisOpenTimeMachine")
    /// Asks the app to show Disk Cleanup.
    static let vardisOpenDiskCleanup = Notification.Name("vardisOpenDiskCleanup")
}

/// Hand-off to Time Machine from other screens.
///
/// Contract: a screen that wants Time Machine at a moment calls `TimeMachineFocus.shared.open(at:)`.
/// That sets `pending`, bumps `request`, and posts `.vardisOpenTimeMachine` with the date in
/// `userInfo["date"]`. The shell (MainView) may observe `request` or the notification and switch to
/// `.timeMachine`; TimeMachineView moves its playhead to `pending` when it appears or when the
/// notification arrives, then clears `pending`.
@MainActor
@Observable
final class TimeMachineFocus {
    static let shared = TimeMachineFocus()

    /// The moment Time Machine should show next; nil once taken.
    private(set) var pending: Date?
    /// Increases with every request, so observers see repeats of the same date.
    private(set) var request = 0

    func open(at date: Date) {
        pending = date
        request += 1
        NotificationCenter.default.post(name: .vardisOpenTimeMachine, object: nil, userInfo: ["date": date])
    }

    /// Returns the pending moment and clears it.
    func take() -> Date? {
        defer { pending = nil }
        return pending
    }
}
