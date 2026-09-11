import SwiftUI
import AppKit

/// Tells AppKit that the review has changed.
///
/// **This is not belt and braces; nothing else does it.** Writing through the
/// `FileDocument` binding — `document.file.annotations = new`, in `ReviewRootView` — updates
/// the value SwiftUI will write on a save, and does NOT mark the document as having
/// unsaved changes. Measured, because it is not what anyone would assume and this app
/// assumed it for a long time: with a review open and one annotation's note edited,
/// `isDocumentEdited` was still false two and a half seconds later.
///
/// What that cost is the worst thing this app can do. A reviewer opens a `.revis`, writes a
/// dozen comments, and the window never says "Edited"; Save stays greyed out because
/// AppKit believes there is nothing to save; ⌘Q closes with no "do you want to save?"
/// because, as far as the framework knows, there is nothing to lose. The comments are gone,
/// and nothing anywhere said so. That is what happened — a real review, really lost.
///
/// So the change is reported explicitly, at the one moment we know a change happened: the
/// same `onChange` that writes it into the document. `token` is bumped there and is
/// otherwise meaningless — it exists so this view updates, because a representable is the
/// only way a SwiftUI scene reaches its `NSDocument`, the same way `SourceDetachment` and
/// `WindowSizeMemory` do.
///
/// Saving clears the count on AppKit's side and this never re-dirties on its own, because
/// it acts on the token CHANGING rather than on its value. An import is allowed through and
/// then cleared a hop later by `SourceDetachment` — deliberately, and the ordering is
/// explained there: a document that has only been opened has nothing in it worth a
/// "save your changes?" sheet.
struct DocumentEdits: NSViewRepresentable {
    /// Bumped whenever something that gets WRITTEN to the `.revis` changes. Zero means the
    /// window has only been loaded.
    let token: Int

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard token > 0, context.coordinator.seen != token else { return }
        context.coordinator.seen = token
        // Synchronously where there is a window, which is every edit a person makes; the
        // hop is only for a change that lands before the window is attached, and it has to
        // stay a hop rather than become a skip — that change is as real as any other.
        if let document = view.window?.windowController?.document as? NSDocument {
            document.updateChangeCount(.changeDone)
            // The one fact worth having when somebody says "it did not save". Silent unless
            // REVIS_PAGE_LOG is set, like everything else that reports on this app.
            if PageLog.isOn {
                PageLog.write("edit \(token): edited=\(document.isDocumentEdited)"
                    + " url=\(document.fileURL?.lastPathComponent ?? "none")")
            }
        } else {
            DispatchQueue.main.async {
                (view.window?.windowController?.document as? NSDocument)?
                    .updateChangeCount(.changeDone)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var seen = 0
    }
}
