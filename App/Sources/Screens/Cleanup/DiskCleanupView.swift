import SwiftUI
import VardisCleanup
import VardisCore
import VardisStore

struct DiskCleanupView: View {
    @Environment(CleanupModel.self) private var model
    @Environment(HistoryModel.self) private var history
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if model.needsFolderAccess {
                FolderAccessView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CleanupHeader()
                            .padding(.bottom, 22)
                        StorageBar()
                            .padding(.bottom, 18)
                        FreeSpaceTrend(points: history.freeSpace)
                        LastCleanupBanner()
                        if model.groups.isEmpty {
                            EmptyCleanup()
                        } else {
                            ViewModePicker().padding(.bottom, 12)
                            if model.viewMode == .byKind { CleanupList() } else { ProjectList() }
                        }
                        ReminderFooter().padding(.top, 28)
                    }
                    .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 24)
                }
                ActionBar(confirming: $confirming)
            }
        }
        .background(Theme.window)
        .sheet(isPresented: $confirming) { RemoveConfirmation(items: model.selectedItems) }
        .task { await history.refreshFreeSpace() }
    }
}

/// "up to 1.2 GB" when the size may count data shared with other items.
enum SizeText {
    static func of(_ item: CleanupItem) -> String { item.isUpperBound ? "up to \(Fmt.bytes(item.sizeBytes))" : Fmt.bytes(item.sizeBytes) }
}

// MARK: Header

private struct CleanupHeader: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            if model.result == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Measuring developer folders").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("The first look takes a few seconds. Results stay on this Mac and refresh on their own after that.")
                        .font(.bodyV).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text(Fmt.bytes(model.selectedBytes))
                    .font(.system(size: 40, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .motion(Motion.value, value: model.selectedBytes)
                Text(explanation)
                    .font(.bodyV).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer(minLength: 12)
            ScanStatus()
        }
    }

    private var explanation: String {
        let sel = model.selectedItems
        if sel.isEmpty { return "selected. Tick what can go; everything here was found in developer tool folders." }
        let upTo = sel.contains(where: \.isUpperBound) ? " Some sizes are upper bounds: shared layers and linked files free less." : ""
        if sel.contains(where: \.isPermanent) {
            return "selected. Docker items are removed for good, not moved to the Trash, so look through them first." + upTo
        }
        if sel.contains(where: { $0.safety == .notRebuildable || $0.safety == .reviewFirst || $0.safety == .activeProject }) {
            return "selected. Some of it does not come back on its own, so look through the ticked rows before moving them." + upTo
        }
        return "can go to the Trash without breaking anything. Everything selected is rebuilt or downloaded again the next time a tool needs it." + upTo
    }
}

private struct ScanStatus: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(status(now: ctx.date)).font(.captionV).foregroundStyle(Theme.textTertiary)
                    .contentTransition(.opacity)
                    .motion(Motion.quick, value: model.isScanning)
            }
            Button("Rescan") { model.rescan() }
                .buttonStyle(.link).font(.captionV)
                .disabled(model.isScanning)
        }
    }

    private func status(now: Date) -> String {
        if model.isScanning { return model.result == nil ? "Looking…" : "Rescanning in the background" }
        guard let at = model.scannedAt else { return "" }
        return "Scanned \(Self.ago(at, now: now)) · watching for changes"
    }

    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3_600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3_600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }
}

// MARK: Storage bar

private struct StorageBar: View {
    @Environment(CleanupModel.self) private var model

    private struct Segment: Identifiable {
        var id: String
        var bytes: UInt64
        var color: Color
    }

