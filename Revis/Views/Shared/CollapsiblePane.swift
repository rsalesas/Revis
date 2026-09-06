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
    /// Which side the pane lives on. The anchoring below is mirrored for each, and the
    /// mirroring is the whole of the difference — see the note about sliding.
    var edge: HorizontalEdge = .trailing
    let isOpen: Bool
    let width: CGFloat
    @ViewBuilder var main: Main
    @ViewBuilder var pane: Pane

    private static var dividerWidth: CGFloat { 0.5 }

    var body: some View {
        HStack(spacing: 0) {
            if edge == .leading { collapsingPane }
            // The pane animates. The content does NOT.
            //
            // Measuring both sides settled this. SwiftUI hands the main content its FINAL
            // width in one step — it does not re-run the layout per frame, exactly as
            // Vaelora documents — but the hosted `NSView` then animates to it through Core
            // Animation, so the web view spends a fifth of a second at sizes nobody asked
            // for. WebKit re-lays-out the document at each of them, which is the jerk, and
            // the oversized layer sits under the pane sliding in beside it, which is the
            // overlap. Everything else tried here — refitting per frame, telling the page
            // its width in advance, clamping the sheet — was working around an animation
            // that should not have been running.
            //
            // Stripped of it, the document is the right size on the first frame and the
            // panes move around something that is already correct. What is briefly
            // uncovered is the window's own backdrop, which is the same grey the document
            // sits on, so there is nothing to see.
            main
                .transaction { $0.animation = nil }
                .clipped()
            if edge == .trailing { collapsingPane }
        }
        // On the split, not on the pane: this is what makes the document's width
        // interpolate rather than jump.
        .motion(.panel, value: isOpen)
    }

    private var collapsingPane: some View {
        HStack(spacing: 0) {
            if edge == .trailing { PaneDivider() }
            // Fixed here so the controls stay laid out at their real width all the way
            // through — the outer frame clips, it does not squeeze.
            pane.frame(width: width)
            if edge == .leading { PaneDivider() }
        }
        // Anchored to the edge the pane comes FROM, so it slides rather than being
        // uncovered: closed, the content sits wholly outside the zero-width frame on that
        // side, and the clip hides it there.
        .frame(width: isOpen ? width + Self.dividerWidth : 0,
               alignment: edge == .leading ? .trailing : .leading)
        .clipped()
    }
}
