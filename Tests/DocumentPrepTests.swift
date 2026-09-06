import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Revis

/// End-to-end over a real generated document: the kind of HTML this app exists for, with
/// the kind of things such documents actually carry — a telemetry script, a body `onload`,
/// a `javascript:` link, a tracking pixel, and a figure that is not on disk.
struct DocumentPrepTests {

    /// Read from the source tree by `#filePath`, so a fixture is added by dropping a file
    /// in rather than by editing a build phase.
    private static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private var prepared: PreparedDocument {
        DocumentPrep.prepare(html: Self.fixture("data-retention-spec.html"), baseURL: nil)
    }

    @Test func theDocumentSurvivesAndTheDangerDoesNot() {
        let doc = prepared
        #expect(doc.title == "Customer Data Platform — Retention Specification")

        // What was sent is still there.
        #expect(doc.body.contains("ninety (90) days"))
        #expect(doc.body.contains("<table>"))
        #expect(doc.body.contains("Retention worker sequence diagram"))
        #expect(doc.css.contains("Georgia"))          // the document's own look is kept
        #expect(doc.css.contains("#4a7fd0"))

        // What arrived with it is not.
        #expect(!doc.body.contains("__telemetry"))
        #expect(!doc.body.lowercased().contains("onload"))
        #expect(!doc.body.lowercased().contains("javascript:"))
        #expect(!doc.body.contains("tracker.example.com\""))   // not as a live src

        #expect(doc.report.scripts == 1)
        // The `onload` on `<body>`. Counted even though the tag itself is unwrapped:
        // "nothing was removed" would be a false statement about this document.
        #expect(doc.report.eventHandlers == 1)
        #expect(doc.report.dangerousURLs >= 1)
        #expect(doc.report.remoteResources >= 1)
    }

    @Test func anImageThatIsNotThereSaysSoRatherThanVanishing() {
        let doc = prepared
        #expect(doc.missingImages.contains("figures/retention-worker.png"))
        #expect(doc.body.contains("data-rv-missing"))
    }

    /// A document is not allowed to name a file outside its own folder, however it spells
    /// the path. This is the check that stops a viewer being a way of reading the disk.
    @Test func imagesCannotEscapeTheDocumentsFolder() {
        let root = URL(fileURLWithPath: "/tmp/revis-test-root")
        #expect(DocumentPrep.resolve("../../etc/passwd.png", under: root) == nil)
        #expect(DocumentPrep.resolve("/etc/passwd.png", under: root) == nil)
        #expect(DocumentPrep.resolve("figures/../../../secret.png", under: root) == nil)
        #expect(DocumentPrep.resolve("https://x/y.png", under: root) == nil)
        // …and a path that stays inside is only rejected for not existing, which is the
        // check after this one.
        #expect(DocumentPrep.resolve("figures/ok.txt", under: root) == nil)   // not an image
    }

    /// The page the web view is handed must forbid what the sanitizer already removed.
    /// Belt and braces on purpose: this is the layer that holds if the sanitizer is wrong.
    @Test func theShellForbidsWhatTheScrubberRemoved() {
        let page = DocumentShell.page(for: prepared, chromeCSS: "/* chrome */")
        #expect(page.contains("script-src 'none'"))
        #expect(page.contains("connect-src 'none'"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("form-action 'none'"))
        #expect(page.contains("base-uri 'none'"))
        // The runtime is injected as a user script, never inlined — that is what lets the
        // policy above be absolute.
        #expect(!page.contains("rvCaptureSelection"))
        #expect(page.contains("id=\"rv-doc\""))
        #expect(page.contains("id=\"rv-gutter\""))
    }

    /// The invariant the app rests on: reviewing a file must never modify it.
    ///
    /// Regression test with a real incident behind it — the first run against a real
    /// document autosaved the review over the specification, because AppKit writes a
    /// document back to the URL it was read from and declaring HTML unwritable does not
    /// stop it. `SourceDetachment` is what stops it happening; this is what holds if that
    /// ever breaks.
    @Test func aReviewRefusesToBeSavedOverItsSource() {
        #expect(!ReviewDocument.canWrite(.html))
        #expect(!ReviewDocument.canWrite(.plainText))
        #expect(!ReviewDocument.canWrite(.data))
        // …and the one type it does write, it still writes.
        #expect(ReviewDocument.canWrite(.revisReview))
    }
}
