import SwiftUI
import VardisCore

/// Column widths shared by the header and rows. `compact` (inspector open) keeps only CPU, memory and the trend.
enum AppColumns {
    static let cpu: CGFloat = 64
    static let memory: CGFloat = 150
    static let energy: CGFloat = 76
    static let disk: CGFloat = 88
    static let uptime: CGFloat = 76
    static let trend: CGFloat = 96
    static let spacing: CGFloat = 12
}

struct AppsHeader: View {
    @Binding var sort: AppSort
    @Binding var descending: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: AppColumns.spacing) {
            head(.name, "App", width: nil, alignment: .leading)
            head(.cpu, "CPU", width: AppColumns.cpu)
            head(.memory, "Memory", width: AppColumns.memory)
            if !compact {
                head(.energy, "Energy", width: AppColumns.energy)
                head(.diskWrite, "Disk write", width: AppColumns.disk)
                head(.uptime, "Uptime", width: AppColumns.uptime)
            }
            Text("Memory, 1 h").frame(width: AppColumns.trend, alignment: .leading)
                .help("Memory over the last hour from history; the last minute until history has it")
        }
        .font(.captionStrongV).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func head(_ s: AppSort, _ title: String, width: CGFloat?, alignment: Alignment = .trailing) -> some View {
        Button {
            if sort == s { descending.toggle() } else { sort = s; descending = true }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title).foregroundStyle(sort == s ? Theme.text : Theme.textTertiary)
                if sort == s {
                    Image(systemName: descending == (s != .name) ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }
}

struct AppRow: View {
    @Environment(LiveModel.self) private var live
    let app: AppSample
    let started: Date?
    let hour: [Double]?
    let maxMemory: UInt64
    let leak: Bool
    let pinned: Bool
    let selected: Bool
    let compact: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: AppColumns.spacing) {
            HStack(spacing: 10) {
                AppIconView(bundleURL: app.bundleURL, name: app.name, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.bodyV).foregroundStyle(Theme.text).lineLimit(1)
                        if pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                                .help("Pinned to Now")
                        }
                        if leak {
                            Badge("Memory keeps growing", tone: .orange)
                                .help("Memory rose steadily for hours without a restart")
                        }
                    }
                    Text(AppKind.subtitle(app)).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            number(Fmt.percent(app.cpu), width: AppColumns.cpu, emphasis: app.cpu >= 0.5)
            HStack(spacing: 8) {
                Capsule().fill(Theme.raised).frame(width: 60, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.Metric.memory)
                            .frame(width: max(2, 60 * min(1, Double(app.memory) / Double(max(1, maxMemory)))), height: 4)
                    }
                    .motion(Motion.value, value: app.memory)
                Text(Fmt.bytes(app.memory)).font(.numeric).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: AppColumns.memory)
            if !compact {
                number(Fmt.watts(app.energyWatts), width: AppColumns.energy)
                number(app.diskWriteBytesPerSecond > 0 ? Fmt.rate(app.diskWriteBytesPerSecond) : "\u{2013}", width: AppColumns.disk)
                number(started.map { DurationFmt.compact(Date().timeIntervalSince($0)) } ?? "\u{2013}", width: AppColumns.uptime)
            }
            Sparkline(values: trend, color: leak ? Theme.orange : Theme.textTertiary)
                .frame(width: AppColumns.trend, height: 18)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var trend: [Double] {
        if let hour, hour.count > 2 { return hour }
        return live.appMemory[app.id]?.elements ?? []
    }

    private var background: Color {
        selected ? Theme.accent.opacity(0.12) : hovering ? Theme.selected.opacity(0.6) : .clear
    }

    private func number(_ text: String, width: CGFloat, emphasis: Bool = false) -> some View {
        Text(text).font(.numeric).foregroundStyle(emphasis ? Theme.orange : Theme.textSecondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}
