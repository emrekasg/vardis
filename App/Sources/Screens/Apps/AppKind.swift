import Foundation
import VardisCore

/// How the Apps screen files an app. Decided from its bundle's Info.plist and path, cached per bundle.
enum AppKind: String, CaseIterable, Identifiable {
    case app, background, system, commandLine

    var id: String { rawValue }

    var filterTitle: String {
        switch self {
        case .app: "Apps"
        case .background: "Background"
        case .system: "System"
        case .commandLine: "Command line"
        }
    }

    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    /// Bundles marked LSUIElement or LSBackgroundOnly have no Dock icon: menu bar items, agents, helpers.
    @MainActor
    static func of(_ app: AppSample) -> AppKind {
        guard let url = app.bundleURL else { return app.isSystem ? .system : .commandLine }
        if let k = cache[url] { return k }
        let path = url.path
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        func flag(_ key: String) -> Bool {
            if let b = info[key] as? Bool { return b }
            if let s = info[key] as? String { return s == "1" || s.lowercased() == "yes" || s.lowercased() == "true" }
            return false
        }
        let faceless = flag("LSUIElement") || flag("LSBackgroundOnly")
        let isSystemPath = systemPrefixes.contains { path.hasPrefix($0) }
        let kind: AppKind = faceless ? (isSystemPath ? .system : .background) : .app
        cache[url] = kind
        return kind
    }

    @MainActor private static var cache: [URL: AppKind] = [:]

    /// The line under the app name in the table.
    @MainActor
    static func subtitle(_ app: AppSample) -> String {
        let n = app.processCount
        let processes = n == 1 ? "1 process" : "\(n) processes"
        switch of(app) {
        case .app: return processes
        case .background: return n > 1 ? "Background, \(processes)" : "Background"
        case .system: return n > 1 ? "System, \(processes)" : "System"
        case .commandLine: return n > 1 ? "Command line tool, \(processes)" : "Command line tool"
        }
    }
}
