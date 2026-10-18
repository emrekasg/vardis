import SwiftUI

struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(color.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(Image(systemName: systemName).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(color))
    }
}

enum BadgeTone { case neutral, green, orange, red, blue, claude
    var color: Color {
        switch self {
        case .neutral: Theme.textSecondary
        case .green: Theme.green
        case .orange: Theme.orange
        case .red: Theme.red
        case .blue: Theme.accent
        case .claude: Theme.claude
        }
    }
}

struct Badge: View {
    let text: String
    var tone: BadgeTone = .neutral

    init(_ text: String, tone: BadgeTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.captionStrongV)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Grouped form box used by Settings and onboarding.
struct GroupBoxV<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.captionStrongV).foregroundStyle(Theme.textSecondary) }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
            if let footer { Text(footer).font(.captionV).foregroundStyle(Theme.textTertiary) }
        }
    }
}

struct FormRow<Control: View>: View {
    let label: String
    var detail: String?
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.bodyV).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.captionV).foregroundStyle(Theme.textTertiary) }
                }
                Spacer(minLength: 8)
                control
            }
            .padding(.vertical, 10)
            if showsDivider { Rectangle().fill(Theme.separator).frame(height: 1) }
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 1) }
}

struct AppIconView: View {
    let bundleURL: URL?
    let name: String
    var size: CGFloat = 20

    var body: some View {
        if let bundleURL {
            Image(nsImage: IconCache.shared.icon(for: bundleURL))
                .resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(Theme.raised)
                .frame(width: size, height: size)
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(Theme.textSecondary))
        }
    }
}

/// NSWorkspace icon lookups are slow; cache them for the life of the app.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [URL: NSImage] = [:]

    /// Workspace icons carry every representation up to 1024 px. Keep one 64 px bitmap instead.
    func icon(for url: URL) -> NSImage {
        if let img = cache[url] { return img }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let px = 64
        let small = NSImage(size: NSSize(width: 32, height: 32))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = NSSize(width: 32, height: 32)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            small.addRepresentation(rep)
        }
        cache[url] = small
        return small
    }
}
