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

    static func realisticFile() throws -> ReviewFile {
        let markdown = source()
        let prepared = DocumentPrep.prepare(markdown: markdown, baseURL: nil,
                                            options: .default)
        let document = ReviewFixtures.document(html: prepared.body)

        var annotations: [Annotation] = []
        func note(_ intent: Intent, _ instruction: String, _ anchor: Anchor,
                  author: String = "Robert Salesas") -> Annotation {
            Annotation(author: author, intent: intent, note: instruction, anchor: anchor)
        }

        // MARK: The hard ones, named

        // Said twice, word for word, in Appendix A. Only the second is meant, and nothing
        // but the heading trail and the surrounding words can say so.
        let twin = LargeDocument.twinPassage
        if let second = document.locate(twin, occurrence: 1)?.0 {
            var anchor = ReviewFixtures.anchor(twin, occurrence: 1, in: document)
            anchor.path = second.path
            annotations.append(note(.change,
                "In the degraded case the aggregates are NOT withheld — they are served"
                + " stale and flagged. Change this occurrence only; A.1 is correct as it"
                + " stands.", anchor))
        }

        // A quote with emphasis through the middle of it: the words are contiguous on the
        // page and are not contiguous in the file.
        for block in document.blocks where block.role == "paragraph" {
            guard block.text.contains("must record a durable tombstone") else { continue }
            annotations.append(note(.change,
                "Say WHICH ledger. There are two by the end of §4 and this reads as though"
                + " there were one.",
                ReviewFixtures.anchor("must record a durable tombstone", in: document)))
            break
        }

        // A drawn box over a table — the region tool's whole justification.
        if let table = document.blocks.first(where: { $0.role == "table" }) {
            annotations.append(note(.change,
                "This table disagrees with §3 about the audit row. Reconcile it, and say"
                + " in your reply which one you took to be right.",
                ReviewFixtures.region(over: String(table.text.prefix(40)), in: document)))
        }

        // A code block.
        if let code = document.blocks.first(where: { $0.role == "code" }) {
            annotations.append(note(.comment,
                "Leave this exactly as it is — the argument name is load-bearing"
                + " downstream.",
                ReviewFixtures.anchor(code.text, in: document)))
        }

        // A footnote's text, which the renderer moved to the foot of the page, and whose
        // marker upstream is a number the author never wrote.
        if let footnote = document.blocks.first(where: {
            $0.text.hasPrefix("A sweep that fails")
        }) {
            annotations.append(note(.question,
                "Who is on call for this out of hours? The document never says.",
                ReviewFixtures.anchor(String(footnote.text.prefix(60)), in: document)))
        }

        // A heading.
        if let heading = document.blocks.first(where: { $0.role == "heading-3" }) {
            annotations.append(note(.change, "Number this section; every other one is.",
                                    ReviewFixtures.anchor(heading.text, in: document)))
        }

        // MARK: Spread through the document

        // Every Nth paragraph, right through to the end, because an anchor that drifts
        // drifts progressively and a review of only the first pages would never show it.
        let paragraphs = document.blocks.filter {
            $0.role == "paragraph" && $0.text.split(separator: " ").count > 18
        }
        let stride = max(1, paragraphs.count / 44)
        var taken = 0
        for index in Swift.stride(from: 5, to: paragraphs.count, by: stride) where taken < 44 {
            let words = paragraphs[index].text.split(separator: " ")
            let quote = words[3..<11].joined(separator: " ")
            guard document.locate(quote) != nil else { continue }
            taken += 1
            let anchor = ReviewFixtures.anchor(quote, in: document)
            switch taken % 5 {
            case 0:
                annotations.append(note(.remove,
                    "Cut this — it repeats §1 and the repetition has already drifted.",
                    anchor))
            case 1:
                annotations.append(note(.change,
                    "Give the actual interval. \"Promptly\" has been read as a week.",
                    anchor))
            case 2:
                annotations.append(note(.question,
                    "Is this still true after the v4 cutover? I could not tell from §2.",
                    anchor))
            case 3:
                annotations.append(note(.comment,
                    "Worth keeping exactly as worded — the auditors quoted this back to us.",
                    anchor))
            default:
                annotations.append(note(.move,
                    "This belongs under Evidence and audit, not here.", anchor))
            }
        }

        // MARK: Things that are not instructions

        // Declined: proposed, refused, and must NOT be acted on.
        if annotations.count > 8 {
            annotations[8].decide(.declined, by: "Priya Raman")
        }
        // Approved: agreed, and must survive untouched.
        if annotations.count > 3 {
            annotations[3].decide(.approved, by: "Priya Raman")
        }
        // A thread that asks for something the instruction above it does not — the reader
        // is told to follow the instruction and report the disagreement.
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
        if annotations.count > 17 {
            annotations[17].status = .resolved
        }

        return ReviewFile(
            source: SourceInfo(name: "large-spec.md", path: nil,
                               capturedAt: .reviewStamp,
                               digest: SourceInfo.digest(of: Data(markdown.utf8))),
            document: prepared,
            annotations: annotations)
    }
}
