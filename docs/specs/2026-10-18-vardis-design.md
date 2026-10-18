# Vardis — design spec

Date: 2026-10-18 · Status: approved design (Figma), engineering decisions below

## Intent

Vardis is a native macOS app that shows what the Mac is doing right now, what it did earlier and why, cleans developer junk safely, and keeps Claude Code (sessions, tokens, plan limits, multiple accounts) in view.

It is a better Vitals (vitalsmac.com): same live readouts and app grouping, plus per-app operation history, a rewindable timeline, a safe disk cleaner, and a deep Claude Code section.

**Promise, non-negotiable:** free forever, and Vardis collects nothing. No account, no analytics, no crash reporting, no telemetry SDK. Network use is limited to (1) the update check in the direct edition, which the user can turn off, and (2) asking Anthropic for the user's own plan limits with the user's own sign-in.

Design source: Figma `Nay4HUHlzZlxYOGyzAfaZN` (pages Brand, Components, Screens).

## Goals

1. Feel instant. Performance budgets below are release gates.
2. Group ~1,000 processes into ~60 apps; show CPU, memory, energy, disk, network per app.
3. Live dashboard ("Now") with 1 s updates while visible.
4. History with tiered downsampling; Today digest and Time Machine on top of it.
5. Disk Cleanup for developer junk; always moves to Trash.
6. Claude Code: auto-discovery, usage and cost, sessions with search and resume, live sessions, plan limits, multiple accounts with automatic switching (direct edition).
7. Menu bar items, configurable.
8. Settings (10 panes) and a 5-step onboarding.

## Non-goals

- Windows/Linux. iOS.
- Fan control in v1 (read-only sensors).
- Killing or deleting anything without an explicit confirmation in a Vardis window.
- Any server component.

## Anti-goals (failure even if it works)

- A spinner or skeleton on any screen switch.
- Idle CPU above 0.1% or idle memory above 40 MB.
- Any byte of user data leaving the Mac.

## Editions

One codebase, two build configurations, a compile-time flag `APPSTORE`.

| Capability | Direct (vardis.app, Developer ID, notarized) | App Store (sandboxed) |
|---|---|---|
| Apps/processes of the current user, CPU, memory, energy, disk, network | yes | yes |
| System processes via helper | yes (later milestone) | no |
| Temperatures, fans, ANE (SMC, IOReport) | yes (later milestone) | no |
| Disk Cleanup | yes | user-selected folders (security-scoped bookmarks) |
| Claude Code sessions/usage from `~/.claude` | yes | after the user picks the folder once |
| Keychain discovery, account switching, `claude auth login` | yes | no (shows usage only) |
| Updates | Sparkle | App Store |

Code that needs direct-only capabilities sits behind `Edition.current.supports(_:)` so the App Store build compiles the same sources and hides the feature.

## Performance budgets (release gates, measured on M1 8 GB)

| Moment | Budget |
|---|---|
| Open window from menu bar | < 50 ms |
| Switch screens | < 16 ms |
| Open menu bar dropdown | < 30 ms |
| One live tick, all tiles | < 2 ms main thread |
| Cold launch to menu bar item | < 150 ms |
| Session search (1,000+ sessions) | < 30 ms |
| Idle CPU, window closed | < 0.1 % |
| Idle memory, window closed | < 40 MB |

How:
- Main window created at launch and kept hidden; "open" only orders it front.
- Screens read from in-memory ring buffers owned by a single `Sampler` actor; no disk I/O on the main thread.
- Sampling: one timer, 5 s when no window is visible, 1 s when the Now screen is visible, with timer leeway for coalescing.
- Charts drawn with SwiftUI `Canvas` (single draw call per chart), no per-sample allocation (fixed-size ring buffers of `Float`).
- History: one SQLite file, WAL, tiers 1 s (1 h) → 10 s (24 h) → 1 min (30 d) → 10 min (retention).
- Claude Code: tail each `*.jsonl` from its last byte offset; FSEvents to learn about changes; never re-read whole files; FTS5 index.
- Disk Cleanup: enumerate with prefetching `totalFileAllocatedSize`; low-priority QoS; FSEvents for updates.
- No Electron, no web views, no third-party UI frameworks. Dependencies: Sparkle (direct edition only).

## Architecture

```
App/ (Vardis.app target, AppKit lifecycle + SwiftUI views)
  AppDelegate, StatusItems, MainWindow, Screens/*, Settings/*, Onboarding/*
Packages/VardisKit (SwiftPM, macOS 15+)
  VardisCore      models, RingBuffer, Formatters, Edition
  VardisSampling  CPU, memory, processes, app grouping, disk, network, battery, GPU; Sampler actor
  VardisStore     SQLite wrapper, tiered history, settings persistence
  VardisClaude    discovery, transcript parsing, usage and cost, sessions + FTS5, live sessions, quota client, accounts
  VardisCleanup   rules, scanner, sizes, trash
website/        static site for vardis.app (Cloudflare Pages)
```

