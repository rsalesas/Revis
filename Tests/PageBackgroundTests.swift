import Testing
import Foundation
@testable import Revis

/// Reading the page background out of a document's stylesheet, and deciding what it means.
///
/// This is a small CSS reader, and a small CSS reader is wrong quietly: it does not throw,
/// it just paints the paper the wrong colour, and the failure looks like the app rather
/// than like the parse. So every shape it refuses is written down here beside every shape
/// it accepts.
@Suite("the document's page background")
struct PageBackgroundTests {

    // MARK: - What it takes

    @Test func takesABodyBackground() {
        #expect(PageBackground.declared(in: "body { background: #123456; }") == "#123456")
        #expect(PageBackground.declared(in: "body{background-color:#123456}") == "#123456")
    }

    @Test func takesHtmlAndRoot() {
        #expect(PageBackground.declared(in: "html { background: navy }") == "navy")
        #expect(PageBackground.declared(in: ":root { background: navy }") == "navy")
        #expect(PageBackground.declared(in: "html body { background: navy }") == "navy")
    }

    /// The real article's shape: the colour is a custom property three levels deep, and it
    /// is handed on unresolved for the browser to work out. Resolving it here would mean an
    /// oklch converter in Swift to answer a question WebKit answers for free.
    @Test func handsAVariableOnUnresolved() {
        let css = """
        :root { --brand: oklch(0.260 0.087 260); --canvas: var(--brand); }
        body { margin: 0; background: var(--canvas); color: #f0f0f0; }
        """
        #expect(PageBackground.declared(in: css) == "var(--canvas)")
    }

    /// Source order, not specificity. Predictable beats clever, and the common shape is one
    /// rule anyway.
    @Test func laterRuleWins() {
        let css = "body { background: white } body { background: black }"
        #expect(PageBackground.declared(in: css) == "black")
    }

    @Test func lastDeclarationInARuleWins() {
        #expect(PageBackground.declared(in: "body { background: white; background: black }")
                == "black")
    }

    @Test func stripsImportant() {
        #expect(PageBackground.declared(in: "body { background: navy !important; }") == "navy")
    }

    @Test func keepsAShorthandWhole() {
        let css = "body { background: #101820 url(data:image/gif;base64,AAA=) no-repeat }"
        #expect(PageBackground.declared(in: css)
                == "#101820 url(data:image/gif;base64,AAA=) no-repeat",
                "a semicolon inside a data URI is part of the value, not the end of it")
    }

    // MARK: - What it refuses

    /// A `@media (prefers-color-scheme: dark)` rule is not what the page renders: the web
    /// view is pinned to a light appearance so the guest resolves its LIGHT palette. Taking
    /// the dark branch would paint the sheet a colour the visible text was never chosen
    /// against — which is the exact bug this whole change exists to remove, reintroduced
    /// from the other end.
    @Test func ignoresAtRuleBlocks() {
        let css = """
        body { background: #ffffff }
        @media (prefers-color-scheme: dark) { body { background: #000000 } }
        """
        #expect(PageBackground.declared(in: css) == "#ffffff")
    }

    @Test func ignoresNestedAtRules() {
        let css = """
        @supports (display: grid) {
          @media print { body { background: red } }
        }
        body { background: blue }
        """
        #expect(PageBackground.declared(in: css) == "blue")
    }

    /// A narrower selector describes a condition we have not evaluated. `body.dark` paints
    /// the page only when something else put that class on it, and nothing here knows
    /// whether it did.
    @Test func ignoresNarrowerSelectors() {
        #expect(PageBackground.declared(in: "body.dark { background: black }") == nil)
        #expect(PageBackground.declared(in: "body > main { background: black }") == nil)
        #expect(PageBackground.declared(in: ".page { background: black }") == nil)
        #expect(PageBackground.declared(in: "body:hover { background: black }") == nil)
    }

    /// Every one of these means "show what is behind me", and what is behind the sheet is
    /// the desk — which the document does not get to paint.
    @Test func ignoresPassThroughKeywords() {
        for keyword in ["transparent", "none", "inherit", "initial", "unset", "currentColor"] {
            #expect(PageBackground.declared(in: "body { background: \(keyword) }") == nil,
                    "\(keyword) is not a colour to paint the sheet")
        }
    }

    @Test func ignoresAStylesheetWithNoPageRule() {
        #expect(PageBackground.declared(in: "h1 { color: red } p { margin: 0 }") == nil)
        #expect(PageBackground.declared(in: "") == nil)
        #expect(PageBackground.declared(in: "body { color: red }") == nil)
    }

    /// The value is emitted into a rule of ours. A value that can close that rule can write
    /// a new one, so anything carrying the syntax to do it is refused outright rather than
    /// escaped — there is nothing here worth the risk of escaping it wrongly.
    @Test func refusesAValueThatCouldCloseOurRule() {
        #expect(PageBackground.declared(in: "body { background: red } #rv-gutter { display: none")
                == "red", "the brace belongs to the next rule, not to the value")
        // Constructed to carry the syntax inside the value itself.
        #expect(PageBackground.honourable("red; } #rv-doc { display: none") == nil)
        #expect(PageBackground.honourable("red } @import url(x)") == nil)
        #expect(PageBackground.honourable("url(a") == nil, "unbalanced")
        #expect(PageBackground.honourable(String(repeating: "a", count: 401)) == nil)
    }

    /// A stylesheet the sanitizer left half-written must not take the reader with it.
    @Test func survivesUnbalancedInput() {
        #expect(PageBackground.declared(in: "body { background: red") == nil)
        #expect(PageBackground.declared(in: "} } } body { background: red }") == nil)
        // The scanner's quote handling, not the value guard: a brace inside a string must
        // not be read as the end of a rule, or every rule after it is mis-parsed and the
        // page background is silently lost.
        #expect(PageBackground.declared(
            in: "p::after { content: \"{\" } body { background: navy }") == "navy")
    }

    // MARK: - What a colour means

    /// The threshold is WCAG relative luminance at 0.18 — the point where white text starts
    /// to beat black on the same ground, which is exactly what the chrome needs to know.
    @Test func decidesWhichPaperNeedsTheDarkChrome() {
        #expect(PageBackground.isDark("rgba(7, 33, 77, 1)") == true, "the real article's navy")
        #expect(PageBackground.isDark("rgb(0, 0, 0)") == true)
        #expect(PageBackground.isDark("rgb(255, 255, 255)") == false)
        #expect(PageBackground.isDark("rgb(240, 240, 240)") == false)
        // Yellow is a light colour despite being saturated — luminance, not brightness.
        #expect(PageBackground.isDark("rgb(255, 255, 0)") == false)
    }

    /// An unreadable answer is not an answer. The chrome has assumed white paper since it
    /// was written, so anything it cannot parse leaves it there rather than guessing.
    @Test func refusesToGuessAtAnUnreadableColour() {
        #expect(PageBackground.isDark("oklch(0.26 0.087 260)") == nil,
                "the page converts this before sending it — see resolveColour in review.js")
        #expect(PageBackground.isDark("") == nil)
        #expect(PageBackground.isDark("navy") == nil)
        #expect(PageBackground.isDark("rgb(1, 2)") == nil)
    }

    /// A see-through sheet is showing the desk, and the desk is not the document's answer.
    @Test func aTransparentSheetIsNoAnswer() {
        #expect(PageBackground.isDark("rgba(0, 0, 0, 0)") == nil)
        #expect(PageBackground.isDark("rgba(0, 0, 0, 0.2)") == nil)
        #expect(PageBackground.isDark("rgba(0, 0, 0, 1)") == true)
    }
}

