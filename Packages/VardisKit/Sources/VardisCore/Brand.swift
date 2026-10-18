import Foundation

/// The product name, domain and identifiers live here and in Config/Brand.xcconfig only.
public enum Brand {
    public static let name = "Vardis"
    public static let domain = "vardis.app"
    public static let website = URL(string: "https://vardis.app")!
    public static let repository = URL(string: "https://github.com/emrekasg/vardis")!
    /// Folder under Application Support (and ~/.vardis for Claude Code account homes).
    public static let dataFolderName = "Vardis"
    public static let dotFolderName = ".vardis"
}

/// The two builds share one codebase. Direct-only capabilities are checked at runtime through `supports(_:)`.
public enum Edition: Sendable {
    case direct
    case appStore

    public static var current: Edition {
        #if APPSTORE
        return .appStore
        #else
        return .direct
        #endif
    }

    public enum Capability: Sendable {
        case systemProcessHelper
        case sensors
        case perAppNetwork
        case keychainDiscovery
        case accountSwitching
        case runClaudeLogin
        case unrestrictedFileAccess
        case sparkleUpdates
    }

    public func supports(_ capability: Capability) -> Bool {
        switch self {
        case .direct: return true
        case .appStore: return false
        }
    }
}