    var body: some View {
        let segs = segments
        let total = max(1, segs.reduce(0) { $0 + $1.bytes })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(segs) { s in
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(s.color)
                            .frame(width: max(s.bytes > 0 ? 3 : 0, (g.size.width - CGFloat(segs.count - 1) * 2) * CGFloat(Double(s.bytes) / Double(total))))
                    }
                }
                .motion(Motion.value, value: model.selectedBytes)
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                ForEach(segs) { s in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                        Text("\(s.id) \(Fmt.bytes(s.bytes))").font(.captionV).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                if let v = model.volume { Text("\(Fmt.bytes(v.total)) \(v.name)").font(.captionV).foregroundStyle(Theme.textTertiary) }
            }
        }
    }

    /// Docker data lives inside the engine's disk image, so it is counted with developer files only up to what the disk uses.
    private var segments: [Segment] {
        guard let v = model.volume else { return [] }
        let used = v.total > v.available ? v.total - v.available : 0
        let dev = min(model.totalBytes, used)
        let selected = min(model.selectedBytes, dev)
        return [
            Segment(id: "Everything else", bytes: used - dev, color: Theme.textTertiary.opacity(0.45)),
            Segment(id: "Developer files", bytes: dev - selected, color: Theme.accent.opacity(0.35)),
            Segment(id: "Selected", bytes: selected, color: Theme.accent),
            Segment(id: "Free", bytes: v.available, color: Theme.raised),
        ]
    }
}

// MARK: Free space trend

private struct FreeSpaceTrend: View {
    let points: [Point]

    var body: some View {
        if points.count >= 6, let first = points.first, let last = points.last {
            let delta = last.avg - first.avg
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Free space").font(.headlineV).foregroundStyle(Theme.text)
                    Text(caption(delta: delta, since: first.timestamp)).font(.captionV).foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                TimeChart(times: points.map(\.timestamp),
                          series: [ChartSeries(id: "Free", color: Theme.Metric.disk, values: points.map(\.avg))],
                          maxValue: (points.map(\.avg).max() ?? 1) * 1.15,
                          format: { Fmt.bytes(UInt64(max(0, $0))) },
                          timeFormat: .dateTime.day().month(.abbreviated).hour())
                    .frame(height: 64)
            }
            .padding(.bottom, 22)
            .transition(.opacity)
        }
    }

    private func caption(delta: Double, since: Date) -> String {
        let days = max(1, Int(Date().timeIntervalSince(since) / 86_400))
        let span = days >= 29 ? "last 30 days" : (days == 1 ? "since yesterday" : "last \(days) days")
        if abs(delta) < 1e9 { return "\(span) · about the same" }
        return "\(span) · \(delta < 0 ? "down" : "up") \(Fmt.bytes(UInt64(abs(delta))))"
    }
}

// MARK: Last cleanup

private struct LastCleanupBanner: View {
    @Environment(CleanupModel.self) private var model
    @State private var working = false

    var body: some View {
        if let c = model.lastCleanup, model.lastTrash == nil || model.putBackResult != nil {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 15)).foregroundStyle(Theme.textSecondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(c)).font(.headlineV).foregroundStyle(Theme.text)
                    Text(detail(c)).font(.captionV).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !c.trashed.isEmpty {
                    Button(working ? "Putting back…" : "Put Back") {
                        working = true
                        Task { await model.putBack(); working = false }
                    }
                    .disabled(working)
                }
                Button { model.forgetLastCleanup() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Forget this cleanup")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
            .padding(.bottom, 22)
            .transition(.opacity)
        }
    }

    private func title(_ c: CleanupModel.LastCleanup) -> String {
        let when = c.date.formatted(.relative(presentation: .named))
        if let r = model.putBackResult, !r.restored.isEmpty {
            return "Put back \(r.restored.count) \(r.restored.count == 1 ? "item" : "items")" + (r.failures.isEmpty ? "" : " · \(r.failures.count) could not")
        }
        return c.trashed.isEmpty ? "Last cleanup \(when)" : "Last cleanup \(when): \(Fmt.bytes(c.trashedBytes)) in the Trash"
    }

    private func detail(_ c: CleanupModel.LastCleanup) -> String {
        var parts: [String] = []
        if let f = model.putBackResult?.failures.first { parts.append("\(f.entry.title): \(f.reason)") }
        if !c.trashed.isEmpty { parts.append("Put Back moves \(c.trashed.count == 1 ? "it" : "them") to where \(c.trashed.count == 1 ? "it was" : "they were"), if the place is still free.") }
        if c.permanentCount > 0 {
            parts.append("\(c.permanentCount) Docker \(c.permanentCount == 1 ? "item" : "items") (\(Fmt.bytes(c.permanentBytes))) were removed by Docker and cannot be put back.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: View mode

private struct ViewModePicker: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        @Bindable var m = model
        HStack {
            Picker("", selection: $m.viewMode) {
                Text("By kind").tag(CleanupModel.ViewMode.byKind)
                Text("By project").tag(CleanupModel.ViewMode.byProject)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
    }
}

// MARK: List

enum CleanupColumns {
    static let lastUsed: CGFloat = 122
    static let safety: CGFloat = 150
    static let size: CGFloat = 104
}

private struct ColumnHeader: View {
    let first: String
    let second: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(first).frame(maxWidth: .infinity, alignment: .leading)
                Text(second).frame(width: CleanupColumns.lastUsed, alignment: .leading)
                Text("Safety").frame(width: CleanupColumns.safety, alignment: .leading)
                Text("Size").frame(width: CleanupColumns.size, alignment: .trailing)
            }
            .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8).padding(.bottom, 8)
            Hairline()
        }
    }
}

