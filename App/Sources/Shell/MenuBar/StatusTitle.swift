import AppKit
import VardisCore

/// One readout in the status item: a small symbol and its value. Network stacks two values.
struct MenuPiece: Equatable, Sendable {
    var symbol: String?
    var text: String
    /// Second line, drawn under `text` at a smaller size (network ↓ over ↑).
    var lower: String?
}

/// Formats readouts for the status item. Short on purpose: the menu bar is shared space.
@MainActor
enum MenuBarFormat {
    /// 21_400_000_000 -> "21.4G", 980_000 -> "980K". Decimal units, like Finder.
    static func compact(_ value: Double, bits: Bool = false) -> String {
        var v = bits ? value * 8 : value
        let units = bits ? ["b", "Kb", "Mb", "Gb", "Tb"] : ["B", "K", "M", "G", "T"]
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return bits ? "\(Int(v))b" : "0K" }
        return (v >= 100 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)) + units[i]
    }

    static func batterySymbol(_ b: BatterySample) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.charge {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Every readout that has a value right now. Missing hardware (no GPU, no battery) or data (no Claude account) is left out.
    static func pieces(snapshot s: Snapshot?, claudeFiveHour: Double?, portsCount: Int?) -> [MenuReadout: MenuPiece] {
        var out: [MenuReadout: MenuPiece] = [:]
        let bits = UserDefaults.standard.string(forKey: Pref.networkUnit) == "bits"
        if let s {
            out[.cpu] = MenuPiece(symbol: MenuReadout.cpu.symbol, text: Fmt.percent(s.cpu.total))
            out[.memory] = MenuPiece(symbol: MenuReadout.memory.symbol, text: compact(Double(s.memory.used)))
            out[.network] = MenuPiece(symbol: nil, text: "↓" + compact(s.network.receivedBytesPerSecond, bits: bits)
                                      + " ↑" + compact(s.network.sentBytesPerSecond, bits: bits))
            if s.disk.totalBytes > 0 { out[.disk] = MenuPiece(symbol: MenuReadout.disk.symbol, text: compact(Double(s.disk.freeBytes))) }
            if let g = s.gpu { out[.gpu] = MenuPiece(symbol: MenuReadout.gpu.symbol, text: Fmt.percent(g.utilization)) }
            if let b = s.battery { out[.battery] = MenuPiece(symbol: batterySymbol(b), text: Fmt.percent(b.charge)) }
        }
        if let claudeFiveHour { out[.claude] = MenuPiece(symbol: MenuReadout.claude.symbol, text: "\(Int(claudeFiveHour.rounded()))%") }
        if let portsCount { out[.ports] = MenuPiece(symbol: MenuReadout.ports.symbol, text: "\(portsCount)") }
        return out
    }
}

/// Draws the whole status item (glyph and readouts) as one template image, so macOS tints it for
/// light and dark menu bars and the selected state. Built only when its content changed.
@MainActor
enum StatusTitleRenderer {
    static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
    private static var symbolCache: [String: NSImage] = [:]

    static func image(_ pieces: [MenuPiece], scale: CGFloat = 2) -> NSImage {
        let glyphWidth: CGFloat = 16
        let gap: CGFloat = 8, symbolGap: CGFloat = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let small: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.black]

        struct Laid { var symbol: NSImage?; var text: NSAttributedString; var lower: NSAttributedString?; var width: CGFloat }
        var laid: [Laid] = []
        for p in pieces {
            let sym = p.symbol.flatMap(symbol)
            let text = NSAttributedString(string: p.text, attributes: p.lower == nil ? attrs : small)
            let lower = p.lower.map { NSAttributedString(string: $0, attributes: small) }
            let textWidth = max(text.size().width, lower?.size().width ?? 0)
            laid.append(Laid(symbol: sym, text: text, lower: lower, width: (sym.map { $0.size.width + symbolGap } ?? 0) + ceil(textWidth)))
        }
        let width = glyphWidth + laid.reduce(0) { $0 + gap + $1.width } + (laid.isEmpty ? 0 : 1)
        let size = NSSize(width: ceil(width), height: height)

        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        MenuBarGlyph.draw(in: NSRect(x: 0, y: (height - 16) / 2, width: 16, height: 16))
        var x = glyphWidth
        for l in laid {
            x += gap
            if let s = l.symbol {
                // Symbols at reduced alpha read as secondary once macOS tints the template.
                s.draw(in: NSRect(x: x, y: ((height - s.size.height) / 2).rounded(), width: s.size.width, height: s.size.height),
                       from: .zero, operation: .sourceOver, fraction: 0.62)
                x += s.size.width + symbolGap
            }
            if let lower = l.lower {
                lower.draw(at: NSPoint(x: x, y: -0.5))
                l.text.draw(at: NSPoint(x: x, y: height / 2 - 1))
            } else {
                let h = font.ascender - font.descender
                l.text.draw(at: NSPoint(x: x, y: ((height - h) / 2).rounded() - 0.5))
            }
            x += l.width - (l.symbol.map { $0.size.width + symbolGap } ?? 0)
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        if let s = symbolCache[name] { return s }
        let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
        symbolCache[name] = s
        return s
    }
}

/// The Vardis mark for the menu bar: the icon's two strokes forming a V, with the small dot top right.
/// The right stroke crosses over the left one with a thin gap, as in the app icon.
enum MenuBarGlyph {
    @MainActor static func draw(in r: NSRect) {
        let s = r.width / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + (16 - y) * s) }
        let width = 3.1 * s
        let left = NSBezierPath()
        left.move(to: p(2.6, 3.4)); left.line(to: p(7.0, 13.4))
        let right = NSBezierPath()
        right.move(to: p(12.4, 3.4)); right.line(to: p(7.5, 13.4))
        for path in [left, right] { path.lineCapStyle = .round; path.lineWidth = width }

        NSColor.black.setStroke()
        left.stroke()
        // Knock a hairline gap out of the left stroke where the right one crosses it.
        NSGraphicsContext.current?.compositingOperation = .clear
        right.lineWidth = width + 1.6 * s
        right.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        right.lineWidth = width
        right.stroke()
        // Dot, with the same clear ring so it never touches the stroke.
        let c = p(14.5, 1.9)
        let rad = 1.55 * s
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: c.x - rad - 0.8 * s, y: c.y - rad - 0.8 * s, width: (rad + 0.8 * s) * 2, height: (rad + 0.8 * s) * 2)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)).fill()
    }

    /// The glyph alone, as a template image (Settings preview, accessibility).
    @MainActor static func image(size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            MainActor.assumeIsolated { draw(in: rect) }
            return true
        }
        img.isTemplate = true
        return img
    }
}
