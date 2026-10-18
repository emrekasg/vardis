import Foundation
import Observation

/// Detail tiles on Now, in their default order.
enum NowTile: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, network, disk, gpu, power, claude, watchlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .power: "Power"
        case .claude: "Claude Code"
        case .watchlist: "Watch list"
        }
    }

    /// Tiles that span the full row.
    var isWide: Bool { self == .watchlist }
}

/// Now's layout (tile order, hidden tiles) and the watch list. Persisted in UserDefaults.
/// The watch list holds `AppSample.id`s (bundle ids when the app has one) under `now.watchlist`.
@MainActor
@Observable
final class NowPrefs {
    static let shared = NowPrefs()

    static let orderKey = "now.tileOrder"
    static let hiddenKey = "now.hiddenTiles"
    static let watchlistKey = "now.watchlist"

    private(set) var order: [NowTile]
    private(set) var hidden: Set<NowTile>
    private(set) var watchlist: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = Self.normalized(defaults.stringArray(forKey: Self.orderKey) ?? [])
        hidden = Set((defaults.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(NowTile.init(rawValue:)))
        watchlist = defaults.stringArray(forKey: Self.watchlistKey) ?? []
    }

    /// Saved order first, then any tile a newer build added, in default order.
    static func normalized(_ saved: [String]) -> [NowTile] {
        var out: [NowTile] = []
        for raw in saved { if let t = NowTile(rawValue: raw), !out.contains(t) { out.append(t) } }
        for t in NowTile.allCases where !out.contains(t) { out.append(t) }
        return out
    }

    var visible: [NowTile] { order.filter { !hidden.contains($0) } }

    func move(_ tile: NowTile, before target: NowTile) {
        guard tile != target, let from = order.firstIndex(of: tile), let to = order.firstIndex(of: target) else { return }
        // Moving forward lands after the target, moving back lands before it; either way it takes the target's slot.
        order.remove(at: from)
        order.insert(tile, at: to)
        save()
    }

    func move(_ tile: NowTile, by delta: Int) {
        guard let i = order.firstIndex(of: tile) else { return }
        let j = min(max(0, i + delta), order.count - 1)
        guard i != j else { return }
        order.swapAt(i, j)
        save()
    }

    func setHidden(_ tile: NowTile, _ isHidden: Bool) {
        if isHidden { hidden.insert(tile) } else { hidden.remove(tile) }
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }

    func resetLayout() {
        order = NowTile.allCases
        hidden = []
        defaults.removeObject(forKey: Self.orderKey)
        defaults.removeObject(forKey: Self.hiddenKey)
    }

    func isPinned(_ appID: String) -> Bool { watchlist.contains(appID) }

    func togglePin(_ appID: String) {
        if let i = watchlist.firstIndex(of: appID) { watchlist.remove(at: i) } else { watchlist.append(appID) }
        defaults.set(watchlist, forKey: Self.watchlistKey)
    }

    private func save() { defaults.set(order.map(\.rawValue), forKey: Self.orderKey) }
}
