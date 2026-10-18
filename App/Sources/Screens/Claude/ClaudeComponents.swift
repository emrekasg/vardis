import AppKit
import SwiftUI
import VardisClaude
import VardisCore

/// Registers a Claude screen with `ClaudeModel` while it is on screen and its window is visible,
/// so live detection and fast quota polling run only then.
struct ClaudePresence: ViewModifier {
    let id: String
    @Environment(ClaudeModel.self) private var claude
    @State private var appeared = false
    @State private var windowVisible = true

    func body(content: Content) -> some View {
        content
            .background(WindowVisibility(visible: $windowVisible))
            .onAppear { appeared = true; update() }
            .onDisappear { appeared = false; update() }
            .onChange(of: windowVisible) { update() }
    }

    private func update() { claude.setPresenting(id, appeared && windowVisible) }
}

/// Reports whether the hosting window is visible (not closed, minimised or fully covered).
private struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = { visible = $0 }
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let w = self.window else { return }
                        self.onChange?(!closing && w.isVisible && w.occlusionState.contains(.visible))
                    }
                })
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension View {
    func claudePresence(_ id: String) -> some View { modifier(ClaudePresence(id: id)) }
}

enum ClaudeFmt {
    static func time(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) } ?? "–" }
    static func day(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "–" }
    static func weekdayTime(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated)) + " " + time(d) }

    /// "16:40" today, "Tue" within a week, else "14 Oct".
    static func reset(_ d: Date?) -> String {
        guard let d else { return "" }
        if Calendar.current.isDateInToday(d) { return time(d) }
        if d.timeIntervalSinceNow < 6 * 86_400 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return day(d)
    }

    /// "Today 13:20", "Fri 21:05", "3 Oct 11:02".
    static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today " + time(d) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday " + time(d) }
        if Date().timeIntervalSince(d) < 6 * 86_400 { return weekdayTime(d) }
        return day(d) + " " + time(d)
    }

    /// "45 s", "3 h 5 m", "12 d 9 h".
    static func elapsed(since d: Date?) -> String {
        guard let d else { return "" }
        return DurationFmt.compact(Date().timeIntervalSince(d))
    }

    /// Fmt.tokens with a billions step: 28.4B, 412M, 9.8k.
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e10 { return "\(Int((d / 1e9).rounded()))B" }
        if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1e8 { return "\(Int((d / 1e6).rounded()))M" }
        return Fmt.tokens(n)
    }

    /// "$9,666", "$412", "$3.90", with fixed grouping so a locale's "." separator never reads as a decimal point.
    static func usd(_ v: Double) -> String {
        guard v >= 100 else { return String(format: "$%.2f", v) }
        let digits = String(Int(v.rounded()))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return "$" + out
    }

    static func percent(_ utilization: Double?) -> String { utilization.map { "\(Int($0.rounded()))%" } ?? "–" }
}

/// Label over a large number with a caption under it, as in the Live and Usage stat rows.
struct ClaudeStat: View {
    let label: String
    let value: String
    var caption: String?
    var meter: (Double, Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.calloutV).foregroundStyle(Theme.textSecondary)
            Text(value).font(.numericL).foregroundStyle(Theme.text)
                .contentTransition(.numericText())
                .motion(Motion.quick, value: value)
                .lineLimit(1)
            if let meter { Meter(value: meter.0, color: meter.1).frame(width: 140) }
            if let caption { Text(caption).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A plan window as a meter with "62% · resets 16:40".
struct QuotaMeterView: View {
    let window: QuotaWindow?
    var color: Color = Theme.accent
    var label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                HStack {
                    Text(label).font(.captionV).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(text).font(.captionStrongV).foregroundStyle(Theme.text)
                }
            }
            Meter(value: (window?.utilization ?? 0) / 100, color: tone)
            if label == nil {
                Text(text).font(.captionV).foregroundStyle(isFull ? Theme.orange : Theme.textSecondary)
            }
        }
    }

    private var isFull: Bool { (window?.utilization ?? 0) >= 100 }
    private var tone: Color { isFull ? Theme.orange : color }
    private var text: String {
        guard let w = window else { return "–" }
        let reset = ClaudeFmt.reset(w.resetsAt)
        return ClaudeFmt.percent(w.utilization) + (reset.isEmpty ? "" : " \u{00B7} resets \(reset)")
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String?
    var trailingTone: Color = Theme.textTertiary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headlineV).foregroundStyle(Theme.text)
            Spacer()
            if let trailing { Text(trailing).font(.captionV).foregroundStyle(trailingTone) }
        }
    }
}

/// Calm one-line progress for the first index ("Indexing 1,617 files…"), never an overlay.
struct IndexingLine: View {
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        if let p = claude.indexing {
            HStack(spacing: 8) {
                ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                    .progressViewStyle(.linear).frame(width: 120).tint(Theme.claude)
                Text(p.total > 0 ? "Indexing \(p.total.formatted()) files\u{2026}" : "Looking for Claude Code sessions\u{2026}")
                    .font(.captionV).foregroundStyle(Theme.textSecondary)
            }
            .transition(.opacity)
        }
    }
}

/// Empty state with a symbol and one or two lines. Same look as every other screen's `EmptyState`.
struct ClaudeEmpty: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View { EmptyState(symbol: symbol, title: title, detail: detail) }
}

/// Plain bordered button matching the design's secondary buttons.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.raised.opacity(configuration.isPressed ? 1 : 0.75), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .motion(Motion.quick, value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.window)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .motion(Motion.quick, value: configuration.isPressed)
    }
}
