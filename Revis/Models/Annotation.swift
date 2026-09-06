import Foundation

// MARK: - What a reviewer is asking for

/// The verb of an annotation.
///
/// The whole reason this exists: the thing reading a review back is a language model, and
/// a mark on a page is not an instruction. An arrow says *here*; it does not say whether
/// here should be cut, rewritten, or merely queried. Making the verb a required, closed
/// choice means every annotation leaves the app as a sentence something can act on —
/// "remove this paragraph", not "the reviewer drew on this paragraph".
///
/// Seven, and deliberately no more. They are the operations a reader can want performed on
/// a document; a longer list starts drawing distinctions the writer of a note does not
/// have in mind when they make it, and an intent picked at random is worse than none.
enum Intent: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Rewrite what is here.
    case change
    /// Put something new at this point.
    case insert
    /// Take this out.
    case remove
    /// This belongs somewhere else.
    case move
    /// A question about this — no change asked for yet.
    case question
    /// This is right. Recorded so a review can say what NOT to touch.
    case approve
    /// An observation with no request attached.
    case note

    var id: String { rawValue }

    /// What the picker shows.
    var title: String {
        switch self {
        case .change:   return "Change"
        case .insert:   return "Insert"
        case .remove:   return "Remove"
        case .move:     return "Move"
        case .question: return "Question"
        case .approve:  return "Approve"
        case .note:     return "Note"
        }
    }

    /// The SF Symbol drawn in the margin and on the row.
    var symbol: String {
        switch self {
        case .change:   return "pencil.line"
        case .insert:   return "text.insert"
        case .remove:   return "strikethrough"
        case .move:     return "arrow.up.arrow.down"
        case .question: return "questionmark"
        case .approve:  return "checkmark"
        case .note:     return "text.bubble"
        }
    }

    /// The placeholder in the note field. It is doing real work: an instruction written
    /// against a prompt is far more likely to say what the model needs than one written
    /// into an empty box labelled "Comment".
    var prompt: String {
        switch self {
        case .change:   return "What should this say instead?"
        case .insert:   return "What should go here?"
        case .remove:   return "Why should this come out?"
        case .move:     return "Where should this go?"
        case .question: return "What do you want to know?"
        case .approve:  return "Anything to preserve about it?"
        case .note:     return "What did you notice?"
        }
    }

    /// How the export opens the instruction, so the reader is told the operation before
    /// it is told the words. See `ReviewExport`.
    var directive: String {
        switch self {
        case .change:   return "Rewrite the quoted text."
        case .insert:   return "Insert new content immediately AFTER the quoted text."
        case .remove:   return "Delete the quoted text."
        case .move:     return "Relocate the quoted text."
        case .question: return "Answer this question about the quoted text."
        case .approve:  return "Leave the quoted text as it is."
        case .note:     return "Take this observation into account."
        }
    }

    /// Which part of the export an annotation of this kind belongs in.
    ///
    /// Three, not two. Questions used to be filed under requested changes, and a model
    /// applying the review said so: an item headed "Requested changes" that asks for no
    /// change, and whose answer has nowhere to go, reads as an edit it cannot work out how
    /// to make. A question is neither an edit nor an observation; it is a question.
    enum Bucket { case edit, question, observation }

    var bucket: Bucket {
        switch self {
        case .change, .insert, .remove, .move: return .edit
        case .question: return .question
        case .approve, .note: return .observation
        }
    }
}

/// Whether an annotation is still outstanding.
///
/// Unlike Vaelora, resolving does not delete: a review is a document handed to somebody
/// else and then handed back, and "we already dealt with that" is part of what it has to
/// record. The export leaves resolved items out of the instructions and lists them under
/// their own heading, so a second pass does not re-litigate the first.
enum AnnotationStatus: String, Codable, CaseIterable, Sendable {
    case open, resolved
}

// MARK: - Where it points

/// A rectangle in a block's own coordinates, each side a fraction of the block's box.
///
/// Normalised rather than in pixels because the page reflows: the window is resized, the
/// zoom changes, and a stored pixel rect then points at the wrong words. Fractions of the
/// block survive all of that, which is what lets a region drawn today still be drawn in
/// the same place tomorrow.
struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    var x: Double, y: Double, width: Double, height: Double
}

