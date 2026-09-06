import Foundation

/// Turning a review into something an assistant can act on.
///
/// **The problem this file exists to solve.** A reviewer marks up a page: a box round a
/// table, a strike through a sentence, an arrow into a margin. None of that survives the
/// trip to a language model, because a model does not see the page — it sees text. An
/// annotation exported as "the reviewer highlighted something at (412, 880)" is not an
/// instruction; it is a description of a gesture.
///
/// So the export never sends a gesture. Every item is written as three things:
///
/// 1. **An operation.** The intent, spelled as an imperative sentence, first — so the
///    reader knows what kind of change is being asked for before it reads a word of the
///    note.
/// 2. **An address made of text.** The exact quoted string, and where the quote is short
///    or repeated, the words either side of it. A quote is the only address that survives
///    the document being regenerated; block indices are given too, but explicitly as a
///    secondary hint, because saying otherwise would invite a reader to trust them after
///    they have stopped being true.
/// 3. **The instruction.** What the reviewer actually wrote.
///
/// A region drawn round a figure is exported the same way as a text selection: the box
/// contributed the *choice*, and what is exported is the text the box was drawn over. That
/// is the whole trick, and it is why the region tool is worth having at all.
enum ReviewExport {

    // MARK: - Markdown

    /// The review as instructions, in document order.
    static func markdown(_ file: ReviewFile, filter: AnnotationFilter = .open) -> String {
        let ordered = file.annotations.inDocumentOrder()
        let visible = ordered.filter { filter.admits($0) }
        let open = visible.filter { $0.status == .open }
        let requests = open.filter { $0.intent.bucket == .edit }
        let questions = open.filter { $0.intent.bucket == .question }
        let observations = open.filter { $0.intent.bucket == .observation }
        let resolved = ordered.filter { $0.status == .resolved }

        var out = "# Review of \(file.document.title ?? file.source.name)\n\n"
        out += preamble(file, requests: requests.count, questions: questions.count,
                        observations: observations.count, resolved: resolved.count)

        if requests.isEmpty && questions.isEmpty && observations.isEmpty {
            out += "\n## Nothing outstanding\n\nNo changes are requested.\n"
            return out + resolvedSection(resolved, includeIn: filter)
        }

        if !requests.isEmpty {
            out += "\n## Requested changes\n"
            for (index, annotation) in requests.enumerated() {
                out += item(annotation, number: index + 1)
            }
        }
        if !questions.isEmpty {
            out += "\n## Questions\n\n"
            out += "These ask for an ANSWER, not an edit. Do not change the document to"
                + " satisfy one: reply to the reviewer. If answering reveals that the"
                + " document is wrong, say so rather than quietly correcting it.\n"
            for (index, annotation) in questions.enumerated() {
                out += item(annotation, number: requests.count + index + 1)
            }
        }
        if !observations.isEmpty {
            out += "\n## Observations\n\n"
            out += "No change is requested for these. They are recorded so the document's"
                + " intent is not lost — in particular, anything marked **Approve** should"
                + " be left as it stands.\n"
            for (index, annotation) in observations.enumerated() {
                out += item(annotation,
                            number: requests.count + questions.count + index + 1)
            }
        }
        return out + resolvedSection(resolved, includeIn: filter)
    }

    /// The instructions to the reader, stated once at the top.
    ///
    /// Worth the words: without them a reader is left to guess whether "block 14" or the
    /// quoted string is authoritative, and it will guess wrong on a regenerated document —
    /// silently, and in a way that puts an edit in the wrong place.
    private static func preamble(_ file: ReviewFile, requests: Int, questions: Int,
                                 observations: Int, resolved: Int) -> String {
        var lines: [String] = []
        // The WHOLE digest. It was printed truncated, which is the same as not printing
        // it: a reader cannot check that the document in front of it is the one the review
        // was written against, which is the only thing a digest is for.
        lines.append("**Source** `\(file.source.name)`"
            + (file.source.digest.isEmpty ? ""
               : "  ·  SHA-256 `\(file.source.digest)`"))
        lines.append("**Captured** \(Self.formatter.string(from: file.source.capturedAt))")
        var counts = ["\(requests) requested change\(requests == 1 ? "" : "s")"]
        if questions > 0 { counts.append("\(questions) question\(questions == 1 ? "" : "s")") }
        if observations > 0 { counts.append("\(observations) observation\(observations == 1 ? "" : "s")") }
        if resolved > 0 { counts.append("\(resolved) resolved") }
        lines.append("**Contents** " + counts.joined(separator: ", "))

        return lines.joined(separator: "  \n") + """


        > **How to apply this review.**
        >
        > 1. **Locate every item by searching for the quoted text**, not by position. The
        >    section paths and block numbers describe the document as it was reviewed; they
        >    can be imprecise about a target's structural type even now, and will not
        >    survive the document being rewritten. **The quoted text is the anchor; the
        >    path is a hint.**
        > 2. **Quotes are whitespace-normalised** — runs of spaces and newlines are
        >    collapsed to one space — because that is how the text reads on screen. A
        >    document whose source wraps mid-sentence will not match a quote byte for byte;
        >    compare on normalised whitespace.
        > 3. Where a quote is short or occurs more than once, the surrounding words are
        >    given under *Context*, with the marked span between `«` and `»`. Use it: some
        >    quotes occur several times on purpose.
        > 4. **Apply the items in the order given.** They are in document order, and a later
        >    item may depend on an earlier one having been made.
        > 5. Where an instruction describes what to write rather than giving the words,
        >    draft it — and **say in your reply that you drafted it**, so the reviewer knows
        >    which words are theirs and which are yours.
        > 6. Correcting a fact does not authorise correcting every other mention of it. If
        >    an edit leaves the document inconsistent elsewhere, **report that rather than
        >    silently propagating it**.


        """
    }

