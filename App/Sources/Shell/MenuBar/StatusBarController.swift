import AppKit
import SwiftUI
import VardisCore
import os

/// What the status item shows right now, for Settings' live preview. Updated only when a value changed.
@MainActor
@Observable
final class MenuBarFeed {
    static let shared = MenuBarFeed()
    private(set) var pieces: [MenuReadout: MenuPiece] = [:]

    func set(_ next: [MenuReadout: MenuPiece]) { if next != pieces { pieces = next } }

    func ordered(_ readouts: [MenuReadout]) -> [MenuPiece] { readouts.compactMap { pieces[$0] } }
}

/// The one Vardis status item: the glyph plus the readouts chosen in Settings › Menu Bar, and the panel it opens.
///
/// Idle cost: the title is a single template image, rebuilt and re-set only when its text changed, at most
/// once per sample. The panel's view tree exists only while it is open (and two minutes after).
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let live: LiveModel
    private let models: AppModels
    private let prefs = MenuBarPrefs.shared
    private let panel: MenuPanelController
    private var snapshot: Snapshot?
    private var lastPieces: [MenuPiece]?
    private var portsLoop: Task<Void, Never>?
    static let log = Logger(subsystem: "app.vardis", category: "menubar")

    init(live: LiveModel, models: AppModels, openWindow: @escaping (Screen?) -> Void, openSettings: @escaping () -> Void, restoreSampling: @escaping () -> Void) {
        self.live = live
        self.models = models
        panel = MenuPanelController(live: live, models: models, openWindow: openWindow, openSettings: openSettings, restoreSampling: restoreSampling)
        super.init()
        item.autosaveName = "vardis.menubar"
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(Brand.name)
            // Hovering the item builds the panel's views ahead of the click, so even the first open is one frame.
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        panel.anchor = { [weak self] in self?.item.button }
        render()
        live.onEveryTick { [weak self] s in
            self?.snapshot = s
            self?.render()
        }
        observePrefs()
        observeClaude()
        updatePortsLoop()
        if CommandLine.arguments.contains("--menubar-snapshot") { panel.snapshotIfRequested() }
        if CommandLine.arguments.contains("--menubar-open-test") { panel.runOpenTest() }
    }

    /// Rebuilds the title only when the visible text changed; redrawing the status bar is the main idle cost.
    private func render() {
        let claude = models.claude
        let five = claude.quota(claude.activeAccount)?.fiveHour?.utilization
        let ports = PortsModel.shared.hasScanned ? PortsModel.shared.serverCount : nil
        let all = MenuBarFormat.pieces(snapshot: snapshot, claudeFiveHour: five, portsCount: ports)
        MenuBarFeed.shared.set(all)
        let shown = prefs.enabledReadouts.compactMap { all[$0] }
        guard shown != lastPieces, let button = item.button else { return }
        lastPieces = shown
        button.image = StatusTitleRenderer.image(shown)
        button.toolTip = shown.isEmpty ? Brand.name : nil
    }

    private func observePrefs() {
        withObservationTracking {
            _ = prefs.enabledReadouts
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.updatePortsLoop()
                self?.observePrefs()
            }
        }
    }

    /// The Claude readout follows quota checks, which arrive between samples.
    private func observeClaude() {
        let claude = models.claude
        withObservationTracking {
            _ = claude.quota(claude.activeAccount)?.fiveHour?.utilization
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observeClaude()
            }
        }
    }

    /// Counting dev servers needs a port scan. It runs every 30 s, and only while that readout is on.
    private func updatePortsLoop() {
        let wanted = prefs.enabledReadouts.contains(.ports)
        if wanted, portsLoop == nil {
            portsLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let live = self?.live else { return }
                    await PortsModel.shared.refresh(live: live)
                    self?.render()
                    try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
                }
            }
        } else if !wanted, let loop = portsLoop {
            loop.cancel()
            portsLoop = nil
        }
    }

    @objc func mouseEntered(with event: NSEvent) { panel.prepare() }
    @objc func mouseExited(with event: NSEvent) {}

    @objc private func toggle(_ sender: NSStatusBarButton) {
        panel.toggle(clickedAt: NSApp.currentEvent?.timestamp)
    }
}