private struct CleanupList: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(first: "Item", second: "Last used")
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { i, g in
                GroupSection(group: g).staggeredAppear(i)
            }
        }
        .motion(Motion.screen, value: model.expanded)
    }
}

private struct GroupSection: View {
    @Environment(CleanupModel.self) private var model
    let group: CleanupGroup
    @State private var showAll = false

    private static let visibleLimit = 12

    var body: some View {
        let open = model.expanded.contains(group.category)
        VStack(spacing: 0) {
            GroupRow(group: group, open: open)
            if open {
                let items = showAll ? group.items : Array(group.items.prefix(Self.visibleLimit))
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        Hairline().padding(.leading, 44)
                        ItemRow(item: item).staggeredAppear(i)
                    }
                    if group.items.count > Self.visibleLimit && !showAll {
                        Hairline().padding(.leading, 44)
                        ShowMoreRow(rest: Array(group.items.dropFirst(Self.visibleLimit))) { showAll = true }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Hairline()
        }
        .clipped()
    }
}

private struct ShowMoreRow: View {
    let rest: [CleanupItem]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Show \(rest.count) more").font(.bodyV).foregroundStyle(Theme.accent)
                Spacer()
                Text(Fmt.bytes(rest.reduce(0) { $0 + $1.sizeBytes })).font(.numeric).foregroundStyle(Theme.textSecondary)
            }
            .padding(.leading, 72).padding(.trailing, 8).frame(height: 33).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GroupRow: View {
    @Environment(CleanupModel.self) private var model
    let group: CleanupGroup
    let open: Bool

    var body: some View {
        let advisory = group.items.allSatisfy(\.isAdvisory)
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Chevron(open: open)
                if advisory {
                    Color.clear.frame(width: 16, height: 16)
                } else {
                    TriCheckbox(state: model.check(group)) { model.toggle(group) }
                }
                Image(systemName: Self.symbol(group.category)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                Text(group.category.title).font(.headlineV).foregroundStyle(Theme.text)
                Text(summary).font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(open ? "" : lastUsed).font(.calloutV).foregroundStyle(Theme.textSecondary).frame(width: CleanupColumns.lastUsed, alignment: .leading)
            Group {
                if !open, let s = commonSafety { SafetyBadge(safety: s) } else { Color.clear.frame(height: 1) }
            }
            .frame(width: CleanupColumns.safety, alignment: .leading)
            Text((group.items.contains(where: \.isUpperBound) ? "up to " : "") + Fmt.bytes(group.totalBytes))
                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                .frame(width: CleanupColumns.size, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture {
            if open { model.expanded.remove(group.category) } else { model.expanded.insert(group.category) }
        }
        .modifier(HoverHighlight())
    }

    private var summary: String {
        let sel = model.selectedBytes(in: group)
        let n = group.items.count
        let base: String
        if sel == 0 { base = n == 1 ? "1 item, not selected" : "\(n) items, none selected" }
        else if sel == group.totalBytes { base = n == 1 ? "selected" : "all \(n) selected" }
        else { base = "\(Fmt.bytes(sel)) of \(Fmt.bytes(group.totalBytes)) selected" }
        return group.category.isDocker ? base + " · Docker removes these for good" : base
    }

    private var lastUsed: String {
        group.items.compactMap(\.lastUsed).max().map { LastUsed.text($0) } ?? ""
    }

    private var commonSafety: Safety? {
        let s = Set(group.items.map(\.safety))
        return s.count == 1 ? s.first : nil
    }

    static func symbol(_ c: CleanupCategory) -> String {
        switch c {
        case .xcode: "hammer"
        case .simulators: "iphone"
        case .nodeModules: "folder"
        case .buildFolders: "shippingbox.and.arrow.backward"
        case .docker, .dockerImages: "shippingbox"
        case .dockerBuildCache: "square.stack.3d.up"
        case .dockerContainers: "cube"
        case .dockerVolumes: "cylinder"
        case .packageCaches: "archivebox"
        case .ideCaches: "chevron.left.forwardslash.chevron.right"
        case .backups: "externaldrive.badge.timemachine"
        case .largeOldFiles: "doc"
        }
    }
}

private struct Chevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(open ? 90 : 0))
            .motion(Motion.quick, value: open)
            .frame(width: 14)
    }
}

