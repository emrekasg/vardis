import SwiftUI
import VardisCore

struct MainView: View {
    @Environment(Navigation.self) private var nav
    @Environment(LiveModel.self) private var live

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 240)
            Rectangle().fill(Theme.separator).frame(width: 1)
            VStack(spacing: 0) {
                Toolbar(title: nav.screen.toolbarTitle)
                Hairline()
                ZStack {
                    ScreenHost(screen: nav.screen)
                        .id(nav.screen)
                        .modifier(ScreenTransition())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .motion(Motion.screen, value: nav.screen)
            }
            .background(Theme.window)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .ignoresSafeArea()
    }
}

/// Every screen view is cheap to build because data already lives in memory.
/// Switching only swaps the view; no loading state exists by design.
struct ScreenHost: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .now: NowView()
        case .today: TodayView()
        case .apps: AppsView()
        case .timeMachine: TimeMachineView()
        case .diskCleanup: DiskCleanupView()
        case .claudeLive: ClaudeLiveView()
        case .claudeSessions: ClaudeSessionsView()
        case .claudeUsage: ClaudeUsageView()
        case .claudeAccounts: ClaudeAccountsView()
        case .ports: PortsView()
        case .docker: DockerView()
        }
    }
}

struct PlannedScreen: View {
    let screen: Screen
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: screen.symbol).font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
            Text(screen.title).font(.titleV).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Toolbar: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                .contentTransition(.opacity)
                .motion(Motion.quick, value: title)
            Spacer()
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(height: 52)
    }
}

struct Sidebar: View {
    @Environment(Navigation.self) private var nav
    @Namespace private var pill

    private let groups: [(String, [Screen])] = [
        ("Mac", [.now, .today, .apps, .timeMachine, .diskCleanup]),
        ("Claude Code", [.claudeLive, .claudeSessions, .claudeUsage, .claudeAccounts]),
        ("Developer", [.ports, .docker]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 52) // traffic lights live here
            ForEach(groups, id: \.0) { group in
                Text(group.0)
                    .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 24).padding(.top, 14).padding(.bottom, 6)
                ForEach(group.1) { screen in
                    SidebarRow(screen: screen, isSelected: nav.screen == screen, pill: pill) { nav.screen = screen }
                }
            }
            Spacer()
        }
        .motion(Motion.travel, value: nav.screen)
        .background(Theme.sidebar)
    }
}

private struct SidebarRow: View {
    let screen: Screen
    let isSelected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: screen.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(screen.title).font(.bodyV).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.selected)
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.selected.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .padding(.horizontal, 16)
    }
}
