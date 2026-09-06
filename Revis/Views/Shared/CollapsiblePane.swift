import SwiftUI

/// A side pane that collapses by giving its width back, rather than by uncovering what was
/// underneath.
///
/// Covering would defeat the point: the reason to open the annotations pane is to read a
/// note while looking at the passage it is about, which you cannot do if the pane is
/// sitting on top of the passage.
///
/// **A slot in a row, not a container around one.** Vaelora nests these — one pane wrapping
/// another wrapping the content — and there it is deliberate: its layout animates, and an
/// animation has to be applied by the view that lays out BOTH children, so the nesting is
/// what decides whose width each animation comes out of. This layout does not animate at
/// all (see below), so the nesting bought nothing and cost a level: every toggle of the
/// outer pane re-solved the inner one before reaching the document. Three siblings in one
/// row say the same thing with less machinery.
///
/// **The pane stays mounted while closed.** It is cheaper to build it once than to make its
/// first frame correct. A view rebuilt on every open starts from its own initial state and
/// corrects itself a frame later, which shows as soon as opening takes a quarter of a
/// second.
///
/// **The slot changes size instantly; the content slides into it.** This is the whole of
/// what took so long to find. Dragging the window edge never puts the document under a
/// pane and resizes beautifully; toggling a pane did both. The difference is not the web
/// view — on a drag the pane's width is CONSTANT and only the document's changes, while on
/// a toggle the pane's width was animating too, so the layout was being re-solved sixty
/// times against a width that kept moving. Now the slot goes to its final width in one
/// step, which is exactly what a window drag does, and the content slides in from outside
/// on the panel token, clipped to the slot. What moves is a picture, not a layout.
struct CollapsiblePane<Content: View>: View {
    /// Which side of the row this sits on. The anchoring is mirrored for each, and the
    /// mirroring is the whole of the difference.
    let edge: HorizontalEdge
    let isOpen: Bool
    let width: CGFloat
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var dividerWidth: CGFloat { 0.5 }
    private var slot: CGFloat { width + Self.dividerWidth }

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { PaneDivider() }
            // Fixed here so the controls stay laid out at their real width all the way
            // through — the slot clips, it does not squeeze.
            content.frame(width: width)
            if edge == .leading { PaneDivider() }
        }
        // Closed, the content sits wholly outside the slot, on the side it comes from.
        .offset(x: isOpen ? 0 : (edge == .leading ? -slot : slot))
        // On the offset ALONE. Applied here, below the frame, so it animates the slide and
        // not the size of the slot the slide happens inside.
        .animation(reduceMotion ? nil : Motion.panel.animation, value: isOpen)
        .frame(width: isOpen ? slot : 0,
               alignment: edge == .leading ? .trailing : .leading)
        .clipped()
    }
}

/// The main content of a row of panes: sized instantly, and clipped.
///
/// **Instantly**, because the layout is not what should be moving. A toggle is wrapped in
/// `withAnimation` by whatever calls it, and that animation reaches every view in the
/// update — including a hosted `NSView`, which then animates its layer to the new width
/// through Core Animation and spends a fifth of a second at sizes nobody asked for.
/// Measured, that was twelve intermediate widths over two hundred milliseconds for one
/// toggle, each one a full document re-layout in WebKit.
///
/// **Clipped**, because `NSView`s are real views: SwiftUI's own clip masks what SwiftUI
/// draws, and a hosted view's layer needs telling separately.
extension View {
    func paneContent() -> some View {
        self
            .transaction { $0.animation = nil }
            .clipped()
    }
}
