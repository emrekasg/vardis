import AppKit
import SwiftUI

/// Compact line + soft area, for menu bar tiles. `values` oldest first; `maxValue` nil = scale to the data.
/// One Canvas pass, no hover, no axes.
struct AreaSparkline: View {
    let values: [Double]
    let color: Color
    var maxValue: Double? = nil
    /// A second series drawn under the first (network upload, disk read).
    var secondary: [Double]? = nil
    var secondaryColor: Color? = nil

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let top = max(maxValue ?? max(values.max() ?? 0, secondary?.max() ?? 0), 0.0001)
            if let secondary { draw(ctx, size, secondary, secondaryColor ?? color.opacity(0.6), top, fill: 0.14) }
            draw(ctx, size, values, color, top, fill: 0.26)
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ v: [Double], _ c: Color, _ top: Double, fill: Double) {
        guard v.count > 1 else { return }
        let inset: CGFloat = 1.5
        let h = size.height - inset
        let pts = v.enumerated().map { i, x in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(v.count - 1), y: inset + h * (1 - CGFloat(min(1, max(0, x / top)))))
        }
        var line = Path()
        line.addLines(pts)
        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(Gradient(colors: [c.opacity(fill), c.opacity(0.0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(line, with: .color(c), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }
}

/// Segments of one horizontal bar (memory: app / wired / compressed / free).
struct SegmentBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let total = segments.reduce(0) { $0 + $1.value }
            guard total > 0 else { return }
            ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.raised))
            var x: CGFloat = 0
            for s in segments where s.value > 0 {
                let w = size.width * CGFloat(s.value / total)
                ctx.fill(Path(CGRect(x: x, y: 0, width: max(0, w - 1), height: size.height)), with: .color(s.color))
                x += w
            }
        }
        .frame(height: height)
    }
}

/// A rounded tile on the menu bar panel. Translucent so the panel's vibrancy shows through.
struct PanelTileBackground: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(PanelColor.tile, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(PanelColor.tileBorder))
    }
}

extension View {
    func panelTile(cornerRadius: CGFloat = 12) -> some View { modifier(PanelTileBackground(cornerRadius: cornerRadius)) }
}

/// Small caption heading inside the panel ("Busiest right now").
struct PanelHeading: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.captionStrongV).foregroundStyle(Theme.textSecondary)
            Spacer()
            if let trailing { Text(trailing).font(.captionV).foregroundStyle(Theme.textTertiary).monospacedDigit() }
        }
    }
}

/// Colors only the menu bar panel uses. The panel is opaque, so text never sits on a busy desktop.
enum PanelColor {
    static let background = dynamic(light: NSColor(hex: 0xF2F2F4), dark: NSColor(hex: 0x1C1C1E))
    static let tile = Color(nsColor: dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x2A2A2D)))
    static let tileBorder = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.04)))
    /// Tab bar track and footer buttons.
    static let control = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(hex: 0x2A2A2D)))
    static let controlHover = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(hex: 0x333337)))
    static let controlPressed = Color(nsColor: dynamic(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(hex: 0x3C3C40)))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.12))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}