private struct ItemRow: View {
    @Environment(CleanupModel.self) private var model
    let item: CleanupItem
    var showsKind = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 14)
                if let cmd = item.advisoryCommand {
                    Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .textSelection(.enabled)
                } else {
                    TriCheckbox(state: model.isSelected(item) ? .on : .off) { model.toggle(item) }
                }
                Text(title).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.lastUsed.map { LastUsed.text($0) } ?? (item.isAdvisory ? "" : "Unknown"))
                .font(.calloutV).foregroundStyle(Theme.textSecondary).frame(width: CleanupColumns.lastUsed, alignment: .leading)
            SafetyBadge(safety: item.safety).frame(width: CleanupColumns.safety, alignment: .leading)
            Text(SizeText.of(item)).font(.numeric).foregroundStyle(Theme.text)
                .contentTransition(.numericText())
                .motion(Motion.value, value: item.sizeBytes)
                .frame(width: CleanupColumns.size, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.leading, 26)
        .frame(height: 33)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item) }
        .contextMenu {
            if !item.urls.isEmpty { Button("Show in Finder") { model.showInFinder([item]) } }
            if let ref = item.docker { Button("Copy Docker Command") { copy("docker " + ref.arguments.joined(separator: " ")) } }
        }
        .help(item.urls.map { LastUsed.tilde($0.path) }.joined(separator: "\n"))
        .modifier(HoverHighlight())
    }

    private var title: String {
        if showsKind, let u = item.urls.first {
            return item.category == .xcode ? "DerivedData · \(item.title)" : u.lastPathComponent
        }
        if item.category == .nodeModules, let u = item.urls.first { return LastUsed.tilde(u.deletingLastPathComponent().path) }
        return item.title
    }

    private var detail: String { showsKind ? item.category.title : item.detail }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: By project

private struct ProjectList: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        let projects = model.projects
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(first: "Project", second: "Last active")
            if projects.isEmpty {
                Text("No project folders with build output were found in your project folders.")
                    .font(.calloutV).foregroundStyle(Theme.textTertiary).padding(.vertical, 14).padding(.horizontal, 8)
            }
            ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                ProjectSection(project: p).staggeredAppear(i)
            }
        }
        .motion(Motion.screen, value: model.expandedProjects)
    }
}

private struct ProjectSection: View {
    @Environment(CleanupModel.self) private var model
    let project: CleanupModel.ProjectGroup

