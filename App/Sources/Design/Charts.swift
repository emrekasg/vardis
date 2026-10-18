import SwiftUI

/// Bar history drawn in a single Canvas pass. `values` are 0...1, oldest first.
struct BarHistory: View {
    let values: [Double]
    let color: Color
    var capacity = 60

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let n = max(capacity, values.count)
            let step = size.width / CGFloat(n)
            let w = max(1.5, step - 1.4)
            let offset = CGFloat(n - values.count)
            for (i, v) in values.enumerated() {
                let h = max(2, CGFloat(min(1, max(0, v))) * size.height)
                let x = (offset + CGFloat(i)) * step
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                let fade = 0.55 + 0.45 * Double(i) / Double(max(1, values.count - 1))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color.opacity(i == values.count - 1 ? 1 : fade)))
            }
        }
    }
}

/// Thin line sparkline for table rows.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, 0.0001)
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                                 y: size.height - 2 - CGFloat((v - lo) / span) * (size.height - 4))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct DonutSlice: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

/// Donut with 2-point gaps between slices.
struct Donut: View {
    let slices: [DonutSlice]
    var lineWidth: CGFloat = 13

    var body: some View {
        Canvas { ctx, size in
            let total = slices.reduce(0) { $0 + $1.value }
            guard total > 0 else { return }
            let r = min(size.width, size.height) / 2 - lineWidth / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let gap = 0.035
            var a = -Double.pi / 2
            for s in slices {
                let sweep = s.value / total * 2 * .pi
                var p = Path()
                p.addArc(center: c, radius: r, startAngle: .radians(a + gap / 2), endAngle: .radians(a + max(gap, sweep) - gap / 2), clockwise: false)
                ctx.stroke(p, with: .color(s.color), lineWidth: lineWidth)
                a += sweep
            }
        }
    }
}

struct Meter: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, value))))
            }
            .motion(Motion.value, value: value)
        }
        .frame(height: 4)
    }
}
