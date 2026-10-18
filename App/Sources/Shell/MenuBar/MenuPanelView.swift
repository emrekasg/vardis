import AppKit
import SwiftUI
import VardisCore

/// Root of the menu bar panel: icon tabs, the selected tab, and the footer.
struct MenuPanelView: View {
    @Bindable var state: MenuPanelState
    let open: (Screen?) -> Void
    let settings: () -> Void
    let onHeight: (CGFloat) -> Void

    @Environment(LiveModel.self) private var live
    @Environment(ClaudeModel.self) private var claude
    @Namespace private var pill
    private var prefs: MenuBarPrefs { .shared }

    /// Tabs the user turned on that this Mac can fill (no Battery tab on a desktop, no Claude tab without Claude data).
    private var tabs: [MenuTab] {
        let s = live.snapshot
        let list = prefs.enabledTabs.filter { t in
            switch t {
            case .battery: s?.battery != nil
            case .gpu: s?.gpu != nil
            case .claude: !claude.accounts.isEmpty || !claude.live.isEmpty
            default: true
            }
        }
        return list.isEmpty ? [.overview] : list
    }

    private var current: MenuTab { tabs.contains(state.tab) ? state.tab : tabs[0] }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            ZStack(alignment: .top) {
                content(current)
                    .id(current)
                    .transition(TabSlide.transition(forward: state.forward))
            }
            .padding(.horizontal, 12)
            .clipped()
            footer
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .frame(width: MenuPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                TabIcon(tab: t, isSelected: t == current, pill: pill) { select(t) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .padding(3)
        .background(PanelColor.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .motion(Motion.travel, value: current)
    }

    private func select(_ t: MenuTab) {
        guard t != current else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.screen) { state.tab = t }
    }

    @ViewBuilder private func content(_ t: MenuTab) -> some View {
        switch t {
        case .overview: OverviewTab(open: open)
        case .cpu: CPUTab()
        case .memory: MemoryTab()
        case .disk: DiskTab(open: open)
        case .network: NetworkTab()
        case .gpu: GPUTab()
        case .battery: BatteryTab()
        case .ports:
            // Only while open: the section scans ports while it is on screen.
            if state.isOpen { PortsMenuSection(open: open).frame(maxWidth: .infinity, alignment: .leading) } else { Color.clear.frame(height: 200) }
        case .claude: ClaudeTab()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { open(current.screen) } label: {
                HStack(spacing: 7) {
                    Image(nsImage: MenuBarGlyph.image(size: 14)).renderingMode(.template)
                    Text("Open \(Brand.name)").font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(PanelButtonStyle())
            .keyboardShortcut(.defaultAction)
            .help("Open \(Brand.name) on \(current.screen.title) (⌥⌘V)")
            Button(action: settings) {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).frame(width: 40, height: 36)
            }
            .buttonStyle(PanelButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .help("Menu Bar settings")
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 13, weight: .medium))
                    Text("Quit").font(.system(size: 13, weight: .medium))
                }
                .frame(width: 84, height: 36)
            }
            .buttonStyle(PanelButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit \(Brand.name)")
        }
        .foregroundStyle(Theme.text)
    }
}

private struct TabIcon: View {
    let tab: MenuTab
    let isSelected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : hovering ? Theme.text : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent)
                            .matchedGeometryEffect(id: "tab-pill", in: pill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
    }
}

/// Footer and row buttons: translucent fill, a touch brighter on hover, dimmer when pressed.
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelButton(configuration: configuration)
    }

    private struct PanelButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(configuration.isPressed ? PanelColor.controlPressed : hovering ? PanelColor.controlHover : PanelColor.control,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
                .motion(Motion.quick, value: hovering)
        }
    }
}

/// Tab content slides a few points in the direction of travel and fades. Reduce Motion keeps the fade.
enum TabSlide {
    static func transition(forward: Bool) -> AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 18 : -18)),
                           removal: .opacity.combined(with: .offset(x: forward ? -18 : 18)))
    }
}
