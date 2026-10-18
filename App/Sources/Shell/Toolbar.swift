import SwiftUI
import VardisCore

/// The main window's unified toolbar: title with an optional subtitle, the screen's accessory, and search.
/// It sits in the window's 52 pt title bar, so the traffic lights share its centre line.
struct Toolbar: View {
    static let height: CGFloat = 52
    let screen: Screen
    let subtitle: String?
    let accessory: AnyView?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(screen.toolbarTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Group {
                    if let subtitle {
                        if !subtitle.isEmpty { Text(subtitle) }
                    } else {
                        DefaultSubtitle(screen: screen)
                    }
                }
                .font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                .contentTransition(.numericText())
            }
            .id(screen)
            .transition(.opacity)
            Spacer(minLength: 16)
            if let accessory { accessory.transition(.opacity) }
            ToolbarSearchField()
        }
        .padding(.leading, 20).padding(.trailing, 14)
        .frame(height: Self.height)
        .motion(Motion.quick, value: screen)
    }
}

/// Subtitles the shell can compute from data in memory. A screen overrides it with `.toolbarSubtitle(_:)`.
private struct DefaultSubtitle: View {
    let screen: Screen
    @Environment(LiveModel.self) private var live
    @Environment(ClaudeModel.self) private var claude

    var body: some View {
        if let text { Text(text).motion(Motion.quick, value: text) }
    }

    private var text: String? {
        switch screen {
        case .apps:
            guard let s = live.snapshot else { return nil }
            return "\(Fmt.grouped(s.apps.count)) apps, \(Fmt.grouped(s.processCount)) processes"
        case .claudeLive, .claudeSessions, .claudeUsage, .claudeAccounts:
            return screen.title
        default:
            return nil
        }
    }
}

/// Looks like a search field; opens the command palette, where the typing happens.
private struct ToolbarSearchField: View {
    @Environment(Navigation.self) private var nav
    @State private var hovering = false

    var body: some View {
        Button { nav.paletteOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                Text("Search").font(.bodyV)
                Spacer(minLength: 8)
                Text("\u{2318}K").font(.captionV).foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(width: 200, height: 28)
            .background(Theme.raised.opacity(hovering ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .help("Search screens, apps, sessions and actions (\u{2318}K)")
        .accessibilityLabel("Search")
    }
}