/// Everything the app knows about *what* an annotation is attached to.
///
/// Four addresses for one place, and all four are load-bearing because they answer to
/// different readers:
///
/// - `blocks` is what the *app* uses — the `data-rv` indices the runtime stamped on the
///   document, so a marker can be redrawn beside the right paragraph.
/// - `quote` (with `prefix`/`suffix`) is what a *language model* uses. It is the text
///   itself, which is the only address that still means something once the document has
///   been regenerated and every index has moved. It is also, on its own, enough to find
///   the passage with a search.
/// - `path` is what a *person* reads: "§2.1 Data Retention › paragraph 3".
/// - `rect` is what the *screen* uses, and only for a region.
///
/// The design rule the whole app follows is here: an annotation is never only a mark. It
/// always carries the words it is about, because the thing that reads the review back
/// reads words.
struct Anchor: Codable, Equatable, Hashable, Sendable {
    /// The `data-rv` indices this annotation covers, in document order. One for a text
    /// selection inside a single block; several for a region drawn across them.
    var blocks: [Int]
    /// The nearest headings above the anchor, joined — how a person says where it is.
    var path: String
    /// What kind of thing was marked: "paragraph", "heading-2", "list-item", "table",
    /// "figure", "code". Reported by the runtime from the element itself.
    var role: String
    /// The exact text covered. For a region, the text of everything the rectangle
    /// touched, which is what turns a drawn box into something readable.
    var quote: String
    /// Up to 64 characters either side, so the quote can be re-found unambiguously in a
    /// document that says the same short phrase in several places.
    var prefix: String
    var suffix: String
    /// Character offsets of `quote` within the first block's own text, or -1 when the
    /// anchor is not a text range (a region, or a whole block).
    var start: Int
    var end: Int
    /// Region annotations only: where the box was drawn, relative to the first block.
    var rect: NormalizedRect?

    /// True when this was drawn as an area rather than selected as text.
    var isRegion: Bool { rect != nil }

    /// The quote, shortened for a one-line row. Never mid-word, and never so short that
    /// it stops identifying the passage.
    func summary(limit: Int = 120) -> String {
        let flat = quote.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        guard let space = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[cut.startIndex..<space]) + "…"
    }
}

// MARK: - The annotation

/// One mark on the document, with the instruction that goes with it.
///
/// Identified by a UUID rather than by its position, because a review is saved, reopened
/// and added to: an ordinal would renumber the moment anything was inserted above it, and
/// the file would then disagree with itself about which note was which.
struct Annotation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var created: Date = .reviewStamp
    var author: String
    var intent: Intent
    /// What the reviewer wrote. May be empty for an approval, where the mark is the point.
    var note: String
    var anchor: Anchor
    var status: AnnotationStatus = .open

    /// Document order, so the pane and the export both read down the page.
    ///
    /// The first block, then where in it — a region and a selection on the same paragraph
    /// still sort by where they sit. Created-at breaks the last tie so two annotations on
    /// one word keep the order they were made in rather than swapping about between
    /// renders.
    var ordering: (Int, Int, Date) {
        (anchor.blocks.first ?? Int.max, anchor.start, created)
    }
}

extension Array where Element == Annotation {
    /// Down the page, then by when they were written.
    func inDocumentOrder() -> [Annotation] {
        sorted {
            let (a, b) = ($0.ordering, $1.ordering)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }
    }
}


extension Date {
    /// Now, to the second.
    ///
    /// The file writes dates as ISO 8601, which has no fractional part — so an annotation
    /// held in memory with sub-second precision was a different value from the same
    /// annotation read back off disk, and a review did not survive a round trip. The
    /// precision was never meaningful (nobody needs to know a note was written 340
    /// milliseconds into the minute); dropping it where the value is MADE, rather than
    /// tolerating the drift where it is compared, is what makes save-and-reopen an
    /// identity.
    static var reviewStamp: Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}
