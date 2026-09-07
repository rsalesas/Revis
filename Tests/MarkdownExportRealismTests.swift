import Testing
import Foundation
@testable import Revis

/// A review of the three-hundred-page Markdown document, for testing the export against a
/// real model.
///
/// The HTML export has been through this twice and it is the only test that answers the
/// question the whole app is built around: not "did we write a file" but "can the thing
/// that reads it act on it". Markdown adds a second document to the problem — the reviewer
/// marked a rendering and the reader is editing a source — so it needs asking again, and
/// at a size where being nearly right is not good enough.
///
/// Every anchor here is cut out of the RENDERED document by the same rules the runtime
/// uses, so what comes out is what the app would really produce. The set is chosen to be
/// hard: quotes with markup through the middle of them, a passage that occurs twice word
/// for word, a footnote whose marker is a number nobody wrote, a drawn region, an insertion
/// point, an item somebody declined, and a thread that argues with its own instruction.
struct MarkdownExportRealismTests {

    static func source() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/large-spec.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func writeALargeMarkdownReviewForTestingAgainstAModel() throws {
        let file = try Self.realisticFile()

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try ReviewExport.markdown(file).write(
            to: directory.appendingPathComponent("markdown-model-test-review.md"),
            atomically: true, encoding: .utf8)
        try ReviewExport.json(file).write(
            to: directory.appendingPathComponent("markdown-model-test-review.json"),
            atomically: true, encoding: .utf8)

        // What the app believes about its own export, so the model's answer can be scored
        // against something rather than read impressionistically.
        let shadow = MarkdownShadow.build(Self.source(), options: .default)
        var unmapped: [String] = []
        for annotation in file.annotations
        where MarkdownLocator.locate(annotation.anchor, in: shadow) == nil {
            unmapped.append(annotation.anchor.summary(limit: 50))
        }
        print("""

        markdown-model-test-review.md — \(file.annotations.count) annotations, \
        \(file.annotations.filter { $0.verdict == .declined }.count) declined, \
        \(file.annotations.flatMap(\.replies).count) replies
        located in the source: \(file.annotations.count - unmapped.count)/\
        \(file.annotations.count)

        """)
        for quote in unmapped { print("  NOT LOCATED: \(quote)") }

        #expect(file.annotations.count >= 40)
        #expect(unmapped.isEmpty, "the export cannot address what it cannot find")
    }

    // MARK: - Instructions that are about the words they are attached to
    //
    // The first version of this file paired a canned instruction with a randomly chosen
    // quote, and a model applying it reported — correctly, and at length — that the review
    // was incoherent: "Give the actual interval, 'promptly' has been read as a week" on a
    // document where `promptly` never occurs, "say WHICH ledger, there are two" where there
    // is one, "number this section" on a section already numbered. It located all
    // forty-seven items and could act on far fewer, which tested the anchoring hard and the
    // rest of the export not at all.
    //
    // So every instruction below is derived from the block it lands on and quotes a phrase
    // that is really in it, taken from the generator's own vocabulary so the two cannot
    // drift apart. An item that cannot be made to say something true about its block is not
    // written.

    /// A phrase from the quote that a reviewer could reasonably object to, and the
    /// objection. Nil when the block offers nothing to say — in which case no item is made.
    static func objection(to quote: String) -> (phrase: String, instruction: String)? {
        if let vague = LargeDocument.qualifiers.first(where: { quote.contains($0) }),
           vague.hasPrefix("within") || vague.hasPrefix("before") || vague.hasPrefix("at the") {
            return (vague, "Replace “\(vague)” with a number of hours. The phrase is used"
                    + " throughout the document and defined nowhere in it, and two teams have"
                    + " already read it differently.")
        }
        if let verb = LargeDocument.verbs.first(where: { quote.contains($0) }) {
            return (verb, "“\(verb)” does not say whether this is a hard requirement or the"
                    + " default when nothing else applies. Make it one or the other.")
        }
        return nil
    }

    /// A span of `text` containing `phrase`, with a few words either side so the quote reads
    /// as a passage rather than as a fragment.
    ///
    /// Built around the phrase rather than cut at fixed word positions, because an
    /// instruction that objects to “within one scheduling interval” has to be attached to a
    /// span that actually contains it. Cutting words 3 to 11 and hoping produced a review
    /// where most items had to be abandoned for want of anything true to say about them.
    static func span(around phrase: String, in text: String, either side: Int = 4) -> String? {
        guard let found = text.range(of: phrase) else { return nil }
        let before = text[text.startIndex..<found.lowerBound]
            .split(separator: " ").suffix(side)
        let after = text[found.upperBound...].split(separator: " ").prefix(side)
        let quote = (before + [Substring(phrase)] + after).joined(separator: " ")
        return quote.split(separator: " ").count >= 5 ? quote : nil
    }

