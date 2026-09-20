import SwiftUI
import AppKit

/// Shared palette and small style helpers.
///
/// The accent is appearance-adaptive: blue in Light, warm orange in Dark. Deliberately
/// the same two directions as Vaelora, because these are two halves of one workflow —
/// write the document in one, review it in the other — and an app that looks like a
/// stranger to its sibling makes that harder to believe.
enum Theme {
    static let accent = Color(nsColor: .revisAccent)
    static let accentGradient = LinearGradient(
        colors: [Color(nsColor: .revisAccentHighlight), Color(nsColor: .revisAccent)],
        startPoint: .top, endPoint: .bottom)

    static let inspectorBackground = Color(nsColor: .windowBackgroundColor)
    static let paneBackground = Color(nsColor: .revisPaneBackground)
    static let windowBackground = Color(nsColor: .revisWindowBackground)
    static let documentBackground = Color(nsColor: .revisDocumentBackground)
    static let hairline = Color.primary.opacity(0.10)

    /// Something the reviewer needs to know before they carry on — not an error, and not
    /// decoration either. Used where re-reading a Markdown document has left marks that no
    /// longer point at anything.
    ///
    /// A token rather than `.orange` at the call site, because in Dark the accent IS
    /// orange: a warning typed as a colour would be indistinguishable from the app's own
    /// emphasis exactly where it most needs to stand apart from it.
    static let warning = Color(nsColor: .systemYellow).opacity(0.95)

    /// The height of a pane's header strip. One number, so the annotation pane's header
    /// and the inspector's land their hairlines on the same row — a two-point difference
    /// between two headers side by side is the kind of thing you cannot unsee.
    static let paneHeader: CGFloat = 38
}

extension NSColor {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static let revisAccent = NSColor(name: nil) { a in
        isDark(a) ? NSColor(srgbRed: 0.98, green: 0.42, blue: 0.22, alpha: 1)
                  : NSColor(srgbRed: 0.039, green: 0.424, blue: 1.0, alpha: 1)
    }

    static let revisAccentHighlight = NSColor(name: nil) { a in
        isDark(a) ? NSColor(srgbRed: 1.0, green: 0.56, blue: 0.34, alpha: 1)
                  : NSColor(srgbRed: 0.247, green: 0.545, blue: 1.0, alpha: 1)
    }

    /// The annotations pane's surface — a step off the window background, so a pane
    /// sitting beside the inspector reads as a different surface rather than as one wide
    /// panel with a stray hairline down it. Dark needs the bigger step: the same
    /// arithmetic difference reads as less separation down there.
    static let revisPaneBackground = NSColor(name: nil) { a in
        isDark(a) ? NSColor(white: 0.225, alpha: 1)
                  : NSColor(white: 0.965, alpha: 1)
    }

    /// The window's own surface — which a toolbar-bearing window shows through its title
    /// bar, because the content view runs up underneath it.
    ///
    /// It used to be the desk below, and that is what made the title bar look like a slab
    /// carrying on past the document's top edge: two surfaces the eye reads as one, with
    /// nothing but the toolbar's controls to say where the chrome stopped. Same colour as
    /// before — the title bar is not what changed — but named for what it actually paints.
    static let revisWindowBackground = NSColor(name: nil) { a in
        isDark(a) ? NSColor(white: 0.157, alpha: 1)
                  : NSColor(srgbRed: 228/255, green: 228/255, blue: 230/255, alpha: 1)
    }

    /// The desk the document sheet sits on. Matches `--rv-backdrop` in review.css, so the
    /// web view and the SwiftUI around it are one surface rather than two greys meeting.
    ///
    /// A STEP DOWN from the window above, and it has to clear two things rather than one:
    /// the title bar it meets along the top, and the outline pane it meets down the side
    /// (`windowBackgroundColor`, a darker grey than the title bar in Dark). Landing
    /// between them would separate the desk from one and merge it with the other, so it
    /// goes below both — far enough that the document reads as sunk into a well rather
    /// than laid on the same surface as the controls.
    static let revisDocumentBackground = NSColor(name: nil) { a in
        isDark(a) ? NSColor(white: 26/255, alpha: 1)
                  : NSColor(srgbRed: 217/255, green: 217/255, blue: 222/255, alpha: 1)
    }
}

/// A compact hairline divider used between panes.
struct PaneDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5)
    }
}

/// Uppercase section header used in the inspector and settings.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
