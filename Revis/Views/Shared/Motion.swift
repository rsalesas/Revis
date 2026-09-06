import SwiftUI
import AppKit

/// Named motion tokens, the way `Theme` holds named colours.
///
/// Animation exists here to make a state change legible — that a mark *arrived*, that a
/// pane took width from the document — not to decorate. Durations and curves live here and
/// nowhere else; a sixth duration typed at a call site is how a set of animations stops
/// looking like one system.
///
/// Three of the tokens have to survive a trip into the document's stylesheet, which is why
/// they are spelled as explicit control points rather than `.easeOut`: the same four
/// numbers appear in review.css as a `cubic-bezier(…)`.
struct Motion: Equatable, Sendable {

    struct Curve: Equatable, Sendable {
        let x1: Double, y1: Double, x2: Double, y2: Double
        init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        }
        var cssValue: String {
            "cubic-bezier(\(trim(x1)), \(trim(y1)), \(trim(x2)), \(trim(y2)))"
        }
        private func trim(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(v)
        }
    }

    let name: String
    let duration: Double
    let curve: Curve?
    let animation: Animation

    /// Hover fills and other cursor-follow affordances — short enough to feel attached to
    /// the pointer.
    static let hover = Motion(
        name: "hover", duration: 0.12, curve: Curve(0, 0, 0.58, 1),
        animation: .timingCurve(0, 0, 0.58, 1, duration: 0.12))

    /// Fades and opacity reveals: anything that changes what is there without changing
    /// where anything is.
    static let reveal = Motion(
        name: "reveal", duration: 0.18, curve: Curve(0, 0, 0.58, 1),
        animation: .timingCurve(0, 0, 0.58, 1, duration: 0.18))

    /// Structural movement — a pane taking width from the document, a row growing to hold
    /// its controls. Decelerating hard at the end, so a panel settles rather than stopping.
    static let panel = Motion(
        name: "panel", duration: 0.24, curve: Curve(0.32, 0.72, 0, 1),
        animation: .timingCurve(0.32, 0.72, 0, 1, duration: 0.24))

    /// Rolling numerals and control state. A trace of bounce so a changing count reads as
    /// *changed* rather than redrawn.
    static let value = Motion(
        name: "value", duration: 0.25, curve: nil,
        animation: .snappy(duration: 0.25, extraBounce: 0.05))

    static let all: [Motion] = [hover, reveal, panel, value]
    /// The tokens review.css must mirror.
    static let crossBoundary: [Motion] = [hover, reveal, panel]

    var cssCurveProperty: String { "--rv-motion-\(name)" }
    var cssDurationProperty: String { "--rv-motion-\(name)-duration" }
    var cssDurationValue: String { "\(Int((duration * 1000).rounded()))ms" }

    /// The animation to use, or nil (instant) when motion is being reduced. Always reached
    /// through `.motion(_:value:)` so no call site can quietly skip the check.
    func resolved(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    @MainActor
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Reads `accessibilityReduceMotion` itself, which is why this is a `ViewModifier` rather
/// than a plain function — an Environment value can only be read inside one.
private struct MotionModifier<V: Equatable>: ViewModifier {
    let token: Motion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(token.resolved(reduceMotion), value: value)
    }
}

extension View {
    /// Animate changes to `value` with a named token, honouring Reduce Motion. Use this in
    /// place of `.animation(_:value:)` everywhere.
    func motion<V: Equatable>(_ token: Motion, value: V) -> some View {
        modifier(MotionModifier(token: token, value: value))
    }

    /// Roll a changing number rather than redrawing it. Pair with `.monospacedDigit()`.
    func rollingNumber(_ value: Double) -> some View {
        contentTransition(.numericText(value: value))
            .motion(.value, value: value)
    }
}

@MainActor
func withMotion<R>(_ token: Motion, _ body: () throws -> R) rethrows -> R {
    try withAnimation(token.resolved(Motion.systemReduceMotion), body)
}

/// How a row's extra controls arrive when it is chosen: a fade with a little height, so
/// the list does not jump.
extension View {
    func revealedRowTransition() -> some View {
        transition(.opacity.combined(with: .move(edge: .top)))
    }
}
