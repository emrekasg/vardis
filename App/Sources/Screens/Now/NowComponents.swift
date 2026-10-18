import SwiftUI
import VardisCore

/// "21.7 GB" -> ("21.7", "GB"). Keeps the number large and the unit quiet.
func splitUnit(_ s: String) -> (String, String) {
    guard let space = s.lastIndex(of: " ") else { return (s, "") }
    return (String(s[..<space]), String(s[s.index(after: space)...]))
}

/// A number with its unit, tabular digits, sliding between readings.
struct BigNumber: View {
    let value: String
    let unit: String
    var font: Font = .numericXL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(font).foregroundStyle(Theme.text)
                .contentTransition(.numericText())
                .motion(Motion.value, value: value)
            if !unit.isEmpty { Text(unit).font(.headlineV).foregroundStyle(Theme.textTertiary) }
        }
        .lineLimit(1)
    }
}

/// A label over a value, for the small facts under a tile's headline number.
struct Stat: View {
    let label: String
    let value: String
    var tint: Color = Theme.text
    var swatch: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 7, height: 7) }
                Text(label).font(.captionV).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Text(value).font(.numeric).foregroundStyle(tint).lineLimit(1)
                .contentTransition(.numericText())
                .motion(Motion.value, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Memory pressure as a colored dot plus its word, never color alone.
struct PressureLabel: View {
    let pressure: MemoryPressure

    var tone: BadgeTone {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pressure == .normal ? "circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: pressure == .normal ? 6 : 9, weight: .bold))
            Text(NowFacts.pressureLabel(pressure)).font(.captionStrongV)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tone.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory pressure \(NowFacts.pressureLabel(pressure))")
    }
}

/// A Now tile: title row with an open chevron, then content. The whole tile opens its drawer.
struct NowCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    var accessory: AnyView? = nil
    var onOpen: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconTile(systemName: symbol, color: color, size: 22)
                Text(title).font(.headlineV).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                if let accessory { accessory }
                if onOpen != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(hovering && onOpen != nil ? Theme.textTertiary.opacity(0.4) : Theme.separator))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .motion(Motion.quick, value: hovering)
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
        .accessibilityAction(named: "Show details") { onOpen?() }
    }
}

/// One app with a value, for "Top" lines and the drawers' top-5 lists. Clicking opens it in Apps.
struct AppValueRow: View {
    let app: AppSample
    let value: String
    var share: Double? = nil
    var color: Color = Theme.textTertiary
    let open: (AppSample) -> Void

    var body: some View {
        Button { open(app) } label: {
            HStack(spacing: 8) {
                AppIconView(bundleURL: app.bundleURL, name: app.name, size: 16)
                Text(app.name).font(.calloutV).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                if let share {
                    Capsule().fill(Theme.raised).frame(width: 56, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(color).frame(width: max(2, 56 * min(1, share)), height: 4) }
                }
                Text(value).font(.numeric).foregroundStyle(Theme.textSecondary).frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .help("Show \(app.name) in Apps")
    }
}

/// A row of facts in a drawer: label left, value right.
struct FactRow: View {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.calloutV).foregroundStyle(Theme.textSecondary)
                    if let detail { Text(detail).font(.captionV).foregroundStyle(Theme.textTertiary) }
                }
                Spacer(minLength: 12)
                Text(value).font(.numeric).foregroundStyle(Theme.text).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 7)
            Hairline()
        }
    }
}