    /// Something in the quote a reader could not look up, for a question that has an answer.
    static func undefinedTerm(in quote: String) -> String? {
        for term in ["the disclosure threshold", "a legal hold", "the retention class",
                     "the warm tier", "break-glass access", "the reconciliation pass"]
        where quote.contains(term) {
            return term
        }
        return nil
    }

    static func realisticFile() throws -> ReviewFile {
        let markdown = source()
        let prepared = DocumentPrep.prepare(markdown: markdown, baseURL: nil,
                                            options: .default)
        let document = ReviewFixtures.document(html: prepared.body)

        var annotations: [Annotation] = []
        // At most one item per block. Two annotations on one span is how the last run ended
        // up with an exact duplicate pair and, worse, a "change this" and a "keep this
        // exactly as worded" on the same sentence — a contradiction the reader had to
        // resolve, and one no reviewer would actually have written.
        var claimed = Set<Int>()

        func add(_ intent: Intent, _ instruction: String, _ anchor: Anchor,
                 author: String = "Robert Salesas") {
            guard let block = anchor.blocks.first, !claimed.contains(block) else { return }
            claimed.insert(block)
            annotations.append(Annotation(author: author, intent: intent,
                                          note: instruction, anchor: anchor))
        }

        // MARK: The hard ones, named

        // Said twice, word for word, in Appendix A. Only the second is meant, and nothing
        // but the heading trail and the surrounding words can say so.
        let twin = LargeDocument.twinPassage
        if let second = document.locate(twin, occurrence: 1)?.0 {
            var anchor = ReviewFixtures.anchor(twin, occurrence: 1, in: document)
            anchor.path = second.path
            add(.change,
                "In the degraded case the aggregates are NOT withheld — they are served"
                + " stale and flagged. Change this occurrence only; A.1 describes the"
                + " ordinary case and is correct as it stands.", anchor)
        }

        // A quote with emphasis through the middle of it: contiguous on the page, and not
        // contiguous in the file.
        if document.locate("must record a durable tombstone") != nil {
            add(.change,
                "This sentence says a tombstone is recorded and not where it is recorded."
                + " Name the destination, as the sentences either side of it do.",
                ReviewFixtures.anchor("must record a durable tombstone", in: document))
        }

        // A drawn box over a table — the region tool's whole justification. The instruction
        // asks for something the table's own contents show is missing, rather than asserting
        // a disagreement with a section that may not disagree.
        if let table = document.blocks.first(where: { $0.role == "table" }) {
            add(.change,
                "Give this table a caption saying which retention class family it covers."
                + " The rows are numbered within the family and the family is never named,"
                + " so the table cannot be read on its own.",
                ReviewFixtures.region(over: String(table.text.prefix(40)), in: document))
        }

        // A code block, left alone on purpose.
        if let code = document.blocks.first(where: { $0.role == "code" }) {
            add(.comment,
                "Leave this exactly as it is. The argument name is load-bearing — it is"
                + " passed by keyword from the scheduler.",
                ReviewFixtures.anchor(code.text, in: document))
        }

        // A footnote's text, which the renderer moved to the foot of the page and whose
        // marker upstream is a number nobody wrote.
        if let footnote = document.blocks.first(where: {
            $0.text.hasPrefix("A sweep that fails")
        }) {
            add(.question,
                "Who is paged, and on which rota? This is the only place in the document"
                + " that mentions being paged at all.",
                ReviewFixtures.anchor(String(footnote.text.prefix(60)), in: document))
        }

        // A heading. Every part repeats the same eight facet headings, so asking for one to
        // be distinguished is a thing that is actually true of the document.
        if let heading = document.blocks.first(where: {
            $0.role == "heading-3" && $0.text.contains("Scope and definitions")
        }) {
            let repeats = document.blocks.filter { $0.text == heading.text }.count
            add(.change,
                "This heading appears \(repeats) times in the document, each under a"
                + " different part and each about something else. Qualify it so a contents"
                + " list is usable.",
                ReviewFixtures.anchor(heading.text, in: document))
        }

        // MARK: Spread through the document
        //
        // Every Nth paragraph, right through to the end, because an anchor that drifts
        // drifts progressively and a review of only the first pages would never show it.

        let paragraphs = document.blocks.filter {
            $0.role == "paragraph" && $0.text.split(separator: " ").count > 18
        }
        let step = max(1, paragraphs.count / 46)
        var taken = 0
        var cycle = 0

        /// Try each kind against this block in turn and take the first that can say
        /// something true about it. Rotating the starting point rather than keying the kind
        /// off a counter that only advances on success, which starved four of the five as
        /// soon as one of them stopped fitting.
        func item(_ kind: Int, _ block: ReviewFixtures.IndexedBlock) -> Bool {
            let before = annotations.count
            switch kind {
            case 0:
                // Only where the sentence really is repeated elsewhere, which in this
                // document it usually is — and the item names where.
                // The anchor is built by searching the whole document, so it lands on the
                // FIRST occurrence — which, for a sentence this document repeats, may be
                // the echo rather than this block. Unguarded, the item anchored to the echo
                // and then named the echo's own section as the place the duplicate lives:
                // "cut this, the same requirement is made under" its own heading.
                guard let sentence = block.text.split(separator: ".").first.map(String.init),
                      sentence.split(separator: " ").count >= 6,
                      document.locate(sentence)?.0.index == block.index,
                      let echo = document.blocks.first(where: {
                          $0.index != block.index && $0.role == "paragraph"
                              && $0.text.contains(sentence) && $0.path != block.path
                      })
                else { return false }
                add(.remove, "Cut this. The same requirement is made under \(echo.path),"
                    + " and two statements of one rule drift apart.",
                    ReviewFixtures.anchor(sentence, in: document))
            case 1:
                guard let objection = objection(to: block.text),
                      let quote = span(around: objection.phrase, in: block.text),
                      document.locate(quote) != nil
                else { return false }
                add(.change, objection.instruction,
                    ReviewFixtures.anchor(quote, in: document))
            case 2:
                guard let term = undefinedTerm(in: block.text),
                      let quote = span(around: term, in: block.text),
                      document.locate(quote) != nil
                else { return false }
                add(.question, "Where is “\(term)” defined? It is used as though it were a"
                    + " defined term and §2 does not define it.",
                    ReviewFixtures.anchor(quote, in: document))
            case 3:
                let words = block.text.split(separator: " ")
                guard words.count > 12 else { return false }
                let quote = words[2..<10].joined(separator: " ")
                guard document.locate(quote) != nil else { return false }
                add(.comment, "Keep this wording. It is quoted verbatim in the processor"
                    + " agreement, so changing it here puts the two out of step.",
                    ReviewFixtures.anchor(quote, in: document))
            default:
                // A named destination that is really somewhere else, and really about the
                // thing the instruction says it is about. Taking "the first heading that is
                // not this one" gave items reading "this is not a scope statement, it
                // belongs under Scope and definitions".
                let words = block.text.split(separator: " ")
                guard words.count > 12,
                      !block.path.contains("Evidence and audit"),
                      let elsewhere = document.blocks.first(where: {
                          $0.role == "heading-3" && $0.text.contains("Evidence and audit")
                      })
                else { return false }
                let quote = words[2..<10].joined(separator: " ")
                guard document.locate(quote) != nil else { return false }
                add(.move, "This is an evidence requirement rather than part of the rule"
                    + " above it. It belongs under \(elsewhere.text) in this part.",
                    ReviewFixtures.anchor(quote, in: document))
            }
            return annotations.count > before
        }

        for index in Swift.stride(from: 5, to: paragraphs.count, by: step) where taken < 46 {
            let block = paragraphs[index]
            guard !claimed.contains(block.index) else { continue }
            for offset in 0..<5 where item((cycle + offset) % 5, block) {
                taken += 1
                cycle += 1
                break
            }
        }

        // MARK: Things that are not instructions

        // Declined: proposed, refused, and must NOT be acted on.
        if annotations.count > 8 { annotations[8].decide(.declined, by: "Priya Raman") }
        // Approved: agreed, and must survive untouched.
        if annotations.count > 3 { annotations[3].decide(.approved, by: "Priya Raman") }
        // A thread asking for something the instruction above it does not — the reader is
        // told to follow the instruction and report the disagreement.
        if annotations.count > 12 {
            annotations[12].replies = [
                Reply(author: "Dan Whitfield",
                      text: "I would rather we deleted this outright than reworded it.",
                      isAssistant: false),
                Reply(author: "Robert Salesas",
                      text: "Noted, but the instruction stands for this pass.",
                      isAssistant: false),
            ]
        }
        // Already resolved: listed for the record, not handed over as work.
        if annotations.count > 17 { annotations[17].status = .resolved }

        return ReviewFile(
            source: SourceInfo(name: "large-spec.md", path: nil,
                               capturedAt: .reviewStamp,
                               digest: SourceInfo.digest(of: Data(markdown.utf8))),
            document: prepared,
            annotations: annotations)
    }
}
