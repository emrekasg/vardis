import SwiftUI
import VardisCleanup
import VardisCore

struct DiskCleanupView: View {
    @Environment(CleanupModel.self) private var model
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
                            .padding(.bottom, 26)
                        if model.groups.isEmpty {
                            EmptyCleanup()
                        } else {
                            CleanupList()
                        }
                    }
                    .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 24)
                }
                ActionBar(confirming: $confirming)
            }
        }
        .background(Theme.window)
        .sheet(isPresented: $confirming) { TrashConfirmation(items: model.selectedItems) }
    }
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
        if sel.contains(where: { $0.safety == .notRebuildable || $0.safety == .reviewFirst || $0.safety == .activeProject }) {
            return "selected. Some of it does not come back on its own, so look through the ticked rows before moving them."
        }
        return "can go to the Trash without breaking anything. Everything selected is rebuilt or downloaded again the next time a tool needs it."
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

// MARK: List

private struct CleanupList: View {
    @Environment(CleanupModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                Text("Last used").frame(width: CleanupColumns.lastUsed, alignment: .leading)
                Text("Safety").frame(width: CleanupColumns.safety, alignment: .leading)
                Text("Size").frame(width: CleanupColumns.size, alignment: .trailing)
            }
            .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8).padding(.bottom, 8)
            Hairline()
            ForEach(model.groups) { g in
                GroupSection(group: g)
            }
        }
        .motion(Motion.screen, value: model.expanded)
    }
}

enum CleanupColumns {
    static let lastUsed: CGFloat = 122
    static let safety: CGFloat = 150
    static let size: CGFloat = 90
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
                ForEach(items) { item in
                    Hairline().padding(.leading, 44)
                    ItemRow(item: item)
                }
                if group.items.count > Self.visibleLimit && !showAll {
                    Hairline().padding(.leading, 44)
                    let rest = group.items.dropFirst(Self.visibleLimit)
                    Button { showAll = true } label: {
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
            Hairline()
        }
        .transition(.opacity)
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .motion(Motion.quick, value: open)
                    .frame(width: 14)
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
            Text(Fmt.bytes(group.totalBytes)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
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
        if group.category == .docker { return "Docker's own command frees this; Vardis never touches its files" }
        let sel = model.selectedBytes(in: group)
        let n = group.items.count
        if sel == 0 { return n == 1 ? "1 item, not selected" : "\(n) items, none selected" }
        if sel == group.totalBytes { return n == 1 ? "selected" : "all \(n) selected" }
        return "\(Fmt.bytes(sel)) of \(Fmt.bytes(group.totalBytes)) selected"
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
        case .docker: "shippingbox"
        case .packageCaches: "archivebox"
        case .largeOldFiles: "doc"
        }
    }
}

private struct ItemRow: View {
    @Environment(CleanupModel.self) private var model
    let item: CleanupItem

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
                Text(item.detail).font(.calloutV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.lastUsed.map { LastUsed.text($0) } ?? (item.isAdvisory ? "" : "Unknown"))
                .font(.calloutV).foregroundStyle(Theme.textSecondary).frame(width: CleanupColumns.lastUsed, alignment: .leading)
            SafetyBadge(safety: item.safety).frame(width: CleanupColumns.safety, alignment: .leading)
            Text(Fmt.bytes(item.sizeBytes)).font(.numeric).foregroundStyle(Theme.text)
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
        }
        .modifier(HoverHighlight())
        .transition(.opacity)
    }

    private var title: String {
        if item.category == .nodeModules, let u = item.urls.first { return LastUsed.tilde(u.deletingLastPathComponent().path) }
        return item.title
    }
}

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
                Text("No Xcode builds, simulators, node_modules or package caches worth moving were found.")
                    .font(.bodyV).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: Action bar

private struct ActionBar: View {
    @Environment(CleanupModel.self) private var model
    @Binding var confirming: Bool

    var body: some View {
        let sel = model.selectedItems
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 14) {
                Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let r = model.lastTrash {
                        Text(trashSummary(r)).font(.headlineV).foregroundStyle(r.failures.isEmpty ? Theme.text : Theme.orange)
                        Text(r.failures.first.map { "\($0.url?.lastPathComponent ?? $0.itemID): \($0.reason)" } ?? "Find them in the Trash until you empty it.")
                            .font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    } else {
                        Text("\(Fmt.bytes(model.selectedBytes)) selected in \(sel.count) \(sel.count == 1 ? "item" : "items")")
                            .font(.headlineV).foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                        Text("Moved to the Trash, not deleted. Empty the Trash when you are sure.")
                            .font(.captionV).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                Button("Show in Finder") { model.showInFinder(sel) }
                    .disabled(sel.isEmpty)
                Button("Move \(Fmt.bytes(model.selectedBytes)) to Trash") { model.dismissTrashResult(); confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(sel.isEmpty)
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .padding(.horizontal, 40).padding(.vertical, 14)
        }
        .background(Theme.surface)
    }

    private func trashSummary(_ r: TrashResult) -> String {
        let moved = "Moved \(Fmt.bytes(r.bytes)) in \(r.moved) \(r.moved == 1 ? "item" : "items") to the Trash"
        return r.failures.isEmpty ? moved : moved + " · \(r.failures.count) could not move"
    }
}

private struct TrashConfirmation: View {
    @Environment(CleanupModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [CleanupItem]
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(Fmt.bytes(items.reduce(0) { $0 + $1.sizeBytes })) to the Trash?").font(.titleV).foregroundStyle(Theme.text)
            Text("These \(items.count) \(items.count == 1 ? "item moves" : "items move") to the Trash. Nothing is deleted until you empty it.")
                .font(.bodyV).foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { i in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.category == .nodeModules ? LastUsed.tilde(i.urls.first?.deletingLastPathComponent().path ?? i.title) : i.title)
                                    .font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                                Text(i.urls.map { LastUsed.tilde($0.path) }.joined(separator: ", "))
                                    .font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            SafetyBadge(safety: i.safety)
                            Text(Fmt.bytes(i.sizeBytes)).font(.numeric).foregroundStyle(Theme.text).frame(width: 74, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        Hairline()
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    working = true
                    Task {
                        await model.trash(items)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.window)
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
