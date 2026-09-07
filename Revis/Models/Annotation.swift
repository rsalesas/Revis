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
    /// An observation with no request attached.
    ///
    /// Called `comment` because that is what it is. It was `note`, and nobody writing one
    /// thinks of it as a note; they think they are commenting on the document.
    case comment

    var id: String { rawValue }

    /// What the picker shows.
    var title: String {
        switch self {
        case .change:   return "Change"
        case .insert:   return "Insert"
        case .remove:   return "Remove"
        case .move:     return "Move"
        case .question: return "Question"
        case .comment:  return "Comment"
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
        // `bubble`, not `text.bubble`. The marks want to read as one set, and the one with
        // lines drawn inside it carried noticeably more ink than the rest — it looked a
        // size larger at the same point size, which is exactly the thing a row of type
        // labels must not do. An empty bubble is the same idea at the same weight.
        case .comment:  return "bubble"
        }
    }

    /// The placeholder in the note field. It is doing real work: an instruction written
    /// against a prompt is far more likely to say what the model needs than one written
    /// into an empty box labelled "Comment".
    ///
    /// It also says whether words are needed at all — see `needsInstruction`.
    var prompt: String {
        let question: String
        switch self {
        case .change:   question = "What should this say instead?"
        case .insert:   question = "What should go here?"
        case .remove:   question = "Why should this come out?"
        case .move:     question = "Where should this go?"
        case .question: question = "What do you want to know?"
        case .comment:  question = "What did you want to say?"
        }
        return needsInstruction ? question : question + " (optional)"
    }

    /// Whether an annotation of this kind is incomplete without words.
    ///
    /// The test is whether `directive` alone is already an instruction somebody could
    /// carry out. "Delete the quoted text" and "leave the quoted text as it is" are; the
    /// span says which text, and there is nothing left to ask. "Rewrite the quoted text"
    /// is not — rewrite it to say what? — and neither is a question with no question in it.
    ///
    /// This is why Add is available on an empty Remove and not on an empty Change, which
    /// looks arbitrary until it is said out loud. The interface has to say it: see the hint
    /// beside the Add button, and the "(optional)" the prompt grows.
    var needsInstruction: Bool {
        switch self {
        case .remove: return false
        case .change, .insert, .move, .question, .comment: return true
        }
    }

    /// What the export says for an annotation of this kind that carries no words. Only
    /// reachable for the two that do not need any.
    var standsAlone: String {
        switch self {
        case .remove: return "_No reason given; the deletion is the instruction._"
        default:      return ""
        }
    }

    /// Read leniently, so a review written by an older build still opens.
    ///
    /// `approve` and `note` were both intents once. Approving is a verdict on somebody
    /// else's annotation now rather than a thing you write on a document, and `note` was
    /// only ever a comment by another name — but a file full of them is still a file
    /// somebody's afternoon went into, and a format that refuses to open one has lost it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "note", "approve": self = .comment
        default:
            guard let intent = Intent(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown annotation intent \"\(raw)\""))
            }
            self = intent
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
        case .comment:  return "Take this comment into account."
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
        case .comment: return .observation
        }
    }
}

/// One reviewer's verdict on another's annotation.
///
/// **Why this is not an intent.** Approving used to be something you wrote on the
/// document — "this bit is right". That was the wrong shape, and it showed as soon as a
/// second person read a review: what you actually want to say is not "this paragraph is
/// fine" but "yes, do what they asked" or "no, leave it". A verdict is *about an
/// annotation*, so it belongs on one.
///
/// It also changes the export in a way an intent never could. A declined request is a
/// request the team decided against, and handing it to an assistant anyway would have it
/// make a change somebody had explicitly refused.
enum Verdict: String, Codable, CaseIterable, Sendable {
    case approved, declined

    var title: String { self == .approved ? "Approved" : "Declined" }
    var verb: String { self == .approved ? "Approve" : "Decline" }
    var symbol: String { self == .approved ? "checkmark" : "xmark" }
    /// Olive for agreement; grey for a refusal. Deliberately NOT a red — declining a
    /// colleague's suggestion is a decision, not an error.
    var hex: String { self == .approved ? "#8aa35b" : "#9a9a9e" }
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

