import Testing
import Foundation
@testable import Revis

/// The `.revis` file is what a review IS, so its shape is pinned here: a file written by
/// this build has to be readable by the next one, and a format that only exists as
/// whatever the encoder happened to emit is a format nobody can rely on.
struct FileFormatTests {

    private func sample() -> ReviewFile {
        let text = Anchor(
            blocks: [3], path: "1. Scope › paragraph 1", role: "paragraph",
            quote: "each class of record",
            prefix: "This document specifies how long the Customer Data Platform retains",
            suffix: ", what triggers deletion, and how deletion is evidenced.",
            start: 88, end: 108, rect: nil)
        let region = Anchor(
            blocks: [8, 9, 10, 11], path: "2. Definitions › term 1", role: "region",
            quote: "Collection event ⏎ The moment a record first enters the platform,"
                + " whether by API, batch import, or manual entry. ⏎ Deletion ⏎"
                + " Irreversible removal from primary storage, all replicas, and all"
                + " backups taken after the deletion request.",
            prefix: "", suffix: "", start: -1, end: -1,
            rect: NormalizedRect(x: -0.02, y: -0.31, width: 1.79, height: 1.23))
        return ReviewFile(
            source: SourceInfo(name: "data-retention-spec.html",
                               path: "/Users/robert/Documents/data-retention-spec.html",
                               capturedAt: Date(timeIntervalSince1970: 1_788_690_000),
                               digest: "39b5352d9712d516c52c4b2b05fdd49672a6dcf1b0c991"
                                     + "c323fe79764d168490"),
            document: PreparedDocument(
                body: "<h1>Customer Data Platform — Retention Specification</h1>…",
                css: "body { font-family: Georgia, serif; color: #23252b; }…",
                title: "Customer Data Platform — Retention Specification",
                report: SanitizationReport(scripts: 1, eventHandlers: 1, frames: 0,
                                           interactive: 0, remoteResources: 2,
                                           dangerousURLs: 1),
                missingImages: ["figures/retention-worker.png"]),
            annotations: [
                Annotation(author: "Robert Salesas", intent: .change,
                           note: "Say \"category\" rather than \"class\" — class means"
                               + " something else in the data model.",
                           anchor: text),
                Annotation(author: "Robert Salesas", intent: .question,
                           note: "Does \"all backups\" include the offsite weeklies?",
                           anchor: region,
                           replies: [
                               Reply(author: "Claude",
                                     text: "No — §2 says \"all backups taken after the"
                                         + " deletion request\", which excludes the"
                                         + " offsite weeklies written before it.",
                                     isAssistant: true),
                               Reply(author: "Robert Salesas",
                                     text: "Then the definition needs to say so."),
                           ]),
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
        #expect(restored.annotations[1].anchor.isRegion)
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
