import SwiftUI
import VardisClaude
import VardisCore

/// Screens in three collapsible groups, with quiet counts and the active Claude account at the bottom.
/// ⌘1…⌘9 pick screens from anywhere in the window; ↑ and ↓ move while the sidebar has focus.
struct Sidebar: View {
    @Environment(Navigation.self) private var nav
    @Namespace private var pill
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""
    @FocusState private var focused: Bool

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Toolbar.height) // traffic lights live here
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Screen.sidebarGroups, id: \.title) { group in
                        let isCollapsed = collapsed.contains(group.title)
                        GroupHeader(title: group.title, isCollapsed: isCollapsed) { toggle(group.title) }
                        ForEach(group.screens.filter { !isCollapsed || $0 == nav.screen }) { screen in
                            SidebarRow(screen: screen, isSelected: nav.screen == screen, pill: pill) { select(screen) }
                                .transition(.opacity.combined(with: .offset(y: -4)))
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            ActiveAccountCard()
        }
        .motion(Motion.travel, value: nav.screen)
        .motion(Motion.quick, value: collapsedRaw)
        .background(Theme.sidebar)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
    }

    private func select(_ screen: Screen) {
        nav.screen = screen
        focused = true
    }

    private func step(_ delta: Int) {
        let visible = Screen.sidebarGroups.flatMap { g in collapsed.contains(g.title) ? g.screens.filter { $0 == nav.screen } : g.screens }
        guard let i = visible.firstIndex(of: nav.screen) else { return }
        let j = i + delta
        if visible.indices.contains(j) { nav.screen = visible[j] }
    }

    private func toggle(_ group: String) {
        var c = collapsed
        if c.contains(group) { c.remove(group) } else { c.insert(group) }
        collapsedRaw = c.sorted().joined(separator: ",")
    }
}

private struct GroupHeader: View {
    let title: String
    let isCollapsed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.captionStrongV).foregroundStyle(Theme.textTertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .opacity(hovering || isCollapsed ? 1 : 0)
            }
            .padding(.leading, 24).padding(.trailing, 22).padding(.top, 14).padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .motion(Motion.quick, value: isCollapsed)
        .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
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
                Spacer(minLength: 4)
                SidebarBadge(screen: screen)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A quiet count at the end of a row. Each badge reads only its own model, so a tick redraws one label.
private struct SidebarBadge: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .apps: AppsBadge()
        case .diskCleanup: CleanupBadge()
        case .claudeLive: ClaudeLiveBadge()
        case .ports: PortsBadge()
        default: EmptyView()
        }
    }
}

private struct BadgeText: View {
    let text: String
    var tone: Color = Theme.textTertiary

    var body: some View {
        Text(text).font(.captionV).monospacedDigit().foregroundStyle(tone)
            .contentTransition(.numericText())
            .motion(Motion.value, value: text)
    }
}

private struct AppsBadge: View {
    @Environment(LiveModel.self) private var live
    var body: some View {
        if let n = live.snapshot?.apps.count { BadgeText(text: Fmt.grouped(n)) }
    }
}

private struct CleanupBadge: View {
    @Environment(CleanupModel.self) private var cleanup
    var body: some View {
        let bytes = cleanup.groups.reduce(UInt64(0)) { sum, g in sum + g.items.reduce(0) { $0 + ($1.isAdvisory ? 0 : $1.sizeBytes) } }
        if bytes >= 1_000_000_000 { BadgeText(text: Fmt.bytes(bytes)).help("Reclaimable") }
    }
}

private struct ClaudeLiveBadge: View {
    @Environment(ClaudeModel.self) private var claude
    var body: some View {
        let waiting = claude.live.filter { $0.status() == .waiting }.count
        if waiting > 0 {
            BadgeText(text: "\(waiting) waiting", tone: Theme.orange)
        } else if !claude.live.isEmpty {
            BadgeText(text: "\(claude.live.count)")
        }
    }
}

/// The account new Claude Code sessions start on, with its 5-hour window when Vardis can read it.
private struct ActiveAccountCard: View {
    @Environment(ClaudeModel.self) private var claude
    @Environment(Navigation.self) private var nav
    @State private var hovering = false

    var body: some View {
        if let account = claude.activeAccount {
            let five = claude.quota(account)?.fiveHour
            Button { nav.screen = .claudeAccounts } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.claude.opacity(0.15)).frame(width: 22, height: 22)
                            .overlay(Text(String(account.name.prefix(1)).uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.claude))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(account.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(account.plan.map { "\($0) plan" } ?? "Active account").font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if claude.supportsQuota, let five {
                        QuotaMeterView(window: five, color: Theme.claude)
                    }
                }
                .padding(10)
                .background(Theme.selected.opacity(hovering ? 0.8 : 0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .motion(Motion.quick, value: hovering)
            .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
            .help("Claude Code accounts")
            .transition(.opacity)
        }
    }
}
