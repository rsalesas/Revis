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
        #expect(restored.annotations[1].anchor.isRegion)
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
