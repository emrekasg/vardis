import SwiftUI
import VardisCore

/// Apps pinned from the Apps screen, as compact live rows with CPU and memory over the last minute.
struct WatchListTile: View {
    @Environment(LiveModel.self) private var live
    @State private var prefs = NowPrefs.shared
    let snapshot: Snapshot
    let openApp: (AppSample) -> Void

    var body: some View {
        NowCard(title: "Watch list", symbol: "pin", color: Theme.accent) {
            if prefs.watchlist.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "pin.slash").foregroundStyle(Theme.textTertiary)
                    Text("Pin apps to watch them here. In Apps, right-click an app and choose Pin to Now.")
                        .font(.calloutV).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    header
                    ForEach(prefs.watchlist, id: \.self) { id in
                        WatchRow(id: id, app: snapshot.apps.first { $0.id == id }, openApp: openApp)
                            .transition(.row)
                    }
                }
                .animatesRows(prefs.watchlist)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 56, alignment: .trailing)
            Text("Last minute").frame(width: 120, alignment: .leading)
            Text("Memory").frame(width: 72, alignment: .trailing)
            Text("Last minute").frame(width: 120, alignment: .leading)
            Color.clear.frame(width: 20)
        }
        .font(.captionV).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

private struct WatchRow: View {
    @Environment(LiveModel.self) private var live
    @State private var prefs = NowPrefs.shared
    let id: String
    let app: AppSample?
    let openApp: (AppSample) -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                AppIconView(bundleURL: app?.bundleURL, name: app?.name ?? id, size: 18)
                Text(app?.name ?? id).font(.bodyV).foregroundStyle(app == nil ? Theme.textTertiary : Theme.text).lineLimit(1)
                if app == nil { Text("not running").font(.captionV).foregroundStyle(Theme.textTertiary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(app.map { Fmt.percent($0.cpu) } ?? "\u{2013}").font(.numeric).foregroundStyle(Theme.text)
                .frame(width: 56, alignment: .trailing)
            Sparkline(values: live.appCPU[id]?.elements ?? [], color: Theme.Metric.cpu).frame(width: 120, height: 18)
            Text(app.map { Fmt.bytes($0.memory) } ?? "\u{2013}").font(.numeric).foregroundStyle(Theme.text)
                .frame(width: 72, alignment: .trailing)
            Sparkline(values: live.appMemory[id]?.elements ?? [], color: Theme.Metric.memory).frame(width: 120, height: 18)
            Button { prefs.togglePin(id) } label: {
                Image(systemName: "pin.slash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 20)
            .help("Unpin")
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .contentShape(Rectangle())
        .modifier(HoverHighlight())
        .onTapGesture { if let app { openApp(app) } }
        .help(app.map { "Show \($0.name) in Apps" } ?? "")
    }
}
