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

    // The document, its text and its anchors all come from `ReviewFixtures`, so this file
    // and `FileFormatTests` cut their quotes out of the same document by the same rules.

    @Test func writeARealisticReviewForTestingAgainstAModel() throws {
        let file = try Self.realisticFile()
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

    /// The annotations, so the reply fixture can be planned against the very review it was
    /// written in answer to.
    static func realisticAnnotations() throws -> [Annotation] {
        try realisticFile().annotations
    }

    static func realisticFile() throws -> ReviewFile {
        let html = ReviewFixtures.html()
        let text = ReviewFixtures.plainText(html)
        let prepared = DocumentPrep.prepare(html: html, baseURL: nil)

        // LITERAL ids, not fresh ones, and this is what makes the round trip testable at
        // all. `Tests/Fixtures/model-reply.md` is a real model's answer to this exact
        // review, committed as it arrived — and it names these items by id. Generate new
        // UUIDs here and that fixture matches nothing on the next run, silently, because an
        // unmatched reply is a reported condition rather than a failure.
        var ids = [
            UUID(uuidString: "c52818a0-988f-441a-ae7e-d169cb1dabc1")!,  // 1  ninety days
            UUID(uuidString: "866e2d08-856a-4982-bca5-fc87a9547dd7")!,  // 2  worker log
            UUID(uuidString: "090a1529-f090-4ece-8ea3-4d6fd3b1eb8e")!,  // 3  the callout
            UUID(uuidString: "893efbbe-78e7-41ef-aac3-b48d80dbb3f1")!,  // 4  the question
            UUID(uuidString: "c1d51bf7-6269-4621-b5c6-4127cc4c5ae0")!,  // 5  the comment
            UUID(uuidString: "7fd488bb-f631-475e-83de-9159b55d662f")!,  // 6  the region
            UUID(uuidString: "b07a7832-08bf-4608-aaee-88133bf8fbc4")!,  // 7  declined
            UUID(uuidString: "0b10dfa0-1c19-4909-a0e9-34f1f33f8670")!,  // 8  argued-with
            UUID(uuidString: "bfccc5f9-c4dc-49a1-bab5-bf34ba92f138")!,  // 9  the insert
        ].makeIterator()

        func note(_ intent: Intent, _ instruction: String, _ anchor: Anchor) -> Annotation {
            Annotation(id: ids.next() ?? UUID(), author: "Robert Salesas", intent: intent,
                       note: instruction, anchor: anchor)
        }

        var annotations: [Annotation] = [
            // 1. The straightforward case: one occurrence, plain prose.
            note(.change, "Make this thirty (30) days.",
                 ReviewFixtures.anchor("ninety (90) days", block: 11,
                             path: "3. Retention periods › 3.1 Personal data › paragraph 1",
                             in: text)),

            // 2. THE HARD ONE. "Worker log" appears twice in the summary table, and only
            //    the second is meant. Nothing but the surrounding words can tell them
            //    apart — this is the case that decides whether quote-plus-context is
            //    enough or whether anchors have to be carried in the document.
            note(.change, "Support transcripts are evidenced by the ticket record, not the"
                 + " worker log. Change this one only.",
                 ReviewFixtures.anchor("Worker log", occurrence: 1, block: 19,
                             path: "3. Retention periods › 3.3 Summary › table",
                             role: "table", in: text)),

            // 3. A whole block, removed.
            note(.remove, "This is covered by the corporate schedule already — take the"
                 + " whole callout out.",
                 ReviewFixtures.anchor("Anything not named in §3 is out of scope and continues to"
                             + " follow the general corporate retention schedule.",
                             block: 5, path: "1. Scope › paragraph 2", in: text)),

            // 4. A question, which asks for no edit at all.
            note(.question, "Where is the fifty-individual threshold defined? It is not in"
                 + " §2.",
                 ReviewFixtures.anchor("Aggregates over cohorts smaller than fifty individuals are"
                             + " treated as personal data.", block: 17,
                             path: "3. Retention periods › 3.2 Derived and aggregate data"
                                 + " › paragraph 2", in: text)),

            // 5. A comment: something worth knowing, asking for no edit.
            note(.comment, "This definition is the one everything else leans on — worth"
                 + " keeping exactly as it is.",
                 ReviewFixtures.anchor("Irreversible removal from primary storage, all replicas, and"
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

        // 7. A request that a second reviewer TURNED DOWN. The export must tell the
        //    reader not to act on it — a declined suggestion handed over as work is a
        //    change somebody explicitly refused.
        var refused = note(.change, "Make the retention worker run every fifteen minutes.",
                           ReviewFixtures.anchor("The retention worker runs hourly.", block: 21,
                                       path: "4. Deletion mechanics › paragraph 1",
                                       in: text))
        refused.decide(.declined, by: "Robert Salesas")
        // A thread on the DECLINED item, which is where the remark saying why is worth
        // most — and which the Declined section would drop if only `item` carried threads.
        refused.replies = [
            Reply(author: "Priya Raman",
                  text: "Declined because the worker's cost is dominated by the scan, not"
                      + " the delete: quarter-hourly would be four times the bill for the"
                      + " same outcome."),
        ]
        annotations.append(refused)

        // 9. A reply that CONTRADICTS its own instruction, nobody having folded it back in.
        //    The export says to follow the instruction and report the disagreement, which
        //    is the one rule about threads a reader has to get right.
        var argued = note(.change, "Change the aggregate retention to five years.",
                          ReviewFixtures.anchor("Aggregates computed from personal data are retained"
                                      + " indefinitely", block: 17,
                                      path: "3. Retention periods › 3.2 Derived and"
                                          + " aggregate data › paragraph 1", in: text))
        argued.replies = [
            Reply(author: "Priya Raman",
                  text: "Five is too long — legal said two years at the review last week."),
            Reply(author: "Claude",
                  text: "For what it is worth, §3.3 says Indefinite for Aggregates, so"
                      + " whichever number wins, that row needs the same edit.",
                  isAssistant: true),
        ]
        annotations.append(argued)

        // 8. A point rather than a span: something has to be added after this paragraph.
        annotations.append(note(
            .insert, "Add a sentence here saying what happens when a replica is offline at"
                + " the moment the delete is issued.",
            ReviewFixtures.anchor("Backups are not rewritten; instead the tombstone is replayed when"
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
        return file
    }
}

/// Emits a review carrying one annotation of every intent, for looking at.
///
/// Card geometry is not something a unit test can measure — SwiftUI decides it at render
/// time — so the way to check that seven cards are the same shape is to put seven cards on
/// screen at once. Building the `.revis` directly is far quicker than making seven
/// annotations by hand, and it is reproducible, which a hand-made one is not.
struct IntentSpecimenTests {

    @Test func writeOneCardOfEveryIntent() throws {
        let html = ReviewFixtures.html()
        let prepared = DocumentPrep.prepare(html: html, baseURL: nil)

        // Blocks 3 upward: the paragraphs of the document, one per intent, so the rows sit
        // in document order and each gets its own marker rather than stacking.
        let annotations = Intent.allCases.enumerated().map { index, intent in
            Annotation(
                author: "Robert Salesas", intent: intent,
                // Every card carries the same words, so any difference in height is the
                // card's doing and not the content's.
                note: "One line of instruction.",
                anchor: Anchor(blocks: [3 + index * 2],
                               path: "Section \(index + 1) › paragraph 1",
                               role: "paragraph",
                               quote: "A quoted passage of roughly one line in length.",
                               prefix: "", suffix: "", start: 0, end: 47, rect: nil))
        }

        let file = ReviewFile(
            source: SourceInfo(name: "data-retention-spec.html", path: nil,
                               capturedAt: .reviewStamp,
                               digest: SourceInfo.digest(of: Data(html.utf8))),
            document: prepared, annotations: annotations)

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.revis.encode(file).write(
            to: directory.appendingPathComponent("all-intents.revis"))
    }
}

/// A real model's real reply document, kept as a fixture.
///
/// The manual half of this cannot be automated and should be repeated whenever the export's
/// wording changes: hand a model the sample HTML and `build/model-test-review.md` with one
/// flat instruction — *"Apply this review to the document"* — and nothing else. Deliberately
/// NOT "apply this review and write a reply document": the whole question is whether the
/// export's own words are enough, and a prompt that repeats them tests the prompt.
///
/// What came back is committed exactly as it arrived. A reply document tidied by hand
/// proves the parser reads tidy files, which was never in doubt.
struct ModelReplyFixtureTests {

    private static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func aRealModelsReplyDocumentReadsCleanly() throws {
        let reading = ReplyImport.read(ReviewFixtures.html("model-reply.md"))
        #expect(reading.problems.isEmpty, "problems: \(reading.problems)")
        #expect(reading.replies.count == 5)
        // It named itself, so the importer does not have to guess.
        #expect(reading.replies.allSatisfy { $0.author == "Claude" })
    }

    /// And every id in it is one this review actually contains.
    ///
    /// The ids in `ExportRealismTests` are literals for exactly this reason. If they ever
    /// go back to being freshly generated, this is the test that says so — otherwise the
    /// fixture would quietly match nothing, because an unmatched reply is a reported
    /// condition and not a failure.
    @Test func everyReplyInItLandsOnAnItemOfThisReview() throws {
        let annotations = try ExportRealismTests.realisticAnnotations()
        var working = annotations
        let landings = ReplyImport.plan(ReplyImport.read(ReviewFixtures.html("model-reply.md")),
                                        against: working)
        let result = ReplyImport.attach(landings, to: &working, signedBy: "Assistant")
        #expect(result.unmatched.isEmpty,
                "named ids this review does not have: \(result.unmatched.map(\.rawID))")
        #expect(result.attached == 5)
        // It answered the question — the item that, before any of this existed, had
        // nowhere to put an answer. It had no thread before the import, so what is there
        // now arrived from the document, and arrived marked as a machine's whatever the
        // document said about itself.
        let question = working.first { $0.intent == .question }
        #expect(question?.replies.count == 1)
        #expect(question?.replies.first?.isAssistant == true)
        #expect(question?.replies.first?.author == "Claude")
    }
}