    var body: some View {
        let open = model.expandedProjects.contains(project.id)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Chevron(open: open)
                    TriCheckbox(state: model.check(project.items)) { model.toggle(items: project.items) }
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                    Text(project.name).font(.headlineV).foregroundStyle(Theme.text).lineLimit(1)
                    Text(LastUsed.tilde((project.root as NSString).deletingLastPathComponent)).font(.calloutV).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(project.lastActive.map { LastUsed.text($0) } ?? "Unknown")
                    .font(.calloutV).foregroundStyle(Theme.textSecondary).frame(width: CleanupColumns.lastUsed, alignment: .leading)
                Group {
                    if project.items.contains(where: { $0.safety == .activeProject }) { SafetyBadge(safety: .activeProject) } else { SafetyBadge(safety: .rebuildable) }
                }
                .frame(width: CleanupColumns.safety, alignment: .leading)
                Text((project.items.contains(where: \.isUpperBound) ? "up to " : "") + Fmt.bytes(project.totalBytes))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    .frame(width: CleanupColumns.size, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(Rectangle())
            .onTapGesture {
                if open { model.expandedProjects.remove(project.id) } else { model.expandedProjects.insert(project.id) }
            }
            .modifier(HoverHighlight())
            if open {
                VStack(spacing: 0) {
                    ForEach(Array(project.items.enumerated()), id: \.element.id) { i, item in
                        Hairline().padding(.leading, 44)
                        ItemRow(item: item, showsKind: true).staggeredAppear(i)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Hairline()
        }
        .clipped()
    }
}

// MARK: Shared pieces

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        switch safety {
        case .rebuildable: Badge("Rebuildable", tone: .green)
        case .redownloads: Badge("Re-downloads", tone: .green)
        case .notRebuildable: Badge("Not rebuildable", tone: .orange)
        case .activeProject: Badge("Active project", tone: .neutral)
        case .reviewFirst: Badge("Review first", tone: .orange)
        }
    }
}

struct TriCheckbox: View {
    let state: CleanupModel.Check
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state == .off ? Theme.window : Theme.accent)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(state == .off ? Theme.textTertiary.opacity(0.7) : Theme.accent, lineWidth: 1)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(Motion.quick, value: state)
        .accessibilityValue(state == .on ? "checked" : (state == .mixed ? "mixed" : "unchecked"))
    }
}

enum LastUsed {
    static func text(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = max(1, Int(now.timeIntervalSince(d) / 86_400))
        if days < 45 { return "\(days) days ago" }
        if days < 365 { return "\(days / 30) months ago" }
        let y = days / 365
        return y == 1 ? "1 year ago" : "\(y) years ago"
    }

