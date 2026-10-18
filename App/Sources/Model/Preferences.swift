import Foundation

/// Every user preference, with its default. Stored in UserDefaults; nothing leaves the Mac.
enum Pref {
    static let openAtLogin = "openAtLogin"
    static let dockMode = "dockMode"                 // "whileOpen" | "always" | "never"
    static let appearance = "appearance"             // "light" | "dark" | "system"
    static let temperatureUnit = "temperatureUnit"   // "c" | "f"
    static let networkUnit = "networkUnit"           // "bytes" | "bits"
    static let cpuMode = "cpuMode"                   // "mac" | "core"
    static let checkUpdates = "checkUpdates"
    static let closedInterval = "closedInterval"     // seconds
    static let openInterval = "openInterval"         // seconds
    static let slowOnLowBattery = "slowOnLowBattery"
    static let keepWindowReady = "keepWindowReady"
    static let menuCPU = "menu.cpu"
    static let menuMemory = "menu.memory"
    static let menuClaude = "menu.claude"
    static let menuNetwork = "menu.network"
    static let menuBattery = "menu.battery"
    static let menuDisk = "menu.disk"
    static let alertCPU = "alert.cpu"
    static let alertLeak = "alert.leak"
    static let alertAwake = "alert.awake"
    static let alertHang = "alert.hang"
    static let alertClaudeLimit = "alert.claudeLimit"
    static let alertClaudeWaiting = "alert.claudeWaiting"
    static let alertSwitched = "alert.switched"
    static let quietHours = "alert.quietHours"
    static let cleanupProtectDays = "cleanup.protectDays"
    static let cleanupLargeFiles = "cleanup.largeFiles"
    static let claudeSearchIndex = "claude.searchIndex"
    static let claudeGroupBy = "claude.groupBy"      // "topic" | "project" | "date"
    static let claudeTerminal = "claude.terminal"
    static let claudeAPICost = "claude.apiCost"
    static let autoSwitch = "claude.autoSwitch"
    static let autoSwitchFiveHour = "claude.autoSwitch.fiveHour"
    static let autoSwitchWeekly = "claude.autoSwitch.weekly"
    static let historyRetentionDays = "history.retentionDays"
    static let mcpServer = "integrations.mcp"
    static let debugLog = "advanced.debugLog"
    static let onboardingDone = "onboardingDone"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openAtLogin: true, dockMode: "whileOpen", appearance: "light", temperatureUnit: "c", networkUnit: "bytes",
            cpuMode: "mac", checkUpdates: true, closedInterval: 5, openInterval: 1, slowOnLowBattery: true, keepWindowReady: true,
            menuCPU: true, menuMemory: true, menuClaude: true, menuNetwork: false, menuBattery: false, menuDisk: false,
            alertCPU: true, alertLeak: true, alertAwake: true, alertHang: true, alertClaudeLimit: true, alertClaudeWaiting: true,
            alertSwitched: true, quietHours: true, cleanupProtectDays: 14, cleanupLargeFiles: false, claudeSearchIndex: true,
            claudeGroupBy: "topic", claudeTerminal: "Terminal", claudeAPICost: true, autoSwitch: false, autoSwitchFiveHour: 90,
            autoSwitchWeekly: 95, historyRetentionDays: 90, mcpServer: false, debugLog: false, onboardingDone: false,
        ])
    }
}
