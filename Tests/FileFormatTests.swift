import Testing
import Foundation
@testable import Revis

/// The `.revis` file is what a review IS, so its shape is pinned here: a file written by
/// this build has to be readable by the next one, and a format that only exists as
/// whatever the encoder happened to emit is a format nobody can rely on.
struct FileFormatTests {

    /// A review of the REAL sample document, anchored at blocks it actually has.
    ///
    /// It used to carry a one-line stub for a body and anchors naming blocks 3 and 8–11,
    /// which that stub did not contain. Nothing failed: a mark whose block is absent is one
    /// the runtime declines to draw, which is right. But `specimen()` exists so a person can
    /// LOOK at a review, and opening this one showed an empty margin beside a full pane —
    /// which reads as the app being broken rather than as the fixture being a sketch. A
    /// specimen has to be a specimen of the whole thing.
    private func sample() -> ReviewFile {
        let html = ReviewFixtures.html()
        let text = ReviewFixtures.plainText(html)
        // Block indices match the runtime's `data-rv` stamping of this document, the same
        // ones `ExportRealismTests` uses.
        let span = ReviewFixtures.anchor(
            "each class of record", block: 3, path: "1. Scope › paragraph 1", in: text)
        let definition = ReviewFixtures.anchor(
            "Irreversible removal from primary storage, all replicas, and all backups taken"
                + " after the deletion request.",
            block: 9, path: "2. Definitions › definition 2", role: "definition", in: text)
        // A drawn box, so the specimen shows the one anchor kind that has no character
        // range — the case a reader of the format is most likely to get wrong.
        let region = Anchor(
            blocks: [19], path: "3. Retention periods › 3.3 Summary › table", role: "region",
            quote: "Class Retention Trigger Evidence Personal data 90 days Collection event"
                + " Worker log Audit records 7 years Write Immutable store Aggregates"
                + " Indefinite — None Support transcripts 180 days Ticket close Worker log",
            prefix: "", suffix: "", start: -1, end: -1,
            rect: NormalizedRect(x: -0.02, y: -0.31, width: 1.79, height: 1.23))
        return ReviewFile(
            source: SourceInfo(name: "data-retention-spec.html",
                               path: "/Users/robert/Documents/data-retention-spec.html",
                               capturedAt: Date(timeIntervalSince1970: 1_788_690_000),
                               digest: SourceInfo.digest(of: Data(html.utf8))),
            document: DocumentPrep.prepare(html: html, baseURL: nil),
            annotations: [
                Annotation(author: "Robert Salesas", intent: .change,
                           note: "Say \"category\" rather than \"class\" — class means"
                               + " something else in the data model.",
                           anchor: span),
                Annotation(author: "Robert Salesas", intent: .question,
                           note: "Does \"all backups\" include the offsite weeklies?",
                           anchor: definition,
                           replies: [
                               Reply(author: "Claude",
                                     text: "No — §2 says \"all backups taken after the"
                                         + " deletion request\", which excludes the"
                                         + " offsite weeklies written before it.",
                                     isAssistant: true),
                               Reply(author: "Robert Salesas",
                                     text: "Then the definition needs to say so."),
                           ]),
                Annotation(author: "Priya Raman", intent: .change,
                           note: "The retention column has to match §3.1.",
                           anchor: region),
            ])
    }

    @Test func aReviewSurvivesBeingWrittenAndReadBack() throws {
        let original = sample()
        let data = try JSONEncoder.revis.encode(original)
        let restored = try JSONDecoder.revis.decode(ReviewFile.self, from: data)
        #expect(restored == original)
        // Every anchor still says what it is about, which is the only part of a review
        // that a regenerated document cannot invalidate.
        #expect(restored.annotations[1].anchor.quote.contains("Irreversible removal"))
        #expect(restored.annotations[2].anchor.isRegion)
        // A thread survives in order and keeps who said what, including which remark came
        // from a machine.
        #expect(restored.annotations[1].replies.map(\.isAssistant) == [true, false])
    }

