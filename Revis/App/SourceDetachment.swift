import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Cuts an imported document loose from the file it was read out of.
///
/// **What this is for.** Opening `spec.html` gives the window an `NSDocument` whose
/// `fileURL` is that HTML file. AppKit's autosave then does exactly what it is supposed
/// to — it writes the document back to where it came from — and the review lands on top
/// of the specification. The file the reviewer was sent is destroyed, silently, before
/// they have made a single mark. That is not hypothetical; it is what happened the first
/// time this app was run against a real document.
///
/// Declaring HTML readable but not writable does not prevent it. So the URL is taken away:
/// after an import the document is untitled and a draft, which is what it actually is — a
/// new review that has not been saved anywhere yet. Save then asks for a location and
/// offers `.revis`, and the source is never a candidate.
///
/// Reaching the `NSDocument` means going through the window, because SwiftUI hands a
/// `FileDocument` its bytes and nothing else. A zero-sized representable is how a SwiftUI
/// scene gets at its window, the same way `WindowSizeMemory` does.
///
/// `ReviewDocument.fileWrapper` refuses to write a non-review type regardless, so this
/// failing means an inconvenient error rather than a lost file. Both, because one of them
/// is a guess about framework behaviour and the other is not.
struct SourceDetachment: NSViewRepresentable {
    /// Bumped when a document has just been imported and needs cutting loose. Zero means
    /// there is nothing to do — a review opened from its own `.revis` file keeps its URL.
    let generation: Int

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard generation > 0, context.coordinator.done != generation else { return }
        context.coordinator.done = generation
        // A turn later: during a view update the window may not be attached yet, and
        // there is nothing to reach through until it is.
        DispatchQueue.main.async {
            guard let document = view.window?.windowController?.document as? NSDocument
            else { return }
            guard document.fileURL != nil else { return }
            document.fileURL = nil
            document.fileType = UTType.revisReview.identifier
            // A draft is a document macOS knows has never been saved, so ⌘S offers a save
            // panel rather than writing somewhere. Without it, a document that has lost
            // its URL is merely a document with nowhere to go.
            document.isDraft = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var done = 0
    }
}
