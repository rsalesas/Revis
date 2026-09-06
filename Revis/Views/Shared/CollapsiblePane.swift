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
/// **The slot animates its width, and everything follows it.**
///
/// This is where it started and where it ends up, but it only works now that the page
/// inside the document fills its container by LAYOUT rather than by a zoom that script has
/// to set (see `body.rv-fitting` in review.css). Before that, animating the width meant
/// asking the page to re-fit itself on every frame through a round trip to another
/// process, and it was always a frame or two behind — which is what put the document under
/// the pane beside it.
///
/// Two other shapes were tried and are worse:
///
/// - Snapping the slot and sliding the CONTENT into it leaves the slot standing open and
///   empty for a quarter of a second. An empty hole is more obviously wrong than anything
///   it was meant to fix.
/// - Not animating at all removes the hole and the lag, and also removes the one thing
///   that tells you where the pane came from.
///
/// The animation comes from whatever calls the toggle, so it reaches the slot and the
/// document together. They are two halves of one width and must not be given separate
/// timing.
struct CollapsiblePane<Content: View>: View {
    /// Which side of the row this sits on. The anchoring is mirrored for each, and the
    /// mirroring is the whole of the difference.
    let edge: HorizontalEdge
    let isOpen: Bool
    let width: CGFloat
    @ViewBuilder var content: Content

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
        // Anchored to the edge the pane comes FROM, so it slides rather than being
        // uncovered: at nought width the content sits wholly outside the frame on that
        // side, and the clip hides it there.
        .frame(width: isOpen ? slot : 0,
               alignment: edge == .leading ? .trailing : .leading)
        .clipped()
    }
}

/// The main content of a row of panes: clipped to its own bounds.
///
/// `NSView`s are real views. SwiftUI's `.clipped()` masks what SwiftUI draws, and a hosted
/// view's layer needs telling separately — so while the width is animating, a web view
/// mid-resize can otherwise present a layer larger than the frame it was given and paint
/// over the pane beside it.
///
/// It used to strip the ambient animation as well, so its width changed in one step while
/// the pane slid. That was necessary while the page had to re-fit itself by script and
/// could not keep up; it is not necessary now that the page fills by layout, and it was
/// never desirable — the document and the pane are two halves of one width, and giving
/// them separate timing is exactly what made them disagree.
extension View {
    func paneContent() -> some View {
        clipped()
    }
}