    /// A review saved before replies existed still opens.
    ///
    /// This is the test the whole feature turns on, and it is written as raw JSON rather
    /// than by re-encoding a value, because re-encoding could only ever produce a file this
    /// build already agrees with. Swift's synthesised decoder throws on a missing key even
    /// when the property has a default — so `replies` arriving with no `init(from:)` would
    /// have made every existing file undecodable. And `ReviewDocument` swallows a decode
    /// failure with `try?` and falls through to treating the bytes as HTML, so nobody would
    /// have seen an error: the review would simply have reopened empty, as a document of
    /// its own JSON.
    @Test func aReviewSavedBeforeRepliesExistedStillOpens() throws {
        let json = """
        {
          "annotations" : [
            {
              "anchor" : { "blocks" : [3], "end" : 108, "path" : "1. Scope › paragraph 1",
                "prefix" : "retains", "quote" : "each class of record", "role" : "paragraph",
                "start" : 88, "suffix" : ", what triggers deletion." },
              "author" : "Robert Salesas", "created" : "2026-09-04T11:00:00Z",
              "id" : "8BF77E0F-0000-4000-8000-000000000001",
              "intent" : "change", "note" : "Say category.", "status" : "open"
            }
          ],
          "app" : "Revis 0.9",
          "document" : { "body" : "<h1>x</h1>", "css" : "", "missingImages" : [],
            "report" : { "dangerousURLs" : 0, "eventHandlers" : 0, "frames" : 0,
              "interactive" : 0, "remoteResources" : 0, "scripts" : 0 } },
          "format" : 1,
          "source" : { "capturedAt" : "2026-09-04T10:00:00Z", "digest" : "abc",
            "name" : "spec.html" }
        }
        """
        let file = try JSONDecoder.revis.decode(ReviewFile.self, from: Data(json.utf8))
        #expect(file.annotations.count == 1)
        #expect(file.annotations[0].replies.isEmpty)
        #expect(file.annotations[0].note == "Say category.")
    }

    /// The other half of the same guarantee: a file missing the fields that have always had
    /// defaults is read rather than refused. These were required keys before `init(from:)`
    /// existed, for no reason anybody intended.
    @Test func anAnnotationNeedsOnlyAnIntentAndAnAnchor() throws {
        let json = """
        { "anchor" : { "blocks" : [1], "end" : -1, "path" : "", "prefix" : "",
            "quote" : "some words", "role" : "paragraph", "start" : -1, "suffix" : "" },
          "intent" : "remove" }
        """
        let annotation = try JSONDecoder.revis.decode(Annotation.self, from: Data(json.utf8))
        #expect(annotation.author.isEmpty)
        #expect(annotation.note.isEmpty)
        #expect(annotation.status == .open)
        #expect(annotation.verdict == nil)
        #expect(annotation.replies.isEmpty)
    }

    /// Writes a specimen out for reading by eye. Not an assertion about the file so much
    /// as a way of looking at one — a format you have never seen printed is a format you
    /// are guessing about.
    @Test func specimen() throws {
        // Into the repository's own `build/` (gitignored), located from `#filePath`
        // rather than from an environment variable: `xcodebuild` runs the test host as its
        // own process and does not pass the invoking shell's environment down to it, so a
        // variable set on the command line simply never arrives.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.revis.encode(sample())
            .write(to: directory.appendingPathComponent("specimen.revis"))
        // …and the thing that is actually handed to an assistant, which is not the file
        // above. Worth writing both out side by side: the file is how a review is STORED,
        // and the Markdown is how it is DELIVERED, and confusing the two makes the design
        // look far more fragile than it is.
        try ReviewExport.markdown(sample())
            .write(to: directory.appendingPathComponent("specimen-review.md"),
                   atomically: true, encoding: .utf8)
    }
}
