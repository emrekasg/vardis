import AppKit
import SwiftUI

/// Colors mirror the Figma "Vardis" variable collection (Light and Dark modes).
enum Theme {
    static let window = dynamic(light: 0xFFFFFF, dark: 0x1B1B1D)
    static let sidebar = dynamic(light: 0xF4F4F6, dark: 0x222225)
    static let surface = dynamic(light: 0xF8F8F9, dark: 0x28282B)
    static let raised = dynamic(light: 0xEDEDEF, dark: 0x323236)
    static let separator = dynamic(light: 0x000000, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let selected = dynamic(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.09)

    static let text = dynamic(light: 0x1D1D1F, dark: 0xF2F2F7)
    static let textSecondary = dynamic(light: 0x6E6E73, dark: 0xA1A1A8)
    static let textTertiary = dynamic(light: 0x99999E, dark: 0x737379)

    static let accent = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let green = dynamic(light: 0x249441, dark: 0x32D74B)
    static let orange = dynamic(light: 0xBF6100, dark: 0xFF9F0A)
    static let red = dynamic(light: 0xD71C1C, dark: 0xFF453A)
    static let claude = dynamic(light: 0xC15F3C, dark: 0xD97757)

    /// Metric identity colors, validated for CVD separation in both modes.
    enum Metric {
        static let cpu = dynamic(light: 0x1F7AE0, dark: 0x3D8EF5)
        static let memory = dynamic(light: 0xC27A00, dark: 0xBD7F14)
        static let gpu = dynamic(light: 0xD9366E, dark: 0xE0507F)
        static let disk = dynamic(light: 0x0F9BAA, dark: 0x1FA8B5)
        static let network = dynamic(light: 0x9B4FD6, dark: 0xA56BE6)
        static let battery = dynamic(light: 0x3E9B47, dark: 0x45A04E)
        static let ane = dynamic(light: 0x5B5BD6, dark: 0x7474EC)
        static let agents = dynamic(light: 0xC15F3C, dark: 0xD27A55)
    }

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Type ramp from the Figma text styles. Numbers use tabular figures so live values do not jitter.
extension Font {
    static let largeTitleV = Font.system(size: 26, weight: .bold)
    static let titleV = Font.system(size: 20, weight: .semibold)
    static let headlineV = Font.system(size: 13, weight: .semibold)
    static let bodyV = Font.system(size: 13)
    static let calloutV = Font.system(size: 12)
    static let captionV = Font.system(size: 11)
    static let captionStrongV = Font.system(size: 11, weight: .semibold)
    static let numericXL = Font.system(size: 34, weight: .semibold).monospacedDigit()
    static let numericL = Font.system(size: 22, weight: .semibold).monospacedDigit()
    static let numeric = Font.system(size: 13, weight: .medium).monospacedDigit()
}
