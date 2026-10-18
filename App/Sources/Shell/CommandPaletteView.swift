import AppKit
import SwiftUI
import VardisCore

/// ⌘K: one field that reaches every screen, running app, Claude session and common action.
/// The index is built once when the palette opens; each keystroke only filters it.
struct CommandPaletteView: View {
    @Environment(Navigation.self) private var nav
    @Environment(LiveModel.self) private var live
    @Environment(ClaudeModel.self) private var claude
    @Environment(CleanupModel.self) private var cleanup
    @State private var query: String
    @State private var index: [PaletteEntry] = []
    @State private var highlighted = 0
    @State private var hovered: String?
    @FocusState private var fieldFocused: Bool

    init(initialQuery: String = "") { _query = State(initialValue: initialQuery) }

    private var results: [PaletteEntry] { PaletteMatcher.results(index, query: query) }

    var body: some View {
        let rows = results
        let selected = rows.isEmpty ? nil : rows[min(highlighted, rows.count - 1)]
        VStack(spacing: 0) {
            field(rows: rows, selected: selected)
            if !rows.isEmpty || !query.isEmpty { Hairline() }
            list(rows: rows, selected: selected)
        }
        .frame(width: 580)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .background {
            // Escape is a key equivalent, so it must be a shortcut to win over a drawer underneath.
            Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onAppear {
            index = PaletteIndex.build(live: live, claude: claude)
            fieldFocused = true
        }
        .onChange(of: query) { highlighted = 0 }
        // Opened before the first sample or the index load: pick up apps and sessions once they exist.
        .onChange(of: live.snapshot == nil) { refreshIfMissing() }
        .onChange(of: claude.sessions.isEmpty) { refreshIfMissing() }
    }

    private func field(rows: [PaletteEntry], selected: PaletteEntry?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textTertiary)
            TextField("Search screens, apps, sessions and actions", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onSubmit { if let selected { run(selected) } }
                .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
        }
        .padding(.horizontal, 16).frame(height: 50)
    }

    @ViewBuilder private func list(rows: [PaletteEntry], selected: PaletteEntry?) -> some View {
        if rows.isEmpty {
            if !query.isEmpty {
                Text("Nothing matches \u{201C}\(query)\u{201D}").font(.calloutV).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                            if i == 0 || rows[i - 1].section != e.section {
                                Text(e.section.title).font(.captionStrongV).foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 12).padding(.top, i == 0 ? 6 : 12).padding(.bottom, 4)
                            }
                            PaletteRow(entry: e, isSelected: e.id == selected?.id)
                                .id(e.id)
                                .contentShape(Rectangle())
                                .onTapGesture { run(e) }
                                .onHover { if $0 { highlighted = i } }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlighted) { if let id = rows[safe: highlighted]?.id { proxy.scrollTo(id) } }
            }
        }
    }

    private func refreshIfMissing() {
        let hasApps = index.contains { $0.section == .apps }
        let hasSessions = index.contains { $0.section == .sessions }
        if (!hasApps && live.snapshot != nil) || (!hasSessions && !claude.sessions.isEmpty) {
            index = PaletteIndex.build(live: live, claude: claude)
        }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = (min(highlighted, count - 1) + delta + count) % count
    }

    private func close() { nav.paletteOpen = false }

    private func run(_ e: PaletteEntry) {
        close()
        switch e.target {
        case .screen(let s): nav.screen = s
        case .app(let id): nav.open(.apps, appID: id)
        case .session(let id): nav.open(.claudeSessions, sessionID: id)
        case .action(let a):
            switch a {
            case .rescanDisk: cleanup.rescan(); nav.screen = .diskCleanup
            case .openSettings: NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
            case .togglePause: live.isPaused.toggle()
            case .toggleAppearance:
                let next = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "light" : "dark"
                UserDefaults.standard.set(next, forKey: Pref.appearance)
                Appearance.apply(next)
            case .quit: NSApp.terminate(nil)
            }
        }
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if entry.section == .apps {
                    AppIconView(bundleURL: entry.bundleURL, name: entry.title, size: 18)
                } else if let symbol = entry.symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(entry.section == .sessions ? Theme.claude : Theme.textSecondary)
                }
            }
            .frame(width: 20)
            Text(entry.title).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
            if let s = entry.subtitle {
                Text(s).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let k = entry.shortcut {
                Text(k).font(.captionV).foregroundStyle(Theme.textTertiary)
            } else if isSelected {
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(isSelected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Dim layer and spring for the palette. Clicking outside closes it.
struct CommandPaletteOverlay: View {
    @Environment(Navigation.self) private var nav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var initialQuery = ""

    var body: some View {
        ZStack(alignment: .top) {
            if nav.paletteOpen {
                Color.black.opacity(0.10)
                    .contentShape(Rectangle())
                    .onTapGesture { nav.paletteOpen = false }
                    .transition(.opacity)
                CommandPaletteView(initialQuery: initialQuery)
                    .padding(.top, 96)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : Motion.panel, value: nav.paletteOpen)
    }
}