    private static func item(_ annotation: Annotation, number: Int) -> String {
        var out = "\n### \(number). \(annotation.intent.title) — \(location(annotation))\n\n"
        out += "\(annotation.intent.directive)\n\n"

        if annotation.anchor.isRegion {
            let count = annotation.anchor.blocks.count
            let subject = count == 1 ? "block" : "\(count) blocks"
            out += "**Applies to** the \(subject) the reviewer drew a box around, whose"
                + " text is quoted below. A box is a coarse anchor — the instruction may"
                + " narrow it to part of what it covers, so read the instruction before"
                + " deciding how much to change.\n\n"
        } else if annotation.anchor.start < 0 {
            out += "**Applies to** this whole \(annotation.anchor.role):\n\n"
        } else {
            out += "**Find this text**\n\n"
        }
        out += quoteBlock(annotation.anchor.quote) + "\n"

        if let context = context(annotation.anchor) {
            out += "\n**Context**\n\n" + quoteBlock(context) + "\n"
        }

        let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            out += "\n**Instruction**"
            if !annotation.author.isEmpty { out += " — \(annotation.author)" }
            out += "\n\n\(note)\n"
        } else if annotation.intent == .approve {
            out += "\n_Approved as written; leave unchanged._\n"
        }

        out += "\n<sub>Anchor: \(anchorHint(annotation.anchor)) — positional, "
            + "use only to break a tie between identical quotes.</sub>\n"
        return out
    }

    /// The human-readable place: the heading trail the runtime worked out.
    private static func location(_ annotation: Annotation) -> String {
        let path = annotation.anchor.path.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? annotation.anchor.role : path
    }

    /// The quote in its surroundings, with the marked span called out.
    ///
    /// Only when there is something to add: repeating the quote inside a context that is
    /// the same length as the quote is noise, and noise in a machine-read document is
    /// worse than in one a person skims.
    private static func context(_ anchor: Anchor) -> String? {
        guard !anchor.prefix.isEmpty || !anchor.suffix.isEmpty else { return nil }
        let head = anchor.prefix.isEmpty ? "" : "…" + anchor.prefix
        let tail = anchor.suffix.isEmpty ? "" : anchor.suffix + "…"
        return head + "«" + anchor.quote + "»" + tail
    }

    /// A Markdown block quote, with every line prefixed — a multi-line quote whose
    /// continuation lines are not prefixed stops being a quote halfway down.
    private static func quoteBlock(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n") + "\n"
    }

    private static func anchorHint(_ anchor: Anchor) -> String {
        var parts = ["block \(anchor.blocks.map(String.init).joined(separator: ", "))"]
        if anchor.start >= 0 { parts.append("characters \(anchor.start)–\(anchor.end)") }
        if anchor.isRegion { parts.append("drawn region") }
        return parts.joined(separator: ", ")
    }

    private static func resolvedSection(_ resolved: [Annotation],
                                        includeIn filter: AnnotationFilter) -> String {
        guard !resolved.isEmpty, filter != .open else { return "" }
        var out = "\n## Already resolved\n\n"
        out += "Listed for the record. **Do not act on these** — they have been dealt with"
            + " in an earlier pass.\n\n"
        for annotation in resolved {
            let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "- **\(annotation.intent.title)** at \(location(annotation)): "
                + "\"\(annotation.anchor.summary(limit: 80))\""
                + (note.isEmpty ? "" : " — \(note)") + "\n"
        }
        return out
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - JSON

    /// The same review, structured.
    ///
    /// For a caller that would rather match on fields than read prose — a script that
    /// applies the changes, or a tool that wants to check them off. Deliberately NOT the
    /// `.revis` file: that carries the whole document snapshot, which is megabytes of
    /// HTML nobody applying a review needs to read.
    static func json(_ file: ReviewFile, filter: AnnotationFilter = .open) -> String {
        struct Item: Encodable {
            var id: String
            var operation: String
            var directive: String
            var author: String
            var instruction: String
            var status: String
            var location: String
            var role: String
            var quote: String
            var contextBefore: String
            var contextAfter: String
            var blocks: [Int]
            var characterRange: [Int]?
            var isRegion: Bool
        }
        struct Payload: Encodable {
            var format = 1
            var kind = "revis.review.export"
            var source: SourceInfo
            var guidance: String
            var items: [Item]
        }

        let items = file.annotations.inDocumentOrder()
            .filter { filter.admits($0) }
            .map { annotation in
                Item(id: annotation.id.uuidString,
                     operation: annotation.intent.rawValue,
                     directive: annotation.intent.directive,
                     author: annotation.author,
                     instruction: annotation.note,
                     status: annotation.status.rawValue,
                     location: annotation.anchor.path,
                     role: annotation.anchor.role,
                     quote: annotation.anchor.quote,
                     contextBefore: annotation.anchor.prefix,
                     contextAfter: annotation.anchor.suffix,
                     blocks: annotation.anchor.blocks,
                     characterRange: annotation.anchor.start >= 0
                        ? [annotation.anchor.start, annotation.anchor.end] : nil,
                     isRegion: annotation.anchor.isRegion)
            }

        let payload = Payload(
            source: file.source,
            guidance: "Locate each item by searching for `quote`. `blocks` and"
                + " `characterRange` describe the reviewed snapshot and are not reliable"
                + " once the document has been rewritten.",
            items: items)
        guard let data = try? JSONEncoder.revis.encode(payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
