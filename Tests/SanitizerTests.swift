import Testing
import Foundation
@testable import Revis

/// The sanitizer is the one place where being wrong is a security bug rather than a
/// cosmetic one, so it is the one place that gets tests before anything else does.
struct SanitizerTests {

    @Test func stripsScriptsAndTheirContents() {
        let result = HTMLSanitizer.sanitize("<p>a</p><script>alert(1)</script><p>b</p>")
        #expect(!result.body.contains("alert"))
        #expect(!result.body.lowercased().contains("script"))
        #expect(result.report.scripts == 1)
    }

    @Test func stripsEventHandlersWhateverTheyAreCalled() {
        // Deliberately includes a handler that does not exist: the rule is "every `on…`",
        // not "the handlers we thought of".
        let result = HTMLSanitizer.sanitize(
            "<div onclick=\"x()\" ONMOUSEOVER='y()' onnotarealevent=\"z()\">hi</div>")
        #expect(!result.body.lowercased().contains("onclick"))
        #expect(!result.body.lowercased().contains("onmouseover"))
        #expect(!result.body.lowercased().contains("onnotarealevent"))
        #expect(result.report.eventHandlers == 3)
    }

    @Test func refusesExecutableURLsHoweverTheyAreSpelled() {
        #expect(HTMLSanitizer.classifyURL("javascript:alert(1)") == .dangerous)
        #expect(HTMLSanitizer.classifyURL("JaVaScRiPt:alert(1)") == .dangerous)
        #expect(HTMLSanitizer.classifyURL("java\tscript:alert(1)") == .dangerous)
        #expect(HTMLSanitizer.classifyURL("&#106;avascript:alert(1)") == .dangerous)
        #expect(HTMLSanitizer.classifyURL("data:text/html,<script>") == .dangerous)
        #expect(HTMLSanitizer.classifyURL("data:image/png;base64,AAA") == .safe)
        #expect(HTMLSanitizer.classifyURL("#section-2") == .safe)
        #expect(HTMLSanitizer.classifyURL("images/figure.png") == .safe)
        #expect(HTMLSanitizer.classifyURL("https://example.com/x.png") == .remote)
    }

    @Test func keepsStructureAndTheDocumentsOwnStyle() {
        let result = HTMLSanitizer.sanitize("""
        <html><head><title>Spec</title><style>p { color: red }</style></head>
        <body><h1>One</h1><p>Two</p><table><tr><td>Three</td></tr></table></body></html>
        """)
        #expect(result.title == "Spec")
        #expect(result.css.contains("color: red"))
        #expect(result.body.contains("<h1>"))
        #expect(result.body.contains("<table>"))
        // The shell is ours; the document's own wrappers go.
        #expect(!result.body.contains("<html"))
        #expect(!result.body.contains("<body"))
    }

    @Test func cssCannotReachOutward() {
        var report = SanitizationReport()
        let css = HTMLSanitizer.scrubCSS(
            "@import url(http://x/y.css); body { background: url(https://x/y.png) }",
            report: &report)
        #expect(!css.contains("@import"))
        #expect(!css.contains("https://"))
        #expect(report.remoteResources >= 2)
    }

    @Test func aDocumentCannotForgeAnAnchor() {
        // Our own addressing. A page that stamped its own indices could make a margin
        // marker point at a passage the reviewer never marked.
        let result = HTMLSanitizer.sanitize("<p data-rv=\"3\" data-rv-for=\"x\">hi</p>")
        #expect(!result.body.contains("data-rv"))
    }
}

/// Anchors are what the export is made of, so their ordering and their summaries have to
/// behave.
struct AnnotationTests {

    private func anchor(block: Int, start: Int, quote: String = "q") -> Anchor {
        Anchor(blocks: [block], path: "", role: "paragraph", quote: quote,
               prefix: "", suffix: "", start: start, end: start + quote.count, rect: nil)
    }

    @Test func sortsDownThePage() {
        let a = Annotation(author: "R", intent: .change, note: "1", anchor: anchor(block: 5, start: 0))
        let b = Annotation(author: "R", intent: .change, note: "2", anchor: anchor(block: 2, start: 9))
        let c = Annotation(author: "R", intent: .change, note: "3", anchor: anchor(block: 2, start: 1))
        #expect([a, b, c].inDocumentOrder().map(\.note) == ["3", "2", "1"])
    }

    @Test func exportLeadsWithTheOperationAndTheWords() {
        let file = ReviewFile(
            source: SourceInfo(name: "spec.html", path: nil, capturedAt: Date(), digest: "abc"),
            document: .empty,
            annotations: [Annotation(author: "Robert", intent: .remove, note: "Cut this.",
                                     anchor: anchor(block: 1, start: 0, quote: "ninety (90) days"))])
        let markdown = ReviewExport.markdown(file)
        #expect(markdown.contains("Remove"))
        #expect(markdown.contains("Delete the quoted text."))
        #expect(markdown.contains("ninety (90) days"))
        #expect(markdown.contains("Cut this."))
        // The instruction to the reader about which anchor to trust is not optional.
        #expect(markdown.contains("searching for the quoted"))
    }

    @Test func resolvedItemsAreNotHandedBackAsWork() {
        var annotation = Annotation(author: "R", intent: .change, note: "done",
                                    anchor: anchor(block: 0, start: 0))
        annotation.status = .resolved
        let file = ReviewFile(
            source: SourceInfo(name: "s", path: nil, capturedAt: Date(), digest: ""),
            document: .empty, annotations: [annotation])
        #expect(!ReviewExport.markdown(file, filter: .open).contains("done"))
        #expect(ReviewExport.markdown(file, filter: .all).contains("Do not act on these"))
    }
}
