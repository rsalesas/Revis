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
    /// A review of the REAL sample document, anchored where the runtime will look.
    ///
    /// It used to carry a one-line stub for a body and hand-written block numbers, and both
    /// were wrong in the same quiet way: an anchor pointing at a block the document does not
    /// have is one the runtime declines to draw, correctly and silently, so the specimen
    /// opened looking like a broken app rather than a broken fixture. Nothing is written
    /// down here now except the words — `ReviewFixtures.document()` finds the block.
    private func sample() -> ReviewFile {
        let document = ReviewFixtures.document()
        return ReviewFile(
            source: SourceInfo(name: "data-retention-spec.html",
                               path: "/Users/robert/Documents/data-retention-spec.html",
                               capturedAt: Date(timeIntervalSince1970: 1_788_690_000),
                               digest: SourceInfo.digest(of: Data(document.html.utf8))),
            document: DocumentPrep.prepare(html: document.html, baseURL: nil),
            annotations: [
                Annotation(author: "Robert Salesas", intent: .change,
                           note: "Say \"category\" rather than \"class\" — class means"
                               + " something else in the data model.",
                           anchor: ReviewFixtures.anchor("each class of record",
                                                         in: document)),
                Annotation(author: "Robert Salesas", intent: .question,
                           note: "Does \"all backups\" include the offsite weeklies?",
                           anchor: ReviewFixtures.anchor(
                               "all backups taken after the deletion request",
                               in: document),
                           replies: [
                               Reply(author: "Claude",
                                     text: "No — §2 says \"all backups taken after the"
                                         + " deletion request\", which excludes the"
                                         + " offsite weeklies written before it.",
                                     isAssistant: true),
                               Reply(author: "Robert Salesas",
                                     text: "Then the definition needs to say so."),
                           ]),
                // A drawn box, so the specimen shows the one anchor kind with no character
                // range — the case a reader of the format is most likely to get wrong.
                Annotation(author: "Priya Raman", intent: .change,
                           note: "The retention column has to match §3.1.",
                           anchor: ReviewFixtures.region(over: "Class Retention Trigger",
                                                         in: document)),
            ])
    }

    @Test func aReviewSurvivesBeingWrittenAndReadBack() throws {
        let original = sample()
        let data = try JSONEncoder.revis.encode(original)
        let restored = try JSONDecoder.revis.decode(ReviewFile.self, from: data)
        #expect(restored == original)
        // Every anchor still says what it is about, which is the only part of a review
        // that a regenerated document cannot invalidate.
        #expect(restored.annotations[1].anchor.quote.contains("all backups"))
        #expect(restored.annotations[2].anchor.isRegion)
        // The region names the table, not whatever block happens to sit at a number
        // somebody typed. This is the assertion the old fixture could not have made.
        #expect(restored.annotations[2].anchor.quote.hasPrefix("Class Retention"))
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

    // MARK: - Where a review is offered a home

    /// A review is offered beside the file it reviews, under that file's name.
    ///
    /// Before this the save panel was seeded from the only two things a detached draft has
    /// left — the document's display name, which was its `<title>`, and whatever folder a
    /// panel was last pointed at. A review of `Masterclass_IA_Responsable.html` came up as
    /// *Angles morts de l'IA : Numérique responsable — Masterclass.revis* somewhere else
    /// entirely, which is a name nobody typed in a place nobody chose.
    @MainActor
    @Test func aReviewIsOfferedBesideTheFileItReviews() {
        let source = URL(fileURLWithPath: "/Users/someone/Downloads/spec.html")
        let offered = SourceDetachment.reviewURL(beside: source)
        #expect(offered.deletingLastPathComponent() == source.deletingLastPathComponent())
        #expect(offered.lastPathComponent == "spec.revis")

        // Only the LAST extension goes: `spec.v2.html` is a file called `spec.v2`.
        #expect(SourceDetachment.reviewURL(
            beside: URL(fileURLWithPath: "/tmp/spec.v2.html")).lastPathComponent
                == "spec.v2.revis")
    }

    /// And the name it is offered under is the name its export would use.
    ///
    /// Two answers to "what is this document called", arrived at in two places — the save
    /// panel through `NSDocument.displayName`, the export through `exportBaseName` — and a
    /// reviewer with `spec.revis` beside `spec review.md` should not have to wonder whether
    /// they belong together.
    @MainActor
    @Test func theSaveNameAndTheExportNameAgree() {
        let model = ReviewModel(file: ReviewFile(
            source: SourceInfo(name: "Masterclass_IA_Responsable.html", path: nil,
                               capturedAt: .reviewStamp, digest: ""),
            document: .empty), appSettings: AppSettings())
        let offered = SourceDetachment.reviewURL(
            beside: URL(fileURLWithPath: "/tmp/Masterclass_IA_Responsable.html"))
        #expect(offered.deletingPathExtension().lastPathComponent == model.exportBaseName)
    }
}
