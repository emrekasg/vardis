import SwiftUI

/// Motion tokens. Every animation starts on the frame the input arrives, is interruptible,
/// and never delays what the user asked for. Reduce Motion turns them into cross-fades or nothing.
enum Motion {
    /// Hover, press, small state flips.
    static let quick = Animation.easeOut(duration: 0.14)
    /// Screen and panel changes.
    static let screen = Animation.smooth(duration: 0.22)
    /// Selection indicators that travel (sidebar pill, segmented controls).
    static let travel = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Live values easing to their new reading.
    static let value = Animation.smooth(duration: 0.45)
    /// Drawers and sheets sliding in.
    static let drawer = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// Staggered entrance for grids: item `i` starts `i × 25 ms` later, capped so the last starts by 150 ms.
    static func stagger(_ i: Int) -> Animation { screen.delay(min(Double(i) * 0.025, 0.15)) }
}

extension View {
    /// Applies `animation` unless the user asked macOS to reduce motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Screen entrance: a short fade with a 6 pt rise. Reduce Motion keeps only the fade.
struct ScreenTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity))
    }
}

/// Row hover highlight that fades in and out.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.selected.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .motion(Motion.quick, value: hovering)
    }
}

/// Fades and lifts a grid item in on first appearance, staggered by index.
struct StaggeredAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(Motion.stagger(index)) { shown = true } }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}