    /// True when this names a PLACE rather than a span — a caret between two words.
    ///
    /// An insertion has no span by nature: you are not marking words, you are naming a gap.
    /// The quote is then the words immediately before the point, so the instruction still
    /// reads as something a reader can find by searching.
    var isPoint: Bool { start >= 0 && start == end }

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

/// Something said back about an annotation.
///
/// Not an annotation of its own, and the difference is the whole of why this type exists: a
/// reply has no anchor, because it is not about a place in the document — it is about what
/// somebody said about that place. Giving it an anchor would put "the answer to your
/// question" on the page as a second mark on the same words.
struct Reply: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    /// `.reviewStamp`, never `Date()`. The coders are ISO-8601 without fractional seconds,
    /// so a date carrying them does not survive a save and a reload as the same value.
    var created: Date = .reviewStamp
    var author: String
    /// What was said, verbatim — prose, Markdown and all.
    var text: String
    /// Whether this arrived from an assistant rather than being typed here by a person.
    ///
    /// Set by whatever imports it and never by the document being imported: a flag a file
    /// can set says whatever the file says. The two mistakes are not the same size. A
    /// hand-written reply marked as a machine's is a cosmetic over-attribution; a model's
    /// answer wearing a colleague's name is a reviewer trusting a sentence that nobody
    /// stands behind.
    var isAssistant: Bool = false
}

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
    /// What a reviewer decided about this annotation, if anyone has.
    var verdict: Verdict?
    /// Who decided. Kept because "declined" without a name is an anonymous veto.
    var verdictBy: String?
    /// What has been said back about it, oldest first. Not gated by authorship or by a
    /// verdict: replying is a RESPONSE, in the same category as resolving and deciding.
    var replies: [Reply] = []

    /// The id as it is printed and as it is matched: lowercase, hyphenated.
    ///
    /// One property rather than `uuidString` at each call site, because the Markdown export
    /// and the JSON have to print the same characters — a reviewer who copies an id out of
    /// one and searches the other is entitled to find it.
    var exportID: String { id.uuidString.lowercased() }

    /// Decoded by hand, and this is not tidiness.
    ///
    /// Swift's synthesised decoder does NOT fall back to a property's default when a key is
    /// missing — it throws. So the day `replies` was added, every `.revis` file already on
    /// disk stopped decoding; and `ReviewDocument.init(configuration:)` swallows a decode
    /// failure with `try?` and falls through to treating the bytes as HTML, so the symptom
    /// was not an error but a saved review silently reopening as a fresh review OF ITS OWN
    /// JSON, with every annotation gone.
    ///
    /// Only `intent` and `anchor` are required, because an annotation without them is not
    /// one. Everything else has a defensible default, and a file that refuses to open is a
    /// file lost — the same policy as `Intent.init(from:)` above, for the same reason.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        created = try container.decodeIfPresent(Date.self, forKey: .created) ?? .reviewStamp
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        intent = try container.decode(Intent.self, forKey: .intent)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        anchor = try container.decode(Anchor.self, forKey: .anchor)
        status = try container.decodeIfPresent(AnnotationStatus.self, forKey: .status) ?? .open
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
        verdictBy = try container.decodeIfPresent(String.self, forKey: .verdictBy)
        replies = try container.decodeIfPresent([Reply].self, forKey: .replies) ?? []
    }

    /// Written back out by hand only because writing `init(from:)` cost the synthesised
    /// memberwise initialiser, which every call site uses.
    init(id: UUID = UUID(), created: Date = .reviewStamp, author: String, intent: Intent,
         note: String, anchor: Anchor, status: AnnotationStatus = .open,
         verdict: Verdict? = nil, verdictBy: String? = nil, replies: [Reply] = []) {
        self.id = id
        self.created = created
        self.author = author
        self.intent = intent
        self.note = note
        self.anchor = anchor
        self.status = status
        self.verdict = verdict
        self.verdictBy = verdictBy
        self.replies = replies
    }

    /// Whether this should be acted on. A declined request is one somebody refused.
    var isActionable: Bool { status == .open && verdict != .declined }

    /// Whether a verdict has been given. Once one has, the annotation is settled.
    var isDecided: Bool { verdict != nil }

    /// Give a verdict. **Final** — it cannot be changed or taken back.
    ///
    /// It was a toggle, and that was wrong. A verdict is somebody putting their name to a
    /// decision, and a decision you can quietly reverse is not on the record: the author
    /// of a request could watch it be declined and click it back to undecided, and nothing
    /// would show that it had ever happened. If a verdict was given in error the honest
    /// remedy is a new annotation saying so, which leaves both on the record.
    mutating func decide(_ verdict: Verdict, by author: String) {
        guard self.verdict == nil else { return }
        self.verdict = verdict
        verdictBy = author
    }

    /// Whether `reviewer` may rewrite or delete this.
    ///
    /// Two rules, both about not editing history out from under somebody.
    ///
    /// Yours or nobody's — the same rule Vaelora applies to its comments. Rewriting
    /// another reviewer's words leaves their name on a sentence they did not write, which
    /// is worse than not being able to fix their typo. Anyone can still resolve one or
    /// give it a verdict; those are RESPONSES, and responding to what somebody said is the
    /// point.
    ///
    /// And nothing that has been decided. Once a reviewer has approved a request, its
    /// author must not be able to change what was approved into something else — an
    /// agreement to one thing is not an agreement to whatever it later became.
    func isEditable(by reviewer: String) -> Bool {
        guard !isDecided else { return false }
        return author.isEmpty
            || author.compare(reviewer, options: .caseInsensitive) == .orderedSame
    }

    /// Why it cannot be edited, for the control that is disabled because of it. A control
    /// you can see and cannot use should say why; a missing one says nothing at all.
    func editingRefusal(for reviewer: String) -> String? {
        if isDecided {
            let by = verdictBy.map { " by \($0)" } ?? ""
            return "\(verdict?.title ?? "Decided")\(by) — a decided annotation cannot be"
                + " changed. Add a new one if it is wrong."
        }
        guard !isEditable(by: reviewer) else { return nil }
        return "Only \(author) can change this — you can resolve it, or approve or decline it."
    }

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
