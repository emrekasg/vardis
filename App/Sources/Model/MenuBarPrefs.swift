import Foundation
import Observation

/// A value the status item can show next to the Vardis glyph.
enum MenuReadout: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, network, disk, gpu, battery, claude, ports
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .claude: "Claude Code"
        case .ports: "Ports & Servers"
        }
    }

    var detail: String {
        switch self {
        case .cpu: "Whole-Mac use"
        case .memory: "Memory used"
        case .network: "Download and upload speed"
        case .disk: "Free space"
        case .gpu: "GPU use"
        case .battery: "Charge"
        case .claude: "Active account’s 5-hour window"
        case .ports: "Dev servers listening. Checks every 30 s."
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .gpu: "square.stack.3d.up"
        case .battery: "battery.75percent"
        case .claude: "sparkle"
        case .ports: "powerplug"
        }
    }
}

/// A tab of the menu bar panel.
enum MenuTab: String, CaseIterable, Identifiable, Sendable {
    case overview, cpu, memory, disk, network, gpu, battery, ports, claude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .battery: "Battery & Power"
        case .ports: "Ports & Servers"
        case .claude: "Claude Code"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "square.stack.3d.up"
        case .battery: "bolt"
        case .ports: "powerplug"
        case .claude: "sparkle"
        }
    }

    /// Where "Open Vardis" goes from this tab.
    var screen: Screen {
        switch self {
        case .overview, .network, .gpu: .now
        case .cpu, .memory, .battery: .apps
        case .disk: .diskCleanup
        case .ports: .ports
        case .claude: .claudeLive
        }
    }
}

/// A tile of the Overview tab.
enum MenuTile: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, network, disk, gpu, battery, claude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .claude: "Claude Code"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .gpu: "square.stack.3d.up"
        case .battery: "battery.75percent"
        case .claude: "sparkle"
        }
    }
}

enum PanelTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
}

/// One entry of an ordered, toggleable list.
struct OrderedChoice<Item: Hashable & Sendable>: Hashable, Sendable {
    var item: Item
    var isOn: Bool
}

/// Everything the menu bar can be told to show, in the order the user chose. Stored in UserDefaults.
/// Changing a value updates the status item and the open panel at once (they observe this object).
@MainActor
@Observable
final class MenuBarPrefs {
    static let shared = MenuBarPrefs()

    enum Key {
        static let readouts = "menubar.readouts"        // [String], "~" prefix = off
        static let showReadouts = "menubar.showReadouts" // Bool
        static let tabs = "menubar.tabs"                // [String], "~" prefix = off
        static let tiles = "menubar.tiles"              // [String], "~" prefix = off
        static let theme = "menubar.theme"              // "system" | "light" | "dark"
    }

    var readouts: [OrderedChoice<MenuReadout>] { didSet { if readouts != oldValue { save(readouts, Key.readouts) } } }
    var showReadouts: Bool { didSet { if showReadouts != oldValue { defaults.set(showReadouts, forKey: Key.showReadouts) } } }
    var tabs: [OrderedChoice<MenuTab>] { didSet { if tabs != oldValue { save(tabs, Key.tabs) } } }
    var tiles: [OrderedChoice<MenuTile>] { didSet { if tiles != oldValue { save(tiles, Key.tiles) } } }
    var theme: PanelTheme { didSet { if theme != oldValue { defaults.set(theme.rawValue, forKey: Key.theme) } } }

    var enabledReadouts: [MenuReadout] { showReadouts ? readouts.filter(\.isOn).map(\.item) : [] }
    var enabledTabs: [MenuTab] { tabs.filter(\.isOn).map(\.item) }
    var enabledTiles: [MenuTile] { tiles.filter(\.isOn).map(\.item) }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        readouts = Self.load(d, Key.readouts) ?? Self.defaultReadouts
        showReadouts = d.object(forKey: Key.showReadouts) as? Bool ?? true
        tabs = Self.load(d, Key.tabs) ?? MenuTab.allCases.map { OrderedChoice(item: $0, isOn: true) }
        tiles = Self.load(d, Key.tiles) ?? MenuTile.allCases.map { OrderedChoice(item: $0, isOn: $0 != .claude) }
        theme = PanelTheme(rawValue: d.string(forKey: Key.theme) ?? "") ?? .system
    }

    func resetToDefaults() {
        for k in [Key.readouts, Key.showReadouts, Key.tabs, Key.tiles, Key.theme] { defaults.removeObject(forKey: k) }
        readouts = Self.defaultReadouts
        showReadouts = true
        tabs = MenuTab.allCases.map { OrderedChoice(item: $0, isOn: true) }
        tiles = MenuTile.allCases.map { OrderedChoice(item: $0, isOn: $0 != .claude) }
        theme = .system
    }

    // MARK: Storage

    private func save<Item: RawRepresentable<String>>(_ list: [OrderedChoice<Item>], _ key: String) {
        defaults.set(list.map { ($0.isOn ? "" : "~") + $0.item.rawValue }, forKey: key)
    }

    /// Reads a stored list; items added in a later version are appended, off, so the user sees them in Settings.
    private static func load<Item: RawRepresentable<String> & CaseIterable & Hashable & Sendable>(_ d: UserDefaults, _ key: String) -> [OrderedChoice<Item>]? {
        guard let raw = d.stringArray(forKey: key) else { return nil }
        var seen = Set<Item>()
        var out: [OrderedChoice<Item>] = []
        for s in raw {
            let off = s.hasPrefix("~")
            guard let item = Item(rawValue: off ? String(s.dropFirst()) : s), seen.insert(item).inserted else { continue }
            out.append(OrderedChoice(item: item, isOn: !off))
        }
        for item in Item.allCases where !seen.contains(item) { out.append(OrderedChoice(item: item, isOn: false)) }
        return out
    }

    /// Glyph and CPU only; everything else is one switch away in Settings › Menu Bar.
    static let defaultReadouts = MenuReadout.allCases.map { OrderedChoice(item: $0, isOn: $0 == .cpu) }
}
