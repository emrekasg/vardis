import AppKit
import SwiftUI
import UserNotifications
import VardisCore

struct OnboardingView: View {
    let finish: () -> Void
    @State private var step = 1
    @AppStorage(Pref.openAtLogin) private var openAtLogin = true
    @AppStorage(Pref.menuCPU) private var menuCPU = true
    @AppStorage(Pref.menuMemory) private var menuMemory = true
    @AppStorage(Pref.menuClaude) private var menuClaude = true
    @AppStorage(Pref.menuNetwork) private var menuNetwork = false
    @AppStorage(Pref.menuBattery) private var menuBattery = false
    @AppStorage(Pref.claudeSearchIndex) private var searchIndex = true
    @AppStorage(Pref.autoSwitch) private var autoSwitch = false
    @State private var notificationsAllowed = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 1: welcome
                case 2: access
                case 3: claude
                case 4: menuBar
                default: ready
                }
            }
            .padding(.horizontal, 56).padding(.top, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Hairline()
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.accent : Theme.raised).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step == 1 {
                    Text("Free forever. Nothing leaves your Mac.").font(.calloutV).foregroundStyle(Theme.textTertiary)
                }
                if step > 1 && step < 5 { Button("Back") { step -= 1 } }
                Button(primaryTitle) { step < 5 ? (step += 1) : finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 760, height: 560)
        .background(Theme.window)
    }

    private var primaryTitle: String {
        switch step {
        case 1: "Get started"
        case 5: "Open Vardis"
        default: "Continue"
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitleV).foregroundStyle(Theme.text)
            Text(subtitle).font(.bodyV).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 120, height: 120)
            Text("Welcome to \(Brand.name)").font(.largeTitleV).foregroundStyle(Theme.text)
            Text("See what your Mac is doing and why, clean what you don’t need, and keep Claude Code in check.")
                .font(.bodyV).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(width: 460)
            VStack(alignment: .leading, spacing: 12) {
                feature("bolt", Theme.Metric.cpu, "Now", "Every app’s CPU, memory, power and network, live")
                feature("clock", Theme.Metric.ane, "Black box", "Rewind to any minute and see what slowed you down")
                feature("sparkle", Theme.claude, "Claude Code", "Sessions, tokens, limits and account switching")
            }
            .frame(width: 460).padding(.top, 12)
        }
    }

    private var access: some View {
        VStack(spacing: 18) {
            header("What \(Brand.name) can see", "Apps and processes work right away. The rest is optional, and you can change it later in Settings.")
            VStack(spacing: 0) {
                accessRow("square.grid.2x2", Theme.Metric.cpu, "Apps and processes", "CPU, memory, energy, disk and network for every app you run") {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.calloutV)
                }
                accessRow("internaldrive", Theme.Metric.disk, "Disk Cleanup in ~/Library", "Xcode, simulators and caches live in protected folders. Needs Full Disk Access.") {
                    Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                }
                accessRow("bell", Theme.orange, "Notifications", "For leaks, a Mac kept awake, and accounts near their limit") {
                    if notificationsAllowed { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.calloutV) }
                    else { Button("Allow") { Task { notificationsAllowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false } } }
                }
            }
        }
    }

    private var claude: some View {
        VStack(spacing: 18) {
            header("Claude Code", "Vardis reads Claude Code’s own files on this Mac to show sessions, tokens and limits. Nothing is uploaded.")
            GroupBoxV {
                FormRow(label: "Make sessions searchable", detail: "Builds a search index on this Mac") { Toggle("", isOn: $searchIndex).toggleStyle(.switch).labelsHidden() }
                FormRow(label: "Switch accounts automatically", detail: "Move new sessions to the next account at 90% of the 5-hour window", showsDivider: false) {
                    Toggle("", isOn: $autoSwitch).toggleStyle(.switch).labelsHidden().disabled(!Edition.current.supports(.accountSwitching))
                }
            }
        }
    }

    private var menuBar: some View {
        VStack(spacing: 18) {
            header("Pick your menu bar", "Each readout is its own item. Hold ⌘ and drag to reorder them in the menu bar.")
            GroupBoxV {
                FormRow(label: "CPU") { Toggle("", isOn: $menuCPU).toggleStyle(.switch).labelsHidden() }
                FormRow(label: "Memory") { Toggle("", isOn: $menuMemory).toggleStyle(.switch).labelsHidden() }
                FormRow(label: "Claude Code", detail: "Active account’s 5-hour window") { Toggle("", isOn: $menuClaude).toggleStyle(.switch).labelsHidden() }
                FormRow(label: "Network") { Toggle("", isOn: $menuNetwork).toggleStyle(.switch).labelsHidden() }
                FormRow(label: "Battery", showsDivider: false) { Toggle("", isOn: $menuBattery).toggleStyle(.switch).labelsHidden() }
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            header("You’re set", "Vardis is running in the menu bar. Open it any time with ⌥⌘V.")
            GroupBoxV {
                FormRow(label: "Open Vardis at login", detail: "Stays in the menu bar, so the window opens instantly", showsDivider: false) {
                    Toggle("", isOn: $openAtLogin).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            IconTile(systemName: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headlineV).foregroundStyle(Theme.text)
                Text(detail).font(.calloutV).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func accessRow<C: View>(_ symbol: String, _ color: Color, _ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(systemName: symbol, color: color, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headlineV).foregroundStyle(Theme.text)
                    Text(detail).font(.calloutV).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                control()
            }
            .padding(.vertical, 13)
            Hairline()
        }
    }
}
