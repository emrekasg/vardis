import SwiftUI

/// Live bar history that slides left by one bar when a sample arrives, instead of redrawing in place.
/// `values` are raw readings, oldest first; `top` scales them (nil = the largest value shown).
/// Hover shows the exact value and its age. Same look as `BarHistory`.
struct LiveBars: View {
    let values: [Double]
    let color: Color
    /// Increments once per sample; the slide is keyed to it.
    let tick: Int
    var capacity = liveHistoryLength
    var top: Double? = nil
    /// Seconds between samples, for the hover's "12 s ago".
    var interval: Double = 1
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var label = "Value"

    @State private var hover: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let n = max(capacity, values.count)
            let step = g.size.width / CGFloat(n)
            ZStack(alignment: .topLeading) {
                BarsDrawing(values: values, color: color, capacity: n, top: resolvedTop, tick: tick, shown: Double(tick), highlight: hover)
                    .animation(reduceMotion ? nil : Motion.value, value: tick)
                if let i = hover, let v = values[safe: i] {
                    let age = Double(values.count - 1 - i) * interval
                    let x = (CGFloat(n - values.count + i) + 0.5) * step
                    ChartTooltip(title: age < 0.5 ? "Now" : "\(Int(age.rounded())) s ago", rows: [(label, color, format(v))])
                        .fixedSize()
                        .offset(x: x + 12 > g.size.width - 170 ? x - 172 : x + 12, y: -54)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let slot = Int(p.x / step)
                    let i = slot - (n - values.count)
                    hover = values.indices.contains(i) ? i : nil
                case .ended: hover = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(values.last.map(format) ?? "")
    }

    private var resolvedTop: Double {
        if let top { return max(top, 0.0001) }
        return max(values.max() ?? 0, 0.0001)
    }
}

/// The animatable part: `shown` trails `tick` during the slide, and the gap is the bar offset.
private struct BarsDrawing: View, Animatable {
    let values: [Double]
    let color: Color
    let capacity: Int
    let top: Double
    let tick: Int
    var shown: Double
    let highlight: Int?

    nonisolated var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    var body: some View {
        // 1 right after a sample lands, easing to 0: every bar starts one slot to the right.
        let shift = CGFloat(min(1, max(0, Double(tick) - shown)))
        Canvas(rendersAsynchronously: false) { ctx, size in
            let step = size.width / CGFloat(capacity)
            let w = max(1.5, step - 1.4)
            let offset = CGFloat(capacity - values.count)
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            for (i, v) in values.enumerated() {
                let h = max(2, CGFloat(min(1, max(0, v / top))) * size.height)
                let x = (offset + CGFloat(i) + shift) * step
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                let fade = 0.55 + 0.45 * Double(i) / Double(max(1, values.count - 1))
                let isLast = i == values.count - 1
                let alpha = highlight.map { $0 == i ? 1 : fade * 0.6 } ?? (isLast ? 1 : fade)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color.opacity(alpha)))
            }
        }
    }
}

/// Two series on one time axis (network in and out, disk read and write) with a shared hover.
/// Line + soft area, like `TimeChart`, but for the live 60-sample window.
struct LivePairChart: View {
    let first: (String, Color, [Double])
    let second: (String, Color, [Double])
    var interval: Double = 1
    var format: (Double) -> String

    @State private var hover: Int?

    private var count: Int { max(first.2.count, second.2.count) }
    private var top: Double { max(0.0001, (first.2 + second.2).max() ?? 0) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for g in [0.5, 1.0] {
                        var p = Path()
                        let y = size.height * (1 - g)
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(Theme.separator), lineWidth: 1)
                    }
                    draw(ctx, size, second.2, second.1)
                    draw(ctx, size, first.2, first.1)
                }
                if let i = hover, count > 1 {
                    let x = g.size.width * CGFloat(i) / CGFloat(count - 1)
                    Rectangle().fill(Theme.text.opacity(0.35)).frame(width: 1, height: g.size.height).offset(x: x)
                    let age = Double(count - 1 - i) * interval
                    ChartTooltip(title: age < 0.5 ? "Now" : "\(Int(age.rounded())) s ago",
                                 rows: [(first.0, first.1, format(first.2[safe: i] ?? 0)), (second.0, second.1, format(second.2[safe: i] ?? 0))])
                        .fixedSize()
                        .offset(x: x + 12 > g.size.width - 170 ? x - 172 : x + 12, y: 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard count > 1 else { return }
                    hover = min(count - 1, max(0, Int((p.x / g.size.width * CGFloat(count - 1)).rounded())))
                case .ended: hover = nil
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ values: [Double], _ color: Color) {
        guard values.count > 1 else { return }
        let pts = values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(min(1, v / top))))
        }
        var line = Path()
        line.addLines(pts)
        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        ctx.fill(area, with: .color(color.opacity(0.12)))
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}