    static func tilde(_ path: String) -> String {
        let home = CleanupModel.realHome
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private struct EmptyCleanup: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.result != nil {
                Text("Nothing to clean up").font(.headlineV).foregroundStyle(Theme.text)
                Text("No Xcode builds, simulators, build folders, package caches or unused Docker data worth removing were found.")
                    .font(.bodyV).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: Reminder

private struct ReminderFooter: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        @Bindable var m = model
        HStack(spacing: 8) {
            Toggle(isOn: $m.reminderEnabled) {
                Text("Remind me when more than").font(.calloutV).foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            Picker("", selection: $m.reminderGB) {
                ForEach([10.0, 20, 50, 100], id: \.self) { Text("\(Int($0)) GB").tag($0) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            .disabled(!model.reminderEnabled)
            Text("can go safely").font(.calloutV).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }
}

// MARK: Action bar

private struct ActionBar: View {
    @Environment(CleanupModel.self) private var model
    @Binding var confirming: Bool

    var body: some View {
        let sel = model.selectedItems
        let permanent = sel.filter(\.isPermanent).count
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 14) {
                Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let r = model.lastTrash {
                        Text(summary(r)).font(.headlineV).foregroundStyle(r.failures.isEmpty ? Theme.text : Theme.orange)
                        Text(r.failures.first.map { "\(name($0.itemID)): \($0.reason)" } ?? (r.trashed.isEmpty ? "Docker freed the space." : "Find them in the Trash until you empty it, or put them back above."))
                            .font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    } else {
                        Text("\(Fmt.bytes(model.selectedBytes)) selected in \(sel.count) \(sel.count == 1 ? "item" : "items")")
                            .font(.headlineV).foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                        Text(permanent > 0
                             ? "Files go to the Trash. \(permanent) Docker \(permanent == 1 ? "item is" : "items are") removed by Docker, permanently."
                             : "Moved to the Trash, not deleted. Empty the Trash when you are sure.")
                            .font(.captionV).foregroundStyle(permanent > 0 ? Theme.orange : Theme.textTertiary)
                    }
                }
                Spacer()
                Button("Show in Finder") { model.showInFinder(sel) }
                    .disabled(!sel.contains { !$0.urls.isEmpty })
                Button(permanent > 0 ? "Clean Up \(Fmt.bytes(model.selectedBytes))…" : "Move \(Fmt.bytes(model.selectedBytes)) to Trash…") {
                    model.dismissTrashResult(); confirming = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(sel.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .padding(.horizontal, 40).padding(.vertical, 14)
        }
        .background(Theme.surface)
    }

    private func name(_ id: String) -> String {
        model.groups.flatMap(\.items).first { $0.id == id }?.title ?? (id as NSString).lastPathComponent
    }

    private func summary(_ r: TrashResult) -> String {
        let trashed = r.moved - r.permanentlyRemoved
        var parts: [String] = []
        if trashed > 0 { parts.append("Moved \(trashed) \(trashed == 1 ? "item" : "items") to the Trash") }
        if r.permanentlyRemoved > 0 { parts.append("Docker removed \(r.permanentlyRemoved)") }
        var s = parts.isEmpty ? "Nothing was removed" : parts.joined(separator: " · ") + " (\(Fmt.bytes(r.bytes)))"
        if !r.failures.isEmpty { s += " · \(r.failures.count) could not" }
        return s
    }
}

private struct RemoveConfirmation: View {
    @Environment(CleanupModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [CleanupItem]
    @State private var working = false

    var body: some View {
        let trash = items.filter { !$0.isPermanent }
        let docker = items.filter(\.isPermanent)
        VStack(alignment: .leading, spacing: 14) {
            Text(title(trash: trash, docker: docker)).font(.titleV).foregroundStyle(Theme.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !trash.isEmpty {
                        ConfirmSectionTitle(text: "Move to the Trash · \(trash.count)",
                                     detail: "Nothing is deleted until you empty the Trash. Put Back returns them.", tone: Theme.textSecondary)
                        ForEach(trash) { ConfirmRow(item: $0) }
                    }
                    if !docker.isEmpty {
                        ConfirmSectionTitle(text: "Removed permanently by Docker · \(docker.count)",
                                     detail: "Docker deletes these now. They do not go to the Trash and cannot be put back."
                                        + (docker.contains { $0.docker?.kind == .volume } ? " A volume may hold a database." : ""),
                                     tone: Theme.red)
                            .padding(.top, trash.isEmpty ? 0 : 16)
                        ForEach(docker) { ConfirmRow(item: $0) }
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(docker.isEmpty ? "Move to Trash" : (trash.isEmpty ? "Remove Permanently" : "Move to Trash and Remove")) {
                    working = true
                    Task {
                        await model.remove(items)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(docker.isEmpty ? nil : Theme.red)
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Theme.window)
    }

    private func title(trash: [CleanupItem], docker: [CleanupItem]) -> String {
        let total = Fmt.bytes(items.reduce(0) { $0 + $1.sizeBytes })
        if docker.isEmpty { return "Move \(total) to the Trash?" }
        if trash.isEmpty { return "Permanently remove \(total) of Docker data?" }
        return "Clean up \(total)?"
    }
}

private struct ConfirmSectionTitle: View {
    let text: String
    let detail: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.headlineV).foregroundStyle(tone)
            Text(detail).font(.captionV).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

private struct ConfirmRow: View {
    let item: CleanupItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.category == .nodeModules ? LastUsed.tilde(item.urls.first?.deletingLastPathComponent().path ?? item.title) : item.title)
                        .font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                    Text(subtitle).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SafetyBadge(safety: item.safety)
                Text(SizeText.of(item)).font(.numeric).foregroundStyle(Theme.text).frame(width: 96, alignment: .trailing)
            }
            .padding(.vertical, 7)
            Hairline()
        }
    }

    private var subtitle: String {
        if let ref = item.docker { return "docker " + ref.arguments.joined(separator: " ") }
        return item.urls.map { LastUsed.tilde($0.path) }.joined(separator: ", ")
    }
}

// MARK: App Store folder access

private struct FolderAccessView: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose what Disk Cleanup may look at").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)
            Text("This edition of Vardis can only open folders you pick. Good places to start are ~/Library/Developer (Xcode builds and simulators), ~/Library/Caches (package caches) and the folder that holds your projects. Vardis remembers your choice and never looks anywhere else.")
                .font(.bodyV).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 620, alignment: .leading)
            Button("Choose Folders…") { model.grantFolders() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
