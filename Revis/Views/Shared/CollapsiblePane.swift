import SwiftUI

/// A horizontal split whose side pane collapses by giving its width back, rather than by
/// uncovering what was underneath.
///
/// Covering would defeat the point: the reason to open the annotations pane is to read a
/// note while looking at the passage it is about, which you cannot do if the pane is
/// sitting on top of the passage.
///
/// **Why the pane stays mounted while closed.** It is cheaper to build it once than to make
/// its first frame correct. A view rebuilt on every open starts from its own initial state
/// and corrects itself a frame later, which shows as soon as opening takes a quarter of a
/// second.
struct CollapsibleSidePane<Main: View, Pane: View>: View {
    /// Which side the pane lives on. The anchoring is mirrored for each, and the mirroring
    /// is the whole of the difference.
    var edge: HorizontalEdge = .trailing
    let isOpen: Bool
    let width: CGFloat
    @ViewBuilder var main: Main
    @ViewBuilder var pane: Pane

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var dividerWidth: CGFloat { 0.5 }

    var body: some View {
        HStack(spacing: 0) {
            if edge == .leading { collapsingPane }
            content
            if edge == .trailing { collapsingPane }
        }
        // Nothing here animates the LAYOUT. See `collapsingPane`.
    }

    /// The main content — sized instantly, and clipped.
    ///
    /// **Instantly**, because the layout is not what should be moving. The toggle is
    /// wrapped in `withAnimation` by whatever calls it, and that animation reaches every
    /// view in the update, including this one; a hosted `NSView` then animates its layer to
    /// the new width through Core Animation, spending a fifth of a second at sizes nobody
    /// asked for. For a web view that means WebKit re-laying out the document at each of
    /// them, and an oversized layer sitting under the pane beside it. Measured, it was
    /// twelve intermediate widths over two hundred milliseconds for one toggle.
    ///
    /// **Clipped**, because `NSView`s are real views: SwiftUI's own clip masks what SwiftUI
    /// draws, and a hosted view's layer needs telling separately.
    private var content: some View {
        main
            .transaction { $0.animation = nil }
            .clipped()
    }

    /// The pane's SLOT changes size instantly; its CONTENT slides into the slot.
    ///
    /// This is the shape of the whole problem, and it took the right observation to see it:
    /// dragging the window edge never puts the document under the annotations pane and
    /// resizes beautifully, while toggling a pane did both. The difference is not the web
    /// view. On a drag the pane's width is CONSTANT and only the document's changes; on a
    /// toggle the pane's width was animating too, so for a quarter of a second the layout
    /// was being solved sixty times against a width that kept moving.
    ///
    /// So the layout does not animate at all. The slot goes to its final width in one step
    /// — exactly what a window drag does to the document, which was always the smooth case
    /// — and the pane's content slides in from outside on the panel token, clipped to the
    /// slot. What moves is a picture sliding, not a layout being re-solved.
    private var collapsingPane: some View {
        HStack(spacing: 0) {
            if edge == .trailing { PaneDivider() }
            // Fixed here so the controls stay laid out at their real width all the way
            // through — the slot clips, it does not squeeze.
            pane.frame(width: width)
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

    private var slot: CGFloat { width + Self.dividerWidth }
}
