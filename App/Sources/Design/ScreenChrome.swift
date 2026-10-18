import SwiftUI

// MARK: Toolbar slots

/// A view a screen puts at the trailing end of the main toolbar (filters, a sort menu, one action).
/// Set it with `.toolbarAccessory { … }` anywhere inside the screen.
struct ToolbarAccessory {
    let view: AnyView
}

struct ToolbarAccessoryKey: PreferenceKey {
    static var defaultValue: ToolbarAccessory? { nil }
    static func reduce(value: inout ToolbarAccessory?, nextValue: () -> ToolbarAccessory?) {
        if let next = nextValue() { value = next }
    }
}

/// One short line under the toolbar title, such as "456 apps, 1,452 processes".
struct ToolbarSubtitleKey: PreferenceKey {
    static var defaultValue: String? { nil }
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// Puts `content` at the trailing end of the main window toolbar while this screen shows.
    func toolbarAccessory<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        preference(key: ToolbarAccessoryKey.self, value: ToolbarAccessory(view: AnyView(content())))
    }

    /// Replaces the toolbar subtitle for this screen. `nil` keeps the shell's default; `""` shows none.
    func toolbarSubtitle(_ text: String?) -> some View {
        preference(key: ToolbarSubtitleKey.self, value: text)
    }
}

// MARK: ⌘F

/// Whether the current screen has a search field that ⌘F can focus. Without one, ⌘F opens the palette.
struct ScreenHasSearchKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct ScreenSearchFocus: ViewModifier {
    @Environment(Navigation.self) private var nav
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            .preference(key: ScreenHasSearchKey.self, value: true)
            .onChange(of: nav.searchFocusRequest) { focused.wrappedValue = true }
    }
}

extension View {
    /// Marks this field as the screen's search: ⌘F focuses it.
    /// Usage: `@FocusState var searching: Bool` … `TextField(…).focused($searching).screenSearchFocus($searching)`.
    func screenSearchFocus(_ focused: FocusState<Bool>.Binding) -> some View {
        modifier(ScreenSearchFocus(focused: focused))
    }
}

// MARK: Screen switch

/// Screen change: the new screen rises 8 pt from below when moving down the sidebar, drops from above
/// when moving up, and cross-fades. The old screen only fades, so nothing waits on it.
/// Reduce Motion keeps the cross-fade.
struct ScreenSwitchTransition: ViewModifier {
    let travel: Navigation.Travel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: travel == .down ? 8 : -8)),
            removal: .opacity))
    }
}

// MARK: Lists

extension View {
    /// Rows fade and move as they come and go. Pass the list's ids.
    func animatesRows<ID: Equatable>(_ ids: ID) -> some View {
        motion(Motion.quick, value: ids)
    }
}

/// Row transition for animated lists: fade with a slight move. Reduce Motion is handled by `animatesRows`.
extension AnyTransition {
    static var row: AnyTransition { .opacity.combined(with: .offset(y: -4)) }
}

// MARK: Formatting

enum DurationFmt {
    /// Compact age for elapsed times: "45 s", "12 m", "3 h 5 m", "12 d 9 h". Never "297 h".
    static func compact(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86_400 { let h = (s % 86_400) / 3600; return h > 0 ? "\(s / 86_400) d \(h) h" : "\(s / 86_400) d" }
        if s >= 3600 { let m = (s % 3600) / 60; return m > 0 ? "\(s / 3600) h \(m) m" : "\(s / 3600) h" }
        if s >= 60 { return "\(s / 60) m" }
        return "\(s) s"
    }
}
