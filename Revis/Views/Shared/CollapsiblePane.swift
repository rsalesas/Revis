import SwiftUI

/// A horizontal split whose trailing pane collapses by giving its width back, rather than
/// by uncovering what was underneath.
///
/// Covering would defeat the point: the reason to open the annotations pane is to read a
/// note while looking at the passage it is about, which you cannot do if the pane is
/// sitting on top of the passage.
///
/// **Why this owns the `HStack` instead of being a pane you drop into one.** The animation
/// has to be applied by the view that lays out *both* children. Scoped to the pane alone,
/// the pane's frame interpolates but it reports its final size to the parent immediately,
/// so the document beside it snaps to its new width on frame one.
///
/// **Why the pane stays mounted while closed.** It is cheaper to build it once than to
/// make its first frame correct. A view rebuilt on every open starts from its own initial
/// state and corrects itself a frame later, which shows as soon as opening takes a quarter
/// of a second.
///
/// **The content is anchored to the leading edge, so the pane slides.** Anchored trailing
/// it would sit in its final position from the first frame and the growing frame would
/// uncover it — which reads as the document sliding away to expose something that was
/// already there, rather than as a panel arriving.
struct CollapsibleSidePane<Main: View, Pane: View>: View {
    let isOpen: Bool
    let width: CGFloat
    @ViewBuilder var main: Main
    @ViewBuilder var pane: Pane

    private static var dividerWidth: CGFloat { 0.5 }

    var body: some View {
        HStack(spacing: 0) {
            main
            collapsingPane
        }
        // On the split, not on the pane: this is what makes the document's width
        // interpolate rather than jump.
        .motion(.panel, value: isOpen)
    }

    private var collapsingPane: some View {
        HStack(spacing: 0) {
            PaneDivider()
            // Fixed here so the controls stay laid out at their real width all the way
            // through — the outer frame clips, it does not squeeze.
            pane.frame(width: width)
        }
        .frame(width: isOpen ? width + Self.dividerWidth : 0, alignment: .leading)
        .clipped()
    }
}
