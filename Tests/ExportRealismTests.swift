import Testing
import Foundation
@testable import Revis

/// Generates a review of the sample document for testing the export against a real model.
///
/// The annotations are anchored against the ACTUAL text of the document — quotes, prefixes
/// and suffixes are cut out of it by the same rules the runtime uses — so what comes out is
/// what the app would really produce, not a hand-written imitation of it. The set is chosen
/// to be hard on purpose: a phrase that occurs twice, a region over a table, a point with no
/// span, and an approval that must survive untouched.
struct ExportRealismTests {

    private static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The document's visible text, whitespace collapsed — what the runtime measures
    /// offsets and context against.
    private static func plainText(_ html: String) -> String {
        var out = ""
        var inTag = false
        for character in HTMLSanitizer.sanitize(html).body {
            if character == "<" { inTag = true; out.append(" ") }
            else if character == ">" { inTag = false }
            else if !inTag { out.append(character) }
        }
        return out.replacingOccurrences(of: "\\s+", with: " ",
                                        options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// An anchor built the way the runtime builds one: the exact quote, plus up to 64
    /// characters either side, trimmed only on the outer edge.
    private static func anchor(_ quote: String, occurrence: Int = 0, block: Int,
                               path: String, role: String = "paragraph",
                               in text: String) -> Anchor {
        var searchFrom = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let hit = text.range(of: quote, range: searchFrom..<text.endIndex) else {
                break
            }
            found = hit
            searchFrom = hit.upperBound
        }
        guard let range = found else {
            Issue.record("the fixture does not contain \"\(quote)\"")
            return Anchor(blocks: [block], path: path, role: role, quote: quote,
                          prefix: "", suffix: "", start: -1, end: -1, rect: nil)
        }
        let head = text.index(range.lowerBound, offsetBy: -64,
                              limitedBy: text.startIndex) ?? text.startIndex
        let tail = text.index(range.upperBound, offsetBy: 64,
                              limitedBy: text.endIndex) ?? text.endIndex
        return Anchor(
            blocks: [block], path: path, role: role, quote: quote,
            prefix: String(text[head..<range.lowerBound]).replacingOccurrences(
                of: "^\\s+", with: "", options: .regularExpression),
            suffix: String(text[range.upperBound..<tail]).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression),
            start: text.distance(from: text.startIndex, to: range.lowerBound),
            end: text.distance(from: text.startIndex, to: range.upperBound),
            rect: nil)
    }

    @Test func writeARealisticReviewForTestingAgainstAModel() throws {
        let html = Self.fixture("data-retention-spec.html")
        let text = Self.plainText(html)
        let prepared = DocumentPrep.prepare(html: html, baseURL: nil)

        func note(_ intent: Intent, _ instruction: String, _ anchor: Anchor) -> Annotation {
            Annotation(author: "Robert Salesas", intent: intent, note: instruction,
                       anchor: anchor)
        }

        var annotations: [Annotation] = [
            // 1. The straightforward case: one occurrence, plain prose.
            note(.change, "Make this thirty (30) days.",
                 Self.anchor("ninety (90) days", block: 11,
                             path: "3. Retention periods › 3.1 Personal data › paragraph 1",
                             in: text)),

            // 2. THE HARD ONE. "Worker log" appears twice in the summary table, and only
            //    the second is meant. Nothing but the surrounding words can tell them
            //    apart — this is the case that decides whether quote-plus-context is
            //    enough or whether anchors have to be carried in the document.
            note(.change, "Support transcripts are evidenced by the ticket record, not the"
                 + " worker log. Change this one only.",
                 Self.anchor("Worker log", occurrence: 1, block: 19,
                             path: "3. Retention periods › 3.3 Summary › table",
                             role: "table", in: text)),

            // 3. A whole block, removed.
            note(.remove, "This is covered by the corporate schedule already — take the"
                 + " whole callout out.",
                 Self.anchor("Anything not named in §3 is out of scope and continues to"
                             + " follow the general corporate retention schedule.",
                             block: 5, path: "1. Scope › paragraph 2", in: text)),

            // 4. A question, which asks for no edit at all.
            note(.question, "Where is the fifty-individual threshold defined? It is not in"
                 + " §2.",
                 Self.anchor("Aggregates over cohorts smaller than fifty individuals are"
                             + " treated as personal data.", block: 17,
                             path: "3. Retention periods › 3.2 Derived and aggregate data"
                                 + " › paragraph 2", in: text)),

            // 5. An approval. The model must LEAVE THIS ALONE — a review that cannot say
            //    "do not touch this" is a review that gets its good parts rewritten.
            note(.approve, "This definition is exactly right; do not reword it.",
                 Self.anchor("Irreversible removal from primary storage, all replicas, and"
                             + " all backups taken after the deletion request.", block: 9,
                             path: "2. Definitions › definition 2", role: "definition",
                             in: text)),
        ]

        // 6. A REGION — the whole thesis. The reviewer drew a box over the summary table;
        //    what the export carries is the text the box covered.
        let tableText = "Class Retention Trigger Evidence Personal data 90 days Collection"
            + " event Worker log Audit records 7 years Write Immutable store Aggregates"
            + " Indefinite — None Support transcripts 180 days Ticket close Worker log"
        annotations.append(note(
            .change, "The retention column here has to match §3.1 once that is corrected.",
            Anchor(blocks: [19], path: "3. Retention periods › 3.3 Summary › table",
                   role: "region", quote: tableText, prefix: "", suffix: "",
                   start: -1, end: -1,
                   rect: NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))))

        // 7. A point rather than a span: something has to be added after this paragraph.
        annotations.append(note(
            .insert, "Add a sentence here saying what happens when a replica is offline at"
                + " the moment the delete is issued.",
            Self.anchor("Backups are not rewritten; instead the tombstone is replayed when"
                        + " a backup is restored.", block: 21,
                        path: "4. Deletion mechanics › paragraph 1", in: text)))

        let file = ReviewFile(
            source: SourceInfo(name: "data-retention-spec.html", path: nil,
                               capturedAt: .reviewStamp,
                               digest: SourceInfo.digest(of: Data(html.utf8))),
            document: prepared, annotations: annotations)

        // Every anchor really is in the document — a test of the export that quoted text
        // the document does not contain would prove nothing.
        for annotation in annotations where !annotation.anchor.isRegion {
            #expect(text.contains(annotation.anchor.quote),
                    "anchor not found in the document: \(annotation.anchor.quote)")
        }

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try ReviewExport.markdown(file).write(
            to: directory.appendingPathComponent("model-test-review.md"),
            atomically: true, encoding: .utf8)
        try ReviewExport.json(file).write(
            to: directory.appendingPathComponent("model-test-review.json"),
            atomically: true, encoding: .utf8)
    }
}
