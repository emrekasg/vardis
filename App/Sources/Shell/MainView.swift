import SwiftUI
import VardisCore

struct MainView: View {
    @Environment(Navigation.self) private var nav
    @State private var subtitle: String?
    @State private var screenHasSearch = false

    var body: some View {
        if nav.windowOpen { content } else { Color.clear }
    }

    private var content: some View {
        ZStack {
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 240)
                Rectangle().fill(Theme.separator).frame(width: 1)
                VStack(spacing: 0) {
                    Color.clear.frame(height: Toolbar.height)
                    Hairline()
                    ZStack {
                        ScreenHost(screen: nav.screen)
                            .id(nav.screen)
                            .modifier(ScreenSwitchTransition(travel: nav.travel))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .motion(Motion.screen, value: nav.screen)
                    .environment(\.cancelShortcutBlocked, nav.paletteOpen)
                }
                .overlayPreferenceValue(ToolbarAccessoryKey.self, alignment: .top) { accessory in
                    Toolbar(screen: nav.screen, subtitle: subtitle, accessory: accessory?.view)
                }
                .onPreferenceChange(ToolbarSubtitleKey.self) { v in MainActor.assumeIsolated { subtitle = v } }
                .onPreferenceChange(ScreenHasSearchKey.self) { v in MainActor.assumeIsolated { screenHasSearch = v } }
                .background(Theme.window)
            }
            CommandPaletteOverlay(initialQuery: PaletteDebug.initialQuery)
                .allowsHitTesting(nav.paletteOpen)
        }
        .background { KeyboardShortcuts(screenHasSearch: screenHasSearch) }
        .frame(minWidth: 1100, minHeight: 720)
        .ignoresSafeArea()
    }
}

/// `--palette <query>` opens the palette with a query, for snapshots.
enum PaletteDebug {
    static let initialQuery: String = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--palette"), i + 1 < a.count else { return "" }
        return a[i + 1]
    }()
}

/// Window-wide shortcuts. They exist only inside the main window, so they never fire elsewhere.
private struct KeyboardShortcuts: View {
    @Environment(Navigation.self) private var nav
    let screenHasSearch: Bool

    var body: some View {
        ZStack {
            shortcut("k") { nav.paletteOpen.toggle() }
            shortcut("f") {
                if screenHasSearch && !nav.paletteOpen { nav.searchFocusRequest += 1 } else { nav.paletteOpen = true }
            }
            ForEach(Array(Screen.sidebarOrder.prefix(9).enumerated()), id: \.element) { i, screen in
                shortcut(KeyEquivalent(Character(String(i + 1)))) { nav.paletteOpen = false; nav.screen = screen }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcut(_ key: KeyEquivalent, _ action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(key, modifiers: .command).buttonStyle(.plain)
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

