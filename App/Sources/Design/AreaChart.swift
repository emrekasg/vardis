import SwiftUI

/// One series of a time chart.
struct ChartSeries: Identifiable {
    let id: String
    let color: Color
    /// Values aligned with `TimeChart.times`.
    let values: [Double]
}

/// Line + soft gradient area with a hover crosshair and tooltip. Stacks series when `stacked` is true.
/// Drawn in one Canvas; the tooltip is a regular view so text stays crisp.
struct TimeChart: View {
    let times: [Date]
    let series: [ChartSeries]
    var stacked = false
    /// Upper bound of the y axis; nil = max of the data.
    var maxValue: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var timeFormat: Date.FormatStyle = .dateTime.hour().minute()

    @State private var hoverIndex: Int?

    private var top: Double {
        if let maxValue { return maxValue }
        let m = stacked
            ? (0..<times.count).map { i in series.reduce(0) { $0 + ($1.values[safe: i] ?? 0) } }.max() ?? 0
            : series.flatMap(\.values).max() ?? 0
        return max(m, 0.0001)
    }

    var body: some View {
        GeometryReader { g in
            let size = g.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                if let i = hoverIndex, i < times.count {
                    let x = xPos(i, size.width)
                    Rectangle().fill(Theme.text.opacity(0.35)).frame(width: 1, height: size.height).offset(x: x)
                    ChartTooltip(title: times[i].formatted(timeFormat), rows: series.map { ($0.id, $0.color, format($0.values[safe: i] ?? 0)) })
                        .fixedSize()
                        .offset(x: x + 12 > size.width - 180 ? x - 192 : x + 12, y: 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard times.count > 1 else { return }
                    hoverIndex = min(times.count - 1, max(0, Int((p.x / size.width * CGFloat(times.count - 1)).rounded())))
                case .ended: hoverIndex = nil
                }
            }
        }
    }

    private func xPos(_ i: Int, _ w: CGFloat) -> CGFloat {
        times.count > 1 ? w * CGFloat(i) / CGFloat(times.count - 1) : 0
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard times.count > 1 else { return }
        for g in [0.5, 1.0] {
            var p = Path()
            let y = size.height * (1 - g)
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(Theme.separator), lineWidth: 1)
        }
        var base = [Double](repeating: 0, count: times.count)
        for s in series {
            var upper = base
            for i in 0..<times.count { upper[i] = (stacked ? base[i] : 0) + (s.values[safe: i] ?? 0) }
            let pts = upper.enumerated().map { CGPoint(x: xPos($0.offset, size.width), y: size.height * (1 - CGFloat(min(1, $0.element / top)))) }
            var line = Path()
            line.addLines(pts)
            var area = line
            let lower = stacked ? base : [Double](repeating: 0, count: times.count)
            for i in stride(from: times.count - 1, through: 0, by: -1) {
                area.addLine(to: CGPoint(x: xPos(i, size.width), y: size.height * (1 - CGFloat(min(1, lower[i] / top)))))
            }
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [s.color.opacity(stacked ? 0.55 : 0.28), s.color.opacity(stacked ? 0.35 : 0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if stacked { base = upper }
        }
    }
}

struct ChartTooltip: View {
    let title: String
    let rows: [(String, Color, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.captionStrongV).foregroundStyle(Theme.text)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(r.1).frame(width: 8, height: 8)
                    Text(r.0).font(.captionV).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 12)
                    Text(r.2).font(.captionStrongV).foregroundStyle(Theme.text).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.separator))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }
}

/// Calm empty state: symbol, one sentence, optional action.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(Theme.textTertiary)
            Text(title).font(.headlineV).foregroundStyle(Theme.text)
            if let detail { Text(detail).font(.calloutV).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 360) }
            if let actionTitle, let action { Button(actionTitle, action: action).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
