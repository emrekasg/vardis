import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings and onboarding windows, built lazily (they are not on the hot path).
@MainActor
final class AuxWindows {
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private let live: LiveModel

    init(live: LiveModel) { self.live = live }

    func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environment(live))
            w.center()
            settings = w
        }
        NSApp.setActivationPolicy(.regular)
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showOnboarding(done: @escaping @MainActor () -> Void) {
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
                UserDefaults.standard.set(true, forKey: Pref.onboardingDone)
                self?.onboarding?.close()
                done()
            })
            w.center()
            onboarding = w
        }
        NSApp.setActivationPolicy(.regular)
        onboarding?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// ⌥⌘V opens the window from anywhere. Carbon hot keys work in the sandbox and need no permission.
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private static var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5644_5253), id: 1) // "VDRS"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
