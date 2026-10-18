import SwiftUI

/// A detail panel that slides in from the trailing edge over the current screen.
/// Escape or clicking the dimmed area closes it. Content is built only while open.
struct DetailDrawer<Item: Identifiable & Equatable, Panel: View>: ViewModifier {
    @Binding var item: Item?
    var width: CGFloat = 420
    @ViewBuilder var panel: (Item) -> Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cancelShortcutBlocked) private var cancelBlocked

    func body(content base: Content) -> some View {
        base.overlay {
            ZStack(alignment: .trailing) {
                if item != nil {
                    Color.black.opacity(0.08)
                        .contentShape(Rectangle())
                        .onTapGesture { item = nil }
                        .transition(.opacity)
                }
                if let current = item {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button { item = nil } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.raised, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(cancelBlocked ? nil : .cancelAction)
                            .help("Close (Esc)")
                        }
                        .padding(.horizontal, 16).padding(.top, 14)
                        panel(current)
                            .id(current.id)
                            .transition(.opacity)
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.window)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 1) }
                    .shadow(color: .black.opacity(0.12), radius: 24, x: -6)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .motion(Motion.drawer, value: item?.id)
        }
    }

}

extension View {
    /// Shows `content` in a trailing drawer while `item` is non-nil.
    func detailDrawer<Item: Identifiable & Equatable, C: View>(item: Binding<Item?>, width: CGFloat = 420, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        modifier(DetailDrawer(item: item, width: width, panel: content))
    }
}

extension EnvironmentValues {
    /// True while something above the screen (the command palette) owns Escape, so drawers do not close under it.
    @Entry var cancelShortcutBlocked = false
}
