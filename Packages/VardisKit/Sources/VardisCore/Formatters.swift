import Foundation

/// Cheap, allocation-light formatting for live numbers. Decimal units (1 GB = 10^9 bytes), like Finder.
public enum Fmt {
    public static func bytes(_ value: UInt64) -> String { bytes(double: Double(value)) }

    public static func bytes(double value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return v >= 100 ? "\(Int(v.rounded())) \(units[i])" : String(format: "%.1f %@", v, units[i])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "0 KB/s" : bytes(double: bytesPerSecond) + "/s"
    }

    /// 0.183 -> "18%". Values under 1% keep one decimal.
    public static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        if p > 0, p < 1 { return String(format: "%.1f%%", p) }
        return "\(Int(p.rounded()))%"
    }

    public static func watts(_ w: Double) -> String {
        w < 1 ? "\(Int((w * 1000).rounded())) mW" : String(format: "%.1f W", w)
    }

    /// 7_560 -> "2 h 6 m", 95 -> "1 m 35 s".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 86_400 { return "\(s / 86_400) d \((s % 86_400) / 3600) h" }
        if s >= 3600 { return "\(s / 3600) h \((s % 3600) / 60) m" }
        if s >= 60 { return "\(s / 60) m \(s % 60) s" }
        return "\(s) s"
    }

    /// 4_100_000 -> "4.1M", 412_000 -> "412k".
    public static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1000 { return "\(Int((d / 1000).rounded()))k" }
        return "\(n)"
    }

    /// Always "$1,284" / "$6.40", whatever the user's locale, so dollar amounts never read like decimals.
    public static func usd(_ v: Double) -> String {
        v >= 100 ? "$" + grouped(Int(v.rounded())) : String(format: "$%.2f", v)
    }

    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }
}