/// The seam between the reader and the page it paints.
@Suite("the sheet the document is drawn on")
struct SheetPaintTests {

    private func page(_ html: String, useDocumentCSS: Bool = true) -> String {
        DocumentShell.page(for: DocumentPrep.prepare(html: html, baseURL: nil),
                           chromeCSS: "", useDocumentCSS: useDocumentCSS)
    }

    @Test func aDarkDocumentPaintsItsOwnSheet() {
        let out = page("<html><head><style>body{background:#07214d;color:#fff}</style>"
                       + "</head><body><p>Hello</p></body></html>")
        #expect(out.contains("#rv-sheet { background: #07214d; }"))
    }

    /// The rule has to come after the document's own stylesheet: both name `#rv-sheet` at
    /// the same specificity, so source order settles it — and a `var()` in the value is
    /// defined in the block immediately above.
    @Test func theSheetRuleComesAfterTheDocumentsStylesheet() {
        let out = page("<html><head><style>:root{--c:#07214d}body{background:var(--c)}</style>"
                       + "</head><body><p>Hi</p></body></html>")
        guard let documentCSS = out.range(of: "--c:#07214d"),
              let sheetRule = out.range(of: "#rv-sheet { background:") else {
            Issue.record("expected both stylesheets on the page"); return
        }
        #expect(documentCSS.lowerBound < sheetRule.lowerBound)
    }

    /// In the reading style the document's CSS is not on the page at all, so there is no
    /// colour to take — and taking one would leave its ink and its paper disagreeing, which
    /// is the fault this whole change removes.
    @Test func theReadingStyleKeepsPaperWhite() {
        let out = page("<html><head><style>body{background:#07214d;color:#fff}</style>"
                       + "</head><body><p>Hi</p></body></html>", useDocumentCSS: false)
        #expect(!out.contains("#rv-sheet { background:"))
    }

    @Test func aDocumentThatDeclaresNoPageColourGetsNoRule() {
        let out = page("<html><head><style>p{color:red}</style></head><body><p>Hi</p></body></html>")
        #expect(!out.contains("#rv-sheet { background:"))
    }

    /// The colour is stored in the review beside the CSS it came from, so a review reopened
    /// later is drawn on the paper it was marked up on rather than on whatever the app
    /// would deduce today.
    @Test func theColourSurvivesBeingSavedAndReopened() throws {
        let prepared = DocumentPrep.prepare(
            html: "<html><head><style>body{background:#07214d}</style></head>"
                + "<body><p>Hi</p></body></html>", baseURL: nil)
        #expect(prepared.pageBackground == "#07214d")

        let file = ReviewFile(source: SourceInfo(name: "x.html", path: nil,
                                                capturedAt: Date(), digest: ""),
                              document: prepared)
        let data = try JSONEncoder.revis.encode(file)
        let back = try JSONDecoder.revis.decode(ReviewFile.self, from: data)
        #expect(back.document.pageBackground == "#07214d")
    }

    /// The decoder trap: `PreparedDocument` still uses the synthesised decoder, so a review
    /// written before this field existed has to keep opening. Optional is the one kind that
    /// survives being missing.
    @Test func aReviewWrittenBeforeThisFieldStillOpens() throws {
        let prepared = DocumentPrep.prepare(html: "<p>Hi</p>", baseURL: nil)
        let file = ReviewFile(source: SourceInfo(name: "x.html", path: nil,
                                                capturedAt: Date(), digest: ""),
                              document: prepared)
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder.revis.encode(file)) as! [String: Any]
        var document = json["document"] as! [String: Any]
        document.removeValue(forKey: "pageBackground")
        json["document"] = document

        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder.revis.decode(ReviewFile.self, from: data)
        #expect(back.document.pageBackground == nil)
        #expect(back.document.body.contains("Hi"), "the review itself still has to arrive")
    }
}
