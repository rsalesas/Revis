import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Cuts an imported document loose from the file it was read out of, and says where the
/// review it becomes should be offered a home.
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
/// **And what that used to cost.** A draft with no URL leaves the save panel seeded from
/// the only two things AppKit has left: the document's display name, and whatever folder a
/// panel was last pointed at. Neither was the answer. A review of
/// `Masterclass_IA_Responsable.html` was offered as *Angles morts de l'IA : Numérique
/// responsable — Masterclass.revis* — the document's `<title>`, a name the reviewer never
/// typed — in some folder they were not thinking about. A review belongs beside the thing
/// it reviews, under the name of the thing it reviews, so both are now said out loud:
/// `name` here is the FILE's name, not the document's title, and `offerFolder` points the
/// next panel at where the file came from.
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
    /// What to call the window afterwards — and, because AppKit seeds the save panel's
    /// name field from it, what the review will be called on disk.
    ///
    /// Losing the URL makes macOS call the document "Untitled 3", which tells the reviewer
    /// nothing about which of three open reviews they are looking at — and
    /// `navigationTitle` does not win here, because a document-backed window takes its
    /// title from the document.
    ///
    /// The FILE's name and not the document's title, which is the one thing AppKit reads
    /// that we are allowed to choose. It reads better in the title bar too: the reviewer
    /// opened `Masterclass_IA_Responsable.html` and is reviewing that, whatever the deck
    /// inside calls itself.
    let name: String
    /// The file the review is OF. Never given to the document — that is the whole point of
    /// this type — but used to point the next save panel at the right folder.
    let source: URL?

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard generation > 0, context.coordinator.done != generation else { return }
        context.coordinator.done = generation
        let source = self.source
        let name = self.name
        // A turn later: during a view update the window may not be attached yet, and
        // there is nothing to reach through until it is.
        DispatchQueue.main.async {
            guard let document = view.window?.windowController?.document as? NSDocument
            else { return }
            guard document.fileURL != nil else { return }
            document.fileURL = nil
            document.fileType = UTType.revisReview.identifier
            if !name.isEmpty { document.displayName = name }
            // A draft is a document macOS knows has never been saved, so ⌘S offers a save
            // panel rather than writing somewhere. Without it, a document that has lost
            // its URL is merely a document with nowhere to go.
            document.isDraft = true
            if let source { Self.offerFolder(of: source) }

            // …and it has no unsaved changes yet, whatever the framework currently thinks.
            //
            // Importing writes the sanitized snapshot into the `FileDocument`, which is a
            // change as far as AppKit is concerned — so a window that had just been opened
            // and not touched said "Edited", and quitting put up a "save your changes?"
            // sheet for a review nobody had made a mark on. Nothing has been done to this
            // document; saying so is not a lie, it is the correction.
            //
            // One more hop, because the binding that writes the snapshot back runs in the
            // same update as the import and would otherwise dirty the document again
            // straight after this cleared it. Adding an actual annotation marks it changed
            // again by the ordinary route, so a review with marks on it still asks.
            DispatchQueue.main.async { document.updateChangeCount(.changeCleared) }
        }
    }

    /// Point the next save panel at the folder `source` came out of.
    ///
    /// **Through the defaults, because every other route was tried and none of them
    /// works.** The supported seat is `NSDocument.prepareSavePanel(_:)`, and there is
    /// nothing of ours to override — `DocumentGroup` builds its own private `NSDocument`
    /// subclass. Catching the panel on `NSWindow.willBeginSheetNotification` and setting
    /// `directoryURL` does reach the real panel, and does nothing: the property reads back
    /// as ours on every frame afterwards while the panel goes on showing the folder it
    /// opened in, because a panel takes its location when it is built and we are only told
    /// once it is up. Giving the document the proposed `.revis` as its `fileURL` does not
    /// move it either — and that one is not merely useless but dangerous, since a
    /// document with a URL is a document autosave can write to.
    ///
    /// What the panel actually reads when it opens is this pair of defaults, so this is
    /// not a trick played on it — it is the same question answered one step earlier.
    /// It fails into the old behaviour rather than into an error: if these keys ever stop
    /// meaning what they mean, a panel simply opens where it used to.
    ///
    /// App-wide rather than per-window, which is what the keys are — "the last folder you
    /// were working in". Opening a document out of a folder is a fair claim on that, and
    /// it puts Export Review… and Import Replies… in the same place, which is where the
    /// rest of the review's paperwork belongs anyway.
    private static func offerFolder(of source: URL) {
        let folder = source.deletingLastPathComponent().path
        UserDefaults.standard.set(folder, forKey: "NSNavLastRootDirectory")
        UserDefaults.standard.set(folder, forKey: "NSNavLastCurrentDirectory")
    }

    /// What the review of `source` should be called: its neighbour, same name, our
    /// extension. Not used to write anything — it is the answer this type exists to make
    /// the save panel offer, and having it in one place is what lets a test check it.
    ///
    /// `deletingPathExtension` rather than everything before the first dot, so `spec.v2.html`
    /// becomes `spec.v2.revis` and not `spec.revis` — the same reading of a file's name that
    /// `ReviewModel.exportBaseName` already uses, because a review and its export
    /// disagreeing about what the document is called would be its own small puzzle.
    static func reviewURL(beside source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("revis")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var done = 0
    }
}