Data flow: `Sampler` (actor, background) → `Snapshot` (value type) → `LiveModel` (`@Observable`, main actor, holds ring buffers) → views. History writer subscribes to snapshots and writes tiers off the main thread.

### Sampling sources (public APIs only in v1)

- CPU total: `host_processor_info` deltas (user/system/idle per core).
- Memory: `host_statistics64(HOST_VM_INFO64)`, page size; app/wired/compressed/cached/free; swap via `sysctl vm.swapusage`; pressure via `kern.memorystatus_vm_pressure_level`.
- Processes: `proc_listallpids`, `proc_pid_rusage(RUSAGE_INFO_V6)` (CPU time, phys footprint, disk bytes, energy nJ), `proc_pidpath`, `proc_pidinfo(PROC_PIDTBSDINFO)` for ppid/name.
- App grouping: map pid → owning `.app` bundle by walking the executable path to the outermost `.app`, then ppid chain; helpers (`Google Chrome Helper (Renderer)`) roll up into the parent app. Display name + icon from `NSRunningApplication` / bundle.
- Disk: free space from `volumeAvailableCapacityForImportantUsage`; throughput from IOKit `IOBlockStorageDriver` "Statistics".
- Network: `getifaddrs` `if_data` byte counters (total). Per-app network: direct edition parses `nettop -P -L 1 -x` at 5 s cadence only while the Apps screen is visible (later milestone).
- Battery: `IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry (cycle count, health, wattage).
- GPU: IORegistry `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`, `In use system memory`.

### Claude Code

- Discovery: `~/.claude`, `~/.claude-*`, `$CLAUDE_CONFIG_DIR`, folders added by the user. Credentials: macOS Keychain service `Claude Code-credentials`, fallback `<config>/.credentials.json` (direct edition).
- Usage: each assistant line in `projects/<slug>/<session>.jsonl` carries `message.usage` (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`) and `message.model`; dedupe by `message.id`/`requestId`. Cost from a bundled price table (per model, per token class), overridable.
- Sessions: id, project path (`cwd`), git branch, first user prompt as title fallback, started/ended, tokens, cost, tool-call counts. FTS5 over user/assistant text, stored locally only.
- Live sessions: processes whose executable name is `claude` (or node running claude-code), cwd via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, matched to the newest session file in that project.
- Plan limits: `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <access token>` and `anthropic-beta: oauth-2025-04-20` (same call Claude Code's own `/usage` makes). Polled at most every 60 s while visible, 5 min otherwise.
- Accounts (direct edition, later milestone): each account gets `~/.vardis/accounts/<name>` as its `CLAUDE_CONFIG_DIR`; "Add account" runs the official `claude auth login` with that environment. Automatic switching moves new sessions to the next account when the active one crosses the user's threshold. The user accepted the terms-of-service risk of switching between their own subscriptions.

### Disk Cleanup rules (v1)

Xcode DerivedData, Archives (never preselected), iOS DeviceSupport, unavailable simulators (`xcrun simctl list -j`), `node_modules` under configured project roots (protected if the project was opened in the last 14 days), Docker (via `docker system df` when available), package caches (Homebrew, npm, pnpm, yarn, pip, Cargo, Go, Gradle), large old files (opt-in). Every item: path, size, last used, safety (`rebuildable`, `redownloads`, `notRebuildable`, `active`), selected-by-default flag. Removal = `FileManager.trashItem`.

## Decided by the builder (my calls)

- Swift 6.3 strict concurrency, Xcode 26, deployment target macOS 15.
- XcodeGen (`project.yml`) generates the Xcode project; the `.xcodeproj` is not committed.
- SwiftUI views on an AppKit lifecycle (`NSApplicationDelegate`, `NSStatusItem`, `NSWindow` hosting SwiftUI) so the window can be prebuilt and kept hidden.
- License: MIT for code. Name and logo are not covered by MIT (TRADEMARKS note in README).
- Bundle ids: `app.vardis.Vardis` (App Store), `app.vardis.Vardis.direct` (direct download). Separate ids keep preferences and containers from colliding when both are installed.
- Name, bundle id and domain live in one place (`Config/Brand.xcconfig` + `VardisCore/Brand.swift`).

## Milestones

1. Foundation: repo, XcodeGen project, VardisKit packages with tests, Sampler, app grouping, LiveModel, menu bar items + dropdown, Now, Apps, CI.
2. Claude Code read path: discovery, usage/cost, sessions + search + resume, live sessions, plan limits; Claude screens.
3. Disk Cleanup.
4. History + Today + Time Machine.
5. Settings, onboarding, alerts (UserNotifications).
6. Direct-only: accounts + auto-switch, helper, sensors, per-app network, Sparkle.
7. Release: App Store build, notarization pipeline, website live on vardis.app.
