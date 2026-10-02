import Testing
import Foundation
import AppKit
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

    @Test func anInlineChartKeepsItsGeometryAndPaint() {
        // The shape of every chart in a generated report. Before SVG had a list of its own
        // this came out as `<svg><circle /><text>Fri</text></svg>` — an empty frame.
        let result = HTMLSanitizer.sanitize("""
        <svg viewBox="0 0 860 218"><defs><marker id="a" refX="5" refY="3" orient="auto">\
        <path d="M0 0L6 3L0 6z"/></marker></defs>\
        <circle cx="130" cy="58" r="6" fill="#2a78d6" stroke="#fff" stroke-width="2"/>\
        <line x1="1" y1="2" x2="3" y2="4" stroke-dasharray="5 5" marker-end="url(#a)"/>\
        <text x="130" y="38" font-size="12.5" text-anchor="middle">Fri</text></svg>
        """)
        for kept in ["viewbox=\"0 0 860 218\"", "cx=\"130\"", "r=\"6\"", "fill=\"#2a78d6\"",
                     "stroke-width=\"2\"", "d=\"M0 0L6 3L0 6z\"", "refx=\"5\"",
                     "orient=\"auto\"", "x1=\"1\"", "stroke-dasharray=\"5 5\"",
                     "x=\"130\"", "text-anchor=\"middle\"", "#a"] {
            #expect(result.body.contains(kept), "dropped \(kept)")
        }
        #expect(result.report.isClean)
    }

    @Test func svgShapesStayClosedAndHTMLDoesNotPretend() {
        // Without the slash the parser made the first `<line>` the parent of every shape
        // after it, and a line draws no children.
        let result = HTMLSanitizer.sanitize("""
        <svg viewBox="0 0 10 10"><line x1="0" y1="0" x2="1" y2="1"/>\
        <circle cx="5" cy="5" r="2"/><g><text>a</text></g></svg><div/><p>after</p>
        """)
        #expect(result.body.contains("<line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\" />"))
        #expect(result.body.contains("<circle cx=\"5\" cy=\"5\" r=\"2\" />"))
        #expect(result.body.contains("</svg>"))
        // Outside `<svg>` the slash is still not written: it would claim something the
        // HTML parser does not do.
        #expect(result.body.contains("<div>"))
    }

    @Test func anSVGAnimationCannotRewriteALink() {
        // The classic way past an href check: the link is clean when it is checked, and an
        // animation writes `javascript:` into it afterwards. `attributeName` is what names
        // the target, so it is the attribute that must never be kept.
        let result = HTMLSanitizer.sanitize("""
        <svg><a href="#ok"><set attributeName="href" to="javascript:alert(1)"/>\
        <animate attributeName="href" values="javascript:alert(1)"/><text>x</text></a></svg>
        """)
        #expect(!result.body.lowercased().contains("attributename"))
        #expect(!result.body.lowercased().contains(" to="))
    }

    @Test func svgPaintAndImagesCannotReachOutward() {
        let result = HTMLSanitizer.sanitize("""
        <svg><rect fill="url(https://x.example/p.svg#g)" filter="url('//x.example/f')"/>\
        <image href="https://x.example/i.png"/><use xlink:href="https://x.example/s.svg#a"/></svg>
        """)
        #expect(!result.body.contains("x.example/p"))
        #expect(!result.body.contains("x.example/f"))
        #expect(result.body.contains("fill=\"none\""))
        // Kept as a record, not as a live reference, the way a remote `<img>` is.
        #expect(!result.body.contains("href=\"https://x.example/i.png\""))
        #expect(result.body.contains("data-rv-blocked=\"https://x.example/i.png\""))
        #expect(result.report.remoteResources == 4)
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

/// The margin marks are rasterised SF Symbols. A symbol name that does not exist fails
/// silently — `NSImage(systemSymbolName:)` returns nil, the data URL comes back empty, and
/// the margin simply has nothing in it — so the names are checked rather than trusted.
@MainActor
struct AnnotationSymbolTests {

    /// Every state of every kind has a picture, and they are all different pictures.
    ///
    /// The last part is the one with a bug behind it: a draft's mark was drawn in Change's
    /// amber whatever kind was being written, so it announced itself as the wrong thing
    /// until the moment it was added. A per-intent key that quietly returned the same image
    /// for all seven would pass a test that only asked whether the key existed.
    @Test func everyIntentHasAMarkForEveryState() {
        let images = AnnotationSymbols.images()
        var seen: Set<String> = []
        for intent in Intent.allCases {
            for state in ["", ":current", ":resolved", ":pending"] {
                let key = intent.rawValue + state
                let image = images[key] ?? ""
                #expect(image.hasPrefix("data:image/png;base64,"), "no image for \(key)")
                #expect(image.count > 200, "image for \(key) is empty")
                seen.insert(image)
            }
        }
        // Six intents by four states, and no two of them the same picture. A per-intent
        // key that quietly returned the same image for all of them would satisfy every
        // check above and none of the point.
        #expect(seen.count == Intent.allCases.count * 4)
    }

    @Test func theSymbolNamesResolve() {
        for name in [AnnotationSymbols.disc, AnnotationSymbols.hollow,
                     AnnotationSymbols.pending, AnnotationSymbols.reply] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(name) is not an SF Symbol on this system")
        }
        // Every intent's own glyph, which the pane and the menu draw.
        for intent in Intent.allCases {
            #expect(NSImage(systemSymbolName: intent.symbol, accessibilityDescription: nil) != nil,
                    "\(intent.symbol) is not an SF Symbol on this system")
        }
    }
}
